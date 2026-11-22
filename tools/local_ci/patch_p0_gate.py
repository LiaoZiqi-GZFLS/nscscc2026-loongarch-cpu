import io
p = r"D:\code\Vivado\Loongarch_workspace\T2026143250012561\src\vivado_cannot\src\pipeline\core\ROBFIFOPlugin.scala"
s = open(p, encoding="utf-8").read()

# q0: BRU
old = """    when(Bool(bruPorts.nonEmpty) && bruPorts(0).valid) {
      completionQueues(0).io.push.valid := True"""
new = """    val bruInNextBatch = bruPorts.nonEmpty && (0 until retireWidth).map(j => bruPorts(0).robIdx === popPtr + robInfo.popCount + j).reduce(_ || _)
    when(Bool(bruPorts.nonEmpty) && bruPorts(0).valid && !bruInNextBatch) {
      completionQueues(0).io.push.valid := True"""
assert old in s; s = s.replace(old, new, 1)

# q1/q2: ALU ports
old = """    for ((p, ai) <- aluPorts.zipWithIndex) {
      val qi = 1 + ai
      when(p.valid) {
        completionQueues(qi).io.push.valid := True"""
new = """    for ((p, ai) <- aluPorts.zipWithIndex) {
      val qi = 1 + ai
      val inNextBatch = (0 until retireWidth).map(j => p.robIdx === popPtr + robInfo.popCount + j).reduce(_ || _)
      when(p.valid && !inNextBatch) {
        completionQueues(qi).io.push.valid := True"""
assert old in s; s = s.replace(old, new, 1)

# q3: LSU
old = """    when(Bool(lsuPorts.nonEmpty) && lsuPorts(0).valid) {
      completionQueues(3).io.push.valid := True"""
new = """    val lsuInNextBatch = lsuPorts.nonEmpty && (0 until retireWidth).map(j => lsuPorts(0).robIdx === popPtr + robInfo.popCount + j).reduce(_ || _)
    when(Bool(lsuPorts.nonEmpty) && lsuPorts(0).valid && !lsuInNextBatch) {
      completionQueues(3).io.push.valid := True"""
assert old in s; s = s.replace(old, new, 1)

# q4: MDU
old = """    when(Bool(completePorts.nonEmpty) && completePorts(0).valid) {
      completionQueues(4).io.push.valid := True"""
new = """    val mduInNextBatch = completePorts.nonEmpty && (0 until retireWidth).map(j => completePorts(0).payload === popPtr + robInfo.popCount + j).reduce(_ || _)
    when(Bool(completePorts.nonEmpty) && completePorts(0).valid && !mduInNextBatch) {
      completionQueues(4).io.push.valid := True"""
assert old in s; s = s.replace(old, new, 1)

# born pushes: q5+i
old = """      when(fifoIO.push(i).fire && fifoIO.push(i).payload.state.complete) {
        completionQueues(5 + i).io.push.valid := True"""
new = """      // 与完成事件同一门控:robIdx 落在下一批(同拍前递覆盖)时抑制入队,
      // 否则条目落表后没有本拍 fire 可清,成为陈旧条目
      val bornInNextBatch = (0 until retireWidth).map(j => pushPtr + i === popPtr + robInfo.popCount + j).reduce(_ || _)
      when(fifoIO.push(i).fire && fifoIO.push(i).payload.state.complete && !bornInNextBatch) {
        completionQueues(5 + i).io.push.valid := True"""
assert old in s; s = s.replace(old, new, 1)

open(p, "w", encoding="utf-8").write(s)
print("push gates applied")
