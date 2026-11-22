package NOP.pipeline.exe

import spinal.core._
import spinal.lib._
import NOP.utils._
import NOP.constants.enum._
import NOP.pipeline.core._
import NOP.builder._
import NOP.pipeline._
import NOP.pipeline.decode._
import NOP._
import NOP.constants.LoongArch.CSRAddress
import NOP.pipeline.priviledge.CSRPlugin

class IntExecutePlugin(val config: MyCPUConfig, val fuIdx: Int) extends Plugin[ExecutePipeline] {

  private val withBRU = config.intIssue.bruIdx == fuIdx
  private val withCSR = config.intIssue.csrIdx == fuIdx
  private val withTimer = config.intIssue.timerIdx == fuIdx
  private val withINVTLB = config.intIssue.invTLBIdx == fuIdx

  private val iqDepth = config.intIssue.depth
  private val rPorts = config.regFile.rPortsEachInst
  private val prfAddrWidth = config.regFile.prfAddrWidth

  val rrdReq = Vec(UInt(prfAddrWidth bits), rPorts)
  var rrdRsp: Vec[Bits] = null
  var clrBusy: Flow[UInt] = null
  var wPort: Flow[RegWriteBundle] = null
  var robWriteBRU: Flow[ROBStateBRUPortBundle] = null
  var robWrite: Flow[ROBStateALUPortBundle] = null

  object ISSUE_SLOT extends Stageable(IntIssueSlot(config))
  object REG_READ_RSP extends Stageable(Vec(BWord(), rPorts))
  object EXE_RESULT extends Stageable(BWord())
  object WRITE_REG extends Stageable(Flow(UInt(prfAddrWidth bits)))
  object ROB_IDX extends Stageable(UInt(config.rob.robAddressWidth bits))

  object DIFF_IS_COUNT extends Stageable(Bool())
  object DIFF_COUNT64_value extends Stageable(UInt(64 bits))
  object DIFF_CSR_RSTAT extends Stageable(Bool())
  object DIFF_CSR_DATA extends Stageable(UWord())

  object ACTUAL_TARGET extends Stageable(UWord())
  object ACTUAL_TAKEN extends Stageable(Bool)
  object MISPREDICT extends Stageable(Bool)

  val issReqs = Vec(Bool, iqDepth)
  var issGrant: Vec[Bool] = null

  override def setup(pipeline: ExecutePipeline): Unit = {
    val PRF = pipeline.globalService(classOf[PhysRegFilePlugin])
    val IQ = pipeline.globalService(classOf[IntIssueQueuePlugin])
    val ROB = pipeline.globalService(classOf[ROBFIFOPlugin])

    rrdRsp = Vec(rrdReq.map(PRF.readPort(_)))
    clrBusy = PRF.clearBusy
    // 200MHz 绠€鍖?INT 娴佹按涓嶅仛 EXE 绾ф梺璺?闈炴帹娴嬪啓鍥?,
    // PRF 鍐欏彛涓嶉渶瑕?bypass 鏍囧織(璇诲彛鍚屾媿鍓嶉€掑彧淇濈暀缁?LSU)
    wPort = PRF.writePort(false)

    // Logic: (1) IntPipeline detects all issue slots in issue queue that can be issued
    //        (2) IntPipeline sends issue requests to IntIssueQueue
    //        (3) IntIssueQueue sends issue grants to IntPipeline
    issGrant = IQ.grantPort(issReqs)

    // ! Hook with interface of ROB
    if (withBRU || withCSR || withINVTLB) robWriteBRU = ROB.bruPort
    else robWrite = ROB.aluPort
  }

