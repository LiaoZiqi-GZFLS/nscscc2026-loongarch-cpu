package NOP.pipeline.exe

import spinal.core._
import spinal.lib._

import NOP._
import NOP.builder._
import NOP.utils._
import NOP.pipeline._
import NOP.pipeline.core._
import NOP.constants.enum._

/** 鏁存暟issue queue锛屼笉鍖呮嫭涔橀櫎娉曘€傞噰鐢ㄥ帇缂╂柟娉曘€?
  */
class IntIssueQueuePlugin(config: MyCPUConfig)
    extends CompressedQueue(
      config.intIssue,
      config.decode.decodeWidth,
      HardType(IntIssueSlot(config))
    ) {
  private val issConfig = config.intIssue
  val rPorts = config.regFile.rPortsEachInst
  val busyAddrs = Vec(UInt(config.regFile.prfAddrWidth bits), decodeWidth * rPorts)
  def fuMatch(uop: MicroOp): Bool = {
    uop.fuType === FUType.ALU || uop.fuType === FUType.CMP ||
    uop.fuType === FUType.CSR || uop.fuType === FUType.TIMER || uop.fuType === FUType.INVTLB
  }

  // decode index
  object PUSH_INDEXES extends Stageable(Vec(Flow(UInt(log2Up(decodeWidth) bits)), decodeWidth))

  override def build(pipeline: MyCPUCore): Unit = {
    // 位面寄存器必须先于执行插件 ISS 区创建(依赖序保证本插件先 build)
    createReadyBank(rPorts)
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
        // 鍦╮ename闃舵璁＄畻浜掕仈
        pushIndexes(i).setIdle()
        if (i > 0) {
          val pushIdx = CountOne(enqueueMask.take(i)) // 1, 2, 2, 3, 3, 3 for i = 0, 1, 2, 3, 4, 5
          for (j <- 0 to i) when(pushIdx === j && enqueueMask(i))(pushIndexes(j).push(i)) // pushIndexes[pushIdx] = i
        } else {
          when(enqueueMask(i))(pushIndexes(0).push(i))
        }
      }
    }

    // DISPATCH
    pipeline.DISPATCH plug new Area {
      genIssueSelect()
      import pipeline.DISPATCH._
      // round-14(读进胞元):派发侧 6 口 PRF 初值读
      val PRF = pipeline.service(classOf[PhysRegFilePlugin])
      // 鍞ら啋閫昏緫锛?
      // 1. 鍏ラ槦鍞ら啋锛坉ispatch鍏ュ彛璇籦usy锛?
      // 2. 杩滅▼鍞ら啋锛堢洃鍚啓busy骞挎挱锛?
      // 3. 鏈湴鍞ら啋锛堢洃鍚瑂elect缁撴灉锛?
      // 鍏ラ槦
      val decPacket = input(pipeline.decodePipeline.signals.DECODE_PACKET)
      val renameRecs = input(pipeline.decodePipeline.signals.RENAME_RECORDS)
      val robIdxs = input(pipeline.decodePipeline.signals.ROB_INDEXES)
      val pushIndexes = input(PUSH_INDEXES)
      val pushPorts = Vec(slotType, decodeWidth)
      for (i <- 0 until decodeWidth) {
        // slot澶勭悊
        val valid = decPacket(i).valid
        val uop = decPacket(i).payload
        val rename = renameRecs(i)
        val slot = pushPorts(i)
        slot.uop.assignSomeByName(uop)

        for (j <- 0 until rPorts) {
          slot.rRegs(j).payload := rename.rRegs(j)
          busyAddrs(i * rPorts + j) := rename.rRegs(j)
          // round-14(读进胞元):派发时读 PRF 存 rData 初值——生产者在派发
          // 前已写回时初值即真值(位面已置位,唤醒不再捕);否则为旧值,
          // 由唤醒数据总线在唤醒拍修正。
          slot.rData(j) := PRF.readPort(busyAddrs(i * rPorts + j)).asUInt
        }
        // 鍏ラ槦鍞ら啋锛坉ispatch鍏ュ彛璇籦usy锛?
        slot.rRegs(0).valid := !uop.useRj || !busyRsps(i * rPorts)
        slot.rRegs(1).valid := !(uop.useRk || uop.useRd) || !busyRsps(i * rPorts + 1)
        slot.wReg := rename.wReg
        slot.robIdx := robIdxs(i)

        // port浜掕仈锛屼笌rename鐩镐技
        val idx = pushIndexes(i)
        val port = queueIO.pushPorts(i)
        // round-12(EXE 提前重定向):squash 拍抑制入队(与 ROB push 同门控,
        // 防旧流残留进入 IQ 后 WB 写坏新流 ROB 项)
        val robFIFO = pipeline.globalService(classOf[ROBFIFOPlugin])
        port.valid := arbitration.isValidNotStuck && idx.valid && !robFIFO.earlyRedirect.valid
        port.payload := pushPorts(idx.payload)
        arbitration.haltItself setWhen (arbitration.isValid && idx.valid && !port.ready)
      }

      // flush鏈€楂樹紭鍏堢骇
      val flush = pipeline.globalService(classOf[CommitFlush]).regFlush
      queueFlush setWhen flush
    }

    Component.current.afterElaboration {
      // round-14(读进胞元双总线):数据总线捕获——广播 tag 的 PRF 读(WB 已把
      // 数据写入 PRF,同拍读出即真值);唤醒拍捕获,门控位面未置位:只有
      // "本拍才被唤醒"的槽才捕,标签复用的假匹配不会覆写已就绪槽。
      // 捕获与位面置位同拍(边沿),发射拍两者同时可见,依赖链 4 拍不变。
      // round-15 修复(生成顺序宪法):捕获块必须生成在最前——elaboration 顺序
      // = 最后写入者优先,而"入队 push / 压缩搬移"的整槽写必须覆盖捕获的
      // 部分 rData 写:若捕获在后,当"旧槽 i 未就绪且本拍收到其 tag 广播"
      // 与"就绪槽搬入位置 i"同拍碰撞时,搬入槽的 rData 被旧槽捕获值污染
      // (uop 是新槽、数据是旧槽),错误值进 PRF 后对拍探针无法发现。
      // 捕获在前 → 整槽写(后生成)覆盖部分写;捕获值经 queueNext 镜像
      // 跟随旧内容搬走——与团队 wakeup 双写宪法严格一致。
      val prf = pipeline.globalService(classOf[PhysRegFilePlugin])
      val dbcast = prf.clearBusys.map(p => {
        val b = Flow(p.payload)
        b.valid := RegNext(p.valid)
        b.payload := RegNext(p.payload)
        b
      })
      for (i <- 0 until issConfig.depth; j <- 0 until rPorts; k <- dbcast.indices) {
        when(dbcast(k).valid &&
          dbcast(k).payload === queue(i).payload.rRegs(j).payload &&
          !rReadyBank(i)(j)) {
          // 双写:payload 与 queueNext 都要写——压缩搬移取 queueNext 的组合值,
          // 单写 payload 会在"捕获拍与压缩同拍"时丢数据(与位面 next 面同理)。
          queue(i).payload.rData(j) := prf.readPort(dbcast(k).payload).asUInt
          queueNext(i).payload.rData(j) := prf.readPort(dbcast(k).payload).asUInt
        }
      }
      // 必须在 afterElaboration 创建位面/广播:此时所有执行插件均已注册
      // clearBusy 端口,广播列表完整(否则依赖未注册端口的消费者永远收不到
      // 唤醒而整机死锁)。
      genGlobalWakeup(pipeline.globalService(classOf[PhysRegFilePlugin]), rPorts)
      genEnqueueLogic()
      genCompressLogic()
      genFlushLogic()
      genEarlyKill()
    }
  }
}
