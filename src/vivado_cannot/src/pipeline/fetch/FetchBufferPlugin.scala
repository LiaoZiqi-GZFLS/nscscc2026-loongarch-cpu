package NOP.pipeline.fetch

import spinal.core._
import spinal.lib._

import NOP.pipeline.fetch._
import NOP.pipeline.core._
import NOP.pipeline._
import NOP.builder._
import NOP.utils._
import NOP._

final case class InstBufferEntry(config: FrontendConfig) extends Bundle {
  val pc = UWord()
  val inst = BWord()
  // 优化宽度，前端exception不需要bad va，永远是pc
  val except = Flow(ExceptionPayloadBundle(false))
  val predInfo = BranchPredictInfoBundle()
  val predRecover = PredictRecoverBundle(config)
}

class FetchBufferPlugin(config: MyCPUConfig) extends Plugin[FetchPipeline] {
  private val frontend = config.frontend
  private val icache = config.frontend.icache
  val bufferFIFO =
    // round-4:pop 负载整拍寄存(MultiPortFIFOVecOutReg),切断
    // popPtr→pop数据mux→译码的 15 级链(round-3 top60 中 41 条路径的源头)。
    // OutReg 的读前推(popPtr+popCount+i)与组合 valid 保证对消费端
    // (译码)协议不变:valid/payload 同拍对应同一表项。
    new MultiPortFIFOVecOutReg(
      InstBufferEntry(config.frontend),
      frontend.fetchBufferDepth,
      frontend.fetchWidth,
      config.decode.decodeWidth,
      dataInit = { _ =>
        val z = InstBufferEntry(config.frontend)
        z.assignFromBits(B(0, widthOf(z) bits))
        z
      }, // round-14:X-sweep 缓冲条目复位清零
      useOccupancyCounter = true
      // round-15: specReadPop 回退 - round-11 的投机读(ebc5167 起)是功能
      // 回归源:614a0bf 提交的"通过"网表实为 05ad246(round-9)树产物,
      // 不含 specReads;首个含投机读的网表(00:32)即开始确定性挂死在
      // 功能点 1/3/4/7/8/9/11+。回退到 round-10 的 popPtr+popCount 直接读。
    ) {
      val flush = in(Bool)
      when(flush) {
        pushPtr := 0
        popPtr := 0
        isRisingOccupancy := False
        occupancy := 0
        // io.push.foreach(_.setBlocked())
      }
      pushPtr.asOutput()
      popPtr.asOutput()
    }
  def popPorts = bufferFIFO.io.pop
  override def build(pipeline: FetchPipeline): Unit = pipeline.IF3 plug new Area {

    val flush = pipeline.globalService(classOf[CommitPlugin]).needFlush
    bufferFIFO.flush := flush // clear when need flush. Is this OK??

    import pipeline.IF3._
    import pipeline.signals._
    // data有效当且仅当不超过cache line
    val pcWordOffset = input(PC)(icache.wordOffsetRange)
    val isStall = False
    val fetchPacket = input(pipeline.signals.FETCH_PACKET)
    for (i <- 0 until frontend.fetchWidth) {
      val p = bufferFIFO.io.push(i)
      val fetchWord = fetchPacket.insts(i)
      val fetchWordValid = fetchWord.valid && input(pipeline.signals.INSTRUCTION_MASK)(i)
      // 把前端异常挂给第一条指令，后面的指令没有异常，减少fan out
      if (i == 0)
        p.payload.except := fetchPacket.except
      else
        p.payload.except.setIdle()
      p.payload.pc := fetchPacket.pc + i * 4 // Note: i*4 is a constant
      p.payload.inst := fetchWord.payload

      // //info needed for modify btb and ras
      p.predInfo.predictBranch := input(pipeline.signals.BRANCH_MASK)(i)
      p.predInfo.predictTaken := input(pipeline.signals.TAKEN_MASK)(i)
      p.predInfo.predictAddr := input(PREDICT_ADDR)
      p.predRecover.recoverTop := input(pipeline.signals.RECOVER_TOP)
      p.predRecover.predictCounter := input(pipeline.signals.PRED_COUNTER)(i)
      p.predRecover.ghr := input(PRIVATE_BRANCH_HISTORY)(i)

      // 任何fetch出的word不能进buffer，整个stall住
      isStall setWhen (arbitration.isValid && fetchWordValid && !p.ready)
      p.valid := arbitration.isValidNotStuck && fetchWordValid
    }
    arbitration.haltItself setWhen isStall
  }
}
