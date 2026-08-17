package NOP.constants.enum

import spinal.core.SpinalEnum

object ALUOpType extends SpinalEnum {
  val ADD, ADDU, SUB, SUBU = newElement()
  val AND, OR, XOR, NOR = newElement()
  val SLT, SLTU = newElement()
  val SLL, SRL, SRA = newElement()
  val LU12I, PCADDI, PCADDU12I = newElement()
  val CPUCFG = newElement() // 恒返回 0
//   val CLO, CLZ = newElement()
}
