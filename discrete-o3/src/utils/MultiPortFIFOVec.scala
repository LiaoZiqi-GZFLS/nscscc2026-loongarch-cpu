package NOP.utils

import spinal.core._
import spinal.lib._

/** 多口同步FIFO，要求读写口等宽，但一次可以读写更少的量，不过必须在顺序的口上。
  *
  * 寄存器Vec实现，仅可用于小规模FIFO。好处是延迟仅为1 cycle，很方便插进流水线。
  *
  * 注意同步填充暂不支持。也就是说如果满了，即使这个周期要pop，也不能push，对时序好一些。
  *
  * @param dataType
  * @param depth
  * @param pushCount
  * @param popCount
  */
class MultiPortFIFOVec[T <: Data](
    dataType: HardType[T],
    depth: Int,
    pushPorts: Int,
    popPorts: Int,
    dataInit: Int => T = null,
    pushInit: Int = 0,
    popInit: Int = 0,
    initFull: Boolean = false
) extends Component {
  // pow2保证指针循环没有问题
  require(depth > 0 && isPow2(depth))
  val addressWidth = log2Up(depth)
  val dataVec =
    if (dataInit != null) Vec.tabulate(depth)({ i => RegInit(dataInit(i)) })
    else Reg(Vec(dataType, depth))
  def dataRead(addr: UInt) = dataVec(addr)
  def dataWrite(addr: UInt, value: T) = dataVec(addr) := value
  val pushPtr = RegInit(U(pushInit, addressWidth bits))
  val popPtr = RegInit(U(popInit, addressWidth bits))
  val pushEquals = (0 until depth).map { i => pushPtr === i }
  val popEquals = (0 until depth).map { i => popPtr === i }
  def dataRead(base: UInt, offset: Int) = {
    val result =
      dataVec.dataType().setCompositeName(dataVec, "readPort", weak = true).assignDontCare()
    dataVec.zipWithIndex.foreach { case (d, i) =>
      when(popEquals((i - offset + depth) % depth))(result := dataVec(i))
    }
    result
  }
  def dataWrite(base: UInt, offset: Int, value: T) = dataVec.zipWithIndex.foreach { case (d, i) =>
    when(pushEquals((i - offset + depth) % depth))(dataVec(i) := value)
  }
  val isRisingOccupancy = RegInit(Bool(initFull))
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
  for (i <- 0 until pushPorts) {
    // 所有左侧均valid，且可以push
    val validTakeLeft = io.push.take(i + 1).map(_.valid).andR
    io.push(i).ready := isEmpty || i < maxPush
    when(io.push(i).ready && validTakeLeft)(dataWrite(pushPtr, i, io.push(i).payload))
  }
  pushPtr := pushPtr + pushCount

  // pop logic
  val maxPop = pushPtr - popPtr
  // 找到第一个非fire的
  val popCount = PriorityMux(io.pop.zipWithIndex.map { case (p, i) =>
    !p.fire -> U(i)
  } :+ (True -> U(popPorts)))
  for (i <- 0 until popPorts) {
    // 所有左侧均ready，且可以pop
    val readyTakeLeft = io.pop.take(i + 1).map(_.ready).andR
    io.pop(i).valid := isFull || i < maxPop
    io.pop(i).payload := dataRead(popPtr, i)
  }
  popPtr := popPtr + popCount

  when(pushCount =/= popCount)(isRisingOccupancy := pushCount > popCount)
}

