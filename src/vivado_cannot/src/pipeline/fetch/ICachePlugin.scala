package NOP.pipeline.fetch

import NOP.blackbox.mem._
import NOP.pipeline._
import NOP.builder._
import NOP.utils._
import NOP._
import NOP.constants.`enum`.{CacheOpType, CacheSelType}
import NOP.pipeline.core.{CommitPlugin, ExceptionMuxPlugin}
import spinal.core._
import spinal.lib._
import spinal.lib.bus.amba4.axi._
import spinal.lib.fsm._

final case class CacheLineInfo(config: CacheBasicConfig, useDirty: Boolean = false) extends Bundle {
  val lru = Bits(log2Up(config.ways) bits)
  val tags = Vec(UInt(config.tagRange.size bits), config.ways)
  val dirtyBits = useDirty generate Bits(config.ways bits)
}

final case class CacheOperation() extends Bundle {
  val addr = UWord()
  val sel = CacheSelType()
  val op = CacheOpType()
}

class ICachePlugin(config: MyCPUConfig) extends Plugin[FetchPipeline] {
  private val frontend = config.frontend
  private val icache = config.frontend.icache

  // * Cache Valid/DATA/CacheLineInfo area
  // valid鏈夊崟index娓呯┖鐨勫彲鑳斤紝澶氬啓鍙?
  val valids = Vec(Vec(RegInit(False), icache.ways), icache.sets) // valids[sets][ways]
  val dataRAMs =
    Seq.fill(icache.ways)(
      new SDPRAM(Vec(BWord(), icache.lineWords), icache.sets, false, useByteEnable = true)
    ) // dataRAMs[ways][sets]
  val infoRAM = new SDPRAM(CacheLineInfo(icache), icache.sets, false) // CacheLineInfo[sets]

  // * Cache spans from IF1 to IF2. The following signals are stageable.
  private object ICACHE_VALIDS extends Stageable(valids.dataType()) // Bool[sets][ways]
  // BWord[ways][fetchWidth]
  private object ICACHE_RSPS extends Stageable(Vec(Vec(BWord(), frontend.fetchWidth), icache.ways))
  private object ICACHE_INFO extends Stageable(CacheLineInfo(icache)) // CacheLineInfo

  // * Cache Interface
  // iBus鏈韩涓€瀹氭槸read only锛屼絾瀵瑰鍙互杞珹xi4
  val iBus = Axi4ReadOnly(config.axiConfig).setIdle()

