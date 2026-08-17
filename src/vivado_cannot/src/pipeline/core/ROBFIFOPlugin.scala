package NOP.pipeline.core

import spinal.core._
import spinal.lib._
import NOP._
import NOP.utils._
import NOP.builder._
import NOP.constants.`enum`.LoadStoreType
import NOP.pipeline._
import NOP.pipeline.decode._
import NOP.pipeline.core._

import scala.collection.mutable.ArrayBuffer

class ROBFIFOPlugin(config: MyCPUConfig) extends Plugin[MyCPUCore] {
  private val prfAddressWidth = config.regFile.prfAddrWidth
  private val robDepth = config.rob.robDepth
  private val retireWidth = config.rob.retireWidth
  private val decodeWidth = config.decode.decodeWidth
  private val addressWidth = config.rob.robAddressWidth
  private val entryType = HardType(ROBEntryBundle(config))
  private val infoType = HardType(ROBEntryInfoBundle(config))
  private val stateType = HardType(ROBEntryStateBundle(config.regFile))
  require(isPow2(robDepth))

  val robInfo = new MultiPortFIFOSyncImpl(infoType, robDepth, decodeWidth, retireWidth) {
    val flush = in(Bool)
    when(flush) {
      pushPtr := 0
      popPtr := 0
      isRisingOccupancy := False
      occupancy := 0
      // 可pop不可push，否则数据会丢失
      // fifoIO.push.foreach(_.setBlocked())
    }
    pushPtr.asOutput()
    popPtr.asOutput()
    popCount.asOutput()
  }

  // ROB state随机写口
  private val completePorts = ArrayBuffer[Flow[UInt]]()
  private val lsuPorts = ArrayBuffer[Flow[ROBStateLSUPortBundle]]()
  private val bruPorts = ArrayBuffer[Flow[ROBStateBRUPortBundle]]()
  private val aluPorts = ArrayBuffer[Flow[ROBStateALUPortBundle]]()
  def completePort: Flow[UInt] = {
    val port = Flow(UInt(config.rob.robAddressWidth bits))
    completePorts += port
    port
  }
  def lsuPort = {
    val port = Flow(ROBStateLSUPortBundle(config))
    lsuPorts += port
    port
  }
  def bruPort = {
    val port = Flow(ROBStateBRUPortBundle(config))
    bruPorts += port
    port
  }
  def aluPort = {
    val port = Flow(ROBStateALUPortBundle(config))
    aluPorts += port
    port
  }

  // P1(200MHz,7级目标):读侧由"8队列×32窗口 robIdx CAM + 256 路
  // 优先级 mux"(15 级、布线主导)回退为中央分体 robState:
  // 4 bank × 8 项,读 = idx 加法(2 级 CARRY4)+ bank 内 8:1(2 级)
  // + bank 间 4:1(1 级),共约 5-6 级;读地址由 popPtr(FF)+popCount
  // 驱动,无大扇出 LUT 网。随机写口经动态 bank/地址索引落到对应
  // bank,写侧结构与旧版一致(不在关键路径)。
  val bankCount = 4
  val bankAddrWidth = log2Up(robDepth / bankCount)
  // round-14:X-sweep bank 复位清零(complete=False、except idle、其余字段 0),
  // 消除未初始化寄存器在不同网表间的 X 抖动
  def bankInitState() = Vec.tabulate(robDepth / bankCount) { _ =>
    val s = stateType()
    // 全字段清零:complete=False、except valid=False(即 idle),其余字段 0
    s.assignFromBits(B(0, widthOf(s) bits))
    s
  }
  val robStateBanks = Vec.tabulate(bankCount)(_ => RegInit(bankInitState()))
  def stateBank(idx: UInt) = idx(log2Up(bankCount) - 1 downto 0)
  def stateAddr(idx: UInt) = idx(addressWidth - 1 downto log2Up(bankCount))
  def readState(idx: UInt) = {
    val bankReads = Vec(robStateBanks.map(_(stateAddr(idx))))
    bankReads(stateBank(idx))
  }
  def writeState(idx: UInt) = robStateBanks(stateBank(idx))(stateAddr(idx))
  val pushPtr = robInfo.pushPtr
  val popPtr = robInfo.popPtr
  val fifoIO = new Bundle {

    /** push的valid，pop的ready，都要遵循连续性，从头开始的第一个0就表示了停止的位置，后面的1都会被忽略。
      */
    val push = Vec(Stream(ROBEntryBundle(config, false)), decodeWidth)
    val pop = Vec(Stream(entryType), retireWidth)
    // 同步清空FIFO
    val flush = Bool
  }

  // TODO: [NOP] delete this debugging code
  val debug_fifoIO = out(new Bundle {
    val push = Vec(Stream(ROBEntryBundle(config, false)), decodeWidth)
    val pop = Vec(Stream(entryType), retireWidth)
    val flush = Bool()
  })
  debug_fifoIO.assignAllByName(fifoIO)

