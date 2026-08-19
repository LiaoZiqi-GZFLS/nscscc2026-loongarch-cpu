package NOP.pipeline.mem

import spinal.core._
import spinal.lib._
import NOP.utils._
import NOP.constants.enum._
import NOP.pipeline.core._
import NOP.builder._
import NOP.pipeline._
import NOP.pipeline.decode._
import NOP._
import NOP.pipeline.exe.MemIssueQueuePlugin
import NOP.pipeline.priviledge.ExceptionHandlerPlugin

class MemExecutePlugin(config: MyCPUConfig) extends Plugin[MemPipeline] {
  private val dcache = config.dcache
  private val iqDepth = config.memIssue.depth
  private val rPorts = config.regFile.rPortsEachInst
  private val prfAddrWidth = config.regFile.prfAddrWidth
  val rrdReq = Vec(UInt(prfAddrWidth bits), rPorts)
  var rrdRsp: Vec[Bits] = null
  var clrBusy: Flow[UInt] = null
  var wPort: Flow[RegWriteBundle] = null
  var robWrite: Flow[ROBStateLSUPortBundle] = null

  override def setup(pipeline: MemPipeline): Unit = {
    val PRF = pipeline.globalService(classOf[PhysRegFilePlugin])
    val IQ = pipeline.globalService(classOf[MemIssueQueuePlugin])
    val ROB = pipeline.globalService(classOf[ROBFIFOPlugin])
    rrdRsp = Vec(rrdReq.map(PRF.readPort(_)))
    clrBusy = PRF.clearBusy
    wPort = PRF.writePort(true)
    robWrite = ROB.lsuPort
  }

