package NOP

import spinal.core._
import spinal.lib.bus.amba4.axi._
import spinal.lib._

abstract class CacheBasicConfig {
  val sets: Int
  val lineSize: Int
  val ways: Int
  val offsetWidth = log2Up(lineSize)
  val offsetRange = (offsetWidth - 1) downto 0
  val wordOffsetRange = (offsetWidth - 1) downto 2
  val indexWidth = log2Up(sets)
  val indexRange = (offsetWidth + indexWidth - 1) downto offsetWidth
  val tagOffset = offsetWidth + indexWidth
  val tagRange = 31 downto tagOffset
  def wordCount = sets * lineSize / 4
  def lineWords = lineSize / 4
}

final case class ICacheConfig(
    sets: Int = 64,
    lineSize: Int = 64,
    ways: Int = 2,
    useReorder: Boolean = false
) extends CacheBasicConfig {
  require(sets * lineSize <= (4 << 10), "4KB is VIPT limit")
  val enable = true
}

final case class DCacheConfig(
    sets: Int = 64,
    lineSize: Int = 64,
    ways: Int = 4 // 4-way round-robin: halves D$ misses on perf benchmarks
) extends CacheBasicConfig {
  require(sets * lineSize <= (4 << 10), "4KB is VIPT limit")
  val enable = true
}

final case class BTBConfig(
    sets: Int = 1024,
    lineSize: Int = 4,
    ways: Int = 1,
    rasEntries: Int = 8
) extends CacheBasicConfig {
  val enable = true
}

final case class BPUConfig(
    sets: Int = 1024,
    phtSets: Int = 8192,
    historyWidth: Int = 5,
    counterWidth: Int = 2
) {
  val indexWidth = log2Up(sets)
  val indexRange = 2 until 2 + indexWidth
  val ways = 1 << historyWidth
  val phtIndexWidth = log2Up(phtSets)
  val phtPCRange = 2 until 2 + phtIndexWidth - historyWidth
  val counterType = HardType(UInt(counterWidth bits))
  val historyType = HardType(UInt(historyWidth bits))
  val useGlobal = true
  val useLocal = false
  val useHybrid = false
}

final case class FrontendConfig(
    pcInit: Long = 0x1c000000L,
    icache: ICacheConfig = ICacheConfig(),
    btb: BTBConfig = BTBConfig(),
    bpu: BPUConfig = BPUConfig(),
    fetchWidth: Int = 4,
    fetchBufferDepth: Int = 8,
    // stage2-③: EXE 提前重定向总开关（回退档；关闭时 exeRedirect 恒 idle、earlyResolved 恒 False，
    // 逐拍等价于 ②-only 基线，用于 A/B 对账与现场止损）
    enableEarlyRedirect: Boolean = true
)

final case class RegFileConfig(
    nArchRegs: Int = 32,
    nPhysRegs: Int = 31 + 32
) {
  val arfAddrWidth = log2Up(nArchRegs)
  val prfAddrWidth = log2Up(nPhysRegs)
  val rPortsEachInst = 2
}

final case class DecodeConfig(
    decodeWidth: Int = 3,
    allUnique: Boolean = false
)

// Issuing
abstract class IssueConfig {
  val issueWidth: Int
  val depth: Int
  val addrWidth = log2Up(depth)
}

final case class IntIssueConfig(
    issueWidth: Int = 3,
    bruIdx: Int = 0,
    csrIdx: Int = 0,
    timerIdx: Int = 1,
    invTLBIdx: Int = 0,
    // stage3-③: 容量扩张 7->10(选择树 log2 7=3 -> log2 10=4,+1 级,预算已登记)
    depth: Int = 10,
    // [stage3-①②] 双总线唤醒 + 写引擎广播合并决策开关:
    // true=档 A(默认,新机制):aluWakeupBus(4 条目 FF)+memWakeupBus(1 条目 FF)
    //   广播,PRF busys 清零与胞元唤醒统一读总线;
    // false=档 B(回退/A/B 对账):5 口 clearBusys 组合豁免网 + 3 口 localTag,
    //   行为 ≡ t26-stage2-int(28ffec15)
    registeredWakeup: Boolean = false, // s3b 保险档：关双总线唤醒
    aluBusEntries: Int = 4, // INT0..2(ISS→RRD 沿采样) + MULDIV(EXE 拍打拍)
    memBusEntries: Int = 1 // MEM 加载(M1:MEM1 锥打拍,MEM2 广播)
) extends IssueConfig {
  require(0 <= bruIdx && bruIdx < issueWidth)
  require(0 <= csrIdx && csrIdx < issueWidth)
  require(0 <= timerIdx && timerIdx < issueWidth)
  require(0 <= invTLBIdx && invTLBIdx < issueWidth)
  require(aluBusEntries == 4 && memBusEntries == 1, "stage3: bus entries fixed at 4+1 (②.2 同拍多生产者)")
}

final case class MulDivConfig(
    depth: Int = 3,
    multiplyLatency: Int = 2,
    divisionEarlyOutWidth: Int = 16 // set to 0 to disable early out
) extends IssueConfig {
  val issueWidth: Int = 1
  def useDivisionEarlyOut = divisionEarlyOutWidth > 0
}

// stage3-⑥: MEM 管道配置
final case class MemPipelineConfig(
    // MEM_ADDR→MEM1 TLB 结果路径切片(S1:新增 MEMTLB 级,胖切点 TLB_PARTIAL 寄存)。
    // 默认 true=8 级;false 时 MEMTLB 级仍存在但 TLB partial 直通组合
    // (恢复单拍 TLB 锥,用于 A/B 对账与现场止损;完全去级 = revert commit)
    splitTlbStage: Boolean = true
)

final case class MemIssueConfig(
    depth: Int = 5
) extends IssueConfig {
  val issueWidth: Int = 1
}

// Commit
final case class ROBConfig(
    // stage3-③: 容量扩张 32->64(保 pow2,指针/年龄比较/ReorderCacheRAM 行回卷
    // 全部走自然模 64;设计书 stage3_design ③.0 案 B)
    robDepth: Int = 64,
    retireWidth: Int = 3
) {
  val robAddressWidth = log2Up(robDepth)
}

// Interrupt
final case class InterruptConfig(
    innerCounterDownEvery: Int = 1
)

// TLB
final case class TLBConfig(
    numEntries: Int = 16,
    physAddrWidth: Int = 32
) {
  val indexWidth = log2Up(numEntries)
  val virtAddrWidth = 32
  val asidWidth = 10
}

final case class MyCPUConfig(
    axiConfig: Axi4Config = Axi4Config(
      addressWidth = 32,
      dataWidth = 32,
      idWidth = 4,
      useRegion = false,
      useQos = false
    ),
    debug: Boolean = true,
    weDebug: Boolean = true,
    debug_difftest: Boolean = true,
    frontend: FrontendConfig = FrontendConfig(),
    decode: DecodeConfig = DecodeConfig(),
    regFile: RegFileConfig = RegFileConfig(),
    // EXE
    intIssue: IntIssueConfig = IntIssueConfig(),
    mulDiv: MulDivConfig = MulDivConfig(),
    // MEM
    dcache: DCacheConfig = DCacheConfig(),
    memIssue: MemIssueConfig = MemIssueConfig(),
    memPipeline: MemPipelineConfig = MemPipelineConfig(), // stage3-⑥
    storeBufferDepth: Int = 8,
    // Commit
    rob: ROBConfig = ROBConfig(),
    // Interrupt
    interrupt: InterruptConfig = InterruptConfig(),
    // TLB
    tlbConfig: TLBConfig = TLBConfig()
)
