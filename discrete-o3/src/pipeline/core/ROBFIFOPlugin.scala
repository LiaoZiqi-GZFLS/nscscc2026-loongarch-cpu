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

  // round-12(EXE 提前重定向):BRU 在 WB 拍发现误预测即发起(只冲刷年轻项),
  // 提交拍据此抑制重复 flush。payload: robIdx(分支位置) + target(跳转目标)。
  val earlyRedirect = Flow(new Bundle {
    val robIdx = UInt(config.rob.robAddressWidth bits)
    val target = UWord()
  })

  val robInfo = new MultiPortFIFOSyncImpl(infoType, robDepth, decodeWidth, retireWidth) {
    val flush = in(Bool)
    // round-12(EXE 提前重定向)的尾部压缩请求(由插件级 earlyRedirect 驱动)
    val squash = in(Flow(new Bundle {
      val robIdx = UInt(config.rob.robAddressWidth bits)
    }))
    when(flush) {
      pushPtr := 0
      popPtr := 0
      isRisingOccupancy := False
      occupancy := 0
      // 可pop不可push，否则数据会丢失
      // fifoIO.push.foreach(_.setBlocked())
    }
    // round-12(EXE 提前重定向):ROB 尾部压缩——只保留 popPtr..robIdx(含分支
    // 自身,它仍要按序提交做 BTB 更新/ARF),年轻项全部丢弃。与 flush 同拍时
    // flush 优先(!flush 门控)。须在实例体内写(指针为 asOutput 端口)。
    when(squash.valid && !flush) {
      pushPtr := squash.robIdx + 1
      occupancy := (squash.robIdx - popPtr + 1).resized
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
    defaultState.earlyRedirected := False

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

    // 阶段 1(200MHz 离散化):删除 fwdCands 全部同拍前递折叠(~2k LUT)。
    // WB/派发写 robState 均为同步写,寄存读(Q 侧)天然覆盖,代价仅为提交
    // 晚 1 拍(CommitPlugin 的 CM1/CM2 邮箱)。popCount 不再参与 pop 状态
    // 选择,只驱动指针与邮箱有效标记。
    // WB 随机写口保留(写侧不在关键路径):
    for (p <- aluPorts) {
      when(p.valid) {
        writeState(p.robIdx) := defaultState
        writeState(p.robIdx).allowOverride()
        writeState(p.robIdx).complete := True
        writeState(p.robIdx).assignSomeByName(p.payload)
      }
    }
    for (p <- bruPorts) {
      when(p.valid) {
        writeState(p.robIdx) := defaultState
        writeState(p.robIdx).allowOverride()
        writeState(p.robIdx).complete := True
        writeState(p.robIdx).assignSomeByName(p.payload)
      }
    }
    for (p <- lsuPorts) {
      when(p.valid) {
        writeState(p.robIdx) := defaultState
        writeState(p.robIdx).allowOverride()
        writeState(p.robIdx).complete := True
        writeState(p.robIdx).assignSomeByName(p.payload)
      }
    }
    for (p <- completePorts) {
      when(p.valid) {
        writeState(p.payload) := defaultState
        writeState(p.payload).allowOverride()
        writeState(p.payload).complete := True
      }
    }

    // pop 状态 = 头部第 i 项的 robState 寄存读(无同拍前递,无 popCount 选择)
    for (i <- 0 until retireWidth)
      fifoIO.pop(i).translateFrom(robInfo.io.pop(i)) { (entry, info) =>
        entry.info := info
        entry.state := readState(popPtr + i)
      }

    // round-12(EXE 提前重定向):标记分支已提前重定向(指针压缩在 robInfo
    // 实例体内,见上);提交拍据此抑制重复 flush(只留 BTB 更新/回收)
    robInfo.squash.valid := earlyRedirect.valid
    robInfo.squash.robIdx := earlyRedirect.robIdx
    when(earlyRedirect.valid && !fifoIO.flush) {
      writeState(earlyRedirect.robIdx).earlyRedirected := True
    }
  }
}
