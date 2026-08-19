package NOP.pipeline.core

import NOP._
import NOP.debug._
import NOP.builder._
import NOP.pipeline._
import NOP.pipeline.fetch._
import NOP.pipeline.decode._
import NOP.pipeline.exe._
import NOP.pipeline.mem._
import NOP.pipeline.priviledge._
import spinal.core._
import spinal.lib.bus.amba4.axi._
import spinal.lib._

class MyCPUCore(config: MyCPUConfig, resetDomains: Seq[ClockDomain] = null) extends Component with MultiPipeline {

  val global = this

  // ---- stage1 reset tree split: per-group synchronous reset domains ----
  // resetDomains == null -> legacy single async domain (MyCPUAdapted path, zero behavior change).
  // Group allocation (calibrated against the F3 netlist reset-FF bit counts):
  //   0  fetch core (PC/FetchBuffer/ICache/InstAddrTranslate/RAS) + fetch stage regs
  //   1  GlobalPredictorBTBPlugin (1024-entry BTB valid array, dedicated net)
  //   2  decode pipeline (DecoderArray + RenamePlugin sRAT/aRAT/freeList + stage regs)
  //   3  3x INT ExecutePipeline + IntIssueQueuePlugin
  //   4  MulDiv pipeline + MulDivIssueQueuePlugin
  //   5  mem front (AddressGeneration/DCache valids+DirtyBits/Uncached)
  //   6  mem back (LoadPostprocess/StoreBuffer/MemExecute) + MemIssueQueuePlugin + mem stage regs
  //   7  commit core (ROB FIFO + Commit + BypassNetwork + SpeculativeWakeup)
  //   8  PhysRegFilePlugin (63x32b PRF + busys, dedicated net)
  //   9  privilege common (Timer64/ExceptionHandler/Interrupt/CSR/Wait)
  //   10 MMUPlugin (TLB table, dedicated net)
  //   11 AXI peripherals (consumed in MyCPU.scala)
  private def cd(i: Int): ClockDomain = if (resetDomains != null) resetDomains(i) else null
  private def inCd[T](i: Int)(body: => T): T = if (resetDomains != null) cd(i)(body) else body
  // Construct a plugin inside its group domain (covers class-level member registers, which
  // follow the construction-time ambient domain) AND tag it for build() (PrePopTask, see
  // builder/Pipeline.scala).
  private def grp[P <: Plugin[_]](i: Int)(p: => P): P = {
    val plugin = inCd(i)(p)
    plugin.clockDomain = cd(i)
    plugin
  }

  // ! Fetch Pipeline
  val btbPlugin = grp(1)(new GlobalPredictorBTBPlugin(config.frontend))
  val fetchPipeline = inCd(0) {
    new FetchPipeline {

      override val signals = new FetchSignals(config)
      override val IF1: Stage = newStage()
      override val IF2: Stage = newStage()

      plugins ++= List(
        new ProgramCounterPlugin(config.frontend),
        new FetchBufferPlugin(config),
        new ICachePlugin(config),
        new ExceptionMuxPlugin[FetchPipeline](stages.size - 1),
        new InstAddrTranslatePlugin(),
        btbPlugin,
        new ReturnAddressStackPlugin(config.frontend)
      ).filter(_ != null)

    }
  }
  fetchPipeline.groupCd = cd(0)
  addPipeline(fetchPipeline)

  // ! Decode Pipeline
  val decodePipeline: DecodePipeline = inCd(2) {
    new DecodePipeline {

      override val signals = new DecodeSignals(config)
      // stage2-②: 译码 3 拍化（ID1=FB pop 寄存 / ID2=65 路匹配+字段 mux / ID3=epilogue）
      override val ID1: Stage = newStage()
      override val ID2: Stage = newStage()
      override val ID3: Stage = newStage()
      override val RENAME: Stage = newStage()
      override val DISPATCH: Stage = newStage()

      plugins ++= List(
        new DecoderArray(config, fetchPipeline.service(classOf[FetchBufferPlugin]).popPorts),
        new RenamePlugin(config)
      ).filter(_ != null)
    }
  }
  decodePipeline.groupCd = cd(2)
  addPipeline(decodePipeline)

  // val memPipeline: MemPipeline = null

  // ! INT Pipeline
  var exePipelines = Vector[ExecutePipeline]()
  for (i <- (0 until config.intIssue.issueWidth).reverse) {
    val exePipeline = inCd(3) {
      new ExecutePipeline {
        override val ISS: Stage = newStage().setName(s"INT${i}_ISS")
        override val RRD: Stage = newStage().setName(s"INT${i}_RRD")
        override val EXE: Stage = newStage().setName(s"INT${i}_EXE")
        override val WB: Stage = newStage().setName(s"INT${i}_WB")
        plugins += new IntExecutePlugin(config, i)
      }
    }
    exePipeline.groupCd = cd(3)
    exePipelines = exePipelines :+ exePipeline
    addPipeline(exePipeline)
  }

