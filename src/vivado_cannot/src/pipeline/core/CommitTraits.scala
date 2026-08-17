package NOP.pipeline.core

import spinal.core._
import spinal.lib._

import NOP._
import NOP.utils._
import NOP.constants.enum._
import NOP.builder._
import NOP.pipeline._
import NOP.pipeline.decode._
import NOP.pipeline.fetch._
import NOP.pipeline.core._
import NOP.pipeline.priviledge._

trait ExceptionCommit {
  val except = out(Flow(ExceptionPayloadBundle(true)))
  val ertn = out Bool ()
  val epc = out(UWord())
}

trait TLBCommit {
  val tlbOp = TLBOpType()
  val tlbInvASID = Bits(10 bits)
  val tlbInvVPPN = Bits(19 bits)
}

trait CacheCommit {
  val cacheOp = out(Flow(CacheOperation()))
}

/** Commit to branch prediction unit.
  */
trait BPUCommit {
  val predUpdate: Flow[PredictUpdateBundle]
}

trait CSRCommit {
  val CSRWrite = out(Flow(CSRWriteBundle()))
}

trait ARFCommit {
  val arfCommits: Vec[Flow[RegFileMappingEntryBundle]]
  val recoverPRF = Bool()
}

trait WaitCommit {
  val doWait = Bool()
}

trait StoreBufferCommit {
  val commitStore = Bool()
}

trait CommitFlush {
  val needFlush = Bool
  // round-8(提交拆拍):冲刷与重定向整体延一拍执行(needFlushReg),
  // regFlush 在其后一拍,给 IQ/执行/存储缓冲的冲刷。恢复机制兜底
  // 多一拍的错误路径。
  val needFlushReg = RegNext(needFlush, init = False)
  val regFlush = RegNext(needFlushReg, init = False)
}
