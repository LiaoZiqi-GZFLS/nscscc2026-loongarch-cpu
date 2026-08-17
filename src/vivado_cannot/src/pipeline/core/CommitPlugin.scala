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

  // 鍚戝鐨勬彁浜ゆ帴鍙?
  override val arfCommits = Vec(Flow(RegFileMappingEntryBundle(config.regFile)), retireWidth)

  // TODO: [NOP] Remove debug signals
  val DuncachedMask = out Bits (retireWidth bits)

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
      // P3(鎻愪氦鐜帇缂?:鎺╃爜灞曞钩涓烘瘡鍙ｅ竷灏斿紡銆俢omplete 鍓嶇紑銆佸紓甯告垨銆?
      // unique/recover 鎺╃爜涓嶅啀缁?andR/orR 鏍戝拰 5 鎺╃爜鐩镐笌鐨勪腑闂寸骇,
      // 姣忓彛 ready 浠?state Q 璧风害 3-4 绾?缁煎悎钀?LUT6,6 杈撳叆涓€缃?銆?
      // 璇箟涓庡師鎺╃爜閫愪綅涓€鑷?exc/unique/recover 浣?0 鎭掔湡(寮傚父
      // 鍙兘浠?0 鍙ｆ彁浜?銆倁ncachedMask 浠嶇敱 uncached FSM 椹卞姩銆?
      val uncachedMask = out Bits (retireWidth bits) // uncached load/store
      DuncachedMask := uncachedMask.resized // TODO: [NOP] Remove debug signals

      val c0 = popPorts(0).state.complete
      val blk0 = popPorts(0).state.except.valid || linearRecover
      val mp0 = popPorts(0).state.mispredict
      // uncachedMask 鏄?鍏佽浣?(FSM 榛樿 setAll=1),鐩存帴浣?AND 鍥犲瓙
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

      val port0Commit = new Area {
        // port0鐗规畩澶勭悊
        val port = popPorts(0)
        val entry = port.payload
        val uop = port.info.uop
        val fire = port.fire

        // 涓柇澶勭悊锛氫腑鏂褰撲綔exception鎻愪氦锛屽垯鑷劧灞忚斀鎵€鏈夋寚浠ゆ€ф彁浜?
        // exception鍒嗙被鍦╤andler涓繘琛岋紝鑻ユ湰韬氨鏈塭xception锛屼腑鏂細琚紭鍏堝鐞?
        val intPending = pipeline.service(classOf[InterruptHandlerPlugin]).intPending
        val intInhibit = False // 鐢ㄤ簬鍦╱ncached寮€濮嬫墽琛屽悗灞忚斀涓柇鐨勬彁浜?
        hasExcept := entry.state.except.valid || (intPending && !intInhibit)

        val mispredict = entry.state.mispredict

        // 闇€瑕乫lush鍒癙C+4鐨勬儏鍐碉細1. 鎸囦护鏈韩鏀瑰彉褰卞搷澶勭悊鍣ㄧ姸鎬侊紱2. 闈瀊ranch琚娴嬫敼鍙樹簡鎺у埗娴?
        linearRecover := uop.flushState || (!uop.branchLike && mispredict)

        // 闇€瑕佸洖婊氬鐞嗗櫒鐘舵€佺殑鎯呭喌锛?
        // 1. 鍒嗘敮锛氶娴嬮敊璇?
        // 2. 寮傚父
        // 3. 鍏跺畠鎻愪氦鍚庨渶瑕乫lush娴佹按绾跨殑鎸囦护
        val recoverState = fire && (hasExcept || mispredict || linearRecover)
        // 濡傛灉涓嶉渶瑕佺瓑delay slot锛屽垯绔嬪嵆flush
        needFlush := recoverState
        robFIFO.fifoIO.flush := needFlush // flush鍛ㄦ湡鍚屾椂pop

        // mispredict浠嶇劧浼氭彁浜ゅ垎鏀寚浠ゅ拰delay slot锛屾墍浠ヨ鍏堟洿鏂癆RF锛屽啀鍥炴粴PRF
        // flush鐨勪笅涓€涓懆鏈熶笉浼歱op锛屾墍浠ユ病鏈夊叧绯?
        recoverPRF := regFlush // regFlush 鏄?needFlush 寤惰繜涓€涓懆鏈?

        val jumpTarget = U(0, 32 bits)

        // clear frontend pipelines
        pipeline.fetchPipeline.stages.last.arbitration.flushIt setWhen needFlush
        pipeline.decodePipeline.stages.last.arbitration.flushIt setWhen needFlush

        // exception姘歌繙浠?鍙nique鍙戝嚭
        except.valid := fire && hasExcept
        except.payload := entry.state.except.payload
        // 鍓嶇寮傚父鐨刡adVA蹇呯劧鏄痯c
        when(entry.info.frontendExc) { except.badVA := entry.info.uop.pc }
        epc := uop.pc

        when(fire & !hasExcept) {
          // 鎵€鏈夋寚浠ゆ€х殑commit闇€瑕佸湪娌℃湁except鐨勬椂鍊欏彂鍑?

          cacheOp.valid := uop.operateCache
          // 澶嶇敤badVA锛屽鏋滄病鏈夊紓甯哥殑鏃跺€檅adVA濉玞ache闇€瑕佺殑鐗╃悊鍦板潃
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

          when(uop.isJump || uop.isJR) {
            jumpTarget := entry.state.intResult // when is Jump, go to actual target
          } otherwise {
            jumpTarget := Mux(
              entry.state.actualTaken,
              entry.state.intResult,
              uop.pc + 4
            ) // when branch, decide recover or not based on predictTaken
          }

          when(linearRecover && !uop.isErtn) {
            // 杩欎簺鏄湰韬笉鏀瑰彉鎺у埗娴侊紝浣嗗洜涓篺lush鑰岄渶瑕佹敼鍙樻帶鍒舵祦
            jumpInterface.valid := True
            // [NOP] 琚敼鎴愪簡鐩存帴鐢?pc + 4
            jumpInterface.payload := uop.pc + 4
          }

          when(entry.state.mispredict && uop.branchLike) {
            jumpInterface.valid := True
            jumpInterface.payload := jumpTarget
          }

          // 浠ヤ笂浼樺厛绾ф槸閲嶈鐨勩€侭ranch鏈韩鐨勮烦杞洰鏍囦紭鍏堜簬delay slot涓殑mispredict锛堜竴瀹氶潪branch锛夈€?
        }

        val uncachedProcess = new Area {
          // 澶勭悊uncached load鐨勬彁浜ら棶棰?
          // uncached load瑕佺瓑寰卻tore buffer灏嗗叾鍙戝皠骞舵墽琛屽埌WB闃舵鎵嶈兘鎻愪氦
          // 閬垮厤鍑虹幇瀵勫瓨鍣ㄥ凡缁忚閲嶅垎閰嶅嚭鍘荤殑闂
          val isUncachedUOP = uop.isLoad && entry.state.lsuUncached
          val fsm = new StateMachine {
            disableAutoStart()
            setEntry(stateBoot)
            val execute = new State

            uncachedMask.setAll()
            stateBoot.whenIsActive {
              when(port.valid && isUncachedUOP && entry.state.complete && !hasExcept) {
                // 涓嶆彁浜わ紝绛夊緟store buffer鎵ц
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
              // uncached load鎵ц瀹屾垚
              when(memWB.arbitration.notStuck && isUncachedWB) {
                // FIXME: 闇€瑕佷繚璇佹鍛ㄦ湡涓€瀹氭彁浜や笖涓嶈Е鍙戝紓甯?
                uncachedMask.setAll()
                goto(stateBoot)
              }
            }
          }
        }
      }

      for (i <- 0 until retireWidth) {
        val port = popPorts(i)
        val uop = port.info.uop
        val rename = port.info.rename
        when(port.fire & !hasExcept) {
          // 鎵€鏈夋寚浠ゆ€х殑commit闇€瑕佸湪娌℃湁except鐨勬椂鍊欏彂鍑?
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
