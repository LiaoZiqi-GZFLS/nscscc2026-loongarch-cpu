package NOP.pipeline.core

import spinal.core._
import spinal.lib._

import NOP._
import NOP.builder._
import NOP.pipeline._

/** [stage3-①②] 唤醒总线聚合:双总线唤醒 + 写引擎广播合并。
  *
  * 现状(档 B,registeredWakeup=false)广播网 = 5 全局 clearBusys + 3 本地
  * localTag 共 8 根组合豁免网;本插件提供档 A 的 2 根 FF 直驱向量网:
  *
  *   aluWakeupBus(0..2): 第 k 条 INT 管 ISS→RRD 沿采样 {issValid &&
  *     doRegWrite && notStuck, issSlot.wReg}(IntExecutePlugin 驱动),RRD 拍
  *     广播,与原 RRD clearBusy 同拍位(busys 清零时刻不变)、比 localTag 晚 1 拍
  *     (INT 背靠背链 4→5 拍,已知代价,设计书 ①.4);
  *   aluWakeupBus(3): MULDIV EXE 拍 {wakeupCycle && doRegWrite, wReg} 打拍
  *     (wakeupCycle 锥——mulCounter/in16Bits——入 D 端即斩断);
  *   memWakeupBus(0): M1 保守案——MEM1 拍推测 valid 锥原样打拍,MEM2 广播
  *     (SpeculativeWakeupHandler 语义不变;M2 精确化为独立后续实验)。
  *
  * valid 必须带复位(复位后 X valid 会误唤醒);payload 免复位。
  * busys 清零统一由本插件读总线驱动(②.3:原 5 口驱动端锥从 busys 清零
  * 路径上消失);stale busy 窗口由胞元 post-mux OR 覆盖(①.5 竞态复核:
  * 消费者已在 IQ / 恰好同拍入队 / 之后入队三案均无漏唤醒)。
  *
  * 组域:挂组 3(与 INT 管同组);跨组消费(组 4/6 的 IQ、组 8 的 PRF)为
  * 同钟同步域,合规(①.5/R3,由 FF 直驱 + MAX_FANOUT 覆盖)。
  */
class WakeupBusPlugin(config: MyCPUConfig) extends Plugin[MyCPUCore] {
  private val w = config.regFile.prfAddrWidth

  val aluWakeupBus = Vec(Reg(Flow(UInt(w bits))), config.intIssue.aluBusEntries)
  val memWakeupBus = Vec(Reg(Flow(UInt(w bits))), config.intIssue.memBusEntries)
  aluWakeupBus.foreach(_.valid init (False))
  memWakeupBus.foreach(_.valid init (False))

  override def build(pipeline: MyCPUCore): Unit = pipeline plug new Area {
    if (config.intIssue.registeredWakeup) {
      // PRF busys 清零统一改读总线 FF(档 A);档 B 仍走 clearBusy 口
      val prf = pipeline.globalService(classOf[PhysRegFilePlugin])
      for (p <- aluWakeupBus ++ memWakeupBus) {
        when(p.valid) { prf.busys(p.payload - 1) := False }
      }
    }
  }
}