  // ! Mul / Div Pipeline
  val mulDivPipeline = inCd(4) {
    new ExecutePipeline {
      override val ISS = newStage().setName("MULDIV_ISS")
      override val RRD = newStage().setName("MULDIV_RRD")
      override val EXE = newStage().setName("MULDIV_EXE")
      override val WB = newStage().setName("MULDIV_WB")
      plugins += new MulDivExecutePlugin(config)
    }
  }
  mulDivPipeline.groupCd = cd(4)
  addPipeline(mulDivPipeline)

  // ! Mem Pipeline
  val aguPlugin = grp(5)(new AddressGenerationPlugin(config))
  val dcachePlugin = grp(5)(new DCachePlugin(config))
  val uncachedPlugin = grp(5)(new UncachedAccessPlugin(config))
  val memPipeline = inCd(6) {
    new MemPipeline {
      override val signals = new MemSignals(config)
      override val ISS: Stage = newStage().setName("MEM_ISS")
      override val RRD: Stage = newStage().setName("MEM_RRD")
      override val MEMADDR: Stage = newStage().setName("MEM_ADDR")
      override val MEMTLB: Stage = newStage().setName("MEM_MEMTLB") // stage3-⑥
      override val MEM1: Stage = newStage().setName("MEM_MEM1")
      override val MEM2: Stage = newStage().setName("MEM_MEM2")
      override val WB: Stage = newStage().setName("MEM_WB")
      override val WB2: Stage = newStage().setName("MEM_WB2")

      plugins ++= List(
        aguPlugin,
        dcachePlugin,
        uncachedPlugin,
        new LoadPostprocessPlugin(),
        new StoreBufferPlugin(config),
        new MemExecutePlugin(config),
        new ExceptionMuxPlugin[MemPipeline](stages.size - 1)
      ).filter(_ != null)
    }
  }
  memPipeline.groupCd = cd(6)
  addPipeline(memPipeline)

  // ! IO
  val io = new Bundle {
    val intrpt = in(Bits(8 bits)) default 0
    val debug = config.debug generate out(new DebugInterface())
    val iBus = master(fetchPipeline.service(classOf[ICachePlugin]).iBus.toAxi4())
    val dBus = master(memPipeline.service(classOf[DCachePlugin]).dBus)
    val udBus = master(memPipeline.service(classOf[UncachedAccessPlugin]).udBus)
  }

  io.debug.wb.pc := 0
  io.debug.wb.inst := 0
  io.debug.wb.rf.wen := 0
  io.debug.wb.rf.wnum := 0
  io.debug.wb.rf.wdata := 0

  // ! Global Plugins
  type T = MyCPUCore
  plugins ++= List(
    grp(8)(new PhysRegFilePlugin(config.regFile)),
    grp(7)(new ROBFIFOPlugin(config)),
    grp(7)(new CommitPlugin(config)),
    grp(7)(new BypassNetworkPlugin(config.regFile)),
    // [stage3-①②] 唤醒总线聚合(双总线,档 A;组 3 与 INT 管同组)
    grp(3)(new WakeupBusPlugin(config)),
    // Reservation stations
    grp(3)(new IntIssueQueuePlugin(config)),
    grp(4)(new MulDivIssueQueuePlugin(config)),
    grp(6)(new MemIssueQueuePlugin(config)),
    // Memory Speculative Wakeup
    grp(7)(new SpeculativeWakeupHandler()),
    // Privilege
    grp(9)(new Timer64Plugin()),
    grp(9)(new ExceptionHandlerPlugin()),
    grp(9)(new InterruptHandlerPlugin(config)),
    grp(9)(new CSRPlugin()),
    grp(10)(new MMUPlugin(config)),
    grp(9)(new WaitHandlerPlugin())
  ).filter(_ != null)

  // ! Stages
  val IF1: Stage = fetchPipeline.IF1
  val IF2: Stage = fetchPipeline.IF2
  val ID: Stage = decodePipeline.ID
  val RENAME: Stage = decodePipeline.RENAME
  val DISPATCH: Stage = decodePipeline.DISPATCH
  val EXE: Stage = null
  val MEM1: Stage = memPipeline.MEM1
  val MEM2: Stage = memPipeline.MEM2
  val WB: Stage = null

}
