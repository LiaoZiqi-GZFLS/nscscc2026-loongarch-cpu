package NOP.pipeline

import NOP.builder._
import NOP.pipeline._
import NOP.pipeline.fetch._
import NOP._

import spinal.core._
import spinal.lib._

class DecodeSignals(config: MyCPUConfig) {
  private val decodeWidth = config.decode.decodeWidth
  object DECODE_PACKET extends Stageable(Vec(Flow(MicroOp(config)), decodeWidth))
  object RENAME_RECORDS extends Stageable(Vec(RenameRecordBundle(config.regFile), decodeWidth))
  object ROB_INDEXES extends Stageable(Vec(UInt(config.rob.robAddressWidth bits), decodeWidth))

  // stage2-②: 译码 3 拍化级间寄存（ID1=FB pop 寄存 / ID2=匹配+字段 mux / ID3=epilogue）
  object DECODE_ENTRY extends Stageable(Vec(InstBufferEntry(config.frontend), decodeWidth))
  object DECODE_VALID extends Stageable(Vec(Bool(), decodeWidth))
  object DECODE_BASE_UOP extends Stageable(Vec(MicroOp(config), decodeWidth))
  object DECODE_LOCALS extends Stageable(Vec(DecodeLocalsBundle(), decodeWidth))
}

trait DecodePipeline extends Pipeline {
  type T = DecodePipeline
  // stage2-②: ID 单级拆为 ID1/ID2/ID3 三级
  val ID1: Stage = null
  val ID2: Stage = null
  val ID3: Stage = null
  val RENAME: Stage = null
  val DISPATCH: Stage = null
  // 兼容别名：ID == ID1（译码第一拍；外部引用仅 MyCPUCore.scala 的 Stage 导出）
  def ID: Stage = ID1
  val signals: DecodeSignals
}