  val debugPopWriteData = config.debug generate out(Vec(BWord(), retireWidth))
  override def build(pipeline: MyCPUCore): Unit = pipeline plug new Area {
    if (config.debug) {
      val physRegs = pipeline.service(classOf[PhysRegFilePlugin]).regs
      for (i <- 0 until retireWidth) {
        debugPopWriteData(i) := physRegs(fifoIO.pop(i).payload.info.rename.wReg) // bypassing for debug :)
      }
    }
    // FIFO与MultiPortFIFOVec完全一致，但是ROB不止FIFO端口
    // multi-port FIFO io(状态读与同拍前递见下方 P2/P8 区块)
    for (i <- 0 until decodeWidth) {
      robInfo.io.push(i).translateFrom(fifoIO.push(i)) { (info, entry) =>
        info := entry.info
      }
      when(fifoIO.push(i).fire) {
        writeState(pushPtr + i).assignSomeByName(fifoIO.push(i).payload.state)
      }
    }
    robInfo.flush := fifoIO.flush

    // random write ports
    println("ROB port summary:")
    printf("  pure ALU: %d\n", aluPorts.size)
    printf("  ALU&BRU: %d\n", bruPorts.size)
    printf("  LSU: %d\n", lsuPorts.size)
    printf("  MDU: %d\n", completePorts.size)
    val portCount = aluPorts.size + bruPorts.size + lsuPorts.size + completePorts.size
    printf("  issue width: %d\n", portCount)

    val defaultState = new ROBEntryStateBundle(config.regFile, true)

    // 完成则代表这条指令已经可以提交
    defaultState.complete := False
    // 完整异常信息
    defaultState.except.setIdle()
    // 分支预测恢复信息
    defaultState.mispredict := False
    defaultState.actualTaken := False

    // When full is true
    // LSU检测到uncached区段，需要提交时操作
    defaultState.lsuUncached := False
    // INT执行结果
    defaultState.intResult := 0

    // TODO: [NOP] DiffTest Bundle. Remove this in the future.
    defaultState.isCount := False
    defaultState.count64ReadValue := 0
    defaultState.csrRstat := False
    defaultState.csrRdata := 0
    defaultState.isLoad := False
    defaultState.isStore := False
    defaultState.isLL := False
    defaultState.isSC := False
    defaultState.lsType := LoadStoreType.WORD
    defaultState.vAddr := 0
    defaultState.pAddr := 0
    defaultState.storeData := 0
    defaultState.myPC := B(0x0eadbeef, 32 bits).asUInt

    // P2+P8(提交环路压缩):6 路投机读(popPtr+0..5,与 fire/popCount
    // 并行);同拍前递(派发/WB)折叠进各候选,条件全部为寄存器运算
    // (pushOff/robIdxOff 与常量 k 比较),popCount 到达后状态 D 只剩
    // 4:1 选择(1 级)。环路约 8-9 级且仅 3 bit 宽;前递面积约
    // 6x90bitx4 级 mux ≈ 2k LUT。
    val specReads = Vec((0 until retireWidth * 2).map(k => readState(popPtr + k)))
    val fwdCands = Vec((0 until retireWidth * 2).map { k =>
      val c = stateType()
      c := specReads(k)
      c.allowOverride()
      c
    })
    // 派发前递折叠(部分字段覆盖,最低优先级)
    for (i <- 0 until decodeWidth) {
      val pushOff = pushPtr + i - popPtr
      for (k <- 0 until retireWidth * 2)
        when(fifoIO.push(i).fire && pushOff === k) {
          fwdCands(k).assignSomeByName(fifoIO.push(i).payload.state)
        }
    }
    // WB 前递折叠(全字段覆盖,优先级 alu < bru < lsu < mdu,与旧版一致)
    for (p <- aluPorts) {
      val fwdOff = p.robIdx - popPtr
      val fwdState = stateType()
      fwdState := defaultState
      fwdState.allowOverride()
      fwdState.complete := True
      fwdState.assignSomeByName(p.payload)
      when(p.valid) {
        writeState(p.robIdx) := defaultState
        writeState(p.robIdx).allowOverride()
        writeState(p.robIdx).complete := True
        writeState(p.robIdx).assignSomeByName(p.payload)
      }
      for (k <- 0 until retireWidth * 2) when(p.valid && fwdOff === k) {
        fwdCands(k) := fwdState
      }
    }
    for (p <- bruPorts) {
      val fwdOff = p.robIdx - popPtr
      val fwdState = stateType()
      fwdState := defaultState
      fwdState.allowOverride()
      fwdState.complete := True
      fwdState.assignSomeByName(p.payload)
      when(p.valid) {
        writeState(p.robIdx) := defaultState
        writeState(p.robIdx).allowOverride()
        writeState(p.robIdx).complete := True
        writeState(p.robIdx).assignSomeByName(p.payload)
      }
      for (k <- 0 until retireWidth * 2) when(p.valid && fwdOff === k) {
        fwdCands(k) := fwdState
      }
    }
    for (p <- lsuPorts) {
      val fwdOff = p.robIdx - popPtr
      val fwdState = stateType()
      fwdState := defaultState
      fwdState.allowOverride()
      fwdState.complete := True
      fwdState.assignSomeByName(p.payload)
      when(p.valid) {
        writeState(p.robIdx) := defaultState
        writeState(p.robIdx).allowOverride()
        writeState(p.robIdx).complete := True
        writeState(p.robIdx).assignSomeByName(p.payload)
      }
      for (k <- 0 until retireWidth * 2) when(p.valid && fwdOff === k) {
        fwdCands(k) := fwdState
      }
    }
    for (p <- completePorts) {
      val fwdOff = p.payload - popPtr
      val fwdState = stateType()
      fwdState := defaultState
      fwdState.allowOverride()
      fwdState.complete := True
      when(p.valid) {
        writeState(p.payload) := defaultState
        writeState(p.payload).allowOverride()
        writeState(p.payload).complete := True
      }
      for (k <- 0 until retireWidth * 2) when(p.valid && fwdOff === k) {
        fwdCands(k) := fwdState
      }
    }

    for (i <- 0 until retireWidth)
      fifoIO.pop(i).translateFrom(robInfo.io.pop(i)) { (entry, info) =>
        entry.info := info
        entry.state.setAsReg().allowOverride
        val pick = Vec((i until i + retireWidth + 1).map(k => fwdCands(k)))
        entry.state := pick(robInfo.popCount)
      }
  }
}
