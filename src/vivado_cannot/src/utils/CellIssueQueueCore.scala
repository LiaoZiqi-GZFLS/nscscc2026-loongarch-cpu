package NOP.utils

import spinal.core._
import spinal.core.sim._
import spinal.lib._
import scala.collection.mutable

import NOP.pipeline._

/** [stage2-①④] 胞元化发射队列核心(压缩移位保留、唤醒单写者位面、树选版)。
  *
  * 本类是三个 IQ 插件(Int/MulDiv/Mem)与 SpinalSim 单测共用的唯一实现,
  * 不依赖 Plugin/Pipeline 服务,可独立 elaborate 对拍行为模型。
  *
  * 写入纪律(v2 §3.3 单写者宪法 + stage2 设计书 ①.2):
  *   胞元次态只有唯一汇合点 queueD,优先级(低→高)在调用序中显式给出:
  *     genEnqueue   : queueNext(= 保持/入队覆写,不经压缩)
  *     genCompress  : queueD := 压缩移位选择(queueNext 的相邻 ≤issueWidth+1 槽)
  *     genFlush     : queueD valid 清零(最高优先级)
  *     genWakeup    : rReady 位面唯一写者——对 **post-mux tag**(读后赋值取
  *                    queueD 多路选择后的 tag)做 tag 总线比较,末端 OR 置位。
  *                    唤醒天然随槽移动,且覆盖入队当拍竞态(busy 旁路删除的前置,
  *                    证明见设计书 ①.4);不存在对 queueNext 的第二份写(fo 减半)。
  *     genRegister  : queue := queueD(胞元寄存器唯一装载点)
  *
  * tag 总线为 §3.6 登记的组合豁免网(6bit 轻量,驱动端 RRD/EXE/MEM1/ISS 拍):
  *   PRF clearBusys(5 口) + IntIQ 本地 localTag(每 INT FU 一口)。
  *   收回触发器:该网进入 perf 构建 top-N 违例 → 各口插 1 级 FF(档 A,+1 拍)。
  *
  * @param fifoMode true=CompressedFIFO 语义(仅队头出队,issueReq 驱动,
  *                 用于 MulDiv/Mem);false=CompressedQueue 语义(多 grant 口
  *                 OHMasking.first 树选 + 已授权屏蔽,用于 IntIQ)
  */
