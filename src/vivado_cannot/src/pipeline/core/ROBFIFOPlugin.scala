package NOP.pipeline.core

import spinal.core._
import spinal.lib._
import NOP._
import NOP.utils._
import NOP.builder._
import NOP.constants.`enum`.LoadStoreType
import NOP.pipeline._
import NOP.pipeline.decode._
import NOP.pipeline.core._

import scala.collection.mutable.ArrayBuffer

class ROBFIFOPlugin(config: MyCPUConfig) extends Plugin[MyCPUCore] {
  private val prfAddressWidth = config.regFile.prfAddrWidth
  private val robDepth = config.rob.robDepth
  private val retireWidth = config.rob.retireWidth
  private val decodeWidth = config.decode.decodeWidth
  private val addressWidth = config.rob.robAddressWidth
  private val entryType = HardType(ROBEntryBundle(config))
  private val infoType = HardType(ROBEntryInfoBundle(config))
  private val stateType = HardType(ROBEntryStateBundle(config.regFile))
  require(isPow2(robDepth))

  val robInfo = new MultiPortFIFOSyncImpl(infoType, robDepth, decodeWidth, retireWidth) {
    val flush = in(Bool)
    when(flush) {
      pushPtr := 0
      popPtr := 0
      isRisingOccupancy := False
      // 可pop不可push，否则数据会丢失
      // fifoIO.push.foreach(_.setBlocked())
    }
    pushPtr.asOutput()
    popPtr.asOutput()
    popCount.asOutput()
  }

  // ROB state随机写口
  private val completePorts = ArrayBuffer[Flow[UInt]]()
  private val lsuPorts = ArrayBuffer[Flow[ROBStateLSUPortBundle]]()
  private val bruPorts = ArrayBuffer[Flow[ROBStateBRUPortBundle]]()
  private val aluPorts = ArrayBuffer[Flow[ROBStateALUPortBundle]]()
  def completePort: Flow[UInt] = {
    val port = Flow(UInt(config.rob.robAddressWidth bits))
    completePorts += port
    port
  }
  def lsuPort = {
    val port = Flow(ROBStateLSUPortBundle(config))
    lsuPorts += port
    port
  }
  def bruPort = {
    val port = Flow(ROBStateBRUPortBundle(config))
    bruPorts += port
    port
  }
  def aluPort = {
    val port = Flow(ROBStateALUPortBundle(config))
    aluPorts += port
    port
  }

  // P0(200MHz):完成队列取代中央 robState。每条执行管线一条 CAM
  // 队列(发射按操作数就绪乱序,同管完成不按 robIdx 顺序到达,条目
  // 按 robIdx 标签存取、任意位置清除),加"天生完成"队列承接
  // needNotExecute 条目;提交按 robIdx 位置匹配队列条目,同拍完成由
  // 端口级 forward 覆盖,flush 整体清空。中央 32:1 状态读 mux 与
  // 随机写口交叉全部消失。
  val cqDepth = 16
  val cqCount = 5 + decodeWidth
  // q0..q2: ALU0/1/2(q0 兼 BRU),q3: LSU,q4: MDU,
  // q5..q5+decodeWidth-1: 各派发 lane 的"天生完成"队列
  // (每 lane 一条,避免同拍多 lane 推同一队列的打包/空洞问题)
  val cqStateType = stateType
  val completionQueues = Seq.fill(cqCount)(new CompletionQueue(cqStateType, cqDepth))
  completionQueues.zipWithIndex.foreach { case (q, i) => q.setWeakName(s"completionQueue_$i") }

  val pushPtr = robInfo.pushPtr
  val popPtr = robInfo.popPtr
  val fifoIO = new Bundle {

    /** push的valid，pop的ready，都要遵循连续性，从头开始的第一个0就表示了停止的位置，后面的1都会被忽略。
      */
    val push = Vec(Stream(ROBEntryBundle(config, false)), decodeWidth)
    val pop = Vec(Stream(entryType), retireWidth)
    // 同步清空FIFO
    val flush = Bool
  }

  // TODO: [NOP] delete this debugging code
  val debug_fifoIO = out(new Bundle {
    val push = Vec(Stream(ROBEntryBundle(config, false)), decodeWidth)
    val pop = Vec(Stream(entryType), retireWidth)
    val flush = Bool()
  })
  debug_fifoIO.assignAllByName(fifoIO)

