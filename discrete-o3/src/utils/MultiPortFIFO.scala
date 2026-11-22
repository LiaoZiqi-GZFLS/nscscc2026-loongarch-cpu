package NOP.utils

import spinal.core._
import spinal.lib._

/** 多口同步FIFO，要求读写口等宽，但可以一次push或pop少于读写口数量的数据，但push和pop相对于口要按顺序紧密排列。
  *
  * 重排序bram实现，可用于大规模FIFO。
  *
  * @param dataType
  * @param depth
  * @param pushCount
  * @param popCount
  */
class MultiPortFIFOSyncImpl[T <: Data](
    dataType: HardType[T],
    depth: Int,
    pushPorts: Int,
    popPorts: Int
) extends Component {
  // pow2保证指针循环没有问题
  require(depth > 0 && isPow2(depth))
  // 时序:读地址不再依赖 popCount 的提交就绪优先 mux(popPtr -> popCount mux
  // -> 加法 -> RAM 译码 曾是关键路径),改为直接读 popPtr 并超读 2 倍入口,
  // 弹出数据由寄存一拍的 popCount 在响应侧选择。
  val ram = new ReorderCacheRAMOutReg(dataType, depth, popPorts * 2, pushPorts, false, true,
      rspReplicaCount = popPorts)
  val pushPtr = RegInit(U(0, ram.addressWidth bits))
  val popPtr = RegInit(U(0, ram.addressWidth bits))
  val isRisingOccupancy = RegInit(False)
  val isEmpty = pushPtr === popPtr && !isRisingOccupancy
  val isFull = pushPtr === popPtr && isRisingOccupancy
  val io = new Bundle {

    /** push的valid，pop的ready，都要遵循连续性，从头开始的第一个0就表示了停止的位置，后面的1都会被忽略。
      */
    val push = Vec(slave(Stream(dataType)), pushPorts)
    val pop = Vec(master(Stream(dataType)), popPorts)
  }
  // push logic
  // round-6:ready/valid 由显式占用计数器驱动(寄存器+常数比较,1-2 级),
  // 替换 popPtr-pushPtr 减法链(round-3 的 pushPtr 锥:2 条 freeList
  // +1 条 TLB 路径的源头)。语义与旧指针减法完全一致(不含同拍 pop
  // 的保守下界)。
  val occupancy = RegInit(U(0, log2Up(depth + 1) bits))
  val maxPush = popPtr - pushPtr
  // 找到第一个非fire的
  val pushCount = PriorityMux(io.push.zipWithIndex.map { case (p, i) =>
    !p.fire -> U(i)
  } :+ (True -> U(pushPorts)))
  // 200MHz 结构重构:写端口整拍寄存(地址/数据/掩码/valid 全部延一拍),
  // RENAME→DISPATCH→robInfo 的长组合链在写端口边界截断;RAM 写旁路
  // 因此覆盖的是上一拍的 push。pop 侧语义由输出端"新鲜条目"选择 mux
  // 保全:下一拍弹出"上一拍刚 push"的条目时直接取写寄存器数据。
  val writePayload = RAMWriteCmdWithMask(Vec(dataType, pushPorts), ram.addressWidth, pushPorts)
  writePayload.address := pushPtr
  for (i <- 0 until pushPorts) {
    // 所有左侧均valid，且可以push
    val validTakeLeft = io.push.take(i + 1).map(_.valid).andR
    io.push(i).ready := occupancy <= (depth - 1 - i)
    writePayload.mask(i) := io.push(i).ready && validTakeLeft
    writePayload.data(i) := io.push(i).payload
  }
  val writeValid = io.push.map(_.valid).orR && !isFull
  // round-14:X-sweep 写命令/valid 寄存器复位清零,消除未初始化寄存器
  val writeCmdInit = RAMWriteCmdWithMask(Vec(dataType, pushPorts), ram.addressWidth, pushPorts)
  writeCmdInit.assignFromBits(B(0, widthOf(writeCmdInit) bits))
  val writeCmd = RegNext(writePayload, init = writeCmdInit)
  val writeValidReg = RegNext(writeValid, init = False)
  ram.io.write.payload := writeCmd
  ram.io.write.valid := writeValidReg
  pushPtr := pushPtr + pushCount

  // pop logic
  val maxPop = pushPtr - popPtr
  // 找到第一个非fire的
  val popCount = PriorityMux(io.pop.zipWithIndex.map { case (p, i) =>
    !p.fire -> U(i)
  } :+ (True -> U(popPorts)))
  // 上一拍的实际弹出数:本拍读响应(rsp = popPtr(T) 起的 2*popPorts 入口)
  // 对应下一拍要弹出的条目,响应侧用它选择
  // round-14:X-sweep 历史寄存器复位清零
  val popCountReg = RegNext(popCount.resize(log2Up(popPorts * 2) bits), init = U(0, log2Up(popPorts * 2) bits))
  // 上一拍 push 的指针与计数:本拍弹出的"新鲜条目"(上一拍刚 push,
  // 尚未写入 RAM、也不在 RAM 读窗口的旁路覆盖内)从写寄存器直取
  val pushPtrReg = RegNext(pushPtr, init = U(0, ram.addressWidth bits))
  val pushCountReg2 = RegNext(pushCount, init = U(0, log2Up(pushPorts) bits))
  for (i <- 0 until popPorts) {
    // 所有左侧均ready，且可以pop
    val readyTakeLeft = io.pop.take(i + 1).map(_.ready).andR
    io.pop(i).valid := occupancy >= (i + 1)
    val entryIdx = popPtr + i
    val freshLane = entryIdx - pushPtrReg
    val fresh = entryIdx >= pushPtrReg && freshLane < pushCountReg2
    // 手动复制:每个 pop 口的响应 mux 读不同的 rsp 副本,拆散扇出
    io.pop(i).payload := Mux(
      fresh,
      writeCmd.data(freshLane.resize(log2Up(pushPorts) bits)),
      ram.io.rspReplicas(i % popPorts)(popCountReg + i)
    )
  }
  popPtr := popPtr + popCount
  ram.io.read.cmd.valid := True
  ram.io.read.cmd.payload := popPtr

  occupancy := occupancy + pushCount - popCount
  when(pushCount =/= popCount)(isRisingOccupancy := pushCount > popCount)
}

