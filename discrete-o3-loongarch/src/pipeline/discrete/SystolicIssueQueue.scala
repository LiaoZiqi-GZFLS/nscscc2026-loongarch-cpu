package NOP.pipeline.discrete

import spinal.core._
import spinal.lib._
import NOP.pipeline.discrete.RippleSelect._

/** 离散式发射队列配置。 */
case class DiscreteIQConfig(
    depth: Int = 8,               // 胞元(槽)数
    issueWidth: Int = 3,          // FU 内发射口数
    pushWidth: Int = 3,           // 派发口数(三发射)
    rPorts: Int = 2,              // 每指令源操作数数
    prfAddrWidth: Int = 6,        // 物理寄存器号位宽(63+1)
    wakeupPorts: Int = 6,         // 写回广播口数(PRF clearBusy 广播,FF 驱动)
    pingPong: Boolean = false,    // 乒乓唤醒:写 shadow bank、读 active bank,交替
    captureOnWakeup: Boolean = false, // 捕获式唤醒:广播携带数据,命中即捕获,免 PRF 读
    selectStyle: Style = TreeStyle,   // 选择实现:树 / 脉动
    twoCycleSelect: Boolean = false   // 脉动式建议:grant 寄存一拍,载荷 mux 下一拍
)

/** 写回广播消息(由 WB 输出寄存器驱动,是 IQ 唯一的外部唤醒来源)。 */
case class WakeupBus(cfg: DiscreteIQConfig) extends Bundle {
  val tag = UInt(cfg.prfAddrWidth bits)
  val data = cfg.captureOnWakeup generate Bits(32 bits)
}

/** 槽载荷(派发入队 / 发射出队共用)。 */
case class IQSlotPayload(cfg: DiscreteIQConfig) extends Bundle {
  val uop = Bits(64 bits) // 简化载荷(实际应为 MicroOp 子集)
  val rTags = Vec(UInt(cfg.prfAddrWidth bits), cfg.rPorts)
  val rReadyInit = Vec(Bool(), cfg.rPorts) // 入队时源是否已就绪(派发侧读 PRF busy 得到)
  val rDataInit = cfg.captureOnWakeup generate Vec(Bits(32 bits), cfg.rPorts) // 入队时已就绪数据
  val wTag = UInt(cfg.prfAddrWidth bits)
  val robTag = UInt(5 bits)
}

/** 胞元:payload + 唤醒捕获数据;ready 位在 bank 里(乒乓模式需要双 bank)。 */
case class IQCellBundle(cfg: DiscreteIQConfig) extends Bundle {
  val valid = Bool()
  val payload = IQSlotPayload(cfg)
  val rData = cfg.captureOnWakeup generate Vec(Bits(32 bits), cfg.rPorts)
}

/** 胞元化发射队列。
  *
  * 五个位面,全部本地化(单写者、相邻连线):
  *   1. 唤醒   : 每个 ready 位只有本胞元一个写者;广播源必须是 FF(单写者宪法)。
  *   2. 选择   : 树 / 脉动二选一(RippleSelect)。
  *   3. 载荷   : MuxOH(grant, slots),3 级;或随脉动链逐跳 2:1。
  *   4. 入队   : 派发 3 口填充最低空槽(与 CompressedQueue 同语义)。
  *   5. 出队   : 被发射槽清空,后续槽向低位平移;每槽 mux 输入仅来自 <=4 个相邻槽。
  *
  * 时序对照(docs §7):唤醒输入若为 WB 输出寄存器(宪法:模块边界=寄存器),则
  * WB(n) -> tag 总线(n+1) -> 唤醒置位(ready 可见 n+2) -> 选择/ISS(n+2 树形,
  * n+3 脉动 2 拍) -> RRD(n+3/n+4) -> EXE(n+4/n+5) -> WB(n+5/n+6)。
  * 读进胞元(captureOnWakeup)取消 RRD,链长回到 4/5 拍;数据总线晚 tag 总线
  * 1 拍(§4.6 判据 #1),在 EXE 需要数据的前一拍捕获,不增加链长。
  */
class SystolicIssueQueue(cfg: DiscreteIQConfig) extends Component {
  val io = new Bundle {
    val enqueue = Vec(slave(Stream(IQSlotPayload(cfg))), cfg.pushWidth)
    val wakeup = Vec(in(Flow(WakeupBus(cfg))), cfg.wakeupPorts)
    val issue = Vec(master(Flow(IQSlotPayload(cfg))), cfg.issueWidth)
    val issueFire = in Bool() // FU 侧握手:为假时保留 grant、不清槽
    val flush = in Bool()
  }

  // ---- 胞元状态 ----
  val cells = Vec(Reg(IQCellBundle(cfg)), cfg.depth)
  for (i <- 0 until cfg.depth) cells(i).valid init (False)

  // ---- 位面 1: 唤醒(乒乓双 bank) ----
  // parity=False: 选择读 A、唤醒写 B; True: 反之。写 bank 恒为"读 bank || 本拍匹配",
  // 内容随乒乓交替向两 bank 收敛,不会丢失早期置位。
  val parity = if (cfg.pingPong) {
    val p = RegInit(False)
    p := !p
    p
  } else False

  val readyA = Vec(Vec(RegInit(False), cfg.rPorts), cfg.depth)
  val readyB = Vec(Vec(RegInit(False), cfg.rPorts), cfg.depth)

  // 读侧:选择读 active bank;写侧见下方 when(parity) 分支(Mux 结果不可作为写目标)
  def activeReady(i: Int, j: Int): Bool =
    if (cfg.pingPong) Mux(parity, readyB(i)(j), readyA(i)(j)) else readyA(i)(j)