  override def build(pipeline: FetchPipeline): Unit = pipeline plug new Area {
    // * Plugin Area into FetchPipeline
    import pipeline._
    // I-cache閲嶅彇(round-7:瑙﹀彂鏉′欢鏀逛负绾?FSM 鐘舵€?瑙?finish 鎬佹敞閲?
    val doRefetch = False
    // IF1涓烘皵娉＄殑鏃跺€欒烦杩噐efetch锛岀渷涓€涓懆鏈?
    val refetchValid = pipeline.IF1.arbitration.isValid && doRefetch
    // 璇籺ag鎸夌収index鎵捐
    val nextPC = pipeline.service(classOf[ProgramCounterPlugin]).nextPC
    val rValid = !pipeline.IF1.arbitration.isStuck || refetchValid
    // If refetch, read from PC, else read from nextPC

    // Set infoRAM readPort
    val rAddr = Mux(refetchValid, pipeline.IF1.input(pipeline.signals.PC), nextPC)
    val rPort = infoRAM.io.read
    rPort.cmd.valid := rValid
    rPort.cmd.payload := rAddr(icache.indexRange)

    // Set dataRAM readPort
    val dataRs = Vec(dataRAMs.map(_.io.read))
    dataRs.foreach { p =>
      p.cmd.valid := rValid
      p.cmd.payload := rAddr(icache.indexRange)
    }

    // * Plugin Area into IF1
    IF1 plug new Area {
      import IF1._
      arbitration.haltItself setWhen refetchValid
      val pc = input(pipeline.signals.PC)
      // 璇籿alid涔熸彃杩涙祦姘寸嚎(P7:64:1 鏍戝舰璇?3 绾?
      insert(ICACHE_VALIDS) := TreeRead(valids.map(_.asBits).toIndexedSeq, pc(icache.indexRange)).asBools
      for (i <- 0 until icache.ways) {
        for (j <- 0 until frontend.fetchWidth) {
          // ICACHE_RSPS: BWord[ways][fetchWidth]; dataRAMs[ways][sets]
          insert(ICACHE_RSPS)(i)(j) := dataRAMs(i).io.read.rsp(pc(icache.wordOffsetRange) + j)
        }
      }
      insert(ICACHE_INFO) := rPort.rsp
    }

    // * Plugin Area into IF3
    // 涓夌骇娴佹按:IF1 鍙?RAM 璇?TLB stage1,IF2 瑙ｆ瀽鍑?physPC,IF3 鍋?
    // VIPT 鍛戒腑妫€鏌?refill/缁勫寘銆侾C/PC_PHYSICAL/ICACHE_* 缁忕骇闂村瘎瀛樺櫒娴佸姩銆?
    IF3 plug new Area {
      import IF3._

      val fetchExcHandler = pipeline.service(classOf[ExceptionMuxPlugin[FetchPipeline]])
      val reqValid = arbitration.isValidOnEntry && !output(fetchExcHandler.ExceptionSignals.EXCEPTION_OCCURRED)
      val reqCommit = reqValid && !arbitration.isStuck
      val virtPC = input(pipeline.signals.PC)
      val physPC = input(pipeline.signals.PC_PHYSICAL)
      // PC鍦╟ache line涓殑浣嶇疆锛岀敤浜庤绠梖etch word鏄惁鏈夋晥
      val pcWordOffset = virtPC(icache.wordOffsetRange)

      // Virtual Index, Physical Tag
      val idx = virtPC(icache.indexRange)
      val tag = physPC(icache.tagRange) // physical tag
      val setValids = input(ICACHE_VALIDS)

      // ! Prepare writePorts for replacing
      val wPort = infoRAM.io.write.setIdle()
      val dataWs = Vec(dataRAMs.map(_.io.write.setIdle()))
      val dataMasks = Vec(dataRAMs.map(_.io.writeMask.clearAll().subdivideIn(4 bits, true)))

      // cache鏌ヨ
      val hits = setValids.zip(input(ICACHE_INFO).tags).map { case (valid, t) =>
        valid && t === tag
      }
      val hit = hits.orR
      val hitData = MuxOH(hits, input(ICACHE_RSPS))

      // 瀛樺偍褰撳墠琚～鍏呯殑packet锛岄伩鍏岻F2閲嶅彇
      val storedPacket = Vec(RegInit(B(0, 32 bits)), frontend.fetchWidth) // round-14:X-sweep

      when(reqCommit && hit) {
        // 鍛戒腑锛屾彁浜RU淇敼
        assert(icache.ways == 2)
        val newInfo = input(ICACHE_INFO).copy()
        newInfo.tags := input(ICACHE_INFO).tags
        // Hit 0, then set 1, means replace way 1 if miss next time
        newInfo.lru(0) := hits(0)
        wPort.valid.set()
        wPort.payload.address := idx
        wPort.payload.data := newInfo
      }

      // 瑙ｅ喅cache miss
      val cacheRefillFSM = new StateMachine {
        val waitAXI = new State
        val readMem = new State
        val commit = new State
        val finish = new State

        disableAutoStart()
        setEntry(stateBoot)

        val rspId = Counter(icache.lineWords)

        // 鍙嶆瀵勫瓨涔熶笉澧炲姞鍛ㄦ湡锛岃繕鏀瑰杽鏃跺簭
        val refillValid = RegNext(iBus.r.fire, init = False) // round-14:X-sweep
        val refillWord = RegNext(iBus.r.payload.data, init = B(0, 32 bits)) // round-14:X-sweep
        // 鏍规嵁LRU閫夋嫨涓€璺?
        val replaceWay = input(ICACHE_INFO).lru.asUInt
        // 濉厖stored packet
        for (i <- 0 until frontend.fetchWidth) {
          when(refillValid && rspId === pcWordOffset + i) {
            storedPacket(i) := refillWord
          }
        }

        stateBoot.whenIsActive {
          when(reqValid && !hit) {
            arbitration.haltItself.set()
            goto(waitAXI)
          }
        }

        waitAXI.whenIsActive {
          arbitration.haltItself.set()
          val ar = iBus.ar
          ar.payload.id := 0
          // 鎶瑰幓offset
          ar.payload.addr := physPC(31 downto icache.offsetWidth) @@ U(0, icache.offsetWidth bits)
          ar.payload.len := icache.lineWords - 1 // burst len
          ar.payload.size := 2 // burst size = 4Bytes = 32 bits
          ar.payload.burst := 1 // burst type = INCR
          ar.payload.lock := 0 // normal access
          ar.payload.cache := 0 // device non-bufferable
          if (config.axiConfig.useQos) ar.payload.qos := 0 // no QoS scheme
          ar.payload.prot := 0 // secure and normal(non-priviledged)
          ar.valid := True
          when(ar.ready) {
            rspId.clear()
            goto(readMem)
          }
        }

        readMem.whenIsActive {
          arbitration.haltItself.set()
          val r = iBus.r
          r.ready.set()
          when(refillValid) {
            dataWs(replaceWay).valid := True
            dataWs(replaceWay).payload.address := idx
            dataWs(replaceWay).payload.data.foreach(_ := refillWord)
            dataMasks(replaceWay)(rspId).setAll()
            rspId.increment()
          }
          when(r.valid && r.payload.last)(goto(commit))
        }

        commit.whenIsActive {
          arbitration.haltItself.set()
          // 瀵筪ata鍐欏叆鏈€鍚庝竴涓獁ord
          dataWs(replaceWay).valid := True
          dataWs(replaceWay).payload.address := idx
          dataWs(replaceWay).payload.data.foreach(_ := refillWord)
          dataMasks(replaceWay)(rspId).setAll()
          // 鏇存柊info
          assert(icache.ways == 2)
          val newInfo = input(ICACHE_INFO).copy()
          // 鍏跺畠璺痶ag淇濇寔
          newInfo.tags := input(ICACHE_INFO).tags
          // 閫夋嫨鐨勪竴璺啓鍏ユ柊tag
          newInfo.tags(replaceWay) := tag
          // 鏇存柊LRU
          newInfo.lru := ~input(ICACHE_INFO).lru
          // 璁剧疆valid
          valids(idx)(replaceWay).set()
          // 鍐欏叆Mem
          wPort.valid.set()
          wPort.payload.address := idx
          wPort.payload.data := newInfo
          goto(finish)
        }

        finish.whenIsActive {
          // 閬垮厤IF1涓寚浠ゅ彇涓嶅埌鏂板啓鐨刢ache锛岄噸鍙?
          // 姣忎竴鏉￠兘浠巗tate boot寮€濮?
          // round-7:doRefetch 鐢?FSM 鐘舵€佺洿鎺ラ┍鍔?瀵勫瓨鏉′欢),涓嶅啀
          // 渚濊禆 !IF1.arbitration.isFlushed(round-4 top1 鐨勮法妯″潡
          // 缁勫悎閾?commit except鈫抮egFlush鈫抜sFlushed鈫抮efetch鈫扞F1
          // stall,84% 甯冪嚎)銆俧inish 鏈熼棿鎸佺画鐢?PC 閲嶈鍚屼竴琛?
          // flush 閲嶅畾鍚戜細瑕嗙洊,澶氳鍚屽湴鍧€鏃犲銆?
          doRefetch := True
          when(!arbitration.isStuck) {
            goto(stateBoot)
          }
        }
      }

      val fetchPacket = insert(pipeline.signals.FETCH_PACKET)
      fetchPacket.pc := virtPC
      fetchPacket.except.valid := output(fetchExcHandler.ExceptionSignals.EXCEPTION_OCCURRED)
      fetchPacket.except.payload.code := output(fetchExcHandler.ExceptionSignals.EXCEPTION_ECODE)
      fetchPacket.except.payload.subcode := output(fetchExcHandler.ExceptionSignals.EXCEPTION_ESUBCODE)
      fetchPacket.except.payload.isTLBRefill := output(pipeline.signals.IS_TLB_REFILL)

      for (i <- 0 until frontend.fetchWidth) {
        val fetchWord = fetchPacket.insts(i)
        // e.g. 32B = 8W, 6鐨勬椂鍊欎粎0(6), 1(7)鏈夋晥
        if (i == 0) fetchWord.valid := True
        else fetchWord.valid := pcWordOffset < icache.lineWords - i
        fetchWord.payload := Mux(hit, hitData(i), storedPacket(i))
      }
    }

    // 瑙ｅ喅搴旇娓呯┖cache鐨勬潯浠讹紙鍙渶瑕佽缃畍alid锛?
    val commit = new Area {
      val cacheCommit = pipeline.globalService(classOf[CommitPlugin])
      val operation = cacheCommit.cacheOp

      val cacheOp = operation.op
      val addr = operation.addr
      val targetICache = cacheCommit.cacheOp.payload.sel === CacheSelType.ICache

      val way = addr(0, log2Up(icache.ways) bits)
      val index = addr(icache.indexRange)

      when(operation.valid && targetICache) {
        switch(cacheOp) {
          is(CacheOpType.None) {
            // do nothing
          }
          is(CacheOpType.IndexInvalidate) {
            valids(index)(way) := False
          }
          is(CacheOpType.HitInvalidate) {
            // lazy implementation invalidates all ways (VIPT)
            valids(index).foreach(_ := False)
          }
          is(CacheOpType.StoreTag) {
            for (i <- 0 until icache.sets) {
              for (j <- 0 until icache.ways) {
                valids(i)(j) := False
              }
            }
          }
        }
      }
    }
  }
}
