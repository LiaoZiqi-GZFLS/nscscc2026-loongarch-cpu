package NOP.utils

import spinal.core._

/** LUT6 友好的 4:1 树形读。
  *
  * SpinalHDL 的 Vec.read 生成 2:1 递归 mux 树,深度 = log2(N) 级
  * (64 项 = 6 级,1024 项 = 10 级);本工具按 4:1 逐级归约,综合后
  * 每级落 1 个 LUT6:64 项 = 3 级,1024 项 = 5 级。
  *
  * 要求 vals 长度为 4 的幂,idx 宽度 = log2Up(N)。
  */
object TreeRead {
  def apply(vals: IndexedSeq[Bits], idx: UInt): Bits = {
    val n = vals.length
    if (n == 1) {
      vals(0)
    } else {
      require(n % 4 == 0, s"TreeRead: length $n not divisible by 4")
      val lvl = (0 until n / 4).map { g =>
        Vec(vals.slice(g * 4, g * 4 + 4)).read(idx(1 downto 0))
      }
      apply(lvl.toIndexedSeq, idx(idx.getWidth - 1 downto 2))
    }
  }
}
