package NOP.pipeline.core

import spinal.core._
import spinal.core.sim._
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

/** [stage1] 提交邮箱中每个 retire 口的 ARF/freeList 瘦身字段。
  */
final case class CommitMailboxArfBundle(config: RegFileConfig) extends Bundle {
  val fire = Bool()
  val doRegWrite = Bool()
  val wbAddr = UInt(config.arfAddrWidth bits)
  val wReg = UInt(config.prfAddrWidth bits)
  val wPrevReg = UInt(config.prfAddrWidth bits)
}

/** [stage1] 提交邮箱:CM1(决策拍)与 CM2(执行拍)之间的唯一接口。
  *
  * CM1 拍 fire 的条目组在 T→T+1 沿整体装入本邮箱;所有提交动作
  * (ARF/PRF/freeList/BTB/TLB/CSR/ICache/StoreBuffer/异常/重定向)在 CM2 拍
  * 只读邮箱寄存器,不再读 ROB pop 口。
  * port0 保留提交决策所需的全部字段;port1/2 仅保留 ARF 瘦身字段。
  */
final case class CommitMailboxBundle(config: MyCPUConfig) extends Bundle {
  // port0 全字段
  val uop = ROBMicroOp(config)
  val frontendExc = Bool()
  val excPayload = ExceptionPayloadBundle(true)
  val mispredict = Bool()
  val actualTaken = Bool()
  // stage2-③: 误预测已在 EXE 拍提前重定向(前端引导+GHR 修复已做)
  val earlyResolved = Bool()
  val intResult = UWord()
  // 每口 ARF/freeList 瘦身字段(port0 的 ARF 提交也经此,与 uop/rename 冗余但统一装配)
  val arf = Vec(CommitMailboxArfBundle(config.regFile), config.rob.retireWidth)
  // 决策字段快照(CM1 拍值,含 intPending 采样)
  val hasExcept = Bool()
  val linearRecover = Bool()
}

/** stage2-③ prefix 检查探针总线(精度守卫,纯组合发布;仅 enableEarlyRedirect 时
  * 由各执行管道插件驱动、IntExecutePlugin(FU0) 在 ISS 拍消费)。
  */
final case class IntPipeHazardProbe(robW: Int) extends Bundle {
  val exeValid = Bool()
  val exeCtl = Bool() // branchLike || writeCSR || operateTLB
  val exeRobIdx = UInt(robW bits)
  val wbValid = Bool()
  val wbCtl = Bool()
  val wbRobIdx = UInt(robW bits)
}

