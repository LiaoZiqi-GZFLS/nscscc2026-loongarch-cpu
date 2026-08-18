package NOP.discrete

import org.scalatest.funsuite.AnyFunSuite

import spinal.core._
import spinal.core.sim._
import spinal.lib.bus.amba4.axi.sim._

import NOP._
import NOP.pipeline.core._
import NOP.pipeline.fetch._

import java.nio.file.{Files, Paths}

/**
 * [stage2-③] EXE 提前重定向(R9 flush 分裂协议)的全核定向测试。
 *
 * 方法:复用 CommitChainSim 的 harness 与 stage1_directed.bin(覆盖:背靠背误预测
 * ②/空 ROB 立即误预测①/flush 拍 wrong-path 邮箱装载③/uncached/LL·SC/syscall+ertn/
 * csrwr linearRecover)。开关开/关各跑一遍(回退档 A/B)。
 *
 * 连续断言(每拍,对应设计书 ③.3 四不变量 + R11 + 勘误 #3):
 *  - R9-1 holdWindow:   holdDispatch |-> !RENAME fire(冻结 rename/dispatch)
 *  - R9-1 set:          exeRedirectFire |-> 次拍 holdDispatch=1
 *  - R9-1 release:      holdDispatch 持续 ≤20 拍(提交路径兜底,不死锁);结束时必为 0
 *  - R9-3 priority:     jumpPipe 与 exeJumpPipe 同拍到达且 IF1 未卡 ->
 *                       次拍 regPC == jumpPipe.payload(T-③e 优先级)
 *  - 时序链:            exeRedirectFire |-> 次拍 exeJumpPipe.valid(m2sPipe 副本)
 *  - flush 分裂:        earlyResolved 误预测提交拍 flushBackend 必发、flushFrontend
 *                       被门控(计数 gate 抑制事件,须 ≥1 证明 T-③ 门控真实生效)
 *  - R11 GHR:           commitGhrFire && exeGhrFire 同拍 -> updateGHR.payload ==
 *                       commit 恢复值(提交 > EXE 修复 > 投机移位)
 *  - 勘误 #3:           holdDispatch 窗口内不得再有 exeRedirectFire(嵌套压制)
 *  - 功能:              DONE/checksum/syscall 计数与基线逐值一致
 *
 * 关态(=阶段 1 行为)断言:exeRedirect 恒 0;flushFrontend ≡ flushBackend(≡原 needFlush)。
 */
object EarlyRedirectSim {
  import CommitChainSim._

  case class Stats(
      cycles: Long,
      retired: Long,
      flushes: Long,
      exeRedirects: Long,
      ghrRestores: Long,
      frontendGates: Long, // earlyResolved 提交且 flushFrontend 被抑制次数
      done: Boolean
  )

