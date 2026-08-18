package NOP.pipeline.core

import spinal.core._
import spinal.core.sim._
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

  val robState = Reg(Vec(stateType, robDepth))

  val pushPtr = robInfo.pushPtr
  val popPtr = robInfo.popPtr

  /** [stage1] pop 口 state 投机读的陈旧值标记。
    *
    * pop(j).state 是 robState(popPtr+popCount+j) 的投机读寄存器,与派发写口
    * 同沿装载——派发写入的槽位要下一拍才能被投机读采到新值;若该槽位次拍
    * 恰位于 pop 窗口(空/浅 ROB 快通道),pop 口会看到上一占用者的陈旧 state
    * (其 complete 可能为 1)。F3 用派发旁路折叠掩盖该窗口;阶段 1 删除旁路后
    * 改为由 CommitPlugin 禁止 stale 口 fire(仅推迟 1 拍)。
    * 只索引 popPtr,不引入 popCount 扇出锥。
    */
  val popStateStale = out(Vec(Bool(), retireWidth))

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
    // multi-port FIFO io
    for (i <- 0 until retireWidth)
      fifoIO.pop(i).translateFrom(robInfo.io.pop(i)) { (entry, info) =>
        entry.info := info
        entry.state.setAsReg().allowOverride
        entry.state := robState(popPtr + robInfo.popCount + i)
      }

    for (i <- 0 until decodeWidth) {
      robInfo.io.push(i).translateFrom(fifoIO.push(i)) { (info, entry) =>
        info := entry.info
      }
      when(fifoIO.push(i).fire) {
        robState(pushPtr + i).assignSomeByName(fifoIO.push(i).payload.state)
      }
    }
    robInfo.flush := fifoIO.flush

    // [stage1] 陈旧投机读防护:记录本拍派发写入的槽位,次拍对应 pop 口
    // 的 state 为陈旧值(见 popStateStale 注释)。
    val dispatchWritten = Bits(robDepth bits)
    dispatchWritten := 0
    for (i <- 0 until decodeWidth) {
      when(fifoIO.push(i).fire) {
        dispatchWritten(pushPtr + i) := True
      }
    }
    val dispatchWrittenReg = RegNext(dispatchWritten, init = B(0, robDepth bits))
    for (j <- 0 until retireWidth) {
      popStateStale(j) := dispatchWrittenReg(popPtr + j)
    }

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

    // [stage1] 4 组写口的 pop payload 旁路折叠已删除(原 F3 行为依赖见
    // popStateStale 注释):robState 写口与投机读之间隔完整一拍,WB(n) 完成的
    // 指令最早 n+2 退役(v2 §5.3 方案 a)。
    for (p <- aluPorts)
      when(p.valid) {
        robState(p.robIdx) := defaultState
        robState(p.robIdx).allowOverride()
        robState(p.robIdx).complete := True
        robState(p.robIdx).assignSomeByName(p.payload)
      }
    for (p <- bruPorts)
      when(p.valid) {
        robState(p.robIdx) := defaultState
        robState(p.robIdx).allowOverride()
        robState(p.robIdx).complete := True
        robState(p.robIdx).assignSomeByName(p.payload)
      }
    for (p <- lsuPorts)
      when(p.valid) {
        robState(p.robIdx) := defaultState
        robState(p.robIdx).allowOverride()
        robState(p.robIdx).complete := True
        robState(p.robIdx).assignSomeByName(p.payload)
      }
    for (p <- completePorts)
      when(p.valid) {
        robState(p.payload) := defaultState
        robState(p.payload).allowOverride()
        robState(p.payload).complete := True
      }

    // [stage1] SpinalSim 断言挂钩(零逻辑测试探针)
    popPtr.simPublic()
    pushPtr.simPublic()
    robInfo.isRisingOccupancy.simPublic()
    popStateStale.simPublic()
  }
}