final case class MemPipeHazardProbe(robW: Int) extends Bundle {
  val valid = Bool()
  val robIdx = UInt(robW bits)
}

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

  // [stage1] SpinalSim 探针别名(纯对象引用,零硬件影响;信号本体在
  // retire area 内已 simPublic)
  var probeMboxValid: Bool = null
  var probeMboxWen: Bool = null
  var probeUncachedMask: Bits = null
  var probeUncachedKickReg: Bool = null
  var probeReadyMask: Bits = null

  // ---- stage2-③: EXE 提前重定向 ----
  // GHR 早修复通道(IntExecutePlugin FU0 WB 拍驱动,GlobalPredictorBTBPlugin 消费)
  val exeGhrRestoreIn = Flow(UInt(config.frontend.bpu.historyWidth bits)).setIdle()
  // prefix 检查探针总线(③.4;仅 enableEarlyRedirect 时驱动/消费)
  val intPipeProbes = Vec(IntPipeHazardProbe(config.rob.robAddressWidth), config.intIssue.issueWidth)
  // stage3-⑥: taps 宽度由 memPipeline.stages.size 派生(杜绝硬编码;build 期初始化)
  private var memPipeProbesVar: Vec[MemPipeHazardProbe] = null
  def memPipeProbes: Vec[MemPipeHazardProbe] = memPipeProbesVar
  // [stage2-③] SpinalSim 探针别名
  var probeFlushBackend: Bool = null
  var probeFlushFrontend: Bool = null
  var probeExeRedirectFire: Bool = null
  var probeHoldDispatch: Bool = null
  var probeEarlyMispredictCommit: Bool = null
  var probeRenameFire: Bool = null
  var probeExeGhrRestoreFire: Bool = null

  override def build(pipeline: MyCPUCore): Unit = pipeline plug {
    val robFIFO = pipeline.service(classOf[ROBFIFOPlugin])
    val jumpInterface = pipeline.fetchPipeline.service(classOf[ProgramCounterPlugin]).backendJumpInterface
    // stage3-⑥: MEM 探针总线宽度 = MEM 管道级数(8=ISS/RRD/MEMADDR/MEMTLB/MEM1/MEM2/WB/WB2)
    memPipeProbesVar = Vec(MemPipeHazardProbe(config.rob.robAddressWidth), pipeline.memPipeline.stages.size)

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
        entry.state.earlyResolved := False // stage2-③: WB 拍由 robWriteBRU 写入

        port.valid := arbitration.isValidNotStuck && valid
        arbitration.haltItself setWhen (arbitration.isValid && valid && !port.ready)
        // stage2-③ R9-1: 早重定向后冻结 rename，直到提交侧清理完成（regFlush）
        arbitration.haltItself setWhen holdDispatch
        robIdxs(i) := robFIFO.pushPtr + i
      }
    }

    val retire = new Area {
      // retire asynchronously pops from ROB
      val popPorts = robFIFO.fifoIO.pop

      // ! First set default values for variables in CommitTraits
      // Exception Commit
      ertn := False
      // ARF Commit(arfCommits 各字段由邮箱无条件驱动,见 retire area 末尾)
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

      // ======================= CM1 决策拍(周期 T) =======================
      // mask/ready/fire 逻辑与 F3 相同;输入全部是寄存器(robState 投机读 FF、
      // rsp 副本 FF、intPending 的 CSR FF 源、uncached FSM 状态 FF)。
      // ! Calculate instructions that can be retired
      // 所有mask相与得到最终可以retire的指令
      val completeMask = B((0 until retireWidth).map { i =>
        // 左侧包括自己都complete
        popPorts.take(i + 1).map(_.state.complete).andR
      })
      val excMask = Bits(retireWidth bits) // exception
      val uniqueMask = Bits(retireWidth bits) // unique retire
      val recoverMask = Bits(retireWidth bits) // mispredict recover
      val uncachedMask = out Bits (retireWidth bits) // uncached load/store
      DuncachedMask := uncachedMask // TODO: [NOP] Remove debug signals

      // [stage1] 陈旧投机读防护:派发写入的槽位次拍才反映到投机读,
      // stale 口禁止 fire(仅推迟 1 拍),累积与保持 fire 连续性。
      val freshMask = Bits(retireWidth bits)
      val freshChain = (0 until retireWidth)
        .scanLeft(True: Bool)((acc, j) => acc && !robFIFO.popStateStale(j))
        .tail
      for (i <- 0 until retireWidth) {
        freshMask(i) := freshChain(i)
      }

      excMask(0) := True
      uniqueMask(0) := True
      recoverMask(0) := True

      for (i <- 1 until retireWidth) {
        val port = popPorts(i)
        // 左侧包括自己没有非 delay slot 控制流转移，可以 commit
        excMask(i) := !popPorts
          .take(i + 1)
          .map { p => p.state.except.valid || linearRecover }
          .orR
        // 1~i没有要求在0口commit的指令
        // 这里unique retire只要求在0口commit，并不影响其它非unique指令在后面commit，
        // 因此控制流指令不能只依赖unique retire
        // load指令包含在了unique retire中，因此不需要另外判断uncached了
        uniqueMask(i) := !popPorts
          .slice(1, i + 1)
          .map(p => p.info.uop.uniqueRetire)
          .orR

        // If port 0 mispredict, then recoverMask(1) is False
        recoverMask(i) := !popPorts
          .slice(0, i)
          .map(p => p.state.mispredict)
          .orR
      }

      // readyMask: which instructions can be committed (pop out from ROB)
      val readyMask = completeMask & excMask & uniqueMask & recoverMask & uncachedMask & freshMask

      for (i <- 0 until retireWidth) {
        popPorts(i).ready := readyMask(i)
      }

      // CM1 fire 汇总:popCount 只驱动 popPtr 更新(MultiPortFIFO 内部,不动)
      // 与邮箱装载标记。
      val cm1Fire = Vec(popPorts.map(_.fire))
      val cm1Load = cm1Fire.orR

      // ======================= 提交邮箱 =======================
      val mboxValid = RegInit(False)
      val mbox = Reg(CommitMailboxBundle(config))

      // ======================= CM2 执行拍(周期 T+1) =======================
      // needFlush 驱动源随邮箱自然寄存化:mbox FF Q → ≤3 级译码 → 4 处扇出
      val cm2Fire0 = mboxValid && mbox.arf(0).fire
      // stage2-③ needFlush 分裂:flushBackend=原 needFlush 语义(ROB flush/regFlush/
      // IQ/exe/mem flush 全沿用);flushFrontend 对早 resolved 的误预测不再冲刷前端
      flushBackend := cm2Fire0 && (mbox.hasExcept || mbox.mispredict || mbox.linearRecover)
      flushFrontend := cm2Fire0 &&
        (mbox.hasExcept || mbox.linearRecover || (mbox.mispredict && !mbox.earlyResolved))
      needFlush := flushBackend // CommitTraits 兼容别名(语义不变)

      // flush/pop 对齐协议 R1:flush 拍禁止邮箱装载。T+1 拍 wrong-path 条目
      // 可能 fire(popPtr 悬空前进,被同拍 flush 覆盖,R2),但其不进邮箱、
      // 不产生任何提交动作。
      val mboxWen = cm1Load && !needFlush

      // uncached FSM 的 commitStore 脉冲经 uncachedKick 晚 1 拍发出(A.5-R1)。
      // 互斥证明:kick 产生的 T 拍 uncachedMask=0 → 全口无 fire → T 拍无提交
      // → T+1 拍邮箱无 commitStore。
      val uncachedKick = Bool()
      uncachedKick := False
      val uncachedKickReg = RegNext(uncachedKick, init = False)

      val port0Commit = new Area {
        // port0特殊处理(CM1 决策部分)
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

        // mispredict仍然会提交分支指令和delay slot，所以要先更新ARF，再回滚PRF
        // flush的下一个周期不会pop，所以没有关系
        // [stage1] needFlush 现为 CM2 拍,regFlush 落 T+2,freeList 走既有
        // recover 路径(pushPtr:=popPtr),与 F3 的相对先后关系保留(裁决 A1)
        recoverPRF := regFlush // regFlush 是 needFlush 延迟一个周期

        val uncachedProcess = new Area {
          // 处理uncached load的提交问题
          // uncached load要等待store buffer将其发射并执行到WB阶段才能提交
          // 避免出现寄存器已经被重分配出去的问题
          // [stage1] FSM 整体留 CM1,输入与 F3 完全相同的寄存器(裁决 R1)
          val isUncachedUOP = uop.isLoad && entry.state.lsuUncached
          val fsm = new StateMachine {
            disableAutoStart()
            setEntry(stateBoot)
            val execute = new State

            uncachedMask.setAll()
            stateBoot.whenIsActive {
              // [stage1] 防护:!popStateStale(0) 排除陈旧投机读误触发;
              // !needFlush 排除 CM2 flush 拍(T+1) wrong-path 头条目误触发
              // ——该拍 ROB 指针尚未清零,port0 可能是 wrong-path 的
              // uncached load,触发后会发出幽灵 commitStore。
              when(
                port.valid && isUncachedUOP && entry.state.complete && !hasExcept &&
                  !robFIFO.popStateStale(0) && !needFlush
              ) {
                // 不提交，等待store buffer执行
                uncachedMask := 0
                uncachedKick := True
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

      // ======================= 邮箱装载(T→T+1 沿) =======================
      mboxValid := mboxWen
      when(mboxWen) {
        mbox.uop := popPorts(0).info.uop
        mbox.frontendExc := popPorts(0).info.frontendExc
        mbox.excPayload := popPorts(0).state.except.payload
        mbox.mispredict := popPorts(0).state.mispredict
        mbox.actualTaken := popPorts(0).state.actualTaken
        mbox.earlyResolved := popPorts(0).state.earlyResolved // stage2-③
        mbox.intResult := popPorts(0).state.intResult
        mbox.hasExcept := hasExcept
        mbox.linearRecover := linearRecover
        for (i <- 0 until retireWidth) {
          mbox.arf(i).fire := cm1Fire(i)
          mbox.arf(i).doRegWrite := popPorts(i).info.uop.doRegWrite
          mbox.arf(i).wbAddr := popPorts(i).info.uop.wbAddr
          mbox.arf(i).wReg := popPorts(i).info.rename.wReg
          mbox.arf(i).wPrevReg := popPorts(i).info.rename.wPrevReg
        }
      }

      // ======================= CM2 提交动作(只读邮箱) =======================
      robFIFO.fifoIO.flush := flushBackend // flush 周期覆盖 wrong-path pop 的指针前进

      // clear frontend pipelines(stage2-③: 早 resolved 的误预测不再冲刷前端)
      pipeline.fetchPipeline.stages.last.arbitration.flushIt setWhen flushFrontend
      pipeline.decodePipeline.stages.last.arbitration.flushIt setWhen flushFrontend
      if (config.frontend.enableEarlyRedirect) {
        // stage2-③ T_e 拍组合冲刷 fetch/decode(R9:原位,与 needFlush 同机制)
        pipeline.fetchPipeline.stages.last.arbitration.flushIt setWhen exeRedirectIn.valid
        pipeline.decodePipeline.stages.last.arbitration.flushIt setWhen exeRedirectIn.valid
      }

      // exception永远从0口unique发出
      except.valid := cm2Fire0 && mbox.hasExcept
      except.payload := mbox.excPayload
      // 前端异常的badVA必然是pc
      when(mbox.frontendExc) { except.badVA := mbox.uop.pc }
      epc := mbox.uop.pc

      when(mboxValid && mbox.arf(0).fire && !mbox.hasExcept) {
        // 所有指令性的commit需要在没有except的时候发出
        val uop = mbox.uop

        cacheOp.valid := uop.operateCache
        // 复用badVA，如果没有异常的时候badVA填cache需要的物理地址
        cacheOp.payload.addr := mbox.excPayload.badVA
        cacheOp.payload.op assignFromBits mbox.intResult(0, CacheOpType.None.asBits.getWidth bits).asBits
        cacheOp.payload.sel assignFromBits mbox
          .intResult(CacheOpType.None.asBits.getWidth, CacheSelType.None.asBits.getWidth bits)
          .asBits

        doWait := uop.isWait
        tlbOp := uop.tlbOp
        tlbInvASID := mbox.intResult(9 downto 0).asBits
        tlbInvVPPN := mbox.intResult(28 downto 10).asBits

        when(uop.writeCSR) {
          CSRWrite.valid := True
          CSRWrite.payload.data := mbox.intResult.asBits
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

        // ! BTB Pred Update(随邮箱整体晚 1 拍,消费端不动)
        predUpdate.valid := uop.branchLike || uop.predInfo.predictBranch
        predUpdate.payload.predInfo := uop.predInfo
        predUpdate.payload.predRecover := uop.predRecover
        predUpdate.payload.branchLike := uop.isBranch || uop.isJump || uop.isJR // jump is a always true branch for btb
        // returns also needed to record in btb for ras to predict correctly.
        predUpdate.payload.isTaken := (mbox.mispredict ^ uop.predInfo.predictTaken) || uop.isJump || uop.isJR // note that jump and jr is always taken...
        // 'jr ra'
        predUpdate.payload.isRet := B"01001100000000000000000000100000" === uop.inst // 0x4c000020
        // Call: JIRL with RA linkage and BL
        predUpdate.payload.isCall := (uop.isJR && uop.inst(4 downto 0) === B"00001") || (uop.isJump && uop.inst(26))
        predUpdate.payload.mispredict := mbox.mispredict
        predUpdate.payload.pc := uop.pc
        predUpdate.payload.target := mbox.intResult

        val jumpTarget = U(0, 32 bits)

        when(uop.isJump || uop.isJR) {
          jumpTarget := mbox.intResult // when is Jump, go to actual target
        } otherwise {
          jumpTarget := Mux(
            mbox.actualTaken,
            mbox.intResult,
            uop.pc + 4
          ) // when branch, decide recover or not based on predictTaken
        }

        when(mbox.linearRecover && !uop.isErtn) {
          // 这些是本身不改变控制流，但因为flush而需要改变控制流
          jumpInterface.valid := True
          // [NOP] 被改成了直接用 pc + 4
          jumpInterface.payload := uop.pc + 4
        }

        // stage2-③: 早 resolved 的误预测不再发 jumpInterface(前端已引导);
        // linearRecover 分支不经门控
        when(mbox.mispredict && uop.branchLike && !mbox.earlyResolved) {
          jumpInterface.valid := True
          jumpInterface.payload := jumpTarget
        }

        // 以上优先级是重要的。Branch本身的跳转目标优先于delay slot中的mispredict（一定非branch）。
      }

      // uncached kick 脉冲(与邮箱 commitStore 互斥,证明见上)
      when(uncachedKickReg) {
        commitStore := True
      }

      // ARF 提交:port0~2 统一由邮箱驱动
      for (i <- 0 until retireWidth) {
        arfCommits(i).valid := mboxValid && mbox.arf(i).fire && !mbox.hasExcept && mbox.arf(i).doRegWrite
        arfCommits(i).payload.addr := mbox.arf(i).wbAddr
        arfCommits(i).payload.prevAddr := mbox.arf(i).wPrevReg
        arfCommits(i).payload.prfAddr := mbox.arf(i).wReg
      }

      // ---- stage2-③ R9-1 互锁:holdDispatch set/clear(set 优先,嵌套重定向场景) ----
      when(regFlush) { holdDispatch := False }
      when(exeRedirectIn.valid) { holdDispatch := True }

      // 开关关闭时探针总线置零(不被消费,仅避免悬空)
      if (!config.frontend.enableEarlyRedirect) {
        intPipeProbes.foreach { p =>
          p.exeValid := False; p.exeCtl := False; p.exeRobIdx := 0
          p.wbValid := False; p.wbCtl := False; p.wbRobIdx := 0
        }
        memPipeProbes.foreach { p => p.valid := False; p.robIdx := 0 }
      }

      // [stage1] SpinalSim 断言挂钩(零逻辑测试探针)
      needFlush.simPublic()
      regFlush.simPublic()
      mboxValid.simPublic()
      mboxWen.simPublic()
      uncachedMask.simPublic()
      uncachedKickReg.simPublic()
      commitStore.simPublic()
      readyMask.simPublic()
      probeMboxValid = mboxValid
      probeMboxWen = mboxWen
      probeUncachedMask = uncachedMask
      probeUncachedKickReg = uncachedKickReg
      probeReadyMask = readyMask

      // [stage2-③] SpinalSim 探针(仅挂属性/别名,零硬件影响)
      flushBackend.simPublic()
      flushFrontend.simPublic()
      exeRedirectIn.valid.simPublic()
      exeGhrRestoreIn.valid.simPublic()
      holdDispatch.simPublic()
      val earlyMispredictCommit = (cm2Fire0 && mbox.mispredict && mbox.earlyResolved).simPublic()
      val renameFire = pipeline.RENAME.arbitration.isFiring.simPublic()
      probeFlushBackend = flushBackend
      probeFlushFrontend = flushFrontend
      probeExeRedirectFire = exeRedirectIn.valid
      probeExeGhrRestoreFire = exeGhrRestoreIn.valid
      probeHoldDispatch = holdDispatch
      probeEarlyMispredictCommit = earlyMispredictCommit
      probeRenameFire = renameFire
    }

    retire
  }
}
