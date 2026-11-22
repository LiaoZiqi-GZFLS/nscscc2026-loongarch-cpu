package NOP.pipeline.mem

import spinal.core._
import spinal.lib._
import spinal.lib.fsm._
import spinal.lib.bus.amba4.axi.Axi4

import NOP._
import NOP.blackbox.mem._
import NOP.builder._
import NOP.utils._
import NOP.pipeline._
import NOP.pipeline.core._
import NOP.constants.enum._

class DirtyBitsManager(config: CacheBasicConfig) extends Component {
  val io = new Bundle {
    val readCmd = in(UInt(config.indexWidth bits))
    val readRsp = out(Bits(config.ways bits))
    val writeCmd = in(Flow(new Bundle {
      val idx = UInt(config.indexWidth bits)
      val way = UInt(log2Up(config.ways) bits)
      val data = Bool()
    }))
  }
  val dirtyBits = Vec(RegInit(B(0, config.ways bits)), config.sets)
  // normal read(P7:64:1 树形读,3 级,替代 Vec.read 的 2:1 递归 6 级)
  io.readRsp := TreeRead(dirtyBits.toIndexedSeq, io.readCmd)
  // normal write
  when(io.writeCmd.valid) {
    dirtyBits(io.writeCmd.idx)(io.writeCmd.way) := io.writeCmd.data
  }
  // write -> read bypass
  when(io.writeCmd.valid && io.readCmd === io.writeCmd.idx) {
    io.readRsp(io.writeCmd.way) := io.writeCmd.data
  }
}
