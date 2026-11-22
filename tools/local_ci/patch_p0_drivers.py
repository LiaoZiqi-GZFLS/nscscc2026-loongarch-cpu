import io
p = r"D:\code\Vivado\Loongarch_workspace\T2026143250012561\src\vivado_cannot\src\pipeline\core\ROBFIFOPlugin.scala"
s = open(p, encoding="utf-8").read()

old = """    // P0:完成事件入队列(状态装配与旧 robState 写完全一致);
    // 同拍前递(robIdx 匹配当前批)保留
    completionQueues.foreach(_.io.push.valid := False)
    for ((p, qi) <- aluPorts.zipWithIndex)
      when(p.valid) {
        completionQueues(qi).io.push.valid := True
        completionQueues(qi).io.push.robIdx := p.robIdx
        val pushState = ROBEntryStateBundle(config.regFile)
        pushState := defaultState
        pushState.allowOverride()
        pushState.complete := True
        pushState.assignSomeByName(p.payload)
        completionQueues(qi).io.push.state := pushState
        for (j <- 0 until retireWidth) when(p.robIdx === popPtr + robInfo.popCount + j) {
          fifoIO.pop(j).payload.state := defaultState
          fifoIO.pop(j).payload.state.allowOverride()
          fifoIO.pop(j).payload.state.complete := True
          fifoIO.pop(j).payload.state.assignSomeByName(p.payload)
        }
      }
    for (p <- bruPorts)
      when(p.valid) {
        completionQueues(0).io.push.valid := True
        completionQueues(0).io.push.robIdx := p.robIdx
        val pushState = ROBEntryStateBundle(config.regFile)
        pushState := defaultState
        pushState.allowOverride()
        pushState.complete := True
        pushState.assignSomeByName(p.payload)
        completionQueues(0).io.push.state := pushState
        for (j <- 0 until retireWidth) when(p.robIdx === popPtr + robInfo.popCount + j) {
          fifoIO.pop(j).payload.state := defaultState
          fifoIO.pop(j).payload.state.allowOverride()
          fifoIO.pop(j).payload.state.complete := True
          fifoIO.pop(j).payload.state.assignSomeByName(p.payload)
        }
      }
    for (p <- lsuPorts)
      when(p.valid) {
        completionQueues(3).io.push.valid := True
        completionQueues(3).io.push.robIdx := p.robIdx
        val pushState = ROBEntryStateBundle(config.regFile)
        pushState := defaultState
        pushState.allowOverride()
        pushState.complete := True
        pushState.assignSomeByName(p.payload)
        completionQueues(3).io.push.state := pushState
        for (j <- 0 until retireWidth) when(p.robIdx === popPtr + robInfo.popCount + j) {
          fifoIO.pop(j).payload.state := defaultState
          fifoIO.pop(j).payload.state.allowOverride()
          fifoIO.pop(j).payload.state.complete := True
          fifoIO.pop(j).payload.state.assignSomeByName(p.payload)
        }
      }
    for (p <- completePorts)
      when(p.valid) {
        completionQueues(4).io.push.valid := True
        completionQueues(4).io.push.robIdx := p.payload
        val pushState = ROBEntryStateBundle(config.regFile)
        pushState := defaultState
        pushState.allowOverride()
        pushState.complete := True
        completionQueues(4).io.push.state := pushState
        for (j <- 0 until retireWidth) when(p.payload === popPtr + robInfo.popCount + j) {
          fifoIO.pop(j).payload.state := defaultState
          fifoIO.pop(j).payload.state.allowOverride()
          fifoIO.pop(j).payload.state.complete := True
        }
      }"""

new = """    // P0:完成事件入队列(状态装配与旧 robState 写完全一致);
    // 同拍前递(robIdx 匹配当前批)保留。每队列单 when/otherwise 链
    def pushPayload(q: CompletionQueue, robIdx: UInt) = {
      q.io.push.robIdx := robIdx
      val pushState = ROBEntryStateBundle(config.regFile)
      pushState := defaultState
      pushState.allowOverride()
      pushState.complete := True
      pushState
    }
    // q0:ALU0 与 BRU 互斥(同一管线),otherwise 兜底
    when(aluPorts.nonEmpty && aluPorts(0).valid) {
      completionQueues(0).io.push.valid := True
      val ps = pushPayload(completionQueues(0), aluPorts(0).robIdx)
      ps.assignSomeByName(aluPorts(0).payload)
      completionQueues(0).io.push.state := ps
    } elsewhen (bruPorts.nonEmpty && bruPorts(0).valid) {
      completionQueues(0).io.push.valid := True
      val ps = pushPayload(completionQueues(0), bruPorts(0).robIdx)
      ps.assignSomeByName(bruPorts(0).payload)
      completionQueues(0).io.push.state := ps
    } otherwise {
      completionQueues(0).io.push.valid := False
    }
    // q1/q2:ALU1/ALU2
    for (qi <- 1 until 3) {
      val p = aluPorts(qi)
      when(p.valid) {
        completionQueues(qi).io.push.valid := True
        val ps = pushPayload(completionQueues(qi), p.robIdx)
        ps.assignSomeByName(p.payload)
        completionQueues(qi).io.push.state := ps
      } otherwise {
        completionQueues(qi).io.push.valid := False
      }
    }
    // q3:LSU
    when(lsuPorts.nonEmpty && lsuPorts(0).valid) {
      completionQueues(3).io.push.valid := True
      val ps = pushPayload(completionQueues(3), lsuPorts(0).robIdx)
      ps.assignSomeByName(lsuPorts(0).payload)
      completionQueues(3).io.push.state := ps
    } otherwise {
      completionQueues(3).io.push.valid := False
    }
    // q4:MDU
    when(completePorts.nonEmpty && completePorts(0).valid) {
      completionQueues(4).io.push.valid := True
      val ps = pushPayload(completionQueues(4), completePorts(0).payload)
      completionQueues(4).io.push.state := ps
    } otherwise {
      completionQueues(4).io.push.valid := False
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
      }"""

assert old in s, "port-group block not found"
s = s.replace(old, new, 1)

old2 = """      completionQueues(5 + i).io.push.valid := False
      when(fifoIO.push(i).fire && fifoIO.push(i).payload.state.complete) {
        completionQueues(5 + i).io.push.valid := True
        completionQueues(5 + i).io.push.robIdx := pushPtr + i
        val pushState = ROBEntryStateBundle(config.regFile)
        pushState := defaultState
        pushState.allowOverride()
        pushState.complete := True
        pushState.assignSomeByName(fifoIO.push(i).payload.state)
        completionQueues(5 + i).io.push.state := pushState
      }"""
new2 = """      when(fifoIO.push(i).fire && fifoIO.push(i).payload.state.complete) {
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
      }"""
assert old2 in s, "dispatch push block not found"
s = s.replace(old2, new2, 1)
open(p, "w", encoding="utf-8").write(s)
print("single-driver chains done")
