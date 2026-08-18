package NOP.discrete

import org.scalatest.funsuite.AnyFunSuite

import spinal.core._
import spinal.core.sim._
import spinal.lib.bus.amba4.axi.sim._

import NOP._
import NOP.pipeline.core._
import NOP.pipeline.decode._

import java.nio.file.{Files, Paths}

/**
 * [stage1] RegisteredCommit(CM1/CM2 + 提交邮箱)与重定向消息链的全核定向测试。
 *
 * 方法:真实 mycpu_top 全核 SpinalSim(Verilator + xpm 行为模型 + AxiMemorySim),
 * 运行 test/resources/stage1_directed.bin(LoongArch32r 定向程序,覆盖:
 * ① 空 ROB 派发+立即误预测;② 背靠背误预测;③ flush 拍 wrong-path CM1 fire 与
 * 邮箱装载同拍(须被封锁);④ flush 落非空 ROB 中段(div 在飞行);LL/SC;
 * uncached load/store;syscall 异常提交 + ertn 回跳;多次 csrwr linearRecover)。
 *
 * 连续断言(每拍,设计书 A.4):
 *  - popPtrMonotone: 非 flush 后拍 popPtr 增量 ∈ {0..3};flush 后拍 popPtr == 0
 *  - flushMutex:     needFlush |-> !mboxWen(R1: flush 拍禁邮箱装载)
 *  - recoverQuiet:   regFlush  |-> !mboxValid(R3: recover 周期无提交动作)
 *  - noDoubleFlush:  needFlush |-> !$past(needFlush)(用例②: wrong-path 不得再 flush)
 *  - uncachedMutex:  mboxValid |-> $past(uncachedMask)=="111"
 *  - freeListConservation: freeList 占用 ∈ [0,32](含幽灵项 U(63) 既有行为);
 *    recover 后一拍必须为满(isFull)
 *
 * 功能自检:程序结束时向 0x1d000000/4/8 写 checksum/syscall 次数/DONE magic,
 * 测试比对内存内容(checksum=178, count=1, DONE=0x5a5a5a5a)。
 * 任何 wrong-path 副作用泄漏都会改变 checksum → 被内存比对捕获。
 */
object CommitChainSim {
  val DONE_ADDR = 0x1d000008L
  val CHECKSUM_ADDR = 0x1d000000L
  val SYSCALL_COUNT_ADDR = 0x1d000004L
  val DONE_MAGIC = 0x5a5a5a5aL
  val EXPECT_CHECKSUM = 178L
  val EXPECT_SYSCALL_COUNT = 1L
  val PROG_BASE = 0x1c000000L

  case class Stats(
      cycles: Long,
      retired: Long,
      flushes: Long,
      uncachedKicks: Long,
      commitStores: Long,
      done: Boolean
  )

  def read32(mem: SparseMemory, addr: Long): Long =
    (0 until 4).map(i => (mem.read(addr + i) & 0xff).toLong << (8 * i)).reduce(_ | _)