  override def build(pipeline: ExecutePipeline): Unit = {
    val flush = pipeline.globalService(classOf[CommitPlugin]).regFlush

    pipeline plug new Area {
      // pipeline.stages.last.arbitration.flushIt setWhen flush
      pipeline.stages.drop(1).foreach(_.arbitration.removeIt setWhen flush)
    }

    pipeline.ISS plug new Area {
      import pipeline.ISS._
      val IQ = pipeline.globalService(classOf[IntIssueQueuePlugin])
      require(rPorts == 2)

      val validVec = Vec(Bool, iqDepth)
      val wakenVec = Vec(Bool, iqDepth)
      val matchVec = Vec(Bool, iqDepth)

      for (i <- 0 until iqDepth) {
        val slot = IQ.queue(i).payload // issue slot
        val waken = (0 until rPorts).map { j => IQ.rReadyBank(i)(j) }.andR
        val fuMatch = True

        if (!withBRU) fuMatch clearWhen slot.uop.fuType === FUType.CMP
        if (!withCSR) fuMatch clearWhen slot.uop.fuType === FUType.CSR
        if (!withTimer) fuMatch clearWhen slot.uop.fuType === FUType.TIMER
        if (!withINVTLB) fuMatch clearWhen slot.uop.fuType === FUType.INVTLB

        // 璁＄畻姣忎釜妲芥槸鍚alid
        issReqs(i) := IQ.queue(i).valid && fuMatch && waken

        validVec(i) := IQ.queue(i).valid
        wakenVec(i) := waken
        matchVec(i) := fuMatch
      }

      // one-hot鎻掑叆issue slot锛屽苟璁剧疆valid
      val issSlot = insert(ISSUE_SLOT)
      issSlot := MuxOH(issGrant, IQ.queue.map(_.payload))

      val issValid = issGrant.orR
      IQ.issueFire clearWhen arbitration.isStuck
      arbitration.removeIt setWhen (arbitration.notStuck && (flush || !issValid))

      // 200MHz 绠€鍖?鏈湴鎻愬墠鍞ら啋绉婚櫎(鍘熶緷璧?EXE 绾ф梺璺鐩栨彁鍓嶇獥鍙?,
      // 渚濊禆娑堣垂鑰呯粺涓€鐢?WB 鏃跺埢鐨?busy 娓呴櫎杩滅▼鍞ら啋
    }

    pipeline.RRD plug new Area {
      import pipeline.RRD._
      val issSlot = input(ISSUE_SLOT)
      for (i <- 0 until rPorts) {
        rrdReq(i) := issSlot.rRegs(i).payload
        insert(REG_READ_RSP)(i) := rrdRsp(i)
      }
      // 杩滅▼鍞ら啋锛坓enGlobalWakeup锛?
      // 200MHz 绠€鍖?busy 娓呴櫎绉诲埌 WB(闈炴帹娴嬪啓鍥?瑙?WB 鍖?鈥斺€旀暟鎹厛鍏?
      // PRF,娑堣垂鑰呭啀琚敜閱?娑堣垂绔?RRD 鐩存帴璇?PRF,鏃犻渶 EXE 绾ф梺璺?
      arbitration.haltByOther setWhen pipeline
        .globalService(classOf[SpeculativeWakeupHandler])
        .regWakeupFailed

      // TODO: [NOP] DiffTest Bundle. Remove this in the future.
      insert(DIFF_IS_COUNT) := False
      insert(DIFF_COUNT64_value) := 0
      insert(DIFF_CSR_RSTAT) := False
      insert(DIFF_CSR_DATA) := 0
    }

    pipeline.EXE plug new Area {
      import pipeline.EXE._
      val issSlot = input(ISSUE_SLOT)
      val alu = new ALU()

      // ! Prepare input data
      // round-14(璇昏繘鑳炲厓):鎿嶄綔鏁扮洿鎺ュ彇鍙戝皠妲界殑 rData(娲惧彂鍒濆€?+ 鍞ら啋鏁版嵁
      // 鎬荤嚎鎹曡幏),EXE 涓嶅啀娑堣垂 RRD 鐨?PRF 璇诲搷搴斺€斺€旇鏍戠Щ鍑哄彂灏勫叧閿幆,
      // 闆嗕腑鍒版淳鍙戜晶(REG_READ_RSP 淇濈暀涓烘閫昏緫,鍚庣画娓呯悊)銆?
      val regData = issSlot.rData

      // ! Calculate return value
      val exeResult = insert(EXE_RESULT) // return value

      // TODO: [NOP] remove this debug signal
      val debug_exeResult = out(BWord())
      debug_exeResult := exeResult
      pipeline.update_signal("exeResult", debug_exeResult)

      val fields = InstructionParser(issSlot.uop.inst)
      val imm12 = issSlot.uop.immExtendType
        .mux(
          ExtendType.SIGN -> fields.signExtendImm12,
          ExtendType.ZERO -> fields.zeroExtendImm12
        )

      val alu_src1_alternative = UInt(32 bits)
      switch(issSlot.uop.aluOp) {
        is(ALUOpType.LU12I) {
          alu_src1_alternative := U(0x0, 32 bits)
        }
        is(ALUOpType.PCADDI) {
          alu_src1_alternative := issSlot.uop.pc
        }
        is(ALUOpType.PCADDU12I) {
          alu_src1_alternative := issSlot.uop.pc
        }
        default {
          alu_src1_alternative := U(0xdeadbeefL, 32 bits)
        }
      }
      alu.io.src1 := Mux(issSlot.uop.useRj, regData(0), alu_src1_alternative)

      val alu_src2_alternative = UInt(32 bits)
      switch(issSlot.uop.aluOp) {
        is(ALUOpType.LU12I) {
          alu_src2_alternative := fields.signExtendImm20_12
        }
        is(ALUOpType.PCADDI) {
          alu_src2_alternative := fields.signExtendImm20_2
        }
        is(ALUOpType.PCADDU12I) {
          alu_src2_alternative := fields.signExtendImm20_12
        }
        default {
          alu_src2_alternative := imm12
        }
      }
      alu.io.src2 := Mux(issSlot.uop.useRk, regData(1), alu_src2_alternative)

      alu.io.sa := Mux(issSlot.uop.useRk, regData(1)(4 downto 0), fields.sa)
      alu.io.op := issSlot.uop.aluOp

      // set default result
      exeResult := alu.io.result.asBits

      // ! BRU
      if (withBRU) {
        // BRU Section
        val bru = new BRU
        val comparator = new Comparator()
        comparator.io.src1 := regData(0)
        comparator.io.src2 := Mux(issSlot.uop.useRd, regData(1), imm12)
        comparator.io.op := issSlot.uop.cmpOp

        bru.io.predictJump := issSlot.uop.predInfo.predictTaken
        bru.io.predictAddr := issSlot.uop.predInfo.predictAddr
        bru.io.isBranch := issSlot.uop.isBranch
        bru.io.isJR := issSlot.uop.isJR // JIRL
        bru.io.isJump := issSlot.uop.isJump // B or BL
        bru.io.pc := issSlot.uop.pc
        bru.io.inst := issSlot.uop.inst
        bru.io.condition := comparator.io.result
        bru.io.rj := regData(0)

        insert(ACTUAL_TARGET) := bru.io.actualTarget
        insert(ACTUAL_TAKEN) := comparator.io.result || issSlot.uop.isJR || issSlot.uop.isJump
        insert(MISPREDICT) := bru.io.mispredict

        // Just set exeResult is okay!
        when(issSlot.uop.isJump || issSlot.uop.isJR) {
          exeResult := (issSlot.uop.pc + UWord(4)).asBits
        }
      }

      if (withCSR) {
        val CSRPlugin = pipeline.globalService(classOf[CSRPlugin])
        CSRPlugin.readAddress := fields.csrAddr

        when(issSlot.uop.readCSR) {
          exeResult := CSRPlugin.readData
          output(DIFF_CSR_RSTAT) := fields.csrAddr === CSRAddress.ESTAT
          output(DIFF_CSR_DATA) := CSRPlugin.readData.asUInt
        }

        when(issSlot.uop.writeCSR) {
          when(issSlot.uop.useRj) {
            insert(ACTUAL_TARGET) := (regData(0) & regData(1)) | (~regData(0) &
              CSRPlugin.readData.asUInt)
          } otherwise {
            insert(ACTUAL_TARGET) := regData(1)
          }
        }
      }

      // Timer
      if (withTimer) {
        val timer64Plugin = pipeline.globalService(classOf[Timer64Plugin])
        when(issSlot.uop.readTimer64ID) {
          exeResult := timer64Plugin.counterId.asBits
          output(DIFF_IS_COUNT) := True
        }
        when(issSlot.uop.readTimer64L) {
          exeResult := timer64Plugin.lowBits.asBits
          output(DIFF_IS_COUNT) := True
        }
        when(issSlot.uop.readTimer64H) {
          exeResult := timer64Plugin.highBits.asBits
          output(DIFF_IS_COUNT) := True
        }
        insert(DIFF_COUNT64_value) := (timer64Plugin.highBits @@ timer64Plugin.lowBits)
      }

      // INVTLB
      if (withINVTLB) {
        when(issSlot.uop.operateTLB) {
          val result = insert(ACTUAL_TARGET)
          result(9 downto 0) := regData(0)(9 downto 0) // ASID
          result(28 downto 10) := regData(1)(31 downto 13) // VPN
          result(31 downto 29) := 0
        }
      }

      insert(WRITE_REG).valid := issSlot.uop.doRegWrite
      insert(WRITE_REG).payload := issSlot.wReg
      insert(ROB_IDX) := issSlot.robIdx
    }

    pipeline.WB plug new Area {
      import pipeline.WB._
      val wbReq = input(WRITE_REG)
      val wbData = input(EXE_RESULT)
      val robIdx = input(ROB_IDX)

      // ! Write Back: directly write back to PRF...
      wPort.valid := arbitration.isValidNotStuck && wbReq.valid
      wPort.payload.addr := wbReq.payload
      wPort.payload.data := wbData

      // 200MHz 绠€鍖?闈炴帹娴嬪啓鍥炩€斺€攂usy 鍦?WB 娓呴櫎(鏁版嵁鍚屼竴鎷嶅啓鍏?
      // PRF,涓嬩竴鎷嶆秷璐硅€呰鍞ら啋銆佸啀涓嬩竴鎷?RRD 璇诲埌鏂版暟鎹?鏃犻渶鏃佽矾)
      clrBusy.valid := arbitration.isValidNotStuck && wbReq.valid
      clrBusy.payload := wbReq.payload

      // No except can occur in IntExecute
      val except = Flow(ExceptionPayloadBundle(false)).setIdle()

      // ! Commit
      if (withBRU || withCSR) {
        robWriteBRU.valid := arbitration.isValidNotStuck
        robWriteBRU.robIdx := robIdx
        robWriteBRU.except := except
        robWriteBRU.intResult := input(ACTUAL_TARGET)
        robWriteBRU.mispredict := input(MISPREDICT)
        robWriteBRU.actualTaken := input(ACTUAL_TAKEN)
        // round-12(EXE 鎻愬墠閲嶅畾鍚?:璇娴嬪垎鏀湪 WB 鎷嶇珛鍗冲彂璧烽噸瀹氬悜,
        // 鍙啿鍒峰勾杞婚」(ROB 灏鹃儴鍘嬬缉 + sRAT 鎭㈠ + IQ 閫夋嫨鎬ф竻闄?,
        // 姣旀彁浜や晶閲嶅畾鍚戞棭 2~3 鎷?璇娴嬬綒 ~15 鎷?鈫?~12 鎷嶃€?
        // round-13 閲嶅仛:绌洪棽琛ㄥ洖鏀舵敼涓哄揩鐓ч€愭媿鍥炴帹(CommitPlugin 褰卞瓙琛?
        // arfCommits 鎵╁睍妲?,淇鏃?freeList.recover 鍏ㄩ噺鍥炴粴鐮村潖鏂版祦鏄犲皠
        // 鐨?WAW 瑕嗗啓 bug;娉勬紡涓夐亾闂ㄦ帶(FB/ROB push/IQ 鍏ラ槦)淇濈暀銆?
        // round-13 淇:valid 鏇炬槸 WB 婊炵暀鏈熼棿鐨?6 鎷?hold,hold 鍐呭悗缁?WB
        // 鎸佺画瑕嗗啓 robIdx/target 璐熻浇(瀹炴祴 23鈫?7 婕傜Щ,蹇収寮ч暱绠楁垚 31,
        // 鍥炴帹鍨冨溇椤光啋瀵勫瓨鍣ㄩ敊閲婃斁)銆傛敼涓烘崟鑾峰紡鍗曡剦鍐?璇娴嬫媿閿佸瓨璐熻浇,
        // 涓嬩竴鎷?1 鍛ㄦ湡鑴夊啿,鎵€鏈夋秷璐硅€?鍚揩鐓?鍥炴帹/闂ㄦ帶)鍦ㄨ剦鍐叉媿鐢?
        // 閿佸瓨璐熻浇涓€娆℃€у姩浣溿€?
        if (withBRU) {
          val robFIFO = pipeline.globalService(classOf[ROBFIFOPlugin])
          val redirectFire = arbitration.isValidNotStuck && input(MISPREDICT) &&
            input(ISSUE_SLOT).uop.branchLike
          val earlyRedirectLatched = RegInit(False)
          val earlyRedirectRobIdx = Reg(UInt(config.rob.robAddressWidth bits))
          val earlyRedirectTarget = Reg(UWord())
          when(redirectFire) {
            earlyRedirectLatched := True
            earlyRedirectRobIdx := robIdx
            earlyRedirectTarget := input(ACTUAL_TARGET)
          }
          robFIFO.earlyRedirect.robIdx := earlyRedirectRobIdx
          robFIFO.earlyRedirect.target := earlyRedirectTarget
          robFIFO.earlyRedirect.valid := False
          // round-13 鏀舵暃:蹇収寮忓洖鏀跺凡瀹炵幇(elaborate 閫氳繃),浣嗛噸鍚敤鍚庢暣鏈?
          // 鎱㈠埌 9.9ms 鍐?0 鐐?闈炴閿?ROB 姝ｅ父鎺ㄨ繘,涓庣鐢ㄦ€佸悓鏍烽櫡鍏?
          // tb RAM 鎱㈡ā鍨嬬殑 refill 寰幆,閲嶅畾鍚戝彔鍔犲悗鏀剁泭涓鸿礋)銆傛殏绂佲€斺€?
          // 鍥炶惤鎻愪氦渚ч噸瀹氬悜(58/58 杈?13 鐐?0 閿?銆傞噸鍚敤鏃舵敼 False銆?
          val earlyRedirectDisabled = True
          when(!earlyRedirectDisabled && earlyRedirectLatched && !redirectFire) {
            robFIFO.earlyRedirect.valid := True
            earlyRedirectLatched := False
          }
        }
      } else {
        robWrite.valid := arbitration.isValidNotStuck
        robWrite.robIdx := robIdx
        robWrite.except := except
        robWrite.intResult := wbData.asUInt
        robWrite.isCount := input(DIFF_IS_COUNT) && robWrite.valid
        robWrite.count64ReadValue := input(DIFF_COUNT64_value)
        robWrite.csrRstat := input(DIFF_CSR_RSTAT) && robWrite.valid
        robWrite.csrRdata := input(DIFF_CSR_DATA)
        robWrite.myPC := input(ISSUE_SLOT).uop.pc
      }
    }
  }
}