  override def build(pipeline: MemPipeline): Unit = {

    val EXC_SIGNALS = pipeline.service(classOf[ExceptionMuxPlugin[pipeline.type]]).ExceptionSignals

    import pipeline.signals._
    val flush = pipeline.globalService(classOf[CommitPlugin]).regFlush

    pipeline plug new Area {
      // clear memory pipeline
      val commitPlugin = pipeline.globalService(classOf[CommitPlugin])
      pipeline.stages.drop(1).foreach { s =>
        s.arbitration.removeIt setWhen (commitPlugin.needFlush || flush)
      }
    }

    pipeline.ISS plug new Area {
      import pipeline.ISS._
      val storeBuffer = pipeline.service(classOf[StoreBufferPlugin])
      val IQ = pipeline.globalService(classOf[MemIssueQueuePlugin])
      // RRD, MEM1, MEM2都是潜在的push者，要保证所有发射的都能push进去
      // programmed full, 不是真的满但也不能发射了
      val stBufProgFull = storeBuffer.queue(storeBuffer.depth - 5).valid
      // CACHE指令不必顺序执行，ROB会将其重排序retire
      require(rPorts == 2)

      val QUEUE_HEAD = 0
      val slot = IQ.queue(QUEUE_HEAD).payload
      val waken = (0 until rPorts).map { j => slot.rRegs(j).valid }.andR

      // 计算每个槽是否valid
      IQ.issueReq := IQ.queue(QUEUE_HEAD).valid && waken && !stBufProgFull
      IQ.issueFire clearWhen arbitration.isStuck

      // one-hot插入issue slot，并设置valid
      val issSlot = insert(ISSUE_SLOT)
      issSlot := IQ.queue(QUEUE_HEAD).payload
       val issValid = IQ.issueReq
       when(issValid && ((IQ.queue(QUEUE_HEAD).uop.pc(19 downto 0) >= U(0x2bfb0, 20 bits) &&
          IQ.queue(QUEUE_HEAD).uop.pc(19 downto 0) <= U(0x2bfc0, 20 bits)) ||
          (IQ.queue(QUEUE_HEAD).uop.pc >= U(0x1c221000L, 32 bits) &&
            IQ.queue(QUEUE_HEAD).uop.pc <= U(0x1c221100L, 32 bits)))) {
         report(L"[RAWDBG MEM-ISS] pc=${IQ.queue(QUEUE_HEAD).uop.pc} inst=${slot.uop.inst} r0=${slot.rRegs(0).payload} v0=${slot.rRegs(0).valid} r1=${slot.rRegs(1).payload} v1=${slot.rRegs(1).valid}")
       }
      // load address / cache operation / store address
      val issueLoad = issValid && IQ.queue(QUEUE_HEAD).uop.isLoad
      val issueStore = issValid && IQ.queue(QUEUE_HEAD).uop.isStore

      // 发射STD逻辑
      val stBufPop = storeBuffer.queueIO.popPort
      // Cache, load, std 三个人抢cache，所以std要不然在空的时候发射，要不然sta发射的时候跟着发射
      val stdValid = stBufPop.valid && stBufPop.retired && ((issueStore && !IQ.queue(QUEUE_HEAD).uop.isSC) || !issValid)
      stBufPop.ready setWhen (!arbitration.isStuck && stdValid)
      insert(STD_SLOT).valid := stdValid
      insert(STD_SLOT).payload := stBufPop.payload

      // 仅load/STA与arbitration相关
      arbitration.removeIt setWhen (!arbitration.isStuck && !issValid)
      arbitration.removeIt setWhen (flush && !arbitration.isStuck)
    }

    pipeline.RRD plug new Area {
      import pipeline.RRD._
      val issSlot = input(ISSUE_SLOT)
      for (i <- 0 until rPorts) {
        rrdReq(i) := issSlot.rRegs(i).payload
        insert(REG_READ_RSP)(i) := rrdRsp(i)
      }
      val addrOffset = issSlot.uop.immField.asSInt.resize(32 bits).asUInt
       insert(MEMORY_ADDRESS) := input(REG_READ_RSP)(0).asUInt + addrOffset
       insert(MEMORY_WRITE_DATA) := input(REG_READ_RSP)(1)
        when((issSlot.uop.pc(19 downto 0) >= U(0x2bfb0, 20 bits) &&
          issSlot.uop.pc(19 downto 0) <= U(0x2bfc0, 20 bits)) ||
          (issSlot.uop.pc >= U(0x1c221000L, 32 bits) &&
            issSlot.uop.pc <= U(0x1c221100L, 32 bits))) {
         report(L"[RAWDBG MEM-RRD] pc=${issSlot.uop.pc} inst=${issSlot.uop.inst} r0=${rrdReq(0)} d0=${rrdRsp(0)} r1=${rrdReq(1)} d1=${rrdRsp(1)} addr=${input(MEMORY_ADDRESS)} data=${input(MEMORY_WRITE_DATA)}")
       }
    }

    pipeline.MEM1 plug new Area {
      import pipeline.MEM1._
      val issSlot = input(ISSUE_SLOT)
      val std = input(STD_SLOT)
      val isLDU = std.valid && !std.isStore
      val wRegValid = Mux(std.valid, std.payload.wReg.valid, issSlot.uop.doRegWrite)
      val wRegPayload = Mux(std.valid, std.payload.wReg.payload, issSlot.wReg)
       // Loads are cleared from busy only by the WB stage, after data is ready.
    }

    pipeline.MEM2 plug new Area {

      import pipeline.MEM2._
      val issSlot = input(ISSUE_SLOT)
      val std = input(STD_SLOT)
      val isLDU = std.valid && !std.isStore

       // Dependent instructions wait for the architectural writeback wakeup.
//      clrBusy.valid := ((arbitration.isValid && (input(ADDRESS_CACHED) || issSlot.uop.isSC)) || isLDU) &&
//        arbitration.notStuck && output(WRITE_REG).valid
//      clrBusy.payload := output(WRITE_REG).payload

      when(!input(EXC_SIGNALS.EXCEPTION_OCCURRED)) {
        // 用于CACHE指令复用badVA填物理地址
        output(MEMORY_ADDRESS) := input(MEMORY_ADDRESS_PHYSICAL)
      }
      when(isLDU) {
        output(WRITE_REG) := std.wReg
      }
    }

    pipeline.WB plug new Area {
      import pipeline.WB._
      val issSlot = input(ISSUE_SLOT)
      val std = input(STD_SLOT)
      val isLDU = std.valid && !std.isStore
       val commitPlugin = pipeline.globalService(classOf[CommitPlugin])
       wPort.valid := ((arbitration.isValid && (input(ADDRESS_CACHED) || issSlot.uop.isSC)) || isLDU) &&
         arbitration.notStuck && !arbitration.removeIt && input(WRITE_REG).valid &&
         !commitPlugin.needFlush && !flush
       wPort.addr := input(WRITE_REG).payload
       wPort.data := input(MEMORY_READ_DATA)
       clrBusy.valid := wPort.valid
       clrBusy.payload := wPort.addr
       when(wPort.valid && issSlot.uop.pc >= U(0x1c221000L, 32 bits) &&
         issSlot.uop.pc <= U(0x1c221100L, 32 bits)) {
         report(L"[RAWDBG HANDLER-MEM-WB] pc=${issSlot.uop.pc} inst=${issSlot.uop.inst} w=${wPort.addr} data=${wPort.data} removeIt=${arbitration.removeIt} needFlush=${commitPlugin.needFlush} regFlush=${flush}")
       }

      when(arbitration.isValid && issSlot.uop.isSC) {
        val excHandler = pipeline.globalService(classOf[ExceptionHandlerPlugin])
        wPort.addr := issSlot.wReg
        wPort.data := excHandler.LLBCTL_LLBIT.asUInt.resize(32 bits).asBits
      }

      val ROB = pipeline.globalService(classOf[ROBFIFOPlugin])
      robWrite.valid := arbitration.isValidNotStuck && !arbitration.removeIt &&
        !commitPlugin.needFlush && !flush
      robWrite.robIdx := input(ROB_IDX)
      robWrite.except.valid := robWrite.valid && input(EXC_SIGNALS.EXCEPTION_OCCURRED)
      robWrite.except.payload.code := input(EXC_SIGNALS.EXCEPTION_ECODE)
      robWrite.except.payload.subcode := input(EXC_SIGNALS.EXCEPTION_ESUBCODE)
      robWrite.except.payload.badVA := input(EXC_SIGNALS.BAD_VADDR)
      robWrite.except.payload.isTLBRefill := input(IS_TLB_REFILL)
      robWrite.lsuUncached := !input(ADDRESS_CACHED)
      robWrite.intResult := wPort.data.asUInt
      when(issSlot.uop.cacheOp =/= CacheOpType.None) {
        robWrite.intResult(0, CacheOpType.None.asBits.getWidth bits) := issSlot.uop.cacheOp.asBits.asUInt
        robWrite.intResult(
          CacheOpType.None.asBits.getWidth,
          CacheSelType.None.asBits.getWidth bits
        ) := issSlot.uop.cacheSel.asBits.asUInt
      }
      robWrite.isLoad := input(IS_LOAD) && robWrite.valid
      robWrite.isStore := input(IS_STORE) && robWrite.valid
      robWrite.isLL := issSlot.uop.isLL && robWrite.valid
      robWrite.isSC := issSlot.uop.isSC && robWrite.valid
      robWrite.lsType := issSlot.uop.lsType
      robWrite.vAddr := input(MEMORY_ADDRESS)
      robWrite.pAddr := input(MEMORY_ADDRESS_PHYSICAL)
      robWrite.storeData := input(MEMORY_WRITE_DATA).asUInt
      robWrite.myPC := input(ISSUE_SLOT).uop.pc
    }

    for (stageIndex <- 0 until pipeline.stages.length) {
      val stage = pipeline.stages(stageIndex)
      // stuck的时候使得next stage采样到STD不valid，非stuck的时候STD才能被next stage采样
      stage.output(STD_SLOT).valid clearWhen stage.arbitration.isStuck
    }

    Component.current.afterElaboration {
      pipeline.stages.drop(1).foreach { stage =>
        stage.input(STD_SLOT).valid.getDrivingReg().init(False)
      }
    }
  }
}
