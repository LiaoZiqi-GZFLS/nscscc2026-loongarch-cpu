package NOP.pipeline.core

import spinal.core._
import spinal.lib._
import NOP._
import NOP.utils._
import NOP.builder._
import NOP.constants.`enum`.{CacheOpType, CacheSelType, LoadStoreType, TLBOpType}
import NOP.pipeline._
import NOP.pipeline.decode._
import NOP.pipeline.fetch._
import NOP.pipeline.core._
import NOP.pipeline.priviledge._
import spinal.lib.fsm._

class CommitPlugin(config: MyCPUConfig)
    extends Plugin[MyCPUCore]
    with ExceptionCommit
    with TLBCommit
    with CacheCommit
    with BPUCommit
    with CSRCommit
    with ARFCommit
    with WaitCommit
    with StoreBufferCommit
    with CommitFlush {

  override val predUpdate = Flow(PredictUpdateBundle(config.frontend))

  private val retireWidth = config.rob.retireWidth
  private val decodeWidth = config.decode.decodeWidth

  // 向外的提交接口
  override val arfCommits = Vec(Flow(RegFileMappingEntryBundle(config.regFile)), retireWidth)

  // TODO: [NOP] Remove debug signals
  val DuncachedMask = out Bits (3 bits)

  override def build(pipeline: MyCPUCore): Unit = pipeline plug {
    val robFIFO = pipeline.service(classOf[ROBFIFOPlugin])
    val jumpInterface = pipeline.fetchPipeline.service(classOf[ProgramCounterPlugin]).backendJumpInterface

    // Insert into RENAME stage
    pipeline.RENAME plug new Area {
      import pipeline.RENAME._
      // dispatch to ROB at RENAME stage
      val decPacket = input(pipeline.decodePipeline.signals.DECODE_PACKET)
      val renameRecs = input(pipeline.decodePipeline.signals.RENAME_RECORDS)
      val robIdxs = insert(pipeline.decodePipeline.signals.ROB_INDEXES)
      val pushPorts = robFIFO.fifoIO.push
      for (i <- 0 until decodeWidth) {
        val valid = decPacket(i).valid
        val uop = decPacket(i).payload
        val rename = renameRecs(i)

        // Write to push ports of ROBFIFO
        val port = pushPorts(i)
        val entry = port.payload // ROBEntryBundle

        // ! Set ROBEntryBundle
        entry.info.uop.assignSomeByName(uop) // Assign MicroOp to ROBMicroOp
        entry.info.rename.assignAllByName(rename) // ROBRenameRecordBundle
        entry.info.frontendExc := uop.except.valid

        entry.state.complete := uop.needNotExecute
        entry.state.except.assignSomeByName(uop.except)
        entry.state.mispredict := !uop.branchLike && uop.predInfo.predictTaken
        entry.state.actualTaken := False

        port.valid := arbitration.isValidNotStuck && valid
        arbitration.haltItself setWhen (arbitration.isValid && valid && !port.ready)
        robIdxs(i) := robFIFO.pushPtr + i
      }
    }

    val retire = new Area {
      // retire asynchronously pops from ROB
      val popPorts = robFIFO.fifoIO.pop

      // ! First set default values for variables in CommitTraits
      // Exception Commit
      ertn := False
      // ARF Commit
      arfCommits.foreach(_.setIdle())
      // Commit Flush
      predUpdate.setIdle()
      commitStore := False
      doWait := False
      CSRWrite.setIdle()
      tlbOp := TLBOpType.NONE
      tlbInvASID := 0
      tlbInvVPPN := 0
      cacheOp.setIdle()

      val hasExcept = Bool()
      val linearRecover = Bool()

      // ! Calculate instructions that can be retired
      // P3(提交环压缩):掩码展平为每口布尔式。complete 前缀、异常或、
      // unique/recover 掩码不再经 andR/orR 树和 5 掩码相与的中间级,
      // 每口 ready 从 state Q 起约 3-4 级(综合落 LUT6,6 输入一网)。
      // 语义与原掩码逐位一致:exc/unique/recover 位 0 恒真(异常
      // 只能从 0 口提交)。uncachedMask 仍由 uncached FSM 驱动。
      val uncachedMask = out Bits (retireWidth bits) // uncached load/store
      DuncachedMask := uncachedMask // TODO: [NOP] Remove debug signals

      val c0 = popPorts(0).state.complete
      val blk0 = popPorts(0).state.except.valid || linearRecover
      val mp0 = popPorts(0).state.mispredict
      // uncachedMask 是"允许位"(FSM 默认 setAll=1),直接作 AND 因子
      popPorts(0).ready := c0 && uncachedMask(0)

      if (retireWidth > 1) {
        val c1 = popPorts(1).state.complete
        val blk1 = popPorts(1).state.except.valid || linearRecover
        val uq1 = popPorts(1).info.uop.uniqueRetire
        popPorts(1).ready := c0 && c1 && !(blk0 || blk1) && !uq1 && !mp0 && uncachedMask(1)
        if (retireWidth > 2) {
          val c2 = popPorts(2).state.complete
          val blk2 = popPorts(2).state.except.valid || linearRecover
          val uq2 = popPorts(2).info.uop.uniqueRetire
          val mp1 = popPorts(1).state.mispredict
          popPorts(2).ready := c0 && c1 && c2 && !(blk0 || blk1 || blk2) && !(uq1 || uq2) && !(mp0 || mp1) && uncachedMask(2)
        }
      }

      // round-8(提交拆拍):决策拍(fire/needFlush/uncached FSM)与退役动作拍分离。
      // 退役动作(ARF/PRF/BTB/TLB/CSR/重定向)整体延一拍,消费 fire/payload/
      // hasExcept 的寄存副本。决策环只剩 3bit 状态 → ready → fire;90bit
      // 状态大扇出锥移出关键域(round-4 top60 中 ROB pop 锥 33 条的落点)。
      // 冲刷/重定向同步延一拍(needFlushReg),误预测多跑 1 拍错误路径,
      // 由恢复机制(regFlush/recoverPRF)兜底。
      val fireRegs = Vec(popPorts.map(p => RegNext(p.fire) init (False)))
      val entryRegs = Vec(popPorts.map(p => RegNext(p.payload)))
      val hasExceptReg = RegNext(hasExcept) init (False)
      val linearRecoverReg = RegNext(linearRecover) init (False)

      val port0Commit = new Area {
        // port0特殊处理(决策拍)
        val port = popPorts(0)
        val entry = port.payload
        val uop = port.info.uop
        val fire = port.fire

        // 中断处理：中断被当作exception提交，则自然屏蔽所有指令性提交
        // exception分类在handler中进行，若本身就有exception，中断会被优先处理
        val intPending = pipeline.service(classOf[InterruptHandlerPlugin]).intPending
        val intInhibit = False // 用于在uncached开始执行后屏蔽中断的提交
        hasExcept := entry.state.except.valid || (intPending && !intInhibit)

        val mispredict = entry.state.mispredict

        // 需要flush到PC+4的情况：1. 指令本身改变影响处理器状态；2. 非branch被预测改变了控制流
        linearRecover := uop.flushState || (!uop.branchLike && mispredict)

        // 需要回滚处理器状态的情况：
        // 1. 分支：预测错误
        // 2. 异常
        // 3. 其它提交后需要flush流水线的指令
        val recoverState = fire && (hasExcept || mispredict || linearRecover)
        // 如果不需要等delay slot，则立即flush
        needFlush := recoverState
        // round-8:冲刷整体延一拍(与退役动作拍对齐)
        robFIFO.fifoIO.flush := needFlushReg // flush周期同时pop

        // mispredict仍然会提交分支指令和delay slot，所以要先更新ARF，再回滚PRF
        // flush的下一个周期不会pop，所以没有关系
        recoverPRF := regFlush // regFlush 是 needFlushReg 延迟一个周期

        // clear frontend pipelines
        pipeline.fetchPipeline.stages.last.arbitration.flushIt setWhen needFlushReg
        pipeline.decodePipeline.stages.last.arbitration.flushIt setWhen needFlushReg

        // exception永远从0口unique发出(动作拍,fireRegs(0) 已含 fire)
        except.valid := fireRegs(0) && hasExceptReg
        except.payload := entryRegs(0).state.except.payload
        // 前端异常的badVA必然是pc
        when(entryRegs(0).info.frontendExc) { except.badVA := entryRegs(0).info.uop.pc }
        epc := entryRegs(0).info.uop.pc

        val uncachedProcess = new Area {
          // 处理uncached load的提交问题(决策拍,不变)
          // uncached load要等待store buffer将其发射并执行到WB阶段才能提交
          // 避免出现寄存器已经被重分配出去的问题
          val isUncachedUOP = uop.isLoad && entry.state.lsuUncached
          val fsm = new StateMachine {
            disableAutoStart()
            setEntry(stateBoot)
            val execute = new State

            uncachedMask.setAll()
            stateBoot.whenIsActive {
              when(port.valid && isUncachedUOP && entry.state.complete && !hasExcept) {
                // 不提交，等待store buffer执行
                uncachedMask := 0
                commitStore := True
                goto(execute)
              }
            }

            execute.whenIsActive {
              intInhibit := True
              uncachedMask := 0
              val memWB = pipeline.memPipeline.WB
              val wbSTD = memWB.input(pipeline.memPipeline.signals.STD_SLOT)
              val isUncachedWB = wbSTD.valid && !wbSTD.isStore
              // uncached load执行完成
              when(memWB.arbitration.notStuck && isUncachedWB) {
                // FIXME: 需要保证此周期一定提交且不触发异常
                uncachedMask.setAll()
                goto(stateBoot)
              }
            }
          }
        }
      }

      // ==== 退役动作拍(round-8):全部消费 fireRegs/entryRegs 的寄存副本 ====
      {
        val entry = entryRegs(0)
        val uop = entry.info.uop
        when(fireRegs(0) && !hasExceptReg) {
          // 所有指令性的commit需要在没有except的时候发出

          cacheOp.valid := uop.operateCache
          // 复用badVA，如果没有异常的时候badVA填cache需要的物理地址
          cacheOp.payload.addr := entry.state.except.badVA
          cacheOp.payload.op assignFromBits entry.state.intResult(0, CacheOpType.None.asBits.getWidth bits).asBits
          cacheOp.payload.sel assignFromBits entry.state
            .intResult(CacheOpType.None.asBits.getWidth, CacheSelType.None.asBits.getWidth bits)
            .asBits

          doWait := uop.isWait
          tlbOp := uop.tlbOp
          tlbInvASID := entry.state.intResult(9 downto 0).asBits
          tlbInvVPPN := entry.state.intResult(28 downto 10).asBits

          when(uop.writeCSR) {
            CSRWrite.valid := True
            CSRWrite.payload.data := entry.state.intResult.asBits
            CSRWrite.payload.addr := uop.inst(23 downto 10).asUInt
          }

          ertn := uop.isErtn

          commitStore := uop.isStore

          val excHandler = pipeline.service(classOf[ExceptionHandlerPlugin])
          when(uop.isLL) {
            excHandler.LLBCTL_LLBIT := True
          }

          when(uop.isSC) {
            when(excHandler.LLBCTL_LLBIT) {
              excHandler.LLBCTL_LLBIT := False
            } otherwise {
              commitStore := False
            }
          }

          // ! BTB Pred Update
          predUpdate.valid := uop.branchLike || uop.predInfo.predictBranch
          predUpdate.payload.predInfo := uop.predInfo
          predUpdate.payload.predRecover := uop.predRecover
          predUpdate.payload.branchLike := uop.isBranch || uop.isJump || uop.isJR // jump is a always true branch for btb
          // returns also needed to record in btb for ras to predict correctly.
          predUpdate.payload.isTaken := (entry.state.mispredict ^ uop.predInfo.predictTaken) || uop.isJump || uop.isJR // note that jump and jr is always taken...
          // 'jr ra'
          predUpdate.payload.isRet := B"01001100000000000000000000100000" === uop.inst // 0x4c000020
          // Call: JIRL with RA linkage and BL
          predUpdate.payload.isCall := (uop.isJR && uop.inst(4 downto 0) === B"00001") || (uop.isJump && uop.inst(26))
          predUpdate.payload.mispredict := entry.state.mispredict
          predUpdate.payload.pc := uop.pc
          predUpdate.payload.target := entry.state.intResult

          val jumpTarget = U(0, 32 bits)
          when(uop.isJump || uop.isJR) {
            jumpTarget := entry.state.intResult // when is Jump, go to actual target
          } otherwise {
            jumpTarget := Mux(
              entry.state.actualTaken,
              entry.state.intResult,
              uop.pc + 4
            ) // when branch, decide recover or not based on predictTaken
          }

          when(linearRecoverReg && !uop.isErtn) {
            // 这些是本身不改变控制流，但因为flush而需要改变控制流
            jumpInterface.valid := True
            // [NOP] 被改成了直接用 pc + 4
            jumpInterface.payload := uop.pc + 4
          }

          when(entry.state.mispredict && uop.branchLike) {
            jumpInterface.valid := True
            jumpInterface.payload := jumpTarget
          }

          // 以上优先级是重要的。Branch本身的跳转目标优先于delay slot中的mispredict（一定非branch）。
        }
      }

      for (i <- 0 until retireWidth) {
        val entry = entryRegs(i)
        val uop = entry.info.uop
        val rename = entry.info.rename
        when(fireRegs(i) && !hasExceptReg) {
          // 所有指令性的commit需要在没有except的时候发出
          arfCommits(i).valid := uop.doRegWrite
          arfCommits(i).payload.addr := uop.wbAddr
          arfCommits(i).payload.prevAddr := rename.wPrevReg
          arfCommits(i).payload.prfAddr := rename.wReg
        }
      }

    }

    retire
  }
}
