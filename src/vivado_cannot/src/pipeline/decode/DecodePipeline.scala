package NOP.pipeline

import NOP.builder._
import NOP.pipeline._
import NOP.pipeline.fetch._
import NOP.pipeline.core._
import NOP.constants.enum._
import NOP.utils._
import NOP._

import spinal.core._
import spinal.lib._

/** round-5 两拍译码:ID 拍产出原始字段(DECODE_FIELDS),
  * ID2 拍做 epilogue(异常/回写地址/CSR/Timer 等)并产出 DECODE_PACKET。
  */
final case class DecodeFieldsBundle(config: MyCPUConfig) extends Bundle {
  // 直通
  val pc = UWord()
  val inst = BWord()
  val except = Flow(ExceptionPayloadBundle(false))
  val predInfo = BranchPredictInfoBundle()
  val predRecover = PredictRecoverBundle(config.frontend)

  // dispatch 信息
  val fuType = FUType()

  // REG r/w
  val useRj = Bool
  val useRk = Bool
  val useRd = Bool
  val isRegWrite = Bool
  val overrideRdToRA = Bool
  val overrideRdToRj = Bool

  // IMM
  val immExtendType = ExtendType()

  // ALU
  val aluOp = ALUOpType()

  // LSU
  val lsType = LoadStoreType()
  val isLoad = Bool
  val isStore = Bool

  // BRU
  val cmpOp = CompareOpType()
  val isBranch = Bool
  val isJump = Bool
  val isJR = Bool

  // CSR
  val readCSR = Bool()

  // Timer64
  val readTimer64H = Bool()

  // TLB/cache/杂项
  val tlbOp = TLBOpType()
  val operateCache = Bool
  val isWait = Bool
  val isLL = Bool()
  val isSC = Bool()
  val isErtn = Bool
  val isSyscall = Bool()
  val isBreak = Bool()
  val isBar = Bool()

  // MUL/DIV
  val signed = Bool

  // 非法编码 + 折叠后的组合基
  val illegalEncoding = Bool()
  val flushStateBase = Bool()
  val branchLikeBase = Bool()
  val uniqueRetireBase = Bool()
}

/** round-10 三拍译码第 1 拍的负载:直通 + 65 路比较结果(one-hot)。
  */
final case class DecodeMatchBundle(config: MyCPUConfig) extends Bundle {
  val pc = UWord()
  val inst = BWord()
  val except = Flow(ExceptionPayloadBundle(false))
  val predInfo = BranchPredictInfoBundle()
  val predRecover = PredictRecoverBundle(config.frontend)
  val matchBits = Bits(65 bits)
  val anyMatch = Bool()
}

class DecodeSignals(config: MyCPUConfig) {
  private val decodeWidth = config.decode.decodeWidth
  // ID 拍:比较结果;ID2 拍:字段 mux;ID3 拍:epilogue → DECODE_PACKET
  object DECODE_MATCHES extends Stageable(Vec(Flow(DecodeMatchBundle(config)), decodeWidth))
  object DECODE_FIELDS extends Stageable(Vec(Flow(DecodeFieldsBundle(config)), decodeWidth))
  object DECODE_PACKET extends Stageable(Vec(Flow(MicroOp(config)), decodeWidth))
  object RENAME_RECORDS extends Stageable(Vec(RenameRecordBundle(config.regFile), decodeWidth))
  object ROB_INDEXES extends Stageable(Vec(UInt(config.rob.robAddressWidth bits), decodeWidth))
}

trait DecodePipeline extends Pipeline {
  type T = DecodePipeline
  val ID: Stage = null
  val ID2: Stage = null
  // round-10:三拍译码(比较/字段mux/epilogue)
  val ID3: Stage = null
  val RENAME: Stage = null
  val DISPATCH: Stage = null
  val signals: DecodeSignals
}
