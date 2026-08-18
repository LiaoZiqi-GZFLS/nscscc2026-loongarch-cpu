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
 * [stage2-②] 译码 3 拍化（ID1=FB pop 寄存 / ID2=65 路匹配+字段 mux / ID3=epilogue）
 * 的全核定向测试。复用 CommitChainSimTest 的 harness 模式与 stage1_directed.bin
 * （覆盖误预测/syscall+ertn/CSR 写/uncached/LL·SC，恰好压满 epilogue 全路径）。
 *
 * 三拍化结构断言（每拍，设计书 ②.5：无复制/丢失）：
 *  - 包守恒：ID1 流入 lane 数 - ID3 流出 lane 数的在飞累计 ∈ [0, 9]（3 lane × 3 级）；
 *    flush 拍在飞清零（ID1/ID2/ID3 经 isFlushed 同拍移除，入/出计数均为 0）。
 *  - 流水推进：ID1/ID2/ID3 三级各自的 fire 计数 > 0（证明三级都在流动）。
 *  - 复位气泡：程序流开始时 ID2/ID3 必然后于 ID1 出现首次 fire（深度证据）。
 *
 * 功能自检与 CommitChainSimTest 相同：checksum=178 / syscall 次数=1 / DONE magic，
 * 译码任何字段错误（含 epilogue 覆盖、异常子码、Timer/CSR 改写）都会改变退休序列
 * 或内存内容而被捕获。
 */
object Decode3StageSim {
  import CommitChainSim._

  case class Probes(
      id1Fire: spinal.core.Bool,
      id2Fire: spinal.core.Bool,
      id3Fire: spinal.core.Bool,
      id1LaneValid: spinal.core.Bits,
      id3PacketValid: spinal.core.Bits,
      needFlush: spinal.core.Bool
  )

  def run(dut: MyCPU, maxCycles: Long): Stats = {
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

    // ---- 译码三级探针（DecoderArrayPlugin 内 simPublic 暴露）----
    val core = dut.cpu
    val dp = core.decodePipeline
    val decArray = dp.service(classOf[DecoderArray])
    val probes = Probes(
      id1Fire = decArray.probeId1Fire,
      id2Fire = decArray.probeId2Fire,
      id3Fire = decArray.probeId3Fire,
      id1LaneValid = decArray.probeId1LaneValid,
      id3PacketValid = decArray.probeId3PacketValid,
      needFlush = core.service(classOf[CommitPlugin]).needFlush
    )

    var cycle = 0L
    var retired = 0L
    var flushes = 0L
    var kicks = 0L
    var cstores = 0L
    var done = false

    var inflight = 0
    var id1Fires = 0L
    var id2Fires = 0L
    var id3Fires = 0L
    var firstId1Fire = -1L
    var firstId2Fire = -1L
    var firstId3Fire = -1L

    while (cycle < maxCycles && !done) {
      cd.waitFallingEdge()
      cycle += 1

      val flush = probes.needFlush.toBoolean
      val f1 = probes.id1Fire.toBoolean
      val f2 = probes.id2Fire.toBoolean
      val f3 = probes.id3Fire.toBoolean
      val inLanes = if (f1) Integer.bitCount(probes.id1LaneValid.toInt) else 0
      val outLanes = if (f3) Integer.bitCount(probes.id3PacketValid.toInt) else 0

      if (flush) {
        // flush 拍：译码三级被同拍移除，本拍入/出均为 0，在飞清零
        assert(inLanes == 0 && outLanes == 0,
          s"cycle $cycle: flush cycle but ID1/ID3 still firing (in=$inLanes out=$outLanes)")
        inflight = 0
      } else {
        inflight += inLanes - outLanes
        assert(inflight >= 0 && inflight <= 9,
          s"cycle $cycle: decode in-flight packet count $inflight out of [0,9] (dup/loss)")
      }

      if (f1) { id1Fires += 1; if (firstId1Fire < 0) firstId1Fire = cycle }
      if (f2) { id2Fires += 1; if (firstId2Fire < 0) firstId2Fire = cycle }
      if (f3) { id3Fires += 1; if (firstId3Fire < 0) firstId3Fire = cycle }

      retired += Integer.bitCount(dut.io.DretireMask.toInt)
      if (flush) flushes += 1
      if (core.service(classOf[CommitPlugin]).probeUncachedKickReg.toBoolean) kicks += 1
      if (core.service(classOf[CommitPlugin]).commitStore.toBoolean) cstores += 1

      if ((cycle & 0x3ff) == 0 && read32(mem.memory, DONE_ADDR) == DONE_MAGIC) done = true
    }

    mem.stop()

    // ---- 结构断言汇总 ----
    assert(id1Fires > 0 && id2Fires > 0 && id3Fires > 0,
      s"decode stages not flowing: ID1=$id1Fires ID2=$id2Fires ID3=$id3Fires")
    assert(firstId1Fire >= 0 && firstId2Fire >= firstId1Fire + 1 && firstId3Fire >= firstId1Fire + 2,
      s"first-fire order wrong (depth evidence): ID1@$firstId1Fire ID2@$firstId2Fire ID3@$firstId3Fire")
    println(s"[Decode3StageSim] fires: ID1=$id1Fires ID2=$id2Fires ID3=$id3Fires " +
      s"(first: $firstId1Fire/$firstId2Fire/$firstId3Fire)")

    // ---- 功能自检（与 CommitChainSimTest 同口径）----
    if (done) {
      val checksum = read32(mem.memory, CHECKSUM_ADDR)
      val syscalls = read32(mem.memory, SYSCALL_COUNT_ADDR)
      assert(checksum == EXPECT_CHECKSUM,
        s"checksum=$checksum, expect $EXPECT_CHECKSUM (decode/epilogue 错误会改变退休序列)")
      assert(syscalls == EXPECT_SYSCALL_COUNT,
        s"syscall count=$syscalls, expect $EXPECT_SYSCALL_COUNT")
      println(s"[Decode3StageSim] memory check OK: checksum=$checksum syscalls=$syscalls")
    }
    Stats(cycle, retired, flushes, kicks, cstores, done)
  }
}

/** scalatest 入口。 */
class Decode3StageSimTest extends AnyFunSuite {
  test("stage2: 3-cycle decode (ID1/ID2/ID3) directed program on full mycpu_top") {
    sys.props("nop.sim.xpm.model") = "1"
    val config = new MyCPUConfig()
    val compiled = SimConfig.compile(new MyCPU(config))
    compiled.doSim { dut =>
      val stats = Decode3StageSim.run(dut, maxCycles = 300000)
      println(s"[Decode3StageSim] cycles=${stats.cycles} retired=${stats.retired} " +
        s"flushes=${stats.flushes} uncachedKicks=${stats.uncachedKicks} commitStores=${stats.commitStores}")
      assert(stats.done, "program did not reach DONE within cycle budget")
      assert(stats.flushes >= 5, s"expected several redirects, got ${stats.flushes}")
      assert(stats.uncachedKicks >= 2, s"expected >=2 uncached kicks, got ${stats.uncachedKicks}")
      assert(stats.retired >= 40, s"expected >=40 retired instructions, got ${stats.retired}")
    }
  }
}
