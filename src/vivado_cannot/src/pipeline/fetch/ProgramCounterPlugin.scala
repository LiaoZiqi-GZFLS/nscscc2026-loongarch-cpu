package NOP.pipeline.fetch

import NOP.pipeline._
import NOP.pipeline.core._
import NOP.builder._
import NOP.utils._
import NOP._

import spinal.core._
import spinal.core.sim._
import spinal.lib._
import scala.collection.mutable.ArrayBuffer

class ProgramCounterPlugin(config: FrontendConfig) extends Plugin[FetchPipeline] {
  case class JumpInfo(interface: Stream[UInt], priority: Int)
  private val jumpInfos = ArrayBuffer[JumpInfo]()
  private var predict: Flow[UInt] = null

  // * outside functions
  // add a new entry to the jumpInfo, the larger the higher priority
  def addJumpInterface(interface: Stream[UInt], priority: Int): Unit = {
    jumpInfos += JumpInfo(interface, priority)
  }

  def setPredict(source: Flow[UInt]): Unit = {
    predict = source
  }

  // * inner signals
  val nextPC = UWord()
  val backendJumpInterface = Stream(UWord()).setIdle()

  // [stage2-③] SpinalSim 探针别名(零硬件影响)
  var probeJumpPipeValid: Bool = null
  var probeJumpPipeTarget: UInt = null
  var probeExeJumpPipeValid: Bool = null
  var probeExeJumpPipeTarget: UInt = null
  var probeRegPC: UInt = null
  var probeIf1Stuck: Bool = null

  override def build(pipeline: FetchPipeline): Unit = pipeline.IF1 plug new Area {
    import pipeline.IF1._
    // S3v2：s2mPipe→m2sPipe。s2mPipe 只寄存 ready，skid 空时 valid/payload
    // 组合直通——ROB 重定向锥经 jumpPipe.payload 直达 nextPC→ICache 读地址，
    // 构成 100M 最差路径（9.468ns，82% 布线）。m2sPipe 落寄存器斩断该链，
    // 代价：重定向 valid/payload 晚 1 拍到达（T+1）。
    val jumpPipe = backendJumpInterface.m2sPipe()
    // S3v2 配套（同拍依赖修复）：jump 晚到后，T 拍（needFlush）按旧 nextPC 发出的
    // ICache 读 + regPC(T+1)=nextPC(T) 的旧值偏斜，会在 T+1 于 IF1 拼出一条
    // "标签数据自洽"的旧径指令漏过后端冲刷（S3 coremark cyc860 实锤：早期 boot
    // 漏网指令退休触发异常，EENTRY 未初始化=0 → 坠 0x0 死循环）。
    // jump 到达拍冲刷 IF1 一次：旧读数据/偏斜标签随级丢弃；同拍发出的目标读
    // （rValid 不受 flushIt 影响）在 T+2 与 regPC(T+2)=target 自洽配对。
    arbitration.flushIt setWhen jumpPipe.valid
    jumpPipe.ready := !arbitration.isStuck

    // stage2-③: EXE 提前重定向(m2sPipe 副本,T_e+1 到达 PC;R9-3 优先级低于 jumpPipe)
    val exeJumpPipe = pipeline.globalService(classOf[CommitFlush]).exeRedirectIn.m2sPipe()
    arbitration.flushIt setWhen exeJumpPipe.valid
    exeJumpPipe.ready := !arbitration.isStuck
    val cacheLineWords = config.icache.lineWords

    // ! declare regPC
    val regPC = RegNextWhen(nextPC, !arbitration.isStuck, init = UWord(config.pcInit))
    insert(pipeline.signals.PC) := regPC

    // ! Set nextPC
    // ! nextPC branch 1, increment
    val pcOffset = regPC(2, log2Up(cacheLineWords) bits)
    val fetchWidth = config.fetchWidth

    val defaultPC = regPC + (pcOffset.muxList(
      U(fetchWidth), // default: increment by fetchWidth
      ((cacheLineWords - fetchWidth + 1) until cacheLineWords).map { i =>
        (i, U(cacheLineWords - i)) // 一次fetch不允许跨行，因此最多顶到行尾. 顶到行尾的时候，从下一行开始
      }
    ) @@ U"2'b00")
    nextPC := defaultPC

    // ! nextPC branch 2, BTB prediction jump
    if (predict != null) {
      when(predict.valid)(nextPC := predict.payload)
    }

    // ! nextPC branch 2.5, EXE 提前重定向(stage2-③;低于提交侧 jumpPipe)
    when(exeJumpPipe.valid)(nextPC := exeJumpPipe.payload)

    // ! nextPC branch 3 (highest priority), backend jump
    when(jumpPipe.valid)(nextPC := jumpPipe.payload)

    // [stage2-③] SpinalSim 探针
    jumpPipe.valid.simPublic()
    jumpPipe.payload.simPublic()
    exeJumpPipe.valid.simPublic()
    exeJumpPipe.payload.simPublic()
    regPC.simPublic()
    arbitration.isStuck.simPublic()
    probeJumpPipeValid = jumpPipe.valid
    probeJumpPipeTarget = jumpPipe.payload
    probeExeJumpPipeValid = exeJumpPipe.valid
    probeExeJumpPipeTarget = exeJumpPipe.payload
    probeRegPC = regPC
    probeIf1Stuck = arbitration.isStuck
  }
}