  def run(dut: MyCPU, maxCycles: Long, expectOn: Boolean): Stats = {
    val cd = ClockDomain(clock = dut.io.aclk, reset = dut.io.aresetn, config = ClockDomainConfig(resetActiveLevel = LOW))
    val axi = dut.io.axi

    val memCfg = AxiMemorySimConfig(
      maxOutstandingReads = 8,
      maxOutstandingWrites = 8,
      readResponseDelay = 0,
      writeResponseDelay = 0,
      interruptProbability = 0,
      interruptMaxDelay = 0
    )
    val mem = AxiMemorySim(axi, cd, memCfg)
    val bin = Files.readAllBytes(Paths.get("test/resources/stage1_directed.bin"))
    bin.zipWithIndex.foreach { case (b, i) => mem.memory.write(PROG_BASE + i, b) }
    mem.start()

    fork {
      dut.io.aclk #= false
      while (true) {
        dut.io.aclk #= false; sleep(5)
        dut.io.aclk #= true; sleep(5)
      }
    }

    dut.io.intrpt #= 0
    dut.io.break_point #= false
    dut.io.infor_flag #= false
    dut.io.reg_num #= 0

    dut.io.aresetn #= false
    cd.waitRisingEdge(12)
    dut.io.aresetn #= true

    // ---- 探针 ----
    val core = dut.cpu
    val commit = core.service(classOf[CommitPlugin])
    val pc = core.fetchPipeline.service(classOf[ProgramCounterPlugin])
    val btb = core.fetchPipeline.service(classOf[GlobalPredictorBTBPlugin])

    var cycle = 0L
    var retired = 0L
    var flushes = 0L
    var exeRedirects = 0L
    var ghrRestores = 0L
    var frontendGates = 0L
    var done = false

    var prevExeFire = false
    var prevFlushFrontend = false
    var prevBothJump = false
    var prevBothJumpTarget = 0L
    var prevBothJumpStuck = false
    var holdSince = -1L

    while (cycle < maxCycles && !done) {
      cd.waitFallingEdge()
      cycle += 1

      val exeFire = commit.probeExeRedirectFire.toBoolean
      val hold = commit.probeHoldDispatch.toBoolean
      val flushB = commit.probeFlushBackend.toBoolean
      val flushF = commit.probeFlushFrontend.toBoolean
      val earlyCommit = commit.probeEarlyMispredictCommit.toBoolean
      val renameFire = commit.probeRenameFire.toBoolean
      val ghrFire = commit.probeExeGhrRestoreFire.toBoolean
      val jumpV = pc.probeJumpPipeValid.toBoolean
      val exeJumpV = pc.probeExeJumpPipeValid.toBoolean
      val stuck = pc.probeIf1Stuck.toBoolean
      val updGhrV = btb.probeUpdateGhrValid.toBoolean
      val updGhrP = btb.probeUpdateGhrPayload.toLong
      val exeGhrF = btb.probeExeGhrFire.toBoolean
      val commitGhrF = btb.probeCommitGhrFire.toBoolean
      val commitGhrV = btb.probeCommitGhrValue.toLong

      // ---- R9-1: hold 期间冻结 rename ----
      assert(!(hold && renameFire), s"cycle $cycle: R9-1 violated (holdDispatch && RENAME fire)")
      // ---- R9-1: set 时序 ----
      if (prevExeFire) assert(hold, s"cycle $cycle: exeRedirectFire 次拍 holdDispatch 未置位")
      // ---- 勘误 #3: hold 窗口内不得二次早重定向 ----
      assert(!(hold && exeFire), s"cycle $cycle: 勘误#3 压制失效 (holdDispatch && exeRedirectFire)")
      // ---- 时序链: T_e+1 exeJumpPipe 到达 ----
      if (prevExeFire) assert(exeJumpV, s"cycle $cycle: exeRedirectFire 次拍 exeJumpPipe.valid 未到")
      // ---- R9-1 release 兜底(不死锁) ----
      if (hold) {
        if (holdSince < 0) holdSince = cycle
        assert(cycle - holdSince <= 20, s"cycle $cycle: holdDispatch 持续 ${cycle - holdSince} 拍未释放")
      } else holdSince = -1
      // ---- R9-3/T-③e: 同拍优先级,次拍 regPC 必须取 jumpPipe.payload ----
      if (prevBothJump && !prevBothJumpStuck) {
        val rpc = pc.probeRegPC.toLong
        assert(rpc == prevBothJumpTarget,
          s"cycle $cycle: R9-3 优先级违例, regPC=0x${rpc.toHexString} expect jumpPipe=0x${prevBothJumpTarget.toHexString}")
      }
      prevBothJump = jumpV && exeJumpV
      prevBothJumpTarget = pc.probeJumpPipeTarget.toLong
      prevBothJumpStuck = stuck
      // ---- flush 分裂: earlyResolved 提交拍 flushBackend 必发;flushFrontend 被门控 ----
      if (earlyCommit) {
        assert(flushB, s"cycle $cycle: earlyResolved 误预测提交未发 flushBackend")
        if (!flushF) frontendGates += 1
      }
      // ---- R11: GHR 三写者同拍优先级(提交 > EXE 修复) ----
      if (exeGhrF && commitGhrF) {
        assert(updGhrV, s"cycle $cycle: R11 同拍但 updateGHR 未写")
        assert(updGhrP == commitGhrV,
          s"cycle $cycle: R11 优先级违例, updateGHR.payload=0x${updGhrP.toHexString} expect commit=0x${commitGhrV.toHexString}")
      }
      // ---- 关态不变量: 逐拍等价阶段 1 ----
      if (!expectOn) {
        assert(!exeFire, s"cycle $cycle: 关态下 exeRedirectFire 置位")
        assert(flushF == flushB, s"cycle $cycle: 关态下 flushFrontend != flushBackend")
      }

      prevExeFire = exeFire
      prevFlushFrontend = flushF

      retired += Integer.bitCount(dut.io.DretireMask.toInt)
      if (flushB) flushes += 1
      if (exeFire) exeRedirects += 1
      if (ghrFire) ghrRestores += 1

      if ((cycle & 0x3ff) == 0 && read32(mem.memory, DONE_ADDR) == DONE_MAGIC) done = true
    }

    mem.stop()

    if (done) {
      val checksum = read32(mem.memory, CHECKSUM_ADDR)
      val syscalls = read32(mem.memory, SYSCALL_COUNT_ADDR)
      assert(checksum == EXPECT_CHECKSUM,
        s"checksum=$checksum, expect $EXPECT_CHECKSUM (wrong-path 副作用泄漏或提交错误)")
      assert(syscalls == EXPECT_SYSCALL_COUNT,
        s"syscall count=$syscalls, expect $EXPECT_SYSCALL_COUNT (异常提交/ertn 路径错误)")
    }
    assert(!commit.probeHoldDispatch.toBoolean, "sim 结束时 holdDispatch 未释放")
    Stats(cycle, retired, flushes, exeRedirects, ghrRestores, frontendGates, done)
  }
}

