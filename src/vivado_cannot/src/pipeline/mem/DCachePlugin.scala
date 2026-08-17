package NOP.pipeline.mem

import spinal.core._
import spinal.lib._
import spinal.lib.fsm._
import spinal.lib.bus.amba4.axi.Axi4

import NOP._
import NOP.blackbox.mem._
import NOP.builder._
import NOP.utils._
import NOP.pipeline._
import NOP.pipeline.fetch._
import NOP.pipeline.core._
import NOP.constants.enum._

class DCachePlugin(config: MyCPUConfig) extends Plugin[MemPipeline] {
  private val dcache = config.dcache
  private val prfAddrWidth = config.regFile.prfAddrWidth

  val dBus = Axi4(config.axiConfig).setIdle() // DCache鐨凙XI鎬荤嚎
  dBus.b.ready.allowOverride := True

  // valid鏈夊崟index娓呯┖鐨勫彲鑳斤紝澶氬啓鍙?
  val valids = Vec(Vec(RegInit(False), dcache.ways), dcache.sets)
  val dirtyBitsManager = new DirtyBitsManager(config.dcache)
  // 铏界劧d-cache褰㈠紡涓婄粍缁囨垚渚嬪32B涓€琛岋紝浣嗘槸瀹為檯姣忔璇诲啓閮藉彧闇€瑕佷竴涓獁ord锛屽洜姝ょ墿鐞嗕笂杩欎箞缁勭粐鏈€鐪侀潰绉拰寤惰繜
  val dataRAMs = Seq.fill(dcache.ways)(
    new SDPRAM(BWord(), dcache.lineWords * dcache.sets, true, useByteEnable = true)
  )
  val infoRAM = new SDPRAM(CacheLineInfo(dcache), dcache.sets, false)

  private object DCACHE_VALIDS extends Stageable(valids.dataType())
  private object DCACHE_DIRTY extends Stageable(dirtyBitsManager.dirtyBits.dataType())
  private object DCACHE_INFO extends Stageable(CacheLineInfo(dcache))
  private object TAG_MATCHES extends Stageable(Bits(dcache.ways bits))

  val writebackIdle = False