class MultiPortFIFOVecOutReg[T <: Data](
    dataType: HardType[T],
    depth: Int,
    pushPorts: Int,
    popPorts: Int,
    dataInit: Int => T = null,
    pushInit: Int = 0,
    popInit: Int = 0,
    initFull: Boolean = false,
    // round-6: 用显式占用计数器驱动 ready/valid(寄存器+常数比较),
    // 替换 popPtr-pushPtr 减法链。freeList 的 recover 语义依赖指针
    // 关系,保持默认 false。
    useOccupancyCounter: Boolean = false,
    // round-10:pop 负载 D 用投机读(popPtr+0..2*popPorts-1 并行读,
    // 地址=popPtr+常数,popCount 只做末级选择),斩断
    // 仲裁链→popCount→读地址 的深度(round-10 top60 中 42 条
    // 落点为 fetch buffer pop 负载寄存器)。面积约翻倍(取指缓冲用)。
    specReadPop: Boolean = false
) extends Component {
  // pow2保证指针循环没有问题
  require(depth > 0 && isPow2(depth))
  val addressWidth = log2Up(depth)
  val dataVec =
    if (dataInit != null) Vec.tabulate(depth)({ i => RegInit(dataInit(i)) })
    else Reg(Vec(dataType, depth))
  val pushPtr = RegInit(U(pushInit, addressWidth bits))
  val popPtr = RegInit(U(popInit, addressWidth bits))
  val pushEquals = (0 until depth).map { i => pushPtr === i }
  val popEquals = (0 until depth).map { i => popPtr === i }
  val isRisingOccupancy = RegInit(Bool(initFull))
  val isEmpty = pushPtr === popPtr && !isRisingOccupancy
  val isFull = pushPtr === popPtr && isRisingOccupancy
  val io = new Bundle {

    /** push的valid，pop的ready，都要遵循连续性，从头开始的第一个0就表示了停止的位置，后面的1都会被忽略。
      */
    val push = Vec(slave(Stream(dataType)), pushPorts)
    val pop = Vec(master(Stream(dataType)), popPorts)
  }

  // round-6: 可选占用计数器(见构造参数注释)。
  val occupancy = RegInit(U(if (initFull) depth else 0, log2Up(depth + 1) bits))

  // pop logic
  val maxPop = pushPtr - popPtr
  // 找到第一个非fire的
  val popCount = PriorityMux(io.pop.zipWithIndex.map { case (p, i) =>
    !p.fire -> U(i)
  } :+ (True -> U(popPorts)))
  // round-10:投机读(popPtr+常数 并行读),popCount 只做末级选择
  // round-16(团队):修复投机读索引位宽 bug——popCount(2bit)+i 在 popCount=3 时
  // 溢出截断为 2bit,第 2 口读错表项。先 resize 到 log2Up(popPorts*2) 再做加法。
  // 注:round-12 曾尝试"选择=popCountReg+数据双寄存"的全寄存化(消 13 级链),
  // 两次实现均出现均匀 ~4× 变慢+第 21 点停滞(推导逐拍等价但存在未定位交互),
  // 已放弃回退;FB 链的修复留待 ID0 独立 pop 拍方案。
  val specReads = if (specReadPop) Some(Vec((0 until popPorts * 2).map(k => dataVec(popPtr + k)))) else None
  for (i <- 0 until popPorts) {
    // 所有左侧均ready，且可以pop
    val readyTakeLeft = io.pop.take(i + 1).map(_.ready).andR
    io.pop(i).valid := (if (useOccupancyCounter) occupancy >= (i + 1) else isFull || i < maxPop)
    io.pop(i).payload.setAsReg()
    io.pop(i).payload :=
      (if (specReadPop) specReads.get(popCount.resize(log2Up(popPorts * 2)) + i) else dataVec(popPtr + popCount + i))
  }
  popPtr := popPtr + popCount

  // push logic
  val maxPush = popPtr - pushPtr
  // 找到第一个非fire的
  val pushCount = PriorityMux(io.push.zipWithIndex.map { case (p, i) =>
    !p.fire -> U(i)
  } :+ (True -> U(pushPorts)))
  for (i <- 0 until pushPorts) {
    // 所有左侧均valid，且可以push
    val validTakeLeft = io.push.take(i + 1).map(_.valid).andR
    io.push(i).ready :=
      (if (useOccupancyCounter) occupancy <= (depth - 1 - i) else isEmpty || i < maxPush)
    when(io.push(i).ready && validTakeLeft) {
      dataVec(pushPtr + i) := io.push(i).payload
      for (j <- i until popPorts) when(pushPtr + i === popPtr + popCount + j) {
        io.pop(j).payload := io.push(i).payload
      }
    }
  }
  pushPtr := pushPtr + pushCount

  if (useOccupancyCounter) {
    occupancy := occupancy + pushCount - popCount
  }
  when(pushCount =/= popCount)(isRisingOccupancy := pushCount > popCount)
}
