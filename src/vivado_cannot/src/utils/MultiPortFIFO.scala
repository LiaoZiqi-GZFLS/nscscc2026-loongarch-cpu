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
  val ram = new ReorderCacheRAMOutReg(dataType, depth, popPorts * 2, pushPorts, false, true)
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
  val maxPush = popPtr - pushPtr
  // 找到第一个非fire的
  val pushCount = PriorityMux(io.push.zipWithIndex.map { case (p, i) =>
    !p.fire -> U(i)
  } :+ (True -> U(pushPorts)))
  ram.io.write.valid := io.push.map(_.valid).orR && !isFull
  ram.io.write.payload.address := pushPtr
  for (i <- 0 until pushPorts) {
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
  } :+ (True -> U(popPorts)))
  // 上一拍的实际弹出数:本拍读响应(rsp = popPtr(T) 起的 2*popPorts 入口)
  // 对应下一拍要弹出的条目,响应侧用它选择
  val popCountReg = RegNext(popCount.resize(log2Up(popPorts * 2) bits))
  for (i <- 0 until popPorts) {
    // 所有左侧均ready，且可以pop
    val readyTakeLeft = io.pop.take(i + 1).map(_.ready).andR
    io.pop(i).valid := isFull || i < maxPop
    io.pop(i).payload := ram.io.read.rsp(popCountReg + i)
  }
  popPtr := popPtr + popCount
  ram.io.read.cmd.valid := True
  ram.io.read.cmd.payload := popPtr

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