  override def build(pipeline: MemPipeline): Unit = pipeline plug new Area {
    import pipeline.signals._
    val rPort = infoRAM.io.read
    val dataRs = Vec(dataRAMs.map(_.io.read))
    // 涓轰簡閬垮厤MEM1鍙栦笉鍒癕EM2鍐欑殑cache锛屽仛refetch閲嶅彇
    val doRefetch = False
    val refetchValid = doRefetch
    val wordAddrRange = dcache.indexRange.high downto 2
    val mem1MemAddr = UWord()

    pipeline.MEMADDR plug new Area {
      import pipeline.MEMADDR._
      val std = input(STD_SLOT)
      val memAddr = Mux(std.valid, std.addr, output(MEMORY_ADDRESS))
      val rValid = arbitration.notStuck || refetchValid
      val rAddr = Mux(refetchValid, mem1MemAddr, memAddr)
      // 璇籺ag鎸夌収index鎵捐
      rPort.cmd.valid := rValid
      rPort.cmd.payload := rAddr(dcache.indexRange)
      // 璇籨ata搴斿綋鐩存帴鎵緒ord
      dataRs.foreach { p =>
        p.cmd.valid := rValid
        p.cmd.payload := rAddr(wordAddrRange)
      }
    }

    pipeline.MEM1 plug new Area {
      import pipeline.MEM1._
      arbitration.haltItself setWhen refetchValid
      val std = input(STD_SLOT)
      val memAddr = Mux(std.valid, std.addr, input(MEMORY_ADDRESS))
      mem1MemAddr := memAddr
      // 璇籿alid涔熸彃杩涙祦姘寸嚎(P7:64:1 鏍戝舰璇?3 绾?
      insert(DCACHE_VALIDS) := TreeRead(valids.map(_.asBits).toIndexedSeq, memAddr(dcache.indexRange)).asBools
      dirtyBitsManager.io.readCmd := memAddr(dcache.indexRange)
      insert(DCACHE_DIRTY) := dirtyBitsManager.io.readRsp
      insert(DCACHE_INFO) := rPort.rsp
      val cachePhysAddr = Mux(std.valid, std.addr, input(MEMORY_ADDRESS_PHYSICAL))
      for (i <- 0 until dcache.ways) {
        insert(TAG_MATCHES)(i) := input(DCACHE_INFO).tags(i) === cachePhysAddr(dcache.tagRange)
      }

      // 鎷唅ssue slot
      val issSlot = input(ISSUE_SLOT)
      insert(ROB_IDX) := issSlot.robIdx
      insert(IS_LOAD) := issSlot.uop.isLoad
      insert(IS_STORE) := issSlot.uop.isStore
      insert(WRITE_REG).valid := issSlot.uop.doRegWrite
      insert(WRITE_REG).payload := issSlot.wReg
      insert(LOAD_STORE_TYPE) := issSlot.uop.lsType
      for (i <- 0 until issSlot.rRegs.size) {
        insert(READ_REGS)(i) := issSlot.rRegs(i).payload
      }
    }

    pipeline.MEM2 plug new Area {
      import pipeline.MEM2._

      val EXC_SIGNALS = pipeline.service(classOf[ExceptionMuxPlugin[pipeline.type]]).ExceptionSignals

      val storeBuffer = pipeline.service(classOf[StoreBufferPlugin])
      val addrCached = input(ADDRESS_CACHED)
      // 娉ㄦ剰杩?鑰呭瓨鍦ㄥ悓鏃朵笉婊¤冻鐨勬儏鍐碉紝姝ゆ椂涓篶ache绫绘寚浠?
      // STD = store data
      val std = input(STD_SLOT)
      val isSTD = std.valid && std.isStore && std.isCached
      val isLoad = input(IS_LOAD)
      // STA = store address
      val isSTA = input(IS_STORE)
      val isCACHE = !input(IS_LOAD) && !input(IS_STORE)
      val noExcept = !input(EXC_SIGNALS.EXCEPTION_OCCURRED)

      // uncached
      val isLDU = std.valid && !std.isStore
      val isSTU = std.valid && std.isStore && !std.isCached

      // 濡傛灉load鍙戠幇uncached鎴栬€卐xception锛岄偅涔堣烦杩囨墍鏈塩ache澶勭悊
      val reqValid = (arbitration.isValidOnEntry && isLoad && addrCached && noExcept) || isSTD
      val reqCommit = reqValid && !arbitration.isStuck
      val virtAddr = input(MEMORY_ADDRESS)
      val physAddr = input(MEMORY_ADDRESS_PHYSICAL)
      val memWData = input(MEMORY_WRITE_DATA)
      val memBE = input(MEMORY_BE)
      val cachePhysAddr = Mux(std.valid, std.addr, input(MEMORY_ADDRESS_PHYSICAL))
      val idx = cachePhysAddr(dcache.indexRange)
      val tag = cachePhysAddr(dcache.tagRange) // physical tag
      val setValids = input(DCACHE_VALIDS)
      val wPort = infoRAM.io.write.setIdle()
      val dataWs = Vec(dataRAMs.map(_.io.write.setIdle()))
      val dataMasks = Vec(dataRAMs.map(_.io.writeMask.setAll()))

      // STA蹇界暐cache锛屼絾鏄棤寮傚父涓攃ached鏃惰鍦∕EM2鍐欏叆store buffer
      val storeBufferPush = storeBuffer.queueIO.pushPort
      val storeBufferPushValid =
        arbitration.isValid && noExcept && (isSTA || (isLoad && !addrCached))
      // 鎵╁睍鍚庡啓鍏tore buffer鐨勶細cached store, uncached load, uncached store
      storeBufferPush.valid := storeBufferPushValid && arbitration.notStuck
      storeBufferPush.addr := physAddr
      // store buffer姘歌繙鏀剧Щ濂戒綅鐨?
      storeBufferPush.data := input(MEMORY_WRITE_DATA)
      storeBufferPush.be := input(MEMORY_BE)
      storeBufferPush.retired := False
      storeBufferPush.isStore := isSTA
      storeBufferPush.isCached := addrCached
      storeBufferPush.wReg := input(WRITE_REG)
      storeBufferPush.lsType := input(LOAD_STORE_TYPE)
      storeBufferPush.robIdx := input(ROB_IDX)
      // store buffer涓嶅簲push涓嶈繘鍘伙紝鍚﹀垯memory娴佹按涔熸墽琛屼笉浜哠TD锛屽氨姝婚攣浜?
      arbitration.haltItself setWhen (storeBufferPushValid && !storeBufferPush.ready)

      // cache鏌ヨ
      val hits = for (i <- 0 until setValids.size) yield {
        setValids(i) && input(TAG_MATCHES)(i)
      }
      val hit = hits.orR
      val hitData = MuxOH(hits, dataRAMs.map(_.io.read.rsp))
      val hitWay = OHToUInt(Vec(hits).asBits) // multi-way safe one-hot decode
      val replaceWay = input(DCACHE_INFO).lru.asUInt

      // CACHE鎸囦护鐩稿叧淇℃伅
      val wayCACHE = CombInit(hitWay)
      val cacheOp = input(ISSUE_SLOT).uop.cacheOp
      val cacheSel = input(ISSUE_SLOT).uop.cacheSel

      // 瀛樺偍褰撳墠琚～鍏呯殑word锛岄伩鍏峂EM2閲嶅彇
      val storedWord = RegInit(B(0, 32 bits)) // round-14:X-sweep
      dirtyBitsManager.io.writeCmd.setIdle()

      when(reqCommit && hit) {
        // Round-Robin 鏇挎崲锛氬懡涓笉鏇存柊鏇挎崲淇℃伅
        when(isSTD) {
          // STD鎻愪氦鍐檆ache
          dataWs(hitWay).valid := True
          dataWs(hitWay).payload.address := std.addr(wordAddrRange)
          dataWs(hitWay).payload.data := std.data
          dataMasks(hitWay) := std.be
          dirtyBitsManager.io.writeCmd.valid := True
          dirtyBitsManager.io.writeCmd.idx := idx
          dirtyBitsManager.io.writeCmd.way := hitWay
          dirtyBitsManager.io.writeCmd.data := True
          // 骞朵笉闇€瑕侀噸鍙栵紝MEM1鑷劧杩樹細hit锛屾暟鎹彲浠ヤ粠store buffer鍓嶄紶鍑烘潵
          // doRefetch := True
        }
      }

      // 瑙﹀彂灏嗚剰鍧楀啓鍥炲唴瀛樼殑鐘舵€佹満
      val triggerWriteback = False
      // 鐢变簬淇Uncached瑙﹀彂Writeback
      val triggerWritebackFixUncache = False
      // 鐢变簬CACHE鎸囦护瑙﹀彂Writeback
      val triggerWritebackCACHE = False
      // 鍐欏洖鍧楀彇cache闇€瑕佹棭浜庤鍧楀啓cache
      val lockCache = False
      // 涓轰簡write dirty line锛屾彁鍓峟etch鍑烘潵
      val dirtyLine = Vec(RegInit(B(0, 32 bits)), dcache.lineWords) // round-14:X-sweep
      // 浠嶇劧鏄悓姝ュ啓锛屼絾鏄笌璇诲唴瀛樺苟琛屼簡
      val dirtyLineWritebackFSM = new StateMachine {
        disableAutoStart()
        setEntry(stateBoot)
        val fetchCache = new State
        val waitAW = new State
        val writeMem = new State
        val waitB = new State

        // val wayIdx = ~input(DCACHE_INFO).lru.asUInt
        val wayIdx = RegInit(U(0, log2Up(config.dcache.ways) bits)) // Change to register
        val rspId = Counter(dcache.lineWords)
        val rspIdDelayed = Delay(rspId.value, 2)

        stateBoot.whenIsActive {
          writebackIdle := True
          when(triggerWriteback || triggerWritebackFixUncache || triggerWritebackCACHE) {
            rspId.clear()
            goto(fetchCache)
            when(triggerWriteback) {
              wayIdx := replaceWay
            } elsewhen (triggerWritebackFixUncache) {
              wayIdx := hitWay
            } otherwise {
              // triggerWritebackCACHE
              wayIdx := wayCACHE
            }
          }
        }
        fetchCache.whenIsActive {
          arbitration.haltItself.set()
          lockCache := True
          rspId.increment()
          dataRs.foreach(_.cmd.push(idx @@ rspId))
          dirtyLine(rspIdDelayed) := Vec(dataRAMs.map(_.io.read.rsp))(wayIdx)
          when(rspIdDelayed === dcache.lineWords - 1) {
            goto(waitAW)
          }
        }
        // write-back dirty block
        waitAW.whenIsActive {
          arbitration.haltItself.set()
          val aw = dBus.aw
          aw.valid := True
          aw.payload.id := 1
          aw.payload.addr := input(DCACHE_INFO).tags(wayIdx) @@ idx @@ U(0, dcache.offsetWidth bits)
          aw.payload.len := dcache.lineWords - 1 // burst len
          aw.payload.size := 2
          aw.payload.burst := 1 // burst type = INCR
          aw.payload.lock := 0
          aw.payload.cache := 0
          if (config.axiConfig.useQos) aw.payload.qos := 0
          aw.payload.prot := 0
          when(aw.ready) {
            rspId.clear()
            goto(writeMem)
          }
        }
        writeMem.whenIsActive {
          arbitration.haltItself.set()
          val w = dBus.w
          w.valid := True
          w.data := dirtyLine(rspId)
          w.strb.setAll()
          w.last := rspId.willOverflowIfInc
          when(w.ready) {
            rspId.increment()
            when(w.last) {
              goto(waitB)
            }
          }
        }

        waitB.whenIsActive {
          arbitration.haltItself.set()
          val b = dBus.b
          when(b.valid) {
            goto(stateBoot)
          }
        }
      }

      // 澶勭悊Cache鍛戒腑浣嗘槸鍦板潃鍙樹负uncached鏃剁殑鍒锋柊閫昏緫
      // NOTE:
      // 1. 杩欎釜涓滆タ涓嶄細鍜屼笅闈㈢殑uncached store鍐茬獊锛屽洜涓篠TA蹇呯劧鍦⊿TD涔嬪墠锛?
      // 鎵€浠TD涓嶅彲鑳借Е鍙戣繖娈甸€昏緫
      // 2. 閫昏緫鏄痠sLDU鎴栬€卛sSTU鐨勬椂鍊欙紝瑙﹀彂dirty writeback, 鍐欏畬涔嬪悗锛岀疆瀵瑰簲cache闈炴硶
      // 3. 鎻℃墜锛歠inishWriteback
      val fixUncacheFSM = new StateMachine {
        disableAutoStart()
        setEntry(stateBoot)
        val waitWriteback = new State

        val dirty = setValids(hitWay) && input(DCACHE_DIRTY)(hitWay)

        stateBoot.whenIsActive {
          when((isLDU || isSTU) && hit) {
            arbitration.haltItself := True
            triggerWritebackFixUncache := dirty
            goto(waitWriteback)
          }
        }

        waitWriteback.whenIsActive {
          triggerWritebackFixUncache := False
          // 姣忔潯閮戒粠state boot寮€濮?
          when(arbitration.notStuck) {
            valids(idx)(hitWay) := False // invalidate the cache
            doRefetch := True // valid鐘舵€佹敼浜嗭紝闇€瑕乺efetch
            goto(stateBoot)
          }
        }
      }

      // 澶勭悊CACHE鎸囦护鍙兘寮曞彂鐨勫啓鍥炴搷浣?
      val CACHEFSM = new StateMachine {
        disableAutoStart()
        setEntry(stateBoot)
        val waitWriteBack = new State
        val checkWay = new State
        val writebackWay = new State

        val finishAllWay = RegInit(False) // round-14:X-sweep
        val wayCounter = RegInit(U(0, log2Up(dcache.ways) bits)) // round-14:X-sweep
        val indexCounter = RegInit(U(0, log2Up(dcache.sets) bits)) // round-14:X-sweep

        stateBoot.whenIsActive {
          when(arbitration.isValidOnEntry && isCACHE && cacheSel === CacheSelType.DCache) {
            switch(input(ISSUE_SLOT).uop.cacheOp) {
              import CacheOpType._
              is(IndexInvalidate) {
                arbitration.haltItself.set()
                finishAllWay := False
                wayCounter := 0
                goto(checkWay)
              }
              is(HitInvalidate) {
                arbitration.haltItself.set()
                finishAllWay := False
                wayCounter := 0
                goto(checkWay)
              }
              is(StoreTag) {
                for (i <- 0 until dcache.sets) {
                  for (j <- 0 until (dcache.ways)) {
                    valids(i)(j) := False
                  }
                }
              }
            }
          }
        }

        checkWay.whenIsActive {
          wayCACHE := wayCounter
          when(finishAllWay) {
            when(arbitration.notStuck) {
              doRefetch.set()
              goto(stateBoot)
            }
          } otherwise {
            arbitration.haltItself.set()
            // 妫€鏌ユ璺槸鍚irty锛岃嫢dirty鍒欏啓鍥炪€傛棤璁烘槸鍚﹀啓鍥炲潎杞姸鎬?
            triggerWritebackCACHE := setValids(wayCounter) && input(DCACHE_DIRTY)(wayCounter)
            when(writebackIdle) {
              goto(writebackWay)
            }
          }
        }
        writebackWay.whenIsActive {
          arbitration.haltItself.set()
          when(writebackIdle) {
            // 娓呴櫎姝よ矾valid锛岃浆涓嬩竴璺?
            valids(idx)(wayCounter).clear()
            goto(checkWay)
            when(wayCounter === dcache.ways - 1) {
              finishAllWay := True
            }
            wayCounter := wayCounter + 1
          }
        }

        // Hit Writeback Invalidate
        waitWriteBack.whenIsActive {
          when(arbitration.notStuck) {
            valids(idx)(wayCACHE).clear()
            doRefetch.set()
            goto(stateBoot)
          }
        }
      }

      // 瑙ｅ喅cache miss
      // note. 鍚慶ache濉厖鐨勪笉涓€瀹氭槸鐩墠鐨刴emory state锛屽洜涓烘湁store buffer鏈畬鎴愬啓鐨勯儴鍒嗐€?
      //       浣嗘槸STD浼氬皢杩欎簩鑰呴兘鏇存柊锛屽苟涓旀洿鏂板墠load涔熷彲浠ヤ粠store buffer璇诲埌鏈€鏂扮殑(鍖呮嫭speculative鐨?鏁版嵁銆?
      val cacheRefillFSM = new StateMachine {
        // cached load
        val waitAXI = new State
        val readMem = new State
        val commit = new State
        val finish = new State
        // uncached load
        val waitAXIU = new State
        val readMemU = new State
        val finishU = new State
        disableAutoStart()
        setEntry(stateBoot)
        val rspId = Counter(dcache.lineWords)
        // 鍙嶆瀵勫瓨涔熶笉澧炲姞鍛ㄦ湡锛岃繕鏀瑰杽鏃跺簭
        val refillValid = RegNext(dBus.r.fire, init = False) // round-14:X-sweep
        val regBusWord = RegNext(dBus.r.payload.data, init = B(0, 32 bits)) // round-14:X-sweep
        val refillWord = CombInit(regBusWord)
        // STD鐩存帴寰€cache濉叆鏇存柊浜嗘湰娆″啓鐨勬暟鎹?
        for (i <- 0 until 4)
          when(isSTD && rspId === std.addr(dcache.wordOffsetRange) && std.be(i)) {
            refillWord(i * 8, 8 bits) := std.data(i * 8, 8 bits)
          }
        // 鏍规嵁LRU閫夋嫨涓€璺?
        val dirty = setValids(replaceWay) && input(DCACHE_DIRTY)(replaceWay)

        // 濉厖stored word
        when(refillValid && rspId === cachePhysAddr(dcache.wordOffsetRange)) {
          storedWord := refillWord
        }

        stateBoot.whenIsActive {
          // write-back write allocate, STD闇€瑕乺efill cache
          when(reqValid && !hit) {
            arbitration.haltItself.set()
            rspId.clear()
            triggerWriteback := dirty
            goto(waitAXI)
          }
          when(isLDU) {
            arbitration.haltItself.set()
            goto(waitAXIU)
          }
        }

        // cached load
        waitAXI.whenIsActive {
          arbitration.haltItself.set()
          val ar = dBus.ar
          ar.payload.id := 1
          // 鎶瑰幓offset
          ar.payload.addr := cachePhysAddr(31 downto dcache.offsetWidth) @@
            U(0, dcache.offsetWidth bits)
          ar.payload.len := dcache.lineWords - 1 // burst len
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
          val r = dBus.r
          r.ready := !lockCache
          when(refillValid) {
            dataWs(replaceWay).valid := True
            dataWs(replaceWay).payload.address := idx @@ rspId
            dataWs(replaceWay).payload.data := refillWord
            rspId.increment()
          }
          when(r.fire && r.payload.last) { goto(commit) }
        }

        commit.whenIsActive {
          arbitration.haltItself.set()
          // 瀵筪ata鍐欏叆鏈€鍚庝竴涓獁ord
          dataWs(replaceWay).valid := True
          dataWs(replaceWay).payload.address := idx @@ rspId
          dataWs(replaceWay).payload.data := refillWord
          // 鏇存柊info
          val newInfo = input(DCACHE_INFO).copy()
          // 鍏跺畠璺痶ag淇濇寔
          newInfo.tags := input(DCACHE_INFO).tags
          // 閫夋嫨鐨勪竴璺啓鍏ユ柊tag
          newInfo.tags(replaceWay) := tag
          // Round-Robin锛歳efill 鍚?victim 璁℃暟 +1锛堝搴︽埅鏂嚜鐒跺洖鍗凤級
          newInfo.lru := (input(DCACHE_INFO).lru.asUInt + 1).resize(log2Up(dcache.ways)).asBits
          dirtyBitsManager.io.writeCmd.valid := True
          dirtyBitsManager.io.writeCmd.idx := idx
          dirtyBitsManager.io.writeCmd.way := replaceWay
          dirtyBitsManager.io.writeCmd.data := isSTD
          // 璁剧疆valid
          valids(idx)(replaceWay).set()
          // 鍐欏叆Mem
          wPort.valid.set()
          wPort.payload.address := idx
          wPort.payload.data := newInfo
          rspId.clear()
          goto(finish)
        }

        finish.whenIsActive {
          // 姣忎竴鏉￠兘浠巗tate boot寮€濮?
          when(!arbitration.isStuck) {
            doRefetch := True
            goto(stateBoot)
          }
        }

        // uncached load
        val udBus = pipeline.service(classOf[UncachedAccessPlugin]).udBus
        val uncachedStoreHandshake = pipeline.service(classOf[UncachedAccessPlugin]).uncachedStoreHandshake
        waitAXIU.whenIsActive {
          arbitration.haltItself.set()
          val ar = udBus.ar
          ar.payload.id := 2
          ar.payload.addr := std.addr
          ar.payload.len := 0 // burst len
          ar.payload.size := LoadStoreType.toAxiSize(std.payload.lsType)
          ar.payload.burst := 1 // burst type = INCR
          ar.payload.lock := 0 // normal access
          ar.payload.cache := 0 // device non-bufferable
          if (config.axiConfig.useQos) ar.payload.qos := 0 // no QoS scheme
          ar.payload.prot := 0 // secure and normal(non-priviledged)
          // uncached load瑕佺瓑鍒拌剰琛屽啓瀹屽啀杩涜
          // 灏介噺璁﹗ncached load涔熶笉瑕佷笌姝ｅ湪杩涜涓殑uncached store閲嶅彔
          ar.valid := uncachedStoreHandshake.ready && pipeline
            .service(classOf[DCachePlugin])
            .writebackIdle
          when(ar.fire) { goto(readMemU) }
        }

        readMemU.whenIsActive {
          arbitration.haltItself.set()
          val r = udBus.r
          r.ready.set()
          when(r.valid && r.payload.last) {
            storedWord := r.payload.data
            goto(finishU)
          }
        }

        finishU.whenIsActive {
          // 姣忎竴鏉￠兘浠巗tate boot寮€濮?
          when(!arbitration.isStuck) {
            goto(stateBoot)
          }
        }
      }

      // ! Load Logic: assemble MEMORY_READ_DATA
      val cacheData = Mux(hit, hitData, storedWord)
      val memRData = insert(MEMORY_READ_DATA)
      memRData := cacheData

      // load std鍓嶄紶
      def stdValid(stage: Stage) = {
        val std = stage.input(STD_SLOT)
        std.valid && std.isStore && std.isCached
      }
      pipeline.stages.reverse
        .filter(stage => stage.ne(pipeline.ISS))
        .foreach(stage => {
          when(
            physAddr(2, 30 bits) === stage.input(STD_SLOT).addr(2, 30 bits) && // same addr
              stdValid(stage) // is STD
          ) {
            for (i <- 0 until 4) when(stage.input(STD_SLOT).be(i)) {
              memRData(i * 8, 8 bits) := stage.input(STD_SLOT).data(i * 8, 8 bits);
            }
          }
        })

      // load鏌ヨstore buffer
      storeBuffer.query.addr := physAddr
      for (i <- 0 until 4) when(storeBuffer.query.be(i)) {
        memRData(i * 8, 8 bits) := storeBuffer.query.data(i * 8, 8 bits)
      }

      // LDU蹇呯劧閫塻tored word
      when(isLDU) { memRData := storedWord }
    }
  }
}
