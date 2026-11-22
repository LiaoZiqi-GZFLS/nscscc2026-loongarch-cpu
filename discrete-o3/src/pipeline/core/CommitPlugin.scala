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
  // round-13(早重定向重做):retireWidth+1 槽——末槽由快照回推驱动
  // (addr=0/prfAddr=0 占位,prevAddr=被冲刷项 wPrevReg;RenamePlugin 的
  // 压缩网络把它与真实提交一起排进 freeList 前部口,保连续性)
  override val arfCommits = Vec(Flow(RegFileMappingEntryBundle(config.regFile)), retireWidth + 1)

  // TODO: [NOP] Remove debug signals
  val DuncachedMask = out Bits (retireWidth bits)

  override def build(pipeline: MyCPUCore): Unit = pipeline plug {
    val robFIFO = pipeline.service(classOf[ROBFIFOPlugin])
    val jumpInterface = pipeline.fetchPipeline.service(classOf[ProgramCounterPlugin]).backendJumpInterface

    // ---- RENAME 阶段: 派发到 ROB(与基线一致) ----
    // round-13(早重定向重做):影子表——按 robIdx 记录每槽 (doRegWrite,
    // wPrevReg),供 squash 拍快照回推 freeList(ROB 本体是 RAM,随机读代价高;
    // 影子表写侧在派发,读侧仅 squash 一拍,不在关键路径)。
    val recoverShadow = Vec(
      Reg(Bits(1 + config.regFile.prfAddrWidth bits)),
      config.rob.robDepth
    )
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
        entry.state.earlyRedirected := False

        // round-12(EXE 提前重定向):squash 拍抑制派发写入——DISPATCH 的
        // isValidNotStuck 不含 removeIt,flush 拍仍会把旧流残留推进被
        // squash 的 ROB 区(其生产者已被冲刷,永不完结→提交死锁);
        // 1 拍后新流到达,派发正常恢复。
        port.valid := arbitration.isValidNotStuck && valid && !robFIFO.earlyRedirect.valid
        arbitration.haltItself setWhen (arbitration.isValid && valid && !port.ready)
        robIdxs(i) := robFIFO.pushPtr + i
        // 影子表与 ROB 推入口同门控(squash 拍不写,快照读旧值稳定)
        // 布局: bit[0]=doRegWrite, bit[prfAddrWidth:1]=wPrevReg
        when(port.valid) {
          recoverShadow(robIdxs(i)) := rename.wPrevReg.asBits ## uop.doRegWrite.asBits
        }
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

      // round-13(早重定向重做):快照式空闲表回收——squash 拍从影子表并行
      // 捕获被冲刷弧 (robIdx+1 .. pushPtr) 的 (doRegWrite, wPrevReg),
      // 随后逐拍 1 项经 recoverPort 回推 freeList。替代旧的 recoverEarlyReg
      // (freeList.recover 全量回滚会错误释放重定向后存活的新流映射)。

      // CM2 的 needFlush(邮箱组合); 被 CM1 的 ready 门控引用 ——
      // 环上必经邮箱寄存器, 无组合环。提前重定向过的误预测不再 flush
      // (只留 BTB 更新与空闲表回收), 避免冲掉重定向后的正确路径。
      needFlush := mbValid && (mbHasExcept ||
        (mbEntries(0).state.mispredict && !mbEntries(0).state.earlyRedirected) ||
        mbLinearRecover)

      // round-12(EXE 提前重定向):squash 拍抑制提交 pop——ROB 尾部压缩
      // (pushPtr:=robIdx+1 / occupancy 重写)与 CM1 的 pop 决策同拍竞争时,
      // pop 会钻进被冲刷区(popPtr 越过 squash 点,头项是永不完结的死项),
      // 整机死锁。squash 生效拍把 CM1 fire 压 0,1 拍后按新 occupancy 续提。
      val earlySquashGating = robFIFO.earlyRedirect.valid
      // round-13(早重定向重做):回推状态(声明提前——CM1 门控引用 drainActive)。
      // 回推期间抑制提交 pop:否则提交 push 与回推并发时压缩网络的总 push 数
      // 可超过 freeList 空闲空间,末位回推项被丢弃→寄存器泄漏。
      val robDepth = config.rob.robDepth
      val snapCnt = RegInit(U(0, log2Up(robDepth) bits))
      val snapData = Vec(Reg(Bits(1 + config.regFile.prfAddrWidth bits)), robDepth - 1)
      val drainPtr = RegInit(U(0, log2Up(robDepth) bits))
      val recoverPort = Flow(UInt(config.regFile.prfAddrWidth bits))
      val drainActive = drainPtr < snapCnt
      // ---- CM1: 决策(纯寄存输入, 带 flush/回收抑制) ----
      // 掩码展开为每口布尔式; complete 前缀、异常或 unique/recover 掩码
      // 不再需要 andR/orR 树; 每口 ready 从 state Q 起约 3~4 级
      val c0 = popPorts(0).state.complete
      val mp0 = popPorts(0).state.mispredict
      linearRecover := popPorts(0).info.uop.flushState ||
        (!popPorts(0).info.uop.branchLike && mp0)
      val blk0 = popPorts(0).state.except.valid || linearRecover
      // uncachedMask 是允许位(FSM 默认 setAll=1), 直接作 AND 因子
      popPorts(0).ready := c0 && uncachedMask(0) && !needFlush &&
        !earlySquashGating && !drainActive

      if (retireWidth > 1) {
        val c1 = popPorts(1).state.complete
        val blk1 = popPorts(1).state.except.valid || linearRecover
        val uq1 = popPorts(1).info.uop.uniqueRetire
        popPorts(1).ready := c0 && c1 && !(blk0 || blk1) && !uq1 && !mp0 &&
          uncachedMask(1) && !needFlush && !earlySquashGating && !drainActive
        if (retireWidth > 2) {
          val c2 = popPorts(2).state.complete
          val blk2 = popPorts(2).state.except.valid || linearRecover
          val uq2 = popPorts(2).info.uop.uniqueRetire
          val mp1 = popPorts(1).state.mispredict
          popPorts(2).ready := c0 && c1 && c2 && !(blk0 || blk1 || blk2) &&
            !(uq1 || uq2) && !(mp0 || mp1) && uncachedMask(2) && !needFlush &&
            !earlySquashGating && !drainActive
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
      // round-13: 早重定向的空闲表回收走快照回推(recoverPort),此处只剩
      // 常规 flush 的全量恢复
      recoverPRF := regFlush
      robFIFO.fifoIO.flush := needFlush

      // clear frontend pipelines
      pipeline.fetchPipeline.stages.last.arbitration.flushIt setWhen needFlush
      pipeline.decodePipeline.stages.last.arbitration.flushIt setWhen needFlush

      // round-12(EXE 提前重定向):BRU 在 WB 拍已发起——取指重定向 + 前端冲洗
      val earlyRedir = robFIFO.earlyRedirect
      // round-13:earlyRedirect.valid 是 6 拍 hold(WB 滞留期间持续有效)——
      // 非幂等消费者(前端 flushIt)必须用上升沿脉冲,否则新流前几拍被反复
      // 冲掉(实测功能点错误)。
      val earlyRedirRising = earlyRedir.valid && !RegNext(earlyRedir.valid, init = False)
      // round-13:取指侧跳转握手需要多拍在场(earlyRedirect.valid 已是锁存
      // 单脉冲,ICache refetch 状态机会漏掉单拍跳转→前端排空冻结,实测)。
      // 跳转信号单独保持 4 拍;其余消费者(flushIt/快照/门控)用脉冲。
      val earlyRedirHold = RegInit(False)
      val earlyRedirHoldCnt = RegInit(U(0, 2 bits))
      when(earlyRedir.valid) {
        earlyRedirHold := True
        earlyRedirHoldCnt := 0
      }
      when(earlyRedirHold && earlyRedirHoldCnt < 3) {
        earlyRedirHoldCnt := earlyRedirHoldCnt + 1
      }
      when(earlyRedirHold && earlyRedirHoldCnt === 3) {
        earlyRedirHold := False
      }
      when(earlyRedir.valid || earlyRedirHold) {
        jumpInterface.valid := True
        jumpInterface.payload := earlyRedir.target
      }
      pipeline.fetchPipeline.stages.last.arbitration.flushIt setWhen earlyRedirRising
      pipeline.decodePipeline.stages.last.arbitration.flushIt setWhen earlyRedirRising

      // round-13(早重定向重做):快照式空闲表回收——squash 拍并行捕获被冲刷
      // 弧(robIdx+1 .. pushPtr-1)的影子表内容,随后逐拍 1 项回推 recoverPort。
      // 捕获必须先于回推(新 squash 覆盖旧快照);影子表在 squash 拍稳定
      // (派发已被 !earlyRedirect.valid 门控)。回推期间 CM1 抑制(drainActive),
      // 回推独占压缩网络前口,空闲空间 ≥1 恒成立(分支未提交 outstanding≥1)。
      when(earlyRedir.valid && !robFIFO.fifoIO.flush) {
        drainPtr := 0
        snapCnt := (robFIFO.robInfo.pushPtr - earlyRedir.robIdx - 1).resized
        for (e <- 0 until robDepth - 1) {
          // +e 扩位后截断回 robAddressWidth(模 2^depth 回绕语义保留)
          snapData(e) := recoverShadow((earlyRedir.robIdx + 1 + e).resized)
        }
      }
      recoverPort.valid := False
      recoverPort.payload := 0
      when(drainPtr < snapCnt && !earlyRedir.valid && !robFIFO.fifoIO.flush) {
        recoverPort.valid := snapData(drainPtr)(0)
        recoverPort.payload := snapData(drainPtr)(config.regFile.prfAddrWidth downto 1).asUInt
        drainPtr := drainPtr + 1
      }
      // 常规 flush 时清回推状态(regFlush 全量恢复接管,防双回收/残留抑制)
      when(needFlush) {
        drainPtr := 0
        snapCnt := 0
      }
      // 回推并入 arfCommits 末槽(压缩网络保序);addr/prfAddr 占位 0,
      // RenamePlugin 对 addr=0 跳过 aRAT 更新
      when(recoverPort.valid) {
        arfCommits(retireWidth).valid := True
        arfCommits(retireWidth).payload.addr := 0
        arfCommits(retireWidth).payload.prevAddr := recoverPort.payload
        arfCommits(retireWidth).payload.prfAddr := 0
      }

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
        // round-12: 提前重定向过的分支不再重复重定向
        when(entry0.state.mispredict && uop0.branchLike && !entry0.state.earlyRedirected) {
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
