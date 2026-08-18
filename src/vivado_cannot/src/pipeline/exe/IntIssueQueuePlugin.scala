package NOP.pipeline.exe

import spinal.core._
import spinal.lib._

import NOP._
import NOP.builder._
import NOP.utils._
import NOP.pipeline._
import NOP.pipeline.core._
import NOP.constants.enum._

/** 整数issue queue，不包括乘除法。采用压缩方法。
  */
class IntIssueQueuePlugin(config: MyCPUConfig)
    extends CompressedQueue(
      config.intIssue,
      config.decode.decodeWidth,
      HardType(IntIssueSlot(config)),
      config.regFile.prfAddrWidth
    ) {
  private val issConfig = config.intIssue
  val rPorts = config.regFile.rPortsEachInst
  val busyAddrs = Vec(UInt(config.regFile.prfAddrWidth bits), decodeWidth * rPorts)

  /** [stage2-④] 胞元逻辑区:选择/压缩/flush/唤醒/装载从 DISPATCH area 移入
    * 此类级 Area(随阶段 1 的 plugin.clockDomain 组域);DISPATCH 拍只剩入队
    * 装配与 push 互联,不再承载选择/唤醒逻辑。 */
  val cellArea = new Area {}

  /** [stage2-③] 胞元链 ctlHazard 前缀(③.4 iqPrefix):prefixUnsafe(i)=
    * cell(i) 前方(更老侧)存在 branch/CSR/TLB 控制冒险。组合链,逐槽 1 LUT 本地传递;
    * IntExecutePlugin(FU0) 在分支授权拍采样 !prefixUnsafe(授权槽)。 */
  val ctlHazardPerCell = Vec(Bool(), issConfig.depth)
  val prefixUnsafe = Vec(Bool(), issConfig.depth)

  def fuMatch(uop: MicroOp): Bool = {
    uop.fuType === FUType.ALU || uop.fuType === FUType.CMP ||
    uop.fuType === FUType.CSR || uop.fuType === FUType.TIMER || uop.fuType === FUType.INVTLB
  }

  // decode index
  object PUSH_INDEXES extends Stageable(Vec(Flow(UInt(log2Up(decodeWidth) bits)), decodeWidth))

  override def build(pipeline: MyCPUCore): Unit = {
    // RENAME
    pipeline.RENAME plug new Area {
      import pipeline.RENAME._
      val decPacket = input(pipeline.decodePipeline.signals.DECODE_PACKET)
      val enqueueMask = Bits(decodeWidth bits)
      val pushIndexes = insert(PUSH_INDEXES)
      for (i <- 0 until decodeWidth) {
        val valid = decPacket(i).valid
        val uop = decPacket(i).payload
        enqueueMask(i) := valid && fuMatch(uop) && !uop.except.valid // say, 110100
        // 在rename阶段计算互联
        pushIndexes(i).setIdle()
        if (i > 0) {
          val pushIdx = CountOne(enqueueMask.take(i)) // 1, 2, 2, 3, 3, 3 for i = 0, 1, 2, 3, 4, 5
          for (j <- 0 to i) when(pushIdx === j && enqueueMask(i))(pushIndexes(j).push(i)) // pushIndexes[pushIdx] = i
        } else {
          when(enqueueMask(i))(pushIndexes(0).push(i))
        }
      }
    }

    // [stage2-①④] 选择/唤醒/压缩/装载挂 cellArea(组域);tag 口挂接:
    // 5 口 PRF clearBusys(全局) + 每 INT FU 一口 localTag(本地,§3.6 豁免)
    pipeline.service(classOf[PhysRegFilePlugin]).clearBusys.foreach(addGlobalTagPort)
    val cellArea = new Area { // 选择区(组域,comb)
      genIssueSelect() // 维持 OHMasking 树选版(设计书 ①.2)
    }
    Component.current.afterElaboration {
      val cellAreaTail = new Area { // 压缩/flush/唤醒/装载区(组域,comb 装配)
        genEnqueueLogic()
        genCompressLogic()
        genFlushLogic()
        genCellWakeup(rPorts)
        genCellRegister()
      }
    }

    // [stage2-③] 胞元链 prefix 链(组域,comb;cell(0)=最老)
    val prefixArea = new Area {
      for (i <- 0 until issConfig.depth) {
        ctlHazardPerCell(i) := queue(i).valid &&
          (queue(i).uop.branchLike || queue(i).uop.writeCSR || queue(i).uop.operateTLB)
        prefixUnsafe(i) := (if (i == 0) False else prefixUnsafe(i - 1) || ctlHazardPerCell(i - 1))
      }
    }

    // DISPATCH
    pipeline.DISPATCH plug new Area {
      import pipeline.DISPATCH._
      // 入队唤醒(dispatch入口读busy):[stage2-①] busy 旁路已删,busyRsps
      // 为裸 busys FF 直读;入队当拍 busy=1 的竞态由胞元 post-mux 唤醒 OR
      // 覆盖(设计书 ①.4 R1 完备性证明),本处代码不变。
      val decPacket = input(pipeline.decodePipeline.signals.DECODE_PACKET)
      val renameRecs = input(pipeline.decodePipeline.signals.RENAME_RECORDS)
      val robIdxs = input(pipeline.decodePipeline.signals.ROB_INDEXES)
      val pushIndexes = input(PUSH_INDEXES)
      val pushPorts = Vec(slotType, decodeWidth)
      for (i <- 0 until decodeWidth) {
        // slot处理
        val valid = decPacket(i).valid
        val uop = decPacket(i).payload
        val rename = renameRecs(i)
        val slot = pushPorts(i)
        slot.uop.assignSomeByName(uop)

        for (j <- 0 until rPorts) {
          slot.rRegs(j).payload := rename.rRegs(j)
          busyAddrs(i * rPorts + j) := rename.rRegs(j)
        }
        // 入队唤醒（dispatch入口读busy）
        slot.rRegs(0).valid := !uop.useRj || !busyRsps(i * rPorts)
        slot.rRegs(1).valid := !(uop.useRk || uop.useRd) || !busyRsps(i * rPorts + 1)
        slot.wReg := rename.wReg
        slot.robIdx := robIdxs(i)

        // port互联，与rename相似
        val idx = pushIndexes(i)
        val port = queueIO.pushPorts(i)
        port.valid := arbitration.isValidNotStuck && idx.valid
        port.payload := pushPorts(idx.payload)
        arbitration.haltItself setWhen (arbitration.isValid && idx.valid && !port.ready)
      }

      // flush最高优先级
      val flush = pipeline.globalService(classOf[CommitFlush]).regFlush
      queueFlush setWhen flush

      // stage2-③ R9-1: holdDispatch 期间冻结入队(wrong-path 槽由 regFlush 统一清除,③.3-4)
      arbitration.haltItself setWhen pipeline.globalService(classOf[CommitFlush]).holdDispatch
    }
  }
}
