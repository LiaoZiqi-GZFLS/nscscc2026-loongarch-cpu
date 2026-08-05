package NOP.pipeline.exe

import spinal.core._
import spinal.lib._

import NOP._
import NOP.builder._
import NOP.constants.enum._
import NOP.pipeline._
import NOP.utils._

// Combinatorial ALU
class ALU() extends Component {
  val io = new Bundle {
    val src1 = in(UWord())
    val src2 = in(UWord())
    val sa = in(UInt(5 bits))
    val op = in(ALUOpType())
    val result = out(UWord())
  }
  import io._

  switch(op) {
    import ALUOpType._
    is(ADD, LU12I, PCADDI, PCADDU12I) {
      result := src1 + src2
    }
    is(ADDU) {
      result := src1 + src2
    }
    is(SUB) {
      result := src1 - src2
    }
    is(SUBU) {
      result := src1 - src2
    }
    is(AND) {
      result := src1 & src2
    }
    is(OR) {
      result := src1 | src2
    }
    is(XOR) {
      result := src1 ^ src2
    }
    is(NOR) {
      result := ~(src1 | src2)
    }
    is(SLT) {
      result := (src1.asSInt < src2.asSInt).asUInt.resized
    }
    is(SLTU) {
      result := (src1 < src2).asUInt.resized
    }
    is(SLL) {
      result := src1 |<< sa
    }
    is(SRL) {
      result := src1 |>> sa
    }
    is(SRA) {
      result := (src1.asSInt >> sa).asUInt
    }
    is(CPUCFG) {
      // 2026-final: Linux boot support —— CPUCFG 常量表（rj=字号经 src1 传入，手册卷一表 2-2）
      // word 0x10~0x14（cache 几何）保持返回 0：2026 perf start.S 依此跳过 cacop 初始化，
      // 赛事 5.14 内核（la32r-Linux）cache 几何为硬编码，不读这些字。
      result := 0
      switch(src1) {
        is(0) {
          result := U(0x00144200L, 32 bits) // PRID：公司域 0x14 + LOONGSON32(0x42)，5.14 内核 BUG_ON 必需
        }
        is(1) {
          result := U(0x0001f1fcL, 32 bits) // ARCH=0(LA32R)|PGMMU=1|IOCSR=1，PALEN=VALEN=31（位数-1），UAL=0（非对齐产生 ALE）
        }
        is(2) {
          result := U(0x00004000L, 32 bits) // LLFTP(bit14)：有恒定频率定时器（Timer64Plugin 每拍 +1）
        }
        is(4) {
          result := U(105000000L, 32 bits) // CC_FREQ：稳定计数器频率 = 105MHz CPU 时钟
        }
        is(5) {
          result := U(0x00010001L, 32 bits) // CC_MUL=1 / CC_DIV=1：定时器时钟 = CC_FREQ × 1 / 1
        }
        // word3/word6/word7~0xF/word0x10~0x14 及其余未定义字号：返回 0
      }
    }
    is(IOCSR) {
      result := 0 // 2026-final: Linux boot support —— IOCSR 读恒返回 0（写忽略，译码侧不产生异常）
    }

  }
}
