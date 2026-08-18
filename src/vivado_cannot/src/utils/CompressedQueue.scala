package NOP.utils

import spinal.core._
import spinal.lib._
import scala.collection.mutable

import NOP.pipeline.core._
import NOP.pipeline._
import NOP.builder._
import NOP._

/** 压缩队列。
  *
  * [stage2-①④] 胞元化改造:队列机制收口到 CellIssueQueueCore(本类只做别名/
  * 服务转发)。写入纪律(优先级低→高,由 IQ 插件的调用序显式给出):
  *
  *   1. 保持/入队覆写 → queueNext(不经压缩)
  *   2. 压缩移位 → queueD := queueNext 相邻 ≤issueWidth+1 槽多路选择
  *   3. flush → queueD valid 清零(最高优先级)
  *   4. 唤醒 → rReady 位面唯一写者,post-mux tag(读后赋值取 queueD 选择后的
  *      tag)比较末端 OR;唤醒随槽移动,覆盖入队当拍竞态(设计书 ①.4 R1 证明),
  *      不再有对 queueNext 的第二份写(fo 减半)
  *   5. queue := queueD(胞元寄存器唯一装载点)
  *
  * tag 总线为 §3.6 登记的组合豁免网(6bit 轻量):PRF clearBusys(5 口,驱动端
  * RRD/EXE/MEM1 拍) + IntIQ 本地 localTag(ISS 拍)。收回触发器:该网进入
  * perf 构建 top-N 违例 → 各口插 1 级 FF(档 A,+1 拍,设计书 ①.5 回退档)。
  *
  * @param issConfig 发射队列配置
  * @param decodeWidth 最大入队个数,等于译码宽度
  * @param slotType 队列中存放的数据类型
  * @param tagWidth 唤醒 tag(物理寄存器号)宽度
  */
abstract class CompressedQueue[T <: IssueSlot](
    issConfig: IssueConfig,
    val decodeWidth: Int,
    val slotType: HardType[T],
    val tagWidth: Int
) extends Plugin[MyCPUCore] {
  val issueWidth = issConfig.issueWidth
  val depth = issConfig.depth

  /** [stage2] 胞元核心:插件与 SpinalSim 单测共用的唯一实现 */
  val cells = new CellIssueQueueCore(depth, issueWidth, decodeWidth, slotType, tagWidth, fifoMode = false)

  /** 全局唤醒 tag 口(PR busy 清零广播),IQ 插件 build 时挂接 PRF.clearBusys */
  def addGlobalTagPort(port: Flow[UInt]): Unit = cells.addGlobalTagPort(port)

  /** IntIQ 本地 bypass 唤醒口(§3.6 组合豁免网),每 INT FU 一个 */
  def localWakeupPort(): Flow[UInt] = cells.localWakeupPort()

  val busyAddrs: Vec[UInt] // For overwritten in subclasses
  var busyRsps: Vec[Bool] = null // Read from PRF
  def fuMatch(uop: MicroOp): Bool // For overwritten in subclasses

  // ---- 对外别名(保持原 API,执行插件与 IQ 插件其余代码不变) ----
  val queue = cells.queue // 做槽移动
  val issueMask = cells.issueMask // issueMask是由每个fu的issueGrant的或得来
  val issueFire = cells.issueFire // issue整体使能
  val queueFlush = cells.queueFlush // 清除整个IQ

  val queueIO = new Area {
    val pushPorts = cells.pushPorts
  }

  def grantPort(reqs: Seq[Bool]): Vec[Bool] = cells.grantPort(reqs)

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
