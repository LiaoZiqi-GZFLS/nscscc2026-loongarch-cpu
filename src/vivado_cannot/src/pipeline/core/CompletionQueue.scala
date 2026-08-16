package NOP.pipeline.core

import spinal.core._
import spinal.lib._
import NOP._

/** P0(200MHz)完成队列(CAM 版):每条执行管线一条,保存 {robIdx, state}。
  *
  * 发射按操作数就绪乱序(压缩发射队列选就绪),同管完成事件**不按
  * robIdx 顺序到达** —— FIFO 头弹出的顺序假设不成立。因此条目按
  * robIdx 标签存放(任意位置),弹出按 robIdx 匹配清除匹配位置的条目:
  * - 写口:完成事件(管线的 WB 端口)或派发时的"天生完成"(needNotExecute),
  *   写入第一个空闲槽;
  * - 读口:全部条目可见(提交按 robIdx 位置匹配);
  * - popMask:提交侧给出本拍弹出的 robIdx 匹配位,任意位置清除;
  * - clear:flush 时整体清空(所有年轻指令的完成全部作废)。
  */
class CompletionQueue[T <: Data](stateType: HardType[T], depth: Int) extends Component {
  val io = new Bundle {
    val push = slave(Flow(new Bundle {
      val robIdx = UInt(5 bits)
      val state = stateType()
    }))
    // 全部条目直接可见(提交侧的 robIdx 匹配用)
    val window = out(Vec(new Bundle {
      val valid = Bool
      val robIdx = UInt(5 bits)
      val state = stateType()
    }, depth))
    // 弹出位:robIdx 匹配本拍提交批次的条目(位置任意)
    val popMask = in(Bits(depth bits))
    // 本拍弹出的 robIdx 集合(供同拍 push 的条目清除判定)
    val popped = in(Vec(new Bundle {
      val valid = Bool
      val robIdx = UInt(5 bits)
    }, 3))
    val clear = in(Bool)
  }
  val entries = Vec(Reg(io.push.payloadType), depth)
  val validBits = Vec(RegInit(False), depth)

  // 写口:push 到第一个空闲槽(条目顺序无关,按标签存取)
  val freeOH = OHMasking.first(validBits.map(!_))
  when(io.push.valid) {
    for (d <- 0 until depth) {
      when(freeOH(d)) {
        entries(d) := io.push.payload
        validBits(d) := True
      }
    }
  }
  // 读窗口:全部条目可见
  for (d <- 0 until depth) {
    io.window(d).valid := validBits(d)
    io.window(d).robIdx := entries(d).robIdx
    io.window(d).state := entries(d).state
  }
  // 出队:按 popMask 清除匹配条目(任意位置)
  for (d <- 0 until depth) {
    when(io.popMask(d)) {
      validBits(d) := False
    }
  }
  // 同拍 push 且 robIdx 在本拍弹出的集合中(状态已由前递覆盖):
  // 落表后立即清除,不留陈旧条目
  val pushPopped = (0 until 3).map(j => io.popped(j).valid && io.popped(j).robIdx === io.push.robIdx).reduce(_ || _)
  when(io.push.valid && pushPopped) {
    for (d <- 0 until depth) {
      when(freeOH(d)) {
        validBits(d) := False
      }
    }
  }
  when(io.clear) {
    validBits.foreach(_ := False)
  }
}
