package NOP.constants.enum

import spinal.core.SpinalEnum

object ALUOpType extends SpinalEnum {
  val ADD, ADDU, SUB, SUBU = newElement()
  val AND, OR, XOR, NOR = newElement()
  val SLT, SLTU = newElement()
  val SLL, SRL, SRA = newElement()
  val LU12I, PCADDI, PCADDU12I = newElement()
  val CPUCFG = newElement() // 2026-final: Linux boot support —— 按 rj 索引返回 CPUCFG 常量表（cache 几何字保持 0）
  val IOCSR = newElement() // 2026-final: Linux boot support —— iocsrrd/iocsrwr 读恒返回 0、写忽略
//   val CLO, CLZ = newElement()
}
