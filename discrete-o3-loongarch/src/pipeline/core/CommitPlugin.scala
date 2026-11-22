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

/** 阶段 1(200MHz 离散化): 提交拆为 CM1/CM2 两拍 + 提交邮箱。
  *
  * - CM1(本拍): 纯决策。输入全部为寄存器(robState 寄存读 + RAM 读 + uncachedMask
  *   FSM 状态寄存器 + intPending 寄存器), 计算 ready/fire/popCount(≈5~6 级);
  *   pop payload 打进邮箱寄存器。
  * - CM2(下一拍): 全部退役动作(ARF/PRF/freeList/BTB/TLB/CSR/redirect/store)只
  *   消费邮箱 —— 90bit 提交锥从下游动作中消失, 每个消费者只见自己需要的字段。
  * - flush 对齐协议: CM2 的 needFlush(邮箱组合)同拍抑制 CM1 的 fire(1 级门控),
  *   保证 flush 拍不 pop, freeList recover 的"recover 周期无 push/pop"不变式成立。
  * - 环证明: robState Q → 决策 → popCount → 指针/邮箱 → needFlush → ready,
  *   环上必经邮箱寄存器, 无组合环。
  */
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
  val DuncachedMask = out Bits (retireWidth bits)

  override def build(pipeline: MyCPUCore): Unit = pipeline plug {
    val robFIFO = pipeline.service(classOf[ROBFIFOPlugin])
    val jumpInterface = pipeline.fetchPipeline.service(classOf[ProgramCounterPlugin]).backendJumpInterface

    // ---- RENAME 阶段: 派发到 ROB(与基线一致) ----
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
      ertn := False
      arfCommits.foreach(_.setIdle())
      predUpdate.setIdle()
      commitStore := False
      doWait := False
      CSRWrite.setIdle()
      tlbOp := TLBOpType.NONE
      tlbInvASID := 0
      tlbInvVPPN := 0
      cacheOp.setIdle()

      // ---- CM1 视图信号(由 pop 载荷组合得出) ----
      val hasExcept = Bool()
      val linearRecover = Bool()

      val uncachedMask = out Bits (retireWidth bits) // uncached load/store
      DuncachedMask := uncachedMask.resized

      // ---- 提交邮箱: CM1 -> CM2 寄存器边界 ----
      val mbValid = RegInit(False)
      val mbCount = RegInit(U(0, log2Up(retireWidth + 1) bits))
      val mbFire = Vec(RegInit(False), retireWidth)
      val mbEntries = Vec(Reg(ROBEntryBundle(config)), retireWidth)
      val mbHasExcept = RegInit(False)
      val mbLinearRecover = RegInit(False)

      // CM2 的 needFlush(邮箱组合); 被 CM1 的 ready 门控引用 ——
      // 环上必经邮箱寄存器, 无组合环
      needFlush := mbValid && (mbHasExcept || mbEntries(0).state.mispredict || mbLinearRecover)

      // ---- CM1: 决策(纯寄存输入, 带 flush 抑制) ----
      // 掩码展开为每口布尔式; complete 前缀、异常或 unique/recover 掩码
      // 不再需要 andR/orR 树; 每口 ready 从 state Q 起约 3~4 级
      val c0 = popPorts(0).state.complete
      val mp0 = popPorts(0).state.mispredict
      linearRecover := popPorts(0).info.uop.flushState ||
        (!popPorts(0).info.uop.branchLike && mp0)
      val blk0 = popPorts(0).state.except.valid || linearRecover
      // uncachedMask 是允许位(FSM 默认 setAll=1), 直接作 AND 因子
      popPorts(0).ready := c0 && uncachedMask(0) && !needFlush

      if (retireWidth > 1) {
        val c1 = popPorts(1).state.complete
        val blk1 = popPorts(1).state.except.valid || linearRecover
        val uq1 = popPorts(1).info.uop.uniqueRetire
        popPorts(1).ready := c0 && c1 && !(blk0 || blk1) && !uq1 && !mp0 &&
          uncachedMask(1) && !needFlush
        if (retireWidth > 2) {
          val c2 = popPorts(2).state.complete
          val blk2 = popPorts(2).state.except.valid || linearRecover
          val uq2 = popPorts(2).info.uop.uniqueRetire
          val mp1 = popPorts(1).state.mispredict
          popPorts(2).ready := c0 && c1 && c2 && !(blk0 || blk1 || blk2) &&
            !(uq1 || uq2) && !(mp0 || mp1) && uncachedMask(2) && !needFlush
        }
      }

      // ---- 邮箱捕获(CM1 拍) ----
      mbValid := popPorts.map(_.fire).orR
      mbCount := robFIFO.robInfo.popCount
      for (i <- 0 until retireWidth) {
        mbFire(i) := popPorts(i).fire
        mbEntries(i) := popPorts(i).payload
      }
      mbHasExcept := hasExcept
      mbLinearRecover := linearRecover

      // ---- CM2: 全部退役动作只消费邮箱 ----
      val entry0 = mbEntries(0)
      val uop0 = entry0.info.uop

      val intPending = pipeline.service(classOf[InterruptHandlerPlugin]).intPending
      val intInhibit = False // 由 uncached FSM execute 状态置位(CM1 视图)

      // CM1 视图的 hasExcept(FSM 门控用); 邮箱视图为 mbHasExcept
      hasExcept := popPorts(0).state.except.valid || (intPending && !intInhibit)

      // 异常提交(邮箱视图; 中断当作 exception 提交)
      except.valid := mbValid && mbHasExcept
      except.payload := entry0.state.except.payload
      // 前端异常的 badVA 必然是 pc
      when(entry0.info.frontendExc) { except.badVA := entry0.info.uop.pc }
      epc := uop0.pc

      // flush 与重定向: needFlush 组合由邮箱得出(定义见上)
      recoverPRF := regFlush
      robFIFO.fifoIO.flush := needFlush

      // clear frontend pipelines
      pipeline.fetchPipeline.stages.last.arbitration.flushIt setWhen needFlush
      pipeline.decodePipeline.stages.last.arbitration.flushIt setWhen needFlush

      // 重定向目标(邮箱视图)
      val jumpTarget = UInt(32 bits)
      jumpTarget := 0
      when(mbValid && !mbHasExcept) {
        when(uop0.isJump || uop0.isJR) {
          // when is Jump, go to actual target
          jumpTarget := entry0.state.intResult
        } otherwise {
          // when branch, decide recover or not based on predictTaken
          jumpTarget := Mux(entry0.state.actualTaken, entry0.state.intResult, uop0.pc + 4)
        }
        // 本身不改变控制流, 但因 flush 而需要改变控制流的指令
        when(mbLinearRecover && !uop0.isErtn) {
          jumpInterface.valid := True
          jumpInterface.payload := uop0.pc + 4
        }
        when(entry0.state.mispredict && uop0.branchLike) {
          jumpInterface.valid := True
          jumpInterface.payload := jumpTarget
        }
      }

      // 所有指令性的 commit 动作(原 fire 拍, 现邮箱拍; 晚 1 拍)
      when(mbValid && !mbHasExcept) {
        cacheOp.valid := uop0.operateCache
        // 复用 badVA: 没有异常时 badVA 填 cache 需要的物理地址
        cacheOp.payload.addr := entry0.state.except.badVA
        cacheOp.payload.op assignFromBits entry0.state.intResult(0, CacheOpType.None.asBits.getWidth bits).asBits
        cacheOp.payload.sel assignFromBits entry0.state
          .intResult(CacheOpType.None.asBits.getWidth, CacheSelType.None.asBits.getWidth bits)
          .asBits

        doWait := uop0.isWait
        tlbOp := uop0.tlbOp
        tlbInvASID := entry0.state.intResult(9 downto 0).asBits
        tlbInvVPPN := entry0.state.intResult(28 downto 10).asBits

        when(uop0.writeCSR) {
          CSRWrite.valid := True
          CSRWrite.payload.data := entry0.state.intResult.asBits
          CSRWrite.payload.addr := uop0.inst(23 downto 10).asUInt
        }

        ertn := uop0.isErtn
        commitStore := uop0.isStore

        val excHandler = pipeline.service(classOf[ExceptionHandlerPlugin])
        when(uop0.isLL) {
          excHandler.LLBCTL_LLBIT := True
        }
        when(uop0.isSC) {
          when(excHandler.LLBCTL_LLBIT) {
            excHandler.LLBCTL_LLBIT := False
          } otherwise {
            commitStore := False
          }
        }

        // ! BTB Pred Update
        predUpdate.valid := uop0.branchLike || uop0.predInfo.predictBranch
        predUpdate.payload.predInfo := uop0.predInfo
        predUpdate.payload.predRecover := uop0.predRecover
        predUpdate.payload.branchLike := uop0.isBranch || uop0.isJump || uop0.isJR
        // returns also needed to record in btb for ras to predict correctly.
        predUpdate.payload.isTaken := (entry0.state.mispredict ^ uop0.predInfo.predictTaken) || uop0.isJump || uop0.isJR
        predUpdate.payload.isRet := B"01001100000000000000000000100000" === uop0.inst
        // Call: JIRL with RA linkage and BL
        predUpdate.payload.isCall := (uop0.isJR && uop0.inst(4 downto 0) === B"00001") || (uop0.isJump && uop0.inst(26))
        predUpdate.payload.mispredict := entry0.state.mispredict
        predUpdate.payload.pc := uop0.pc
        predUpdate.payload.target := entry0.state.intResult
      }

      // ARF 提交(邮箱视图)
      for (i <- 0 until retireWidth) {
        val entry = mbEntries(i)
        val uop = entry.info.uop
        val rename = entry.info.rename
        when(mbValid && mbFire(i) && !mbHasExcept) {
          arfCommits(i).valid := uop.doRegWrite
          arfCommits(i).payload.addr := uop.wbAddr
          arfCommits(i).payload.prevAddr := rename.wPrevReg
          arfCommits(i).payload.prfAddr := rename.wReg
        }
      }

      // uncached FSM: 门控用 CM1 视图(pop 前), 动作时序与原版一致
      val uncachedProcess = new Area {
        val isUncachedUOP = popPorts(0).info.uop.isLoad && popPorts(0).payload.state.lsuUncached
        val fsm = new StateMachine {
          disableAutoStart()
          setEntry(stateBoot)
          val execute = new State

          uncachedMask.setAll()
          stateBoot.whenIsActive {
            when(popPorts(0).valid && isUncachedUOP && popPorts(0).state.complete && !hasExcept) {
              // 不提交, 等待 store buffer 执行
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
            // uncached load 执行完成
            when(memWB.arbitration.notStuck && isUncachedWB) {
              uncachedMask.setAll()
              goto(stateBoot)
            }
          }
        }
      }

    }

    retire
  }
}