class CellIssueQueueCore[T <: IssueSlot](
    val depth: Int,
    val issueWidth: Int,
    val decodeWidth: Int,
    val slotType: HardType[T],
    val tagWidth: Int,
    val fifoMode: Boolean,
    // [stage3-①②] 双总线固定形态口(档 A);档 B 回退仍用下方两个 ArrayBuffer 口
    val aluBusEntries: Int = 4,
    val memBusEntries: Int = 1
) extends Area {

  /** 胞元阵列(寄存器 Q) */
  val queue = Vec(RegFlow(slotType()), depth)

  /** 保持/入队覆写后的次态(不经压缩);仅 genEnqueue 可写 */
  val queueNext = CombInit(queue)

  /** 胞元最终次态:压缩+flush+唤醒的唯一汇合点;仅 genCompress/genFlush/genWakeup 可写 */
  val queueD = Vec(Flow(slotType()), depth)

  /** 入队口(DISPATCH 级驱动) */
  val pushPorts = Vec(Stream(slotType()), decodeWidth)

  /** [stage3-①②] 唤醒 tag 双总线(档 A,FF 直驱向量网,由 IQ 插件挂接
    * WakeupBusPlugin;档 B 时由 IQ 插件 tie-off)。aluBus: INT0..2 + MULDIV;
    * memBus: MEM 加载。 */
  val aluTagBus = Vec(Flow(UInt(tagWidth bits)), aluBusEntries)
  val memTagBus = Vec(Flow(UInt(tagWidth bits)), memBusEntries)

  /** 唤醒 tag 口(档 B 回退路径):全局(PR busy 清零广播)+ 本地(IntIQ 早唤醒),
    * §3.6 组合豁免网;档 A 下不使用(保持为空) */
  val globalTagPorts = mutable.ArrayBuffer[Flow[UInt]]()
  val localTagPorts = mutable.ArrayBuffer[Flow[UInt]]()

  /** issue 整体使能(执行侧反压 clearWhen) */
  val issueFire = True

  /** 队列整体冲刷(regFlush) */
  val queueFlush = False

  /** queue 模式:压缩前缀和的驱动位面;fifo 模式:队头出队请求 */
  val issueMask = Bits(depth bits)
  val issueReq = Bool

  // ---- grant 口(queue 模式):执行插件 setup 期注册 reqs,build 期消费 grants ----
  private val grantPorts = mutable.ArrayBuffer[(Seq[Bool], Vec[Bool])]()
  def grantPort(reqs: Seq[Bool]): Vec[Bool] = {
    require(!fifoMode, "fifoMode queue issues head only, no grantPort")
    val grants = Vec(Bool, reqs.size)
    grantPorts += (reqs -> grants)
    grants
  }

  /** 注册一个唤醒 tag 口(全局=PRF clearBusys,本地=IntIQ localTag)。
    * 可在任意阶段(setup/build)调用;genWakeup 在 afterElaboration 统一消费。 */
  def addGlobalTagPort(port: Flow[UInt]): Unit = {
    require(port.payload.getWidth == tagWidth)
    globalTagPorts += port
  }

  /** IntIQ 本地 bypass 唤醒口(档 B 回退用,§3.6 组合豁免网),每 INT FU 一个 */
  def localWakeupPort(): Flow[UInt] = {
    val port = Flow(UInt(tagWidth bits))
    localTagPorts += port
    port
  }

  /** [stage3-①②] 档 A:挂接 WakeupBusPlugin 双总线(FF 直驱) */
  def connectBuses(alu: Vec[Flow[UInt]], mem: Vec[Flow[UInt]]): Unit = {
    require(alu.length == aluBusEntries && mem.length == memBusEntries)
    for (k <- 0 until aluBusEntries) {
      aluTagBus(k).valid := alu(k).valid
      aluTagBus(k).payload := alu(k).payload
    }
    for (k <- 0 until memBusEntries) {
      memTagBus(k).valid := mem(k).valid
      memTagBus(k).payload := mem(k).payload
    }
  }

  /** [stage3-①②] 档 B:总线口 tie-off(唤醒全走旧豁免网口) */
  def tieOffBuses(): Unit = {
    aluTagBus.foreach { b =>
      b.valid := False
      b.payload := 0
    }
    memTagBus.foreach { b =>
      b.valid := False
      b.payload := 0
    }
  }

  /** 1. 入队:定位匹配写入 queueNext(首次空位);pushPorts.ready 由尾部占用给出 */
  def genEnqueue(): Unit = {
    val validFall = !queue(0).valid +: (for (i <- 1 until depth)
      yield queue(i - 1).valid && !queue(i).valid) // the length of current valid depth
    for (i <- 0 until decodeWidth) {
      // 0口ready当且仅当depth-1是空的
      pushPorts(i).ready := !queue(depth - i - 1).valid
      for (j <- i until depth) {
        when(pushPorts(i).valid && validFall(j - i)) {
          // 定位匹配,则将槽入队(只写 queueNext;queue 由 genRegister 统一装载)
          queueNext(j).push(pushPorts(i).payload)
        }
      }
    }
  }

  /** 2. 压缩:queueD 从 queueNext 的相邻槽多路选择(保持=shift 0) */
  def genCompress(): Unit = {
    if (fifoMode) {
      val popCount = issueReq && issueFire
      require(issueWidth == 1)
      for (i <- 0 until depth) {
        queueD(i) := queueNext(i)
        when(popCount) {
          if (i + 1 < depth) queueD(i) := queueNext(i + 1)
          else queueD(i).valid := False
        }
      }
    } else {
      val popCounts = Vec(UInt(log2Up(issueWidth + 1) bits), depth) // prefix sum of issueMask
      popCounts(0) := (issueFire && issueMask(0)).asUInt.resized
      for (i <- 0 to depth - 2) {
        popCounts(i + 1) := Mux(
          issueFire && issueMask(i + 1),
          popCounts(i) + 1,
          popCounts(i)
        )
      }
      for (i <- 0 until depth) {
        queueD(i) := queueNext(i) // 保持(含入队覆写)
        for (j <- 1 to issueWidth) {
          // 后覆盖前。考察[0, i+j-1]的清除情况
          if (i + j < depth) when(popCounts(i + j - 1) === j) { queueD(i) := queueNext(i + j) }
          else when(popCounts.last === j) { queueD(i).valid := False }
        }
      }
    }
  }

  /** 3. flush 最高优先级:清所有 valid */
  def genFlush(): Unit = when(queueFlush) {
    for (i <- 0 until depth) {
      queueD(i).valid := False
    }
  }

  /** 4. 唤醒:rReady 位面唯一写者,post-mux tag 比较末端 OR(设计书 ①.2/①.4)。
    * 必须在 genCompress/genFlush 之后调用(读后赋值取多路选择后的 tag)。
    * [stage3-①②] tag 来源 = 双总线(档 A) ++ 旧豁免网口(档 B 回退,档 A 下为空);
    * 优先级链与调用序逐字不动。 */
  def genWakeup(rPorts: Int): Unit = {
    val tagPorts = (aluTagBus ++ memTagBus).toSeq ++ globalTagPorts.toSeq ++ localTagPorts.toSeq
    for (i <- 0 until depth; j <- 0 until rPorts) {
      val postMuxTag = queueD(i).payload.rRegs(j).payload
      val hit = tagPorts.map(p => p.valid && p.payload === postMuxTag).orR
      when(hit && !queueFlush) {
        queueD(i).payload.rRegs(j).valid := True
      }
    }
  }

  /** 5. 胞元寄存器唯一装载点 */
  def genRegister(): Unit = {
    for (i <- 0 until depth) {
      queue(i) := queueD(i)
    }
  }

  /** issue 选择(queue 模式):每 grant 口 OHMasking.first + 已授权屏蔽。
    * 级数 ≈ 前缀 OR 树(⌈log2 depth⌉) + 屏蔽 1 + fuMatch 2,预算 ≤5 级踩线,
    * 允许 CARRY4 单列记账;违例再树形化拆分(设计书 ①.2/R4)。 */
  def genSelect(): Unit = {
    if (!fifoMode) {
      issueReq := False // queue 模式不用(占住驱动)
      require(grantPorts.size <= issueWidth)
      // Grant only one slot for each FU
      if (grantPorts.nonEmpty) grantPorts(0)._2 := OHMasking.first(grantPorts(0)._1)
      for (i <- 1 until grantPorts.size) {
        val exeMask = grantPorts.map(_._2).take(i).reduceBalancedTree { (l, r) =>
          (l.asBits | r.asBits).asBools
        }
        grantPorts(i)._2 := OHMasking.first(grantPorts(i)._1.zip(exeMask).map { case (b, m) =>
          b && !m // Mask out already granted slots
        })
      }
      issueMask := grantPorts.map(_._2.asBits).reduceBalancedTree(_ | _)
    } else {
      issueMask := 0 // fifo 模式不用(占住驱动)
    }
  }

  // [stage2] SpinalSim 探针(零逻辑):胞元对拍与漏唤醒检测器用
  queue.simPublic()
  queueD.simPublic()
}

object CellIssueQueueCore {
  /** 便捷全装:按优先级序一次调用全部 gen(调用序=写入优先级,勿调整) */
  def genAll(core: CellIssueQueueCore[_ <: IssueSlot], rPorts: Int): Unit = {
    core.genEnqueue()
    core.genCompress()
    core.genFlush()
    core.genWakeup(rPorts)
    core.genRegister()
    core.genSelect()
  }
}
