package NOP.pipeline

import spinal.core._
import spinal.lib._
import NOP.utils._
import NOP._

final case class RenameRecordBundle(config: RegFileConfig) extends Bundle {
  val rRegs = Vec(UInt(config.prfAddrWidth bits), config.rPortsEachInst)
  val wReg = UInt(config.prfAddrWidth bits)
  val wPrevReg = UInt(config.prfAddrWidth bits)
}

final case class ROBRenameRecordBundle(config: RegFileConfig) extends Bundle {
  val wReg = UInt(config.prfAddrWidth bits)
  val wPrevReg = UInt(config.prfAddrWidth bits)
}

// And MicroOps. See DecodeMicroOP.scala

/** stage2-②: 译码 local 信号收敛（R6 对策）。
  *
  * 65 路匹配（ID2）产生、epilogue（ID3）消费的非 MicroOp 字段全部收敛进本 Bundle，
  * 随流水线跨拍寄存，杜绝漏寄存（漏一个 = 静默功能错）。
  * 字段与 MicroOpSignals 中的 local Stageable 一一对应；illegalEncoding 为匹配落空标志。
  */
final case class DecodeLocalsBundle() extends Bundle {
  val isSyscall = Bool()
  val isBreak = Bool()
  val isRegWrite = Bool()
  val overrideRdToRA = Bool()
  val overrideRdToRj = Bool()
  val isBar = Bool()
  val illegalEncoding = Bool()
}