  val debugPopWriteData = config.debug generate out(Vec(BWord(), retireWidth))
  override def build(pipeline: MyCPUCore): Unit = pipeline plug new Area {
    if (config.debug) {
      val physRegs = pipeline.service(classOf[PhysRegFilePlugin]).regs
      for (i <- 0 until retireWidth) {
        debugPopWriteData(i) := physRegs(fifoIO.pop(i).payload.info.rename.wReg) // bypassing for debug :)
      }
    }
    // FIFO与MultiPortFIFOVec完全一致，但是ROB不止FIFO端口
    val defaultState = new ROBEntryStateBundle(config.regFile, true)

    // 完成则代表这条指令已经可以提交
    defaultState.complete := False
    // 完整异常信息
    defaultState.except.setIdle()
    // 分支预测恢复信息
    defaultState.mispredict := False
    defaultState.actualTaken := False

    // When full is true
    // LSU检测到uncached区段，需要提交时操作
    defaultState.lsuUncached := False
    // INT执行结果
    defaultState.intResult := 0

    // TODO: [NOP] DiffTest Bundle. Remove this in the future.
    defaultState.isCount := False
    defaultState.count64ReadValue := 0
    defaultState.csrRstat := False
    defaultState.csrRdata := 0
    defaultState.isLoad := False
    defaultState.isStore := False
    defaultState.isLL := False
    defaultState.isSC := False
    defaultState.lsType := LoadStoreType.WORD
    defaultState.vAddr := 0
    defaultState.pAddr := 0
    defaultState.storeData := 0
    defaultState.myPC := B(0x0eadbeef, 32 bits).asUInt

    // multi-port FIFO io
    // P0:状态来自完成队列的位置匹配(popPtr+popCount+i 的 robIdx
    // 在哪个队列的可见窗口里),缺省为未完成;state 寄存器保留
    // (断 ready↔complete 组合环)
    for (i <- 0 until retireWidth)
      fifoIO.pop(i).translateFrom(robInfo.io.pop(i)) { (entry, info) =>
        entry.info := info
        entry.state.setAsReg().allowOverride
        val idx = popPtr + robInfo.popCount + i
        // 每端口独立的新 bundle:defaultState 是共享对象,直接引用会
        // 让各端口的匹配 when 写同一组信号,后匹配端口的完成状态
        // 污染前面的端口
        val stateSel = new ROBEntryStateBundle(config.regFile)
        stateSel := defaultState
        for (q <- completionQueues) {
          for (d <- 0 until cqDepth) {
            when(q.io.window(d).valid && q.io.window(d).robIdx === idx) {
              stateSel := q.io.window(d).state
            }
          }
        }
        entry.state := stateSel
      }

    // 队列弹出:robIdx 匹配**本拍退休批次**且 fire 的条目在任意位置
    // 清除(同管完成乱序,FIFO 头弹出不适用)。注意本拍退休的 robIdx
    // 是 popPtr+j,而状态读覆盖下一批(popPtr+popCount+j)——
    // 两条路径的 idx 不同;同拍前递覆盖的条目 push 落表后由本拍
    // popMask 清除,不留陈旧条目。
    for (q <- completionQueues) {
      val popMask = Bits(cqDepth bits)
      popMask := 0
      for (d <- 0 until cqDepth) {
        for (j <- 0 until retireWidth) {
          when(robInfo.io.pop(j).fire && q.io.window(d).valid && q.io.window(d).robIdx === popPtr + j) {
            popMask(d) := True
          }
        }
      }
      q.io.popMask := popMask
      // 本拍弹出的 robIdx 集合:同拍 push 的条目若在其中(前递已覆盖
      // 状态),落表后立即清除,不留陈旧条目
      for (j <- 0 until retireWidth) {
        q.io.popped(j).valid := robInfo.io.pop(j).fire
        q.io.popped(j).robIdx := popPtr + j
      }
      // straggler 防护:flush 后一拍 MEM 级指令仍会完成(旧代 robIdx),
      // 其 push 落在已清空的队列里成为陈旧条目。clear 延长一拍覆盖
      // 该窗口(再深处已被 removeIt 清除,不会产生完成事件)。
      val clearHold = RegNext(fifoIO.flush) init (False)
      q.io.clear := fifoIO.flush || clearHold
    }

    for (i <- 0 until decodeWidth) {
      robInfo.io.push(i).translateFrom(fifoIO.push(i)) { (info, entry) =>
        info := entry.info
      }
      // 天生完成条目(needNotExecute):派发即入本 lane 的"天生完成"
      // 队列(complete 标志由 CommitPlugin 在派发载荷上算好)
      when(fifoIO.push(i).fire && fifoIO.push(i).payload.state.complete) {
        completionQueues(5 + i).io.push.valid := True
        completionQueues(5 + i).io.push.robIdx := pushPtr + i
        val pushState = ROBEntryStateBundle(config.regFile)
        pushState := defaultState
        pushState.allowOverride()
        pushState.complete := True
        pushState.assignSomeByName(fifoIO.push(i).payload.state)
        completionQueues(5 + i).io.push.state := pushState
      } otherwise {
        completionQueues(5 + i).io.push.valid := False
        completionQueues(5 + i).io.push.payload.assignDontCare()
      }
      // 与旧版一致:派发前递必须门控 fire(否则 decode 气泡时
      // 用垃圾载荷覆盖 state 寄存器的 complete/except)
      for (j <- i until retireWidth) when(fifoIO.push(i).fire && pushPtr + i === popPtr + robInfo.popCount + j) {
        fifoIO.pop(j).payload.state.assignSomeByName(fifoIO.push(i).payload.state)
      }
    }
    robInfo.flush := fifoIO.flush

    // random write ports
    println("ROB port summary:")
    printf("  pure ALU: %d\n", aluPorts.size)
    printf("  ALU&BRU: %d\n", bruPorts.size)
    printf("  LSU: %d\n", lsuPorts.size)
    printf("  MDU: %d\n", completePorts.size)
    val portCount = aluPorts.size + bruPorts.size + lsuPorts.size + completePorts.size
    printf("  issue width: %d\n", portCount)

    // P0:完成事件入队列(状态装配与旧 robState 写完全一致);
    // 同拍前递(robIdx 匹配当前批)保留。每队列单 when/otherwise 链。
def pushPayload(q: CompletionQueue[_], robIdx: UInt) = {
      q.io.push.robIdx := robIdx
      val pushState = ROBEntryStateBundle(config.regFile)
      pushState := defaultState
      pushState.allowOverride()
      pushState.complete := True
      pushState
    }
    // q0:BRU 管(withBRU 的 pipe0);q1/q2:ALU 管(aluPorts(0)/(1))
    when(Bool(bruPorts.nonEmpty) && bruPorts(0).valid) {
      completionQueues(0).io.push.valid := True
      val ps = pushPayload(completionQueues(0), bruPorts(0).robIdx)
      ps.assignSomeByName(bruPorts(0).payload)
      completionQueues(0).io.push.state := ps
    } otherwise {
      completionQueues(0).io.push.valid := False
      completionQueues(0).io.push.payload.assignDontCare()
    }
    for ((p, ai) <- aluPorts.zipWithIndex) {
      val qi = 1 + ai
      when(p.valid) {
        completionQueues(qi).io.push.valid := True
        val ps = pushPayload(completionQueues(qi), p.robIdx)
        ps.assignSomeByName(p.payload)
        completionQueues(qi).io.push.state := ps
      } otherwise {
        completionQueues(qi).io.push.valid := False
        completionQueues(qi).io.push.payload.assignDontCare()
      }
    }
    // q3:LSU
    when(Bool(lsuPorts.nonEmpty) && lsuPorts(0).valid) {
      completionQueues(3).io.push.valid := True
      val ps = pushPayload(completionQueues(3), lsuPorts(0).robIdx)
      ps.assignSomeByName(lsuPorts(0).payload)
      completionQueues(3).io.push.state := ps
    } otherwise {
      completionQueues(3).io.push.valid := False
      completionQueues(3).io.push.payload.assignDontCare()
    }
    // q4:MDU
    when(Bool(completePorts.nonEmpty) && completePorts(0).valid) {
      completionQueues(4).io.push.valid := True
      val ps = pushPayload(completionQueues(4), completePorts(0).payload)
      completionQueues(4).io.push.state := ps
    } otherwise {
      completionQueues(4).io.push.valid := False
      completionQueues(4).io.push.payload.assignDontCare()
    }
    // 同拍前递(robIdx 匹配当前批)
    for (p <- aluPorts)
      for (j <- 0 until retireWidth) when(p.valid && p.robIdx === popPtr + robInfo.popCount + j) {
        fifoIO.pop(j).payload.state := defaultState
        fifoIO.pop(j).payload.state.allowOverride()
        fifoIO.pop(j).payload.state.complete := True
        fifoIO.pop(j).payload.state.assignSomeByName(p.payload)
      }
    for (p <- bruPorts)
      for (j <- 0 until retireWidth) when(p.valid && p.robIdx === popPtr + robInfo.popCount + j) {
        fifoIO.pop(j).payload.state := defaultState
        fifoIO.pop(j).payload.state.allowOverride()
        fifoIO.pop(j).payload.state.complete := True
        fifoIO.pop(j).payload.state.assignSomeByName(p.payload)
      }
    for (p <- lsuPorts)
      for (j <- 0 until retireWidth) when(p.valid && p.robIdx === popPtr + robInfo.popCount + j) {
        fifoIO.pop(j).payload.state := defaultState
        fifoIO.pop(j).payload.state.allowOverride()
        fifoIO.pop(j).payload.state.complete := True
        fifoIO.pop(j).payload.state.assignSomeByName(p.payload)
      }
    for (p <- completePorts)
      for (j <- 0 until retireWidth) when(p.valid && p.payload === popPtr + robInfo.popCount + j) {
        fifoIO.pop(j).payload.state := defaultState
        fifoIO.pop(j).payload.state.allowOverride()
        fifoIO.pop(j).payload.state.complete := True
      }
  }
}
