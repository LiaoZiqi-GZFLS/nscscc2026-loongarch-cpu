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
  val regFlush = RegNext(needFlush, init = False)

  // ---- stage2-③: EXE 提前重定向（needFlush 分裂 + 早重定向通道）----
  // flushBackend 即原 needFlush 语义（ROB flush / regFlush / IQ/exe/mem flush 全部沿用）；
  // flushFrontend 仅在前端确需重引导时置位（早 resolved 的误预测不再冲刷前端）
  val flushBackend = Bool()
  val flushFrontend = Bool()
  // IntExecutePlugin(FU0/BRU) EXE 拍驱动的提前重定向脉冲（payload=target）
  val exeRedirectIn = Stream(UWord()).setIdle()
  // exeRedirectFire 的寄存副本（T_e+1），FetchBufferPlugin 冲刷用
  val exeFlushReg = RegNext(exeRedirectIn.valid, init = False)
  // R9-1 互锁：早重定向后冻结 RENAME/DISPATCH，直到提交侧清理完成（regFlush）
  val holdDispatch = RegInit(False)
}