  def run(dut: MyCPU, maxCycles: Long): Stats = {
    val cd = ClockDomain(clock = dut.io.aclk, reset = dut.io.aresetn, config = ClockDomainConfig(resetActiveLevel = LOW))
    val axi = dut.io.axi

    // ---- 内存模型 ----
    val memCfg = AxiMemorySimConfig(
      maxOutstandingReads = 8,
      maxOutstandingWrites = 8,
      readResponseDelay = 0,
      writeResponseDelay = 0,
      interruptProbability = 0,
      interruptMaxDelay = 0
    )
    val mem = AxiMemorySim(axi, cd, memCfg)

    // ---- 装载定向程序 ----
    val bin = Files.readAllBytes(Paths.get("test/resources/stage1_directed.bin"))
    bin.zipWithIndex.foreach { case (b, i) => mem.memory.write(PROG_BASE + i, b) }

    mem.start()

    // ---- 时钟 ----
    fork {
      dut.io.aclk #= false
      while (true) {
        dut.io.aclk #= false; sleep(5)
        dut.io.aclk #= true; sleep(5)
      }
    }

    // ---- 静态输入 ----
    dut.io.intrpt #= 0
    dut.io.break_point #= false
    dut.io.infor_flag #= false
    dut.io.reg_num #= 0

    // ---- 复位:保持 ≥10 拍 ----
    dut.io.aresetn #= false
    cd.waitRisingEdge(12)
    dut.io.aresetn #= true

    // ---- 内部探针 ----
    // (stage1 复位网拆分后 MyCPUCore 是顶层直接成员)
    val core = dut.cpu
    val rob = core.service(classOf[ROBFIFOPlugin])
    val commit = core.service(classOf[CommitPlugin])
    val rename = core.decodePipeline.service(classOf[RenamePlugin])

    var prevPopPtr = 0
    var prevNeedFlush = false
    var prevRegFlush = false
    var prevUncachedMask = 7

    var cycle = 0L
    var retired = 0L
    var flushes = 0L
    var kicks = 0L
    var cstores = 0L
    var done = false

    while (cycle < maxCycles && !done) {
      cd.waitFallingEdge() // 避沿竞争,采样稳定值
      cycle += 1

      val popPtr = rob.popPtr.toInt
      val needFlush = commit.needFlush.toBoolean
      val regFlush = commit.regFlush.toBoolean
      val mboxValid = commit.probeMboxValid.toBoolean
      val mboxWen = commit.probeMboxWen.toBoolean
      val uncachedMask = commit.probeUncachedMask.toInt
      val kick = commit.probeUncachedKickReg.toBoolean
      val cstore = commit.commitStore.toBoolean

      // ---- 连续断言 ----
      if (prevNeedFlush) {
        assert(popPtr == 0, s"cycle $cycle: popPtr=$popPtr after flush, expect 0")
      } else {
        val delta = (popPtr - prevPopPtr) & 0x1f
        assert(delta <= 3, s"cycle $cycle: popPtr non-monotone, prev=$prevPopPtr now=$popPtr")
      }
      assert(!(needFlush && mboxWen), s"cycle $cycle: flushMutex violated (needFlush && mboxWen)")
      assert(!(regFlush && mboxValid), s"cycle $cycle: recoverQuiet violated (regFlush && mboxValid)")
      assert(!(needFlush && prevNeedFlush), s"cycle $cycle: noDoubleFlush violated")
      if (mboxValid) {
        assert(prevUncachedMask == 7, s"cycle $cycle: uncachedMutex violated, prevUncachedMask=$prevUncachedMask")
      }
      // freeList 守恒(口径 ≤32,含幽灵项 U(63) 的既有行为)
      val fPush = rename.freeList.pushPtr.toInt
      val fPop = rename.freeList.popPtr.toInt
      val fRising = rename.freeList.isRisingOccupancy.toBoolean
      val occ = if (fPush == fPop) (if (fRising) 32 else 0) else (fPush - fPop) & 0x1f
      assert(occ >= 0 && occ <= 32, s"cycle $cycle: freeList occ=$occ out of [0,32]")
      if (prevRegFlush) {
        assert(fPush == fPop && fRising,
          s"cycle $cycle: after recover freeList not full (push=$fPush pop=$fPop rising=$fRising)")
      }

      prevPopPtr = popPtr
      prevNeedFlush = needFlush
      prevRegFlush = regFlush
      prevUncachedMask = uncachedMask

      retired += Integer.bitCount(dut.io.DretireMask.toInt)
      if (needFlush) flushes += 1
      if (kick) kicks += 1
      if (cstore) cstores += 1

      // DONE 检测
      if ((cycle & 0x3ff) == 0 && read32(mem.memory, DONE_ADDR) == DONE_MAGIC) done = true
    }

    mem.stop()

    // ---- 功能自检:checksum / syscall 次数 / DONE magic ----
    if (done) {
      val checksum = read32(mem.memory, CHECKSUM_ADDR)
      val syscalls = read32(mem.memory, SYSCALL_COUNT_ADDR)
      assert(checksum == EXPECT_CHECKSUM,
        s"checksum=$checksum, expect $EXPECT_CHECKSUM (wrong-path 副作用泄漏或提交错误)")
      assert(syscalls == EXPECT_SYSCALL_COUNT,
        s"syscall count=$syscalls, expect $EXPECT_SYSCALL_COUNT (异常提交/ertn 路径错误)")
      println(s"[CommitChainSim] memory check OK: checksum=$checksum syscalls=$syscalls")
    }
    Stats(cycle, retired, flushes, kicks, cstores, done)
  }
}

/** scalatest 入口。 */
class CommitChainSimTest extends AnyFunSuite {
  test("stage1: RegisteredCommit mailbox directed program on full mycpu_top") {
    sys.props("nop.sim.xpm.model") = "1"
    val config = new MyCPUConfig()
    val compiled = SimConfig.compile(new MyCPU(config))
    compiled.doSim { dut =>
      val stats = CommitChainSim.run(dut, maxCycles = 300000)
      println(s"[CommitChainSim] cycles=${stats.cycles} retired=${stats.retired} " +
        s"flushes=${stats.flushes} uncachedKicks=${stats.uncachedKicks} commitStores=${stats.commitStores}")
      assert(stats.done, "program did not reach DONE within cycle budget")
      assert(stats.flushes >= 5, s"expected several redirects, got ${stats.flushes}")
      assert(stats.uncachedKicks >= 2, s"expected >=2 uncached kicks, got ${stats.uncachedKicks}")
      assert(stats.retired >= 40, s"expected >=40 retired instructions, got ${stats.retired}")
    }
  }
}

/** runMain 兜底入口:sbt "Test / runMain NOP.discrete.CommitChainSimMain" */
object CommitChainSimMain {
  def main(args: Array[String]): Unit = {
    sys.props("nop.sim.xpm.model") = "1"
    val compiled = SimConfig.compile(new MyCPU(new MyCPUConfig()))
    compiled.doSim { dut =>
      val stats = CommitChainSim.run(dut, maxCycles = 300000)
      println(s"[CommitChainSim] cycles=${stats.cycles} retired=${stats.retired} " +
        s"flushes=${stats.flushes} uncachedKicks=${stats.uncachedKicks} commitStores=${stats.commitStores}")
      assert(stats.done, "program did not reach DONE within cycle budget")
      println("CommitChainSimMain: PASS")
    }
  }
}
