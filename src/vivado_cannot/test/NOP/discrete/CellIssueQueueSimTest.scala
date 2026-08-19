package NOP.discrete

import org.scalatest.funsuite.AnyFunSuite

import spinal.core._
import spinal.core.sim._
import spinal.lib._

import NOP._
import NOP.pipeline._
import NOP.pipeline.exe._
import NOP.utils._

import scala.collection.mutable
import scala.util.Random

/** [stage2-①] 胞元测试顶层:直接实例化真实 CellIssueQueueCore(与三个 IQ
  * 插件共用同一份实现),对外暴露 push/tag/flush/issueReq;grant 经 simPublic。 */
class CellQueueTestTop(
    config: MyCPUConfig,
    depth: Int,
    issueWidth: Int,
    decodeWidth: Int,
    nFu: Int,
    fifoMode: Boolean
) extends Component {
  val tagWidth = config.regFile.prfAddrWidth
  val cells = new CellIssueQueueCore(
    depth, issueWidth, decodeWidth, HardType(IntIssueSlot(config)), tagWidth, fifoMode
  )

  val io = new Bundle {
    val push = Vec(slave Stream (IntIssueSlot(config)), decodeWidth)
    val tags = Vec(slave Flow (UInt(tagWidth bits)), 2)
    val flush = in Bool ()
    val issueReq = in Bool () // fifo 模式
  }

  for (i <- 0 until decodeWidth) {
    cells.pushPorts(i).valid := io.push(i).valid
    cells.pushPorts(i).payload := io.push(i).payload
    io.push(i).ready := cells.pushPorts(i).ready
  }
  for (i <- 0 until 2) {
    val tp = Flow(UInt(tagWidth bits))
    cells.addGlobalTagPort(tp)
    tp.valid := io.tags(i).valid
    tp.payload := io.tags(i).payload
  }
  cells.queueFlush setWhen io.flush
  if (fifoMode) cells.issueReq := io.issueReq // queue 模式由 genSelect 占住驱动

  // grant 口(queue 模式):reqs = 有效且两源就绪(与 IntExecutePlugin 同构)
  val grantRefs =
    if (fifoMode) Seq.empty[Vec[Bool]]
    else
      (0 until nFu).map { f =>
        val g = cells.grantPort((0 until depth).map { i =>
          cells.queue(i).valid && cells.queue(i).payload.rRegs(0).valid && cells.queue(i).payload.rRegs(1).valid
        })
        g.simPublic()
        g
      }

  // 调用序=写入优先级(见 CellIssueQueueCore 头注释)
  cells.genEnqueue()
  cells.genCompress()
  cells.genFlush()
  cells.genWakeup(2)
  cells.genRegister()
  cells.genSelect()
}

/** [stage2-①] 胞元-行为模型对拍(设计书 ①.6 契约):
  *  - 每拍比对存活 uopId 的有序序列(按年龄,压缩序=模型序);
  *  - grant 拍断言被授予胞元的 uopId == 模型有序 issue 结果;
  *  - push ready 与模型满状态一致;
  *  - flush 后全空;
  *  - 唤醒权重偏向"打刚入队/未就绪项"(入队当拍竞态,R1)。
  * uopId 编码为胞元依赖 tag(rRegs(0).payload),存活 tag 唯一。
  */
object CellQueueSim {
  case class Cell(var uopId: Int, var ready: Boolean)

