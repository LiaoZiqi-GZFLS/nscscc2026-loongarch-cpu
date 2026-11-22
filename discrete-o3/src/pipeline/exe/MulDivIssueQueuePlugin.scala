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
      HardType(MulDivIssueSlot(config))
    ) {

  val rPorts = config.regFile.rPortsEachInst
  val busyAddrs = Vec(UInt(config.regFile.prfAddrWidth bits), decodeWidth * rPorts)

  def fuMatch(uop: MicroOp) =
    uop.fuType === FUType.MUL || uop.fuType === FUType.DIV || uop.fuType === FUType.MOD || uop.fuType === FUType.MULH

  override def build(pipeline: MyCPUCore): Unit = {
    // 位面寄存器必须先于执行插件 ISS 区创建(依赖序保证本插件先 build)
    createReadyBank(rPorts)
    pipeline.DISPATCH plug new Area {
    genIssueSelect()
    import pipeline.DISPATCH._
    // 鍏ラ槦銆佸敜閱掍笌int IQ鐩稿悓
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
      // 鍏ラ槦鍞ら啋锛坉ispatch鍏ュ彛璇籦usy锛?
      slot.rRegs(0).valid := !uop.useRj || !busyRsps(i * rPorts)
      slot.rRegs(1).valid := !uop.useRk || !busyRsps(i * rPorts + 1)
      slot.wReg := rename.wReg
      // ROB涓嶅叧蹇僅i/Lo瀵勫瓨鍣ㄥ彿锛屽洜涓篎IFO鎻愪氦锛屼絾鏄鍐欏瘎瀛樺櫒闇€瑕佹彁渚涜繖涓彿缁橦i/Lo PRF
      slot.robIdx := robIdxs(i)
      val enqueue = valid && fuMatch(uop) && !uop.except.valid
      enqueueMask(i) := enqueue
      // round-12(EXE 提前重定向):squash 拍抑制入队(与 ROB push 同门控)
      val robFIFO = pipeline.globalService(classOf[ROBFIFOPlugin])
      pushPort.valid := arbitration.isValidNotStuck && enqueue && !robFIFO.earlyRedirect.valid
      arbitration.haltItself setWhen (arbitration.isValid && enqueue && !pushPort.ready)

      // port浜掕仈锛屼笌rename鐩镐技
      if (i > 0) {
        val pushIdx = CountOne(enqueueMask.take(i))
        for (j <- 0 to i) when(pushIdx === j && enqueueMask(i))(pushPort >> queueIO.pushPorts(j))
      } else {
        when(enqueueMask(i))(pushPort >> queueIO.pushPorts(0))
      }
    }

    // flush鏈€楂樹紭鍏堢骇
    val flush = pipeline.globalService(classOf[CommitPlugin]).regFlush
    queueFlush setWhen flush
  }
  }

  Component.current.afterElaboration {
    // 位面/广播必须在 afterElaboration 创建:此时 clearBusy 端口已全部注册
    genGlobalWakeup(pipeline.globalService(classOf[PhysRegFilePlugin]), rPorts)
    genEnqueueLogic()
      genCompressLogic()
    genFlushLogic()
    genEarlyKill()
  }

}
