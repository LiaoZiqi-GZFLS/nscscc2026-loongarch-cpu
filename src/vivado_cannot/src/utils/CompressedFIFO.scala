package NOP.utils

import spinal.core._
import spinal.lib._
import scala.collection.mutable

import NOP.pipeline.core._
import NOP.pipeline._
import NOP.builder._
import NOP._

/** CompressedQueue的退化版本,MulDiv和Mem使用。
  * 只从队头弹出,行为类似fifo,不再需要多路的req/grant;只做单发射。
  *
  * [stage2-①④] 胞元化改造:机制收口到 CellIssueQueueCore(fifoMode=true),
  * 本类只做别名/服务转发。rReady 单写者位面 + post-mux tag 比较 + 压缩
  * 移位保留,与 CompressedQueue 同写入纪律(见该类头注释)。
  */
abstract class CompressedFIFO[T <: IssueSlot](
    issConfig: IssueConfig,
    val decodeWidth: Int,
    val slotType: HardType[T],
    val tagWidth: Int,
    aluBusEntries: Int = 4,
    memBusEntries: Int = 1
) extends Plugin[MyCPUCore] {
  val issueWidth = issConfig.issueWidth
  val depth = issConfig.depth

  /** [stage2] 胞元核心(fifo 语义:仅队头出队,issueReq 驱动) */
  val cells = new CellIssueQueueCore(
    depth, 1, decodeWidth, slotType, tagWidth,
    fifoMode = true, aluBusEntries, memBusEntries
  )

  /** 全局唤醒 tag 口(档 B:PR busy 清零广播),IQ 插件 build 时挂接 PRF.clearBusys */
  def addGlobalTagPort(port: Flow[UInt]): Unit = cells.addGlobalTagPort(port)

  /** [stage3-①②] 档 A 挂双总线 / 档 B tie-off,由 IQ 插件 build 期调用其一 */
  def connectBuses(alu: Vec[Flow[UInt]], mem: Vec[Flow[UInt]]): Unit = cells.connectBuses(alu, mem)
  def tieOffBuses(): Unit = cells.tieOffBuses()

  val busyAddrs: Vec[UInt] // For overwritten in subclasses
  var busyRsps: Vec[Bool] = null // Read from PRF
  def fuMatch(uop: MicroOp): Bool // For overwritten in subclasses

  // ---- 对外别名(保持原 API;queue 维持 out 供顶层 debug 读取) ----
  val queue = out(cells.queue) // 做槽移动
  val issueReq = cells.issueReq // 压缩驱动的选择信号
  val issueFire = cells.issueFire // issue整体使能
  val queueFlush = cells.queueFlush // 清除整个IQ

  val queueIO = new Area {
    val pushPorts = cells.pushPorts
  }

  // ---- 机制转发(调用序=写入优先级,见 CellIssueQueueCore 头注释) ----
  def genEnqueueLogic(): Unit = cells.genEnqueue()
  def genCompressLogic(): Unit = cells.genCompress()
  def genFlushLogic(): Unit = cells.genFlush()

  /** [stage2-①] 唤醒:rReady 单写者位面,post-mux tag 比较。
    * 必须在 genCompressLogic/genFlushLogic 之后调用。 */
  def genCellWakeup(rPorts: Int): Unit = cells.genWakeup(rPorts)

  /** [stage2-①] 胞元寄存器唯一装载点,最后调用 */
  def genCellRegister(): Unit = cells.genRegister()

  def genIssueSelect(): Unit = cells.genSelect()

  override def setup(pipeline: MyCPUCore): Unit = {
    val PRF = pipeline.service(classOf[PhysRegFilePlugin])
    busyRsps = Vec(busyAddrs.map(PRF.readBusy(_)))
  }
}
