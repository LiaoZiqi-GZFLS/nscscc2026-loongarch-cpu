package NOP.blackbox.execute

import spinal.core._
import spinal.lib._
import spinal.sim._

class Multiplier(dataWidth: Int = 32, name: String = "multiplier") extends BlackBox {
  setDefinitionName(name)
  noIoPrefix()
  val io = new Bundle {
    val CLK = in Bool ()
    val A = in UInt (dataWidth bits)
    val B = in UInt (dataWidth bits)
    val P = out UInt (dataWidth * 2 bits)
  }
  mapClockDomain(clock = io.CLK)

  // [stage1] 仅当 NOP_SIM_XPM_MODEL=1 或 -Dnop.sim.xpm.model=1(SpinalSim 测试)
  // 时注入行为模型;综合流程两者均不设,零影响。
  if (sys.env.get("NOP_SIM_XPM_MODEL").contains("1") || sys.props.get("nop.sim.xpm.model").contains("1")) {
    val dir = sys.env.getOrElse("NOP_XPM_MODEL_DIR", "test/resources")
    addRTLPath(new java.io.File(dir, "multiplier_model.v").getAbsolutePath)
  }

}
