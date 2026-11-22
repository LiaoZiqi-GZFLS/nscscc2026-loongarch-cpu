package NOP.pipeline.discrete

import spinal.core._
import spinal.lib._

/** 年龄序优先级选择(cells(0) 最老)。
  *
  * 两种实现,见 docs/离散式乱序三发射架构设计.md §4.2.3:
  *
  * - [[TreeStyle]]   前缀优先树,约 log2(n)+2 级,一拍完成;每个 ready 位扇出 <= ports。
  * - [[RippleStyle]] "无数级小逻辑前后咬合"的极致形态:相邻胞元链,每跳 1 个 LUT +
  *                  1 个 carry,n 槽 = n 跳,全部局部走线(fo<=2);grant 建议寄存一拍,
  *                  载荷 mux 放到下一拍(2 拍选择)。
  *
  * 进位含义:链上携带"更老槽中已被选中的个数"(饱和于 ports),槽 i 拿到第 p 口
  * grant 当且仅当 req(i)=1 且更老槽恰好选中 p 个。8 槽 3 口的链约 8 跳 x 0.15ns
  * ~= 1.2ns,仍在"每拍 <=10 级"预算内,且没有任何一条网扇出超过 2。
  */
object RippleSelect {

  sealed trait Style
  case object TreeStyle extends Style
  case object RippleStyle extends Style

  /** 树形:port p 取第 p+1 个(按年龄序)req 为 1 的槽。 */
  def treeGrants(req: Seq[Bool], ports: Int): Vec[Vec[Bool]] = {
    val n = req.size
    val g = Vec(Vec(Bool, ports), n)
    for (p <- 0 until ports) {
      val masked = Vec(req.zipWithIndex.map { case (r, i) =>
        val olderGrant = (0 until p).map(q => g(i)(q)).foldLeft(False)((a, b) => a || b)
        r && !olderGrant
      })
      // 末尾补一个恒真项:全 0 时 OHMasking.first 落在越界位置,不产生任何 grant
      val first = OHMasking.first(masked :+ True)
      for (i <- 0 until n) g(i)(p) := first(i)
    }
    g
  }

  /** 脉动链:每胞元只与前胞元相连,每跳 1 级。 */
  def rippleGrants(req: Seq[Bool], ports: Int): Vec[Vec[Bool]] = {
    val n = req.size
    val cntWidth = log2Up(ports + 1)
    val g = Vec(Vec(Bool, ports), n)
    var cnt = U(0, cntWidth bits)
    for (i <- 0 until n) {
      for (p <- 0 until ports) g(i)(p) := req(i) && (cnt === p)
      // 饱和计数:cnt 到 ports 后不再增长,避免回绕误发 grant
      val nextCnt = cnt + req(i).asUInt
      cnt = Mux(cnt === ports, cnt, nextCnt)
    }
    g
  }

  def grants(req: Seq[Bool], ports: Int, style: Style = TreeStyle): Vec[Vec[Bool]] =
    style match {
      case TreeStyle   => treeGrants(req, ports)
      case RippleStyle => rippleGrants(req, ports)
    }
}
