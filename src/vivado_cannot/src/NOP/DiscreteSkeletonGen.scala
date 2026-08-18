package NOP

import spinal.core._

/**
 * DiscreteSkeleton — 阶段 0c 占位 top（离散式乱序构建的独立 elaborate 骨架）。
 *
 * 本阶段只提供带时钟复位的空壳与保留接口信号，供网表环边检查流程演练；
 * 后续阶段在此挂载真实模块（占位信号被替换为真实端口）：
 *   - 阶段 1：RegisteredCommit（CM1 决策 + 提交邮箱，flush/pop 对齐协议）
 *   - 阶段 2：SystolicIssueQueue（胞元化发射队列，golden 参考 = NOP.discrete.DiscreteIQSim）
 *
 * elaborate 产物输出到 ./build/discrete_skeleton，独立于 NOP.Main 的 ./build 产物。
 */
class DiscreteSkeleton extends Component {
  val io = new Bundle {
    // ---- 保留接口：阶段 1 RegisteredCommit 提交邮箱（占位） ----
    val commitMailboxValid    = out Bool()        // 提交邮箱 valid（占位行为：flushIn 打一拍）
    val commitMailboxPopCount = out UInt (2 bits) // 本拍退休条数，retireWidth=3 对齐（占位恒 0）
    val flushIn               = in  Bool()        // 未来：重定向消息链（needFlush 消息化）输入
    // ---- 保留接口：阶段 2 SystolicIssueQueue 发射授权（占位） ----
    val issueGrantValid       = out Bool()        // 发射授权 valid（占位恒 0）
    val issueGrantCell        = out UInt (3 bits) // 被授权胞元槽位号，7 胞元 → 3bit（占位恒 0）
  }

  // 占位寄存器：让 clk/reset 被真实使用，演练环边检查（每条组合环至少一个 FF）流程。
  val flushDly = RegNext(io.flushIn) init (False)

  io.commitMailboxValid    := flushDly
  io.commitMailboxPopCount := 0
  io.issueGrantValid       := False
  io.issueGrantCell        := 0
}

object DiscreteSkeletonGen {
  def main(args: Array[String]): Unit = {
    SpinalConfig(
      targetDirectory = "./build/discrete_skeleton",
      headerWithDate = true
    ).generateVerilog(new DiscreteSkeleton())
  }
}