/** scalatest 入口(开/关两遍)。 */
class EarlyRedirectSimTest extends AnyFunSuite {
  test("stage2-3: EXE early redirect directed program (switch ON)") {
    sys.props("nop.sim.xpm.model") = "1"
    val compiled = SimConfig.compile(new MyCPU(new MyCPUConfig())) // 默认 enableEarlyRedirect=true
    compiled.doSim { dut =>
      val stats = EarlyRedirectSim.run(dut, maxCycles = 300000, expectOn = true)
      println(s"[EarlyRedirectSim:ON] cycles=${stats.cycles} retired=${stats.retired} " +
        s"flushes=${stats.flushes} exeRedirects=${stats.exeRedirects} " +
        s"ghrRestores=${stats.ghrRestores} frontendGates=${stats.frontendGates}")
      assert(stats.done, "program did not reach DONE within cycle budget")
      // T-③a: 早重定向确实发生
      assert(stats.exeRedirects >= 1, s"expected >=1 exe early redirects, got ${stats.exeRedirects}")
      // 每次早重定向都应伴随一次 GHR 修复(WB 拍;允许 flush 碰撞吞掉 ≤2 次)
      assert(stats.ghrRestores >= 1 && stats.exeRedirects - stats.ghrRestores <= 2,
        s"GHR restore 计数异常: exe=${stats.exeRedirects} ghr=${stats.ghrRestores}")
      // flush 分裂门控真实生效(早 resolved 误预测提交且前端未再冲刷)
      assert(stats.frontendGates >= 1, s"expected >=1 flushFrontend gate suppressions, got ${stats.frontendGates}")
      assert(stats.retired >= 40, s"expected >=40 retired instructions, got ${stats.retired}")
    }
  }

  test("stage2-3: EXE early redirect switch OFF regression (=stage1 behavior)") {
    sys.props("nop.sim.xpm.model") = "1"
    val cfg = new MyCPUConfig().copy(
      frontend = FrontendConfig(enableEarlyRedirect = false)
    )
    val compiled = SimConfig.compile(new MyCPU(cfg))
    compiled.doSim { dut =>
      val stats = EarlyRedirectSim.run(dut, maxCycles = 300000, expectOn = false)
      println(s"[EarlyRedirectSim:OFF] cycles=${stats.cycles} retired=${stats.retired} flushes=${stats.flushes}")
      assert(stats.done, "OFF: program did not reach DONE within cycle budget")
      assert(stats.exeRedirects == 0, s"OFF: exeRedirect fired ${stats.exeRedirects} times")
      // 关态功能等价阶段 1(checksum/syscall 已在 run 内比对)
      assert(stats.retired >= 40 && stats.flushes >= 5,
        s"OFF: retired=${stats.retired} flushes=${stats.flushes} 异常")
    }
  }
}