  for (i <- 0 until cfg.depth; j <- 0 until cfg.rPorts) {
    val capSel = io.wakeup.map(w => w.valid && w.tag === cells(i).payload.rTags(j))
    val matchHit = capSel.reduceBalancedTree(_ || _)
    // 只有本胞元写自己的 ready 位(单写者宪法)。
    // 乒乓:shadow := active || match(向前收敛,不丢早期置位);非乒乓退化为原地 OR。
    if (cfg.pingPong) {
      when(parity) {
        readyA(i)(j) := readyB(i)(j) || (cells(i).valid && matchHit)
      } otherwise {
        readyB(i)(j) := readyA(i)(j) || (cells(i).valid && matchHit)
      }
    } else {
      readyA(i)(j) := readyA(i)(j) || (cells(i).valid && matchHit)
    }

    if (cfg.captureOnWakeup) {
      // 命中沿(0->1)捕获数据;选择器按 tag 匹配(重命名保证同周期同物理寄存器
      // 只会有一个生产者,数据唯一)
      val capData = MuxOH(capSel, io.wakeup.map(_.data))
      when(cells(i).valid && matchHit && !activeReady(i, j)) {
        cells(i).rData(j) := capData
      }
    }
  }

  // ---- 位面 4: 入队(派发 3 口,填充最低空槽) ----
  val cellsNext = cells.map(c => { val n = IQCellBundle(cfg); n := c; n }) // 入队前快照(压缩读取)
  val validFall = !cells(0).valid +: (1 until cfg.depth).map(i => cells(i - 1).valid && !cells(i).valid)
  for (p <- 0 until cfg.pushWidth) {
    io.enqueue(p).ready := !cells(cfg.depth - p - 1).valid
    for (j <- p until cfg.depth) {
      when(io.enqueue(p).valid && validFall(j - p)) {
        cells(j).valid := True
        cells(j).payload := io.enqueue(p).payload
        // 双 bank 都写初值:清除前一任残留,保证下一拍无论读哪个 bank 都是新值
        for (k <- 0 until cfg.rPorts) {
          readyA(j)(k) := io.enqueue(p).payload.rReadyInit(k)
          readyB(j)(k) := io.enqueue(p).payload.rReadyInit(k)
        }
        if (cfg.captureOnWakeup) cells(j).rData := io.enqueue(p).payload.rDataInit

        cellsNext(j).valid := True
        cellsNext(j).payload := io.enqueue(p).payload
        if (cfg.captureOnWakeup) cellsNext(j).rData := io.enqueue(p).payload.rDataInit
      }
    }
  }

  // ---- 位面 2+3: 选择与载荷 ----
  val req = Vec((0 until cfg.depth).map { i =>
    cells(i).valid && (0 until cfg.rPorts).map(j => activeReady(i, j)).andR
  })
  val grants = RippleSelect.grants(req, cfg.issueWidth, cfg.selectStyle)
  // 2 拍选择:grant 寄存,载荷 mux 下一拍(与脉动链配套;槽在下一拍前不会被清)
  val grantsReg = if (cfg.twoCycleSelect) {
    val g = Vec(Vec(RegInit(False), cfg.issueWidth), cfg.depth)
    for (i <- 0 until cfg.depth; p <- 0 until cfg.issueWidth) g(i)(p) := grants(i)(p)
    g
  } else grants

  def issuePayloadOf(i: Int): IQSlotPayload = {
    val p = IQSlotPayload(cfg)
    val c = cells(i)
    p.uop := c.payload.uop
    p.rTags := c.payload.rTags
    p.rReadyInit.foreach(_ := True) // 发射即代表源已就绪
    if (cfg.captureOnWakeup) p.rDataInit := c.rData
    p.wTag := c.payload.wTag
    p.robTag := c.payload.robTag
    p
  }

  val fire = io.issueFire && !io.flush
  for (p <- 0 until cfg.issueWidth) {
    io.issue(p).valid := fire && grantsReg(p).orR
    io.issue(p).payload := MuxOH(grantsReg.map(_(p)), (0 until cfg.depth).map(issuePayloadOf))
  }

  // ---- 位面 5: 出队压缩(前缀计数 + 相邻槽 mux,无长线) ----
  val issuedMask = Vec((0 until cfg.depth).map(i =>
    (0 until cfg.issueWidth).map(p => fire && grantsReg(i)(p)).foldLeft(False)(_ || _)
  ))
  val popCounts = Vec(UInt(log2Up(cfg.issueWidth + 1) bits), cfg.depth)
  popCounts(0) := issuedMask(0).asUInt.resized
  for (i <- 1 until cfg.depth) {
    // 注:此为逐跳前缀链(8 跳 ~0.8ns);如需更短可换 3 级树前缀,扇出仍在胞元块内
    popCounts(i) := Mux(issuedMask(i), popCounts(i - 1) + 1, popCounts(i - 1))
  }
  for (i <- 0 until cfg.depth; j <- 1 to cfg.issueWidth) {
    if (i + j < cfg.depth) when(popCounts(i + j - 1) === j)(cells(i) := cellsNext(i + j))
    else when(popCounts.last === j)(cells(i).valid := False)
  }

  // ---- flush 最高优先级 ----
  when(io.flush) {
    for (i <- 0 until cfg.depth) {
      cells(i).valid := False
      for (j <- 0 until cfg.rPorts) {
        readyA(i)(j) := False
        readyB(i)(j) := False
      }
    }
  }
}
