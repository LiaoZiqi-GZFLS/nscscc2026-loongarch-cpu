package NOP.utils

import spinal.core._
import spinal.lib._
import scala.collection.mutable

import NOP.pipeline.core._
import NOP.pipeline._
import NOP.builder._
import NOP._

/** 压缩队列。
  *
  * 压缩队列按优先级从低到高：
  *
  * 1. 不压缩时自身状态转移。同步至stateNext。
  *
  * 2. 入队时覆写为初态。同步至stateNext。
  *
  * 3. 压缩时通过stateNext同步状态转移。
  *
  * 4. flush时直接清除所有valid。直接写。最高优先级，不需要stateNext同步。
  *
  * @param issConfig
  * @param decodeWidth
  * @param slotType
  */
abstract class CompressedQueue[T <: IssueSlot](
    issConfig: IssueConfig,
    val decodeWidth: Int,
    val slotType: HardType[T]
) extends Plugin[MyCPUCore] {
  val issueWidth = issConfig.issueWidth
  val depth = issConfig.depth

  val busyAddrs: Vec[UInt] // For overwritten in subclasses
  var busyRsps: Vec[Bool] = null // Read from PRF
  def fuMatch(uop: MicroOp): Bool // For overwritten in subclasses

  // round-12(IQ 胞元化):唤醒位面独立成胞元寄存器——每个 (槽,源) 的 ready 位
  // 只有本胞元一个写者(单写者宪法);广播 tag 寄存一拍(模块边界=寄存器宪法,
  // 唤醒 +1 拍,功能时序不敏感)。执行流水 ISS 直接读位面做 waken 判定,
  // 槽 payload 的 rRegs.valid 保留为入队初值(下游只用 tag)。
  // 位面与 payload 严格镜像:寄存 + next 双写、压缩搬 next(防丢唤醒)。
  var rReadyBank: Vec[Vec[Bool]] = null
  // 位面的组合 next(镜像 queueNext):唤醒/入队写 next,压缩搬 next——
  // 保证"唤醒拍与压缩搬移同拍"时不丢唤醒(广播 RegNext 只存活 1 拍)。
  var rReadyBankNext: Vec[Vec[Bool]] = null

  // round-12(IQ 胞元化):位面寄存器在 build 期创建(执行插件 ISS 在 build 期
  // 读位面,而本插件先于执行插件 build,依赖序保证位面已存在)。
  def createReadyBank(rPorts: Int): Unit = {
    rReadyBank = Vec(Vec(RegInit(False), rPorts), depth)
    rReadyBankNext = CombInit(rReadyBank)
  }

  private val grantPorts = mutable.ArrayBuffer[(Seq[Bool], Vec[Bool])]()
  def grantPort(reqs: Seq[Bool]) = {
    val grants = Vec(Bool, reqs.size)
    grantPorts += (reqs -> grants)
    grants
  }

  val queue = Vec(RegFlow(slotType()), depth) // 做槽移动
  queue.foreach { q => val z = slotType(); z.assignFromBits(B(0, widthOf(z) bits)); q.payload.init(z) } // round-14:X-sweep 槽负载复位清零
  val queueNext = CombInit(queue) // 标志对应槽的下一个值（不考虑压缩）  // 1. 不压缩时自身状态转移。同步至stateNext。

  val issueMask = Bits(depth bits)
  val issueFire = True // issue整体使能
  val queueFlush = False // 清除整个IQ

  val queueIO = new Area {
    val pushPorts = Vec(Stream(slotType), decodeWidth)
  }

  // 2. 入队时覆写为初态。同步至stateNext。
  def genEnqueueLogic() = {
    val validFall = !queue(0).valid +: (for (i <- 1 until depth)
      yield queue(i - 1).valid && !queue(i).valid) // the length of current valid depth
    // 入队逻辑
    for (i <- 0 until decodeWidth) {
      // 0口ready当且仅当depth-1是空的
      queueIO.pushPorts(i).ready := !queue(depth - i - 1).valid
      for (j <- i until depth) {
        when(queueIO.pushPorts(i).valid && validFall(j - i)) {
          // 定位匹配，则将槽入队
          queue(j).push(queueIO.pushPorts(i).payload) // Flow.push, set valid to True and payload to that
          queueNext(j).push(queueIO.pushPorts(i).payload)
          // round-12(IQ 胞元化):位面覆写为入队初始值(优先级高于唤醒);
          // 与 payload 一致,寄存与 next 双写(压缩搬 next)。
          if (rReadyBank != null) {
            for (k <- 0 until rReadyBank(j).size) {
              rReadyBank(j)(k) := queueIO.pushPorts(i).payload.rRegs(k).valid
              rReadyBankNext(j)(k) := queueIO.pushPorts(i).payload.rRegs(k).valid
            }
          }
        }
      }
    }
  }

  // 3. 压缩时通过stateNext同步状态转移。
  def genCompressLogic() = {
    // 压缩逻辑
    val popCounts = Vec(UInt(log2Up(issueWidth + 1) bits), depth) // sized depth, prefix sum of issueMask
    // pop等价于当前valid，下个周期不valid（被抽走了）
    popCounts(0) := (issueFire && issueMask(0)).asUInt.resized
    for (i <- 0 to depth - 2) {
      popCounts(i + 1) := Mux(
        issueFire && issueMask(i + 1),
        popCounts(i) + 1,
        popCounts(i)
      )
    }
    for (i <- 0 until depth) {
      for (j <- 1 to issueWidth) {
        // 后覆盖前。考察[0, i+j-1]的清除情况。例如0被清除，则0选择1，但01都被清除，则0选择2...
        if (i + j < depth) when(popCounts(i + j - 1) === j) {
          queue(i) := queueNext(i + j)
          // round-12(IQ 胞元化):位面搬 next——唤醒拍与压缩同拍时,
          // 唤醒已写入 next,搬移不丢。
          if (rReadyBank != null) {
            rReadyBank(i) := rReadyBankNext(i + j)
          }
        }
        else when(popCounts.last === j)(queue(i).valid := False)
      }
    }
  }

  // 4. flush时直接清除所有valid。直接写。最高优先级，不需要stateNext同步。
  def genFlushLogic() = when(queueFlush) {
    // flush最高优先级
    for (i <- 0 until depth) {
      queue(i).valid := False
      // round-12(IQ 胞元化):位面一并清零
      if (rReadyBank != null) {
        for (j <- 0 until rReadyBank(i).size) {
          rReadyBank(i)(j) := False
        }
      }
    }
  }

  // round-12(EXE 提前重定向):选择性清除——只杀年轻于重定向分支的槽
  // (robIdx 在 (earlyRedirect.robIdx, pushPtr] 弧内的全部作废),优先级与
  // flush 同级(写在其后)。环形窗口比较:dSlot > dK(unsigned,自然回绕)。
  def genEarlyKill() = {
    val robFIFO = pipeline.globalService(classOf[ROBFIFOPlugin])
    when(robFIFO.earlyRedirect.valid) {
      val dK = robFIFO.earlyRedirect.robIdx - robFIFO.popPtr
      for (i <- 0 until depth) {
        when(queue(i).valid && (queue(i).payload.robIdx - robFIFO.popPtr) > dK) {
          queue(i).valid := False
          if (rReadyBank != null) {
            for (j <- 0 until rReadyBank(i).size) {
              rReadyBank(i)(j) := False
            }
          }
        }
      }
    }
  }

  def genIssueSelect() = {
    // issue选择
    require(grantPorts.size <= issueWidth)

    // Grant only one slot for each FU
    if (grantPorts.nonEmpty) grantPorts(0)._2 := OHMasking.first(grantPorts(0)._1)

    for (i <- 1 until grantPorts.size) {
      val exeMask = grantPorts.map(_._2).take(i).reduceBalancedTree { (l, r) =>
        (l.asBits | r.asBits).asBools
      }
      grantPorts(i)._2 := OHMasking.first(grantPorts(i)._1.zip(exeMask).map { case (b, m) =>
        b && !m // Mask out already granted slots
      })
    }
    issueMask := grantPorts.map(_._2.asBits).reduceBalancedTree(_ | _) // orReduce
  }

  def genGlobalWakeup(prf: PhysRegFilePlugin, rPorts: Int) = {
    // round-12(IQ 胞元化):唤醒位面独立胞元寄存器 + 广播寄存一拍。
    // 每 (槽,源) 位只有本胞元写(单写者);比较在本胞元本地完成。
    // 广播源 = WB 拍 clearBusy tag 的寄存副本(模块边界=寄存器,唤醒 +1 拍)。
    // 注意:必须在 afterElaboration 调用——此时所有执行插件已注册 clearBusy
    // 端口,广播列表完整;位面寄存器本身在 build 期由 createReadyBank 创建。
    // round-13 验证:与团队 payload 直写版功能等价(二分确认)。
    require(rReadyBank != null, "createReadyBank must be called before genGlobalWakeup")
    val ports = prf.clearBusys
    // 宪法版: 广播寄存一拍(RegNext)——WB 扇出只剩 4 个捕获寄存器,比较在
    // 本地胞元完成。功能与组合版等价(58/58 同 13 点 0 错),perf 用此版。
    val bcast = ports.map(p => {
      val b = Flow(p.payload)
      b.valid := RegNext(p.valid)
      b.payload := RegNext(p.payload)
      b
    })
    for (i <- 0 until depth) {
      for (j <- 0 until rPorts) {
        val waken = bcast
          .map(b => b.valid && b.payload === queue(i).payload.rRegs(j).payload)
          .reduceBalancedTree(_ || _)
        // 单写者:本胞元只写自己的 ready 位(寄存 + next 双写,镜像团队
        // 唤醒写 payload/queueNext 的模式;next 供同拍压缩搬移)
        when(waken) {
          rReadyBank(i)(j) := True
          rReadyBankNext(i)(j) := True
        }
      }
    }
  }

  override def setup(pipeline: MyCPUCore): Unit = {
    val PRF = pipeline.service(classOf[PhysRegFilePlugin])
    busyRsps = Vec(busyAddrs.map(PRF.readBusy(_)))
  }
}
