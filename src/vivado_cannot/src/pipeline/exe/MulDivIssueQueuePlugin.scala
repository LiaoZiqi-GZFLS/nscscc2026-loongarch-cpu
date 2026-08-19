package NOP.pipeline.exe

import spinal.core._
import spinal.lib._

import NOP._
import NOP.builder._
import NOP.utils._
import NOP.pipeline._
import NOP.pipeline.core._
import NOP.constants.enum._

class MulDivIssueQueuePlugin(config: MyCPUConfig)
    extends CompressedFIFO(
      config.mulDiv,
      config.decode.decodeWidth,
      HardType(MulDivIssueSlot(config)),
      config.regFile.prfAddrWidth
    ) {

  val rPorts = config.regFile.rPortsEachInst
  val busyAddrs = Vec(UInt(config.regFile.prfAddrWidth bits), decodeWidth * rPorts)

  // [stage2-④] 胞元逻辑区 cellArea 在 build 内创建(见下)。

  def fuMatch(uop: MicroOp) =
    uop.fuType === FUType.MUL || uop.fuType === FUType.DIV || uop.fuType === FUType.MOD || uop.fuType === FUType.MULH

  override def build(pipeline: MyCPUCore): Unit = {
    // [stage2-①④] 选择/压缩/flush/唤醒/装载挂 cellArea;tag 口 = 5 口
    // PRF clearBusys(§3.6 组合豁免网);busy 旁路已删,入队当拍竞态由
    // post-mux 唤醒 OR 覆盖(设计书 ①.4 R1)
    // [stage3-①②] 唤醒 tag 来源:档 A 双总线 / 档 B 旧豁免网
    if (config.intIssue.registeredWakeup) {
      val wb = pipeline.globalService(classOf[WakeupBusPlugin])
      connectBuses(wb.aluWakeupBus, wb.memWakeupBus)
    } else {
      tieOffBuses()
      pipeline.service(classOf[PhysRegFilePlugin]).clearBusys.foreach(addGlobalTagPort)
    }
    val cellArea = new Area { genIssueSelect() } // 选择区(组域,comb)
    Component.current.afterElaboration {
      val cellAreaTail = new Area { // 压缩/flush/唤醒/装载区(组域,comb 装配)
        genEnqueueLogic()
        genCompressLogic()
        genFlushLogic()
        genCellWakeup(rPorts)
        genCellRegister()
      }
    }
    pipeline.DISPATCH plug new Area {
    import pipeline.DISPATCH._
    // 入队、唤醒与int IQ相同
    val decPacket = input(pipeline.decodePipeline.signals.DECODE_PACKET)
    val renameRecs = input(pipeline.decodePipeline.signals.RENAME_RECORDS)
    val robIdxs = input(pipeline.decodePipeline.signals.ROB_INDEXES)
    val enqueueMask = Bits(decodeWidth bits)
    queueIO.pushPorts.foreach(_.setIdle())
    for (i <- 0 until decodeWidth) {
      val valid = decPacket(i).valid
      val uop = decPacket(i).payload
      val rename = renameRecs(i)

      // ! Push MicroOp to MulDivIssueSlot in reservation station
      val pushPort = queueIO.pushPorts.dataType().setBlocked()
      val slot = pushPort.payload
      slot.uop.assignAllByName(uop)
      for (j <- 0 until rPorts) {
        slot.rRegs(j).payload := rename.rRegs(j)
        busyAddrs(i * rPorts + j) := rename.rRegs(j)
      }
      // 入队唤醒（dispatch入口读busy）
      slot.rRegs(0).valid := !uop.useRj || !busyRsps(i * rPorts)
      slot.rRegs(1).valid := !uop.useRk || !busyRsps(i * rPorts + 1)
      slot.wReg := rename.wReg
      // ROB不关心Hi/Lo寄存器号，因为FIFO提交，但是读写寄存器需要提供这个号给Hi/Lo PRF
      slot.robIdx := robIdxs(i)
      val enqueue = valid && fuMatch(uop) && !uop.except.valid
      enqueueMask(i) := enqueue
      pushPort.valid := arbitration.isValidNotStuck && enqueue
      arbitration.haltItself setWhen (arbitration.isValid && enqueue && !pushPort.ready)

      // port互联，与rename相似
      if (i > 0) {
        val pushIdx = CountOne(enqueueMask.take(i))
        for (j <- 0 to i) when(pushIdx === j && enqueueMask(i))(pushPort >> queueIO.pushPorts(j))
      } else {
        when(enqueueMask(i))(pushPort >> queueIO.pushPorts(0))
      }
    }

    // flush最高优先级
    val flush = pipeline.globalService(classOf[CommitPlugin]).regFlush
    queueFlush setWhen flush

    // stage2-③ R9-1: holdDispatch 期间冻结入队
    arbitration.haltItself setWhen pipeline.globalService(classOf[CommitFlush]).holdDispatch
    }
  }

}
