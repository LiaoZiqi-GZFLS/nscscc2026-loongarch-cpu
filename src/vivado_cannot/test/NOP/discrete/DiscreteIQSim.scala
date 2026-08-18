package NOP.discrete

/**
 * DiscreteIQSim — 胞元化发射队列的行为参考模型（纯 Scala，非 RTL）。
 *
 * 对应关系（黄金参考）：
 *   本模型是阶段 2 RTL `SystolicIssueQueue` 的 golden reference。
 *   RTL 侧每个物理胞元（valid / ready / age 比较器 / 清除网络）必须与本模型的
 *   胞元语义一一对应：任意随机 enqueue/wakeup/issue 序列下，RTL 的授权输出
 *   （被授权胞元槽位或其 uopId）必须与本模型逐拍一致。
 *
 * 语义契约：
 *   - 队列由 numCells 个胞元组成，每胞元 { valid, ready, age, uopId }。
 *   - enqueue：分配一个空闲胞元（取最小空闲槽位号，模拟 RTL 的固定优先级空槽选择），
 *     写入 uopId，age 取单调递增时间戳计数器当前值（入队越晚年龄越大）。满则返回 -1。
 *   - wakeup(tag)：把所有「valid 且未 ready 且 uopId == tag」的胞元置 ready。
 *     行为模型里 tag 即 uopId（RTL 里对应物理寄存器 tag 比较广播）。
 *   - issue()：在所有 valid && ready 的胞元中选出 age 最小（最老）者授权，
 *     清空其 valid/ready，返回其槽位号；无 ready 胞元返回 None。
 *   - isFull：所有胞元 valid。
 *
 * 不变量（供测试断言）：
 *   1. 队列不满时 enqueue 必成功（返回值 ∈ [0, numCells) 且对应槽位先前为空）。
 *   2. issue 返回值必为 ready 胞元中 age 最小者。
 *   3. age 在存活性命周期内唯一（时间戳单调）。
 */
object DiscreteIQSim {
  /** 单个胞元状态。age 仅在 valid 时有意义。 */
  final case class Cell(valid: Boolean, ready: Boolean, age: Long, uopId: Int)
}

class DiscreteIQSim(val numCells: Int = 7) {
  import DiscreteIQSim.Cell

  private val cells = Array.fill(numCells)(Cell(valid = false, ready = false, age = 0L, uopId = -1))
  private var ageCounter = 0L

  /** 当前占用（valid）胞元数。 */
  def occupancy: Int = cells.count(_.valid)

  def isFull: Boolean = cells.forall(_.valid)

  /** 只读快照：槽位号 -> 胞元状态（供比对/断言）。 */
  def snapshot: Vector[Cell] = cells.toVector

  /**
   * 入队一个 uop。
   * @return 分配的胞元槽位号；队列满返回 -1。
   */
  def enqueue(uopId: Int): Int = {
    val idx = cells.indexWhere(!_.valid)
    if (idx < 0) -1
    else {
      cells(idx) = Cell(valid = true, ready = false, age = ageCounter, uopId = uopId)
      ageCounter += 1
      idx
    }
  }

  /**
   * 唤醒：把等待 tag 的胞元置 ready。行为模型中 tag 即 uopId。
   * 对不存在/已 ready/已发射的 tag 静默无操作（与 RTL 广播比较语义一致）。
   */
  def wakeup(tag: Int): Unit = {
    var i = 0
    while (i < numCells) {
      val c = cells(i)
      if (c.valid && !c.ready && c.uopId == tag) {
        cells(i) = c.copy(ready = true)
      }
      i += 1
    }
  }

  /**
   * 发射授权：选 ready 胞元中年龄最小（最老）者，清空其 valid/ready。
   * @return 被授权胞元的槽位号；无 ready 胞元返回 None。
   */
  def issue(): Option[Int] = {
    var best = -1
    var bestAge = Long.MaxValue
    var i = 0
    while (i < numCells) {
      val c = cells(i)
      if (c.valid && c.ready && c.age < bestAge) {
        best = i
        bestAge = c.age
      }
      i += 1
    }
    if (best < 0) None
    else {
      cells(best) = cells(best).copy(valid = false, ready = false)
      Some(best)
    }
  }
}
