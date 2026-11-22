package NOP.pipeline.discrete

import spinal.core._
import spinal.lib._
import NOP._
import NOP.pipeline.core._

/** 提交邮箱:CM1 的寄存输出、CM2 的唯一输入。
  *
  * 提交载荷在 CM1→CM2 之间整体寄存一拍后,ARF/PRF/freeList/BTB/TLB/CSR/
  * ICache/StoreBuffer 各消费者按字段取寄存副本——90bit 大 mux 锥与 popPtr
  * 高扇出网从下游动作中彻底消失(设计文档 §4.1)。
  */
case class CommitMailboxBundle(config: MyCPUConfig) extends Bundle {
  val valid = Bool() // 本拍至少退役一条
  val count = UInt(log2Up(config.rob.retireWidth + 1) bits) // 退役条数(=CM1 的 popCount)
  val entries = Vec(ROBEntryBundle(config), config.rob.retireWidth) // info+state 全量寄存器化
  val hasExcept = Bool() // entry0 带异常:CM2 据此屏蔽 ARF/PRF/freeList 等动作
}

/** CM1/CM2 寄存提交。
  *
  * 输入全部是寄存器(ROB 侧提供的最老 retireWidth 项的寄存读 + occupancy/popValid),
  * CM1 只做 <=5 级局部决策(popCount);载荷打进邮箱寄存器;下一拍 CM2 执行全部退役
  * 动作。提交环上每一圈都至少经过一个 FF → 组合环不存在(环切割宪法)。
  *
  * 与现状的差异:
  *   - 删除 fwdCands 全部同拍前递折叠(WB/派发写 robState 均为同步写,寄存读天然
  *     覆盖,代价仅为退役晚 1 拍);
  *   - popCount 不再驱动 payload 选择,只驱动 popPtr 指针加法(局部,fo~8)与邮箱
  *     有效标记。
  */
class RegisteredCommit(config: MyCPUConfig) extends Component {
  val retireWidth = config.rob.retireWidth
  val io = new Bundle {
    // ROB 侧提供:robState bank 读 + RAM rsp(含 fresh 旁路)的寄存结果
    val entry0 = in(ROBEntryBundle(config))
    val entry1 = in(ROBEntryBundle(config))
    val popValid = in Bits (retireWidth bits) // occupancy 允许 pop 的 valid 掩码
    val uncachedMask = in Bits (retireWidth bits) // uncached FSM 门控(与 CommitPlugin 同语义)
    val popCount = out UInt (log2Up(retireWidth + 1) bits)
    val mailbox = out(CommitMailboxBundle(config))
  }

  // ---- CM1: 纯寄存输入的局部决策 ----
  val entries = Vec(io.entry0, io.entry1) // retireWidth == 2(3 口同理,仍是 3 输入小函数)
  val complete = entries.map(_.state.complete)
  val blk = entries.map(_.state.except.valid)
  val mp = entries.map(_.state.mispredict)
  val uq = entries.map(_.info.uop.uniqueRetire)

  val fire = Vec(Bool(), retireWidth)
  fire(0) := io.popValid(0) && complete(0) && io.uncachedMask(0)
  fire(1) := io.popValid(1) && complete(0) && complete(1) &&
    !blk(0) && !blk(1) && !uq(1) && !mp(0) && io.uncachedMask(1)
  io.popCount := Mux(fire(0), Mux(fire(1), U(2, 2 bits), U(1, 2 bits)), U(0, 2 bits))

  // ---- 邮箱:CM1 -> CM2 寄存器边界 ----
  io.mailbox.valid := RegNext(io.popValid.orR, init = False)
  io.mailbox.count := RegNext(io.popCount)
  for (i <- 0 until retireWidth) {
    io.mailbox.entries(i).info := RegNext(entries(i).info)
    io.mailbox.entries(i).state := RegNext(entries(i).state)
  }
  io.mailbox.hasExcept := RegNext(blk(0), init = False)
}