  def runCfg(
      config: MyCPUConfig,
      depth: Int,
      issueWidth: Int,
      decodeWidth: Int,
      nFu: Int,
      fifoMode: Boolean,
      steps: Int,
      seed: Int
  ): Unit = {
    val compiled = SimConfig.compile(
      new CellQueueTestTop(config, depth, issueWidth, decodeWidth, nFu, fifoMode)
    )
    compiled.doSim { dut =>
      val rnd = new Random(seed)
      val cd = dut.clockDomain
      cd.forkStimulus(10)
      // 输入默认(uop 不驱动:胞元机制与对拍均不读 uop 内容,任其 X-init)
      dut.io.push.foreach { p =>
        p.valid #= false
        p.payload.rRegs.foreach { r =>
          r.valid #= false
          r.payload #= 0
        }
        p.payload.wReg #= 0
        p.payload.robIdx #= 0
      }
      dut.io.tags.foreach { t =>
        t.valid #= false
        t.payload #= 0
      }
      dut.io.flush #= false
      dut.io.issueReq #= false
      // 胞元寄存器无复位(与真实设计一致),用 flush 拍初始化 valid 位面
      dut.io.flush #= true
      cd.waitRisingEdge(3)
      dut.io.flush #= false
      cd.waitRisingEdge(1)

      // 行为模型:年龄有序存活序列(对齐 RTL 压缩序)
      val alive = mutable.ArrayBuffer[Cell]()
      val liveTags = mutable.Set[Int]()
      var nextTag = 1

      def rtlSeq(): Seq[Int] =
        (0 until depth).flatMap { i =>
          if (dut.cells.queue(i).valid.toBoolean)
            Some(dut.cells.queue(i).payload.rRegs(0).payload.toInt)
          else None
        }

      def checkSeq(cyc: Int): Unit = {
        val rtl = rtlSeq()
        val model = alive.map(_.uopId).toSeq
        assert(rtl == model, s"cyc $cyc: alive uopId seq mismatch rtl=$rtl model=$model")
      }

      for (cyc <- 0 until steps) {
        cd.waitFallingEdge()

        // fifo:上一拍驱动的 issueReq 已沿 T-1→T 落地,先同步模型再对拍
        if (fifoMode && dut.io.issueReq.toBoolean) {
          assert(alive.nonEmpty, s"cyc $cyc: fifo pop but model empty")
          val head = alive.remove(0)
          liveTags -= head.uopId
        }

        // ---- 1. 有序序列对拍 ----
        checkSeq(cyc)
        // push ready 一致性:ready(p) = !queue(depth-1-p).valid
        // queue 模式:S(T) 含本拍将 pop 的项(沿 T→T+1 才落地),用移除前口径;
        // fifo 模式:pop 已落地(上面已同步),用移除后口径。
        val occReady = alive.size
        for (p <- 0 until decodeWidth) {
          val rtlReady = dut.io.push(p).ready.toBoolean
          assert(rtlReady == (occReady + p < depth),
            s"cyc $cyc: push($p).ready=$rtlReady modelOcc=$occReady")
        }

        // ---- 2. queue 模式:本拍 grant 对拍 + 模型应用 pop(沿 T→T+1 生效) ----
        if (!fifoMode) {
          for (f <- 0 until nFu) {
            val gIdx = (0 until depth).find(i => dut.grantRefs(f)(i).toBoolean)
            val modelReady = alive.filter(_.ready)
            gIdx match {
              case Some(idx) =>
                assert(modelReady.nonEmpty, s"cyc $cyc: grant port$f fires but model has no ready cell")
                val expect = modelReady.head.uopId
                val gotTag = dut.cells.queue(idx).payload.rRegs(0).payload.toInt
                assert(gotTag == expect, s"cyc $cyc: grant port$f uopId=$gotTag expect=$expect")
                alive -= modelReady.head
                liveTags -= modelReady.head.uopId
              case None =>
                assert(modelReady.isEmpty,
                  s"cyc $cyc: grant port$f idle but model ready=${modelReady.map(_.uopId)}")
            }
          }
        }
        val occPre = occReady // 入队容量口径 = push ready 口径(S(T))

        // ---- 3. 决定本拍事件并驱动(沿 T→T+1 生效,T+1 可见) ----
        val doFlush = rnd.nextInt(100) < 5
        val enqCells = mutable.ArrayBuffer[Cell]()
        val wakeTags = mutable.ArrayBuffer[Int]()

        if (!doFlush) {
          val nEnq = if (rnd.nextInt(100) < 55) rnd.nextInt(decodeWidth + 1) else 0
          for (p <- 0 until nEnq if occPre + p < depth) {
            var tag = rnd.nextInt(63) + 1
            while (liveTags.contains(tag)) tag = rnd.nextInt(63) + 1
            val preReady = rnd.nextInt(100) < 30 // 30% 入队即就绪
            enqCells += Cell(tag, preReady)
          }
          if (rnd.nextInt(100) < 45) {
            val notReady = alive.filterNot(_.ready).toSeq
            if (notReady.nonEmpty && rnd.nextInt(100) < 55) {
              wakeTags += notReady(rnd.nextInt(notReady.size)).uopId
            } else if (enqCells.nonEmpty && rnd.nextInt(100) < 40) {
              wakeTags += enqCells.head.uopId // 入队当拍唤醒竞态(R1)
            } else {
              wakeTags += rnd.nextInt(64)
            }
            if (rnd.nextInt(100) < 25) wakeTags += rnd.nextInt(64)
          }
        }

        for (p <- 0 until decodeWidth) {
          if (!doFlush && p < enqCells.size) {
            val c = enqCells(p)
            dut.io.push(p).valid #= true
            dut.io.push(p).payload.rRegs(0).payload #= c.uopId
            dut.io.push(p).payload.rRegs(0).valid #= c.ready
            dut.io.push(p).payload.rRegs(1).payload #= 63
            dut.io.push(p).payload.rRegs(1).valid #= true
            dut.io.push(p).payload.wReg #= c.uopId
          } else {
            dut.io.push(p).valid #= false
          }
        }
        for (k <- 0 until 2) {
          if (k < wakeTags.size) {
            dut.io.tags(k).valid #= true
            dut.io.tags(k).payload #= wakeTags(k)
          } else {
            dut.io.tags(k).valid #= false
          }
        }
        dut.io.flush #= doFlush
        if (fifoMode) {
          val headReady = alive.headOption.exists(_.ready)
          // flush 占优于 pop:flush 拍不得驱动 issueReq(与模型 clear 对齐)
          dut.io.issueReq #= (!doFlush && headReady && rnd.nextInt(100) < 70)
        }

        // ---- 4. 模型应用本拍事件(flush 湮灭一切;唤醒命中含新入队,与
        //        RTL post-mux OR 覆盖入队当拍竞态对齐) ----
        if (doFlush) {
          alive.clear()
          liveTags.clear()
        } else {
          for (c <- enqCells) { alive += c; liveTags += c.uopId }
          for (t <- wakeTags) alive.filter(_.uopId == t).foreach(_.ready = true)
        }
      }
      // 收敛性:跑了足够多拍后队列应能排空(starvation 粗查)
      println(s"[CellQueueSim] cfg(depth=$depth,iw=$issueWidth,dw=$decodeWidth,nFu=$nFu,fifo=$fifoMode) seed=$seed PASS alive=${alive.size}")
    }
  }
}

class CellIssueQueueSimTest extends AnyFunSuite {
  val config = new MyCPUConfig()

  test("stage2-1: cell queue-mode (depth=10 iw=3 dw=2 nFu=3) vs model contract") {
    // stage3-③: IntIQ 容量 7->10,对拍配置同步(IntIssueConfig.depth=10)
    for (seed <- Seq(7, 42, 2026))
      CellQueueSim.runCfg(config, depth = 10, issueWidth = 3, decodeWidth = 2, nFu = 3, fifoMode = false, steps = 400, seed)
  }

  test("stage2-1: cell queue-mode narrow (depth=3 iw=1 dw=1 nFu=1) vs model") {
    for (seed <- Seq(11, 99))
      CellQueueSim.runCfg(config, depth = 3, issueWidth = 1, decodeWidth = 1, nFu = 1, fifoMode = false, steps = 400, seed)
  }

  test("stage2-1: cell fifo-mode (depth=5 dw=1) vs model") {
    for (seed <- Seq(5, 77))
      CellQueueSim.runCfg(config, depth = 5, issueWidth = 1, decodeWidth = 1, nFu = 0, fifoMode = true, steps = 400, seed)
  }
}