class MultiPortFIFOAsyncImpl[T <: Data](dataType: HardType[T], depth: Int, pushPopCount: Int) extends Component {
  // pow2保证指针循环没有问题
  require(depth > 0 && isPow2(depth))
  val ram = new ReorderCacheRAMAsync(dataType, depth, pushPopCount)
  val pushPtr = RegInit(U(0, ram.addressWidth bits))
  val popPtr = RegInit(U(0, ram.addressWidth bits))
  val isRisingOccupancy = RegInit(False)
  val isEmpty = pushPtr === popPtr && !isRisingOccupancy
  val isFull = pushPtr === popPtr && isRisingOccupancy
  val io = new Bundle {

    /** push的valid，pop的ready，都要遵循连续性，从头开始的第一个0就表示了停止的位置，后面的1都会被忽略。
      */
    val push = Vec(slave(Stream(dataType)), pushPopCount)
    val pop = Vec(master(Stream(dataType)), pushPopCount)
  }
  // push logic
  val maxPush = popPtr - pushPtr
  // 找到第一个非fire的
  val pushCount = PriorityMux(io.push.zipWithIndex.map { case (p, i) =>
    !p.fire -> U(i)
  } :+ (True -> U(pushPopCount)))
  ram.io.write.valid := io.push.map(_.valid).orR && !isFull
  ram.io.write.payload.address := pushPtr
  for (i <- 0 until pushPopCount) {
    // 所有左侧均valid，且可以push
    val validTakeLeft = io.push.take(i + 1).map(_.valid).andR
    io.push(i).ready := isEmpty || i < maxPush
    ram.io.write.payload.mask(i) := io.push(i).ready && validTakeLeft
    ram.io.write.payload.data(i) := io.push(i).payload
  }
  pushPtr := pushPtr + pushCount

  // pop logic
  val maxPop = pushPtr - popPtr
  // 找到第一个非fire的
  val popCount = PriorityMux(io.pop.zipWithIndex.map { case (p, i) =>
    !p.fire -> U(i)
  } :+ (True -> U(pushPopCount)))
  for (i <- 0 until pushPopCount) {
    // 所有左侧均ready，且可以pop
    val readyTakeLeft = io.pop.take(i + 1).map(_.ready).andR
    io.pop(i).valid := isFull || i < maxPop
    io.pop(i).payload := ram.io.read.data(i)
  }
  popPtr := popPtr + popCount
  ram.io.read.address := popPtr

  when(pushCount =/= popCount)(isRisingOccupancy := pushCount > popCount)
}
