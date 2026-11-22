package NOP.pipeline.discrete

import spinal.core._
import spinal.lib._
import NOP._
import NOP.pipeline.discrete.RippleSelect._

/** 骨架代码独立 elaborate 入口(不影响 NOP.Main 的主网表生成)。
  *
  *   sbt "runMain NOP.pipeline.discrete.DiscreteSkeletonGen"
  *
  * 产物位于 build/discrete/ 目录(各 .v 文件),用于结构检查:
  *   - DiscreteIQTree     : 树形 1 拍选择基线
  *   - DiscreteIQRipple   : 脉动 2 拍选择 + 乒乓唤醒 + 捕获式唤醒(全功能离散形态)
  *   - RegisteredCommitTop: CM1/CM2 寄存提交
  */

class DiscreteIQTreeTop extends Component {
  val dut = new SystolicIssueQueue(DiscreteIQConfig())
  // 独立综合:顶掉未驱动输入,只暴露 issue 观测口
  dut.io.enqueue.foreach(_.valid := False)
  dut.io.wakeup.foreach(_.valid := False)
  dut.io.issueFire := True
  dut.io.flush := False
}

class DiscreteIQRippleTop extends Component {
  val dut = new SystolicIssueQueue(
    DiscreteIQConfig(
      pingPong = true,
      captureOnWakeup = true,
      selectStyle = RippleStyle,
      twoCycleSelect = true
    )
  )
  dut.io.enqueue.foreach(_.valid := False)
  dut.io.wakeup.foreach(_.valid := False)
  dut.io.issueFire := True
  dut.io.flush := False
}

class RegisteredCommitTop extends Component {
  val dut = new RegisteredCommit(new MyCPUConfig())
}

object DiscreteSkeletonGen {
  def main(args: Array[String]): Unit = {
    SpinalConfig(targetDirectory = "./build/discrete").generateVerilog(new DiscreteIQTreeTop)
    SpinalConfig(targetDirectory = "./build/discrete").generateVerilog(new DiscreteIQRippleTop)
    SpinalConfig(targetDirectory = "./build/discrete").generateVerilog(new RegisteredCommitTop)
  }
}
