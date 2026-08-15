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

  val dBus = Axi4(config.axiConfig).setIdle() // DCache的AXI总线
  dBus.b.ready.allowOverride := True

  // valid有单index清空的可能，多写口
  val valids = Vec(Vec(RegInit(False), dcache.ways), dcache.sets)
  val dirtyBitsManager = new DirtyBitsManager(config.dcache)
  // 预取流缓冲(下一行预取,度1):全相联、按整行地址键。需求 miss 时把
  // addr+lineSize 压入 pending,refill 空闲时发突发填入,不写 L1(零污染)。
  // 需求查 L1 优先,流缓冲命中直接回送(不阻塞、不提升)。
  // 一致性:store/写回/uncached 命中/缓存指令都会失效对应条目,见 MEM2。
  val sbEnabled = dcache.streamBufferEntries > 0
  val sbEnabledB = Bool(sbEnabled)
  val sbData = if (sbEnabled) Vec(Reg(Vec(BWord(), dcache.lineWords)), dcache.streamBufferEntries) else null
  val sbTags =
    if (sbEnabled) Vec(RegInit(U(0, (32 - dcache.offsetWidth) bits)), dcache.streamBufferEntries)
    else null
  val sbValid = if (sbEnabled) Vec(RegInit(False), dcache.streamBufferEntries) else null
  val sbAlloc = if (sbEnabled) RegInit(U(0, log2Up(dcache.streamBufferEntries) bits)) else null
  val prefetchPending = RegInit(False)
  val prefetchAddr = RegInit(U(0, 32 bits))
  // 虽然d-cache形式上组织成例如32B一行，但是实际每次读写都只需要一个word，因此物理上这么组织最省面积和延迟
  val dataRAMs = Seq.fill(dcache.ways)(
    new SDPRAM(BWord(), dcache.lineWords * dcache.sets, true, useByteEnable = true)
  )
  val infoRAM = new SDPRAM(CacheLineInfo(dcache), dcache.sets, false)

  private object DCACHE_VALIDS extends Stageable(valids.dataType())
  private object DCACHE_DIRTY extends Stageable(dirtyBitsManager.dirtyBits.dataType())
  private object DCACHE_INFO extends Stageable(CacheLineInfo(dcache))
  private object TAG_MATCHES extends Stageable(Bits(dcache.ways bits))
  private object DCACHE_SB_HITS extends Stageable(Bits(scala.math.max(dcache.streamBufferEntries, 1) bits))

  val writebackIdle = False

  override def build(pipeline: MemPipeline): Unit = pipeline plug new Area {
    import pipeline.signals._
    val rPort = infoRAM.io.read
    val dataRs = Vec(dataRAMs.map(_.io.read))
    // 为了避免MEM1取不到MEM2写的cache，做refetch重取
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
      // 读tag按照index找行
      rPort.cmd.valid := rValid
      rPort.cmd.payload := rAddr(dcache.indexRange)
      // 读data应当直接找word
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
      // 读valid也插进流水线
      insert(DCACHE_VALIDS) := valids(memAddr(dcache.indexRange))
      dirtyBitsManager.io.readCmd := memAddr(dcache.indexRange)
      insert(DCACHE_DIRTY) := dirtyBitsManager.io.readRsp
      insert(DCACHE_INFO) := rPort.rsp
      val cachePhysAddr = Mux(std.valid, std.addr, input(MEMORY_ADDRESS_PHYSICAL))
      for (i <- 0 until dcache.ways) {
        insert(TAG_MATCHES)(i) := input(DCACHE_INFO).tags(i) === cachePhysAddr(dcache.tagRange)
      }

      // 流缓冲查找与 store 失效提前到 MEM1(与 TAG_MATCHES 同模式):
      // 26 位行比较不进 MEM2 组合云,避免拉长 MEM2 haltItself->notStuck 链
      // (该链曾被 -0.390ns 违例路径穿过:STD_SLOT.valid -> 发射队列唤醒)
      if (sbEnabled) {
        val mem1SbHits =
          for (i <- 0 until dcache.streamBufferEntries)
            yield sbValid(i) && sbTags(i) === cachePhysAddr(31 downto dcache.offsetWidth)
        insert(DCACHE_SB_HITS) := Vec(mem1SbHits).asBits
        // 任何 store(含 uncached)的地址槽经过 MEM1 即失效命中条目;
        // 比 MEM2 提前一拍,STD 到达 MEM2 时条目已失效,needRefill 的
        // isSTD 豁免兜底。被 flush 的 store 多失效一条无害(保守方向)
        when(arbitration.isValidNotStuck && input(ISSUE_SLOT).uop.isStore) {
          for (i <- 0 until dcache.streamBufferEntries) {
            when(sbTags(i) === cachePhysAddr(31 downto dcache.offsetWidth)) {
              sbValid(i) := False
            }
          }
        }
      }

      // 拆issue slot
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
      // 注意这3者存在同时不满足的情况，此时为cache类指令
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

      // 如果load发现uncached或者exception，那么跳过所有cache处理
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

      // STA忽略cache，但是无异常且cached时要在MEM2写入store buffer
      val storeBufferPush = storeBuffer.queueIO.pushPort
      val storeBufferPushValid =
        arbitration.isValid && noExcept && (isSTA || (isLoad && !addrCached))
      // 扩展后写入store buffer的：cached store, uncached load, uncached store
      storeBufferPush.valid := storeBufferPushValid && arbitration.notStuck
      storeBufferPush.addr := physAddr
      // store buffer永远放移好位的
      storeBufferPush.data := input(MEMORY_WRITE_DATA)
      storeBufferPush.be := input(MEMORY_BE)
      storeBufferPush.retired := False
      storeBufferPush.isStore := isSTA
      storeBufferPush.isCached := addrCached
      storeBufferPush.wReg := input(WRITE_REG)
      storeBufferPush.lsType := input(LOAD_STORE_TYPE)
      storeBufferPush.robIdx := input(ROB_IDX)
      // store buffer不应push不进去，否则memory流水也执行不了STD，就死锁了
      arbitration.haltItself setWhen (storeBufferPushValid && !storeBufferPush.ready)

      // cache查询
      val hits = for (i <- 0 until setValids.size) yield {
        setValids(i) && input(TAG_MATCHES)(i)
      }
      val l1Hit = hits.orR
      val hitData = MuxOH(hits, dataRAMs.map(_.io.read.rsp))
      val hitWay = OHToUInt(Vec(hits).asBits) // multi-way safe one-hot decode
      val replaceWay = input(DCACHE_INFO).lru.asUInt

      // 流缓冲查询(命中向量在 MEM1 已算好并打拍,这里只做数据选择)
      val sbLineAddr = cachePhysAddr(31 downto dcache.offsetWidth)
      val sbHits = if (sbEnabled) input(DCACHE_SB_HITS).asBools else Vec(Seq.empty[Bool])
      val sbHit = sbHits.orR
      val sbHitData =
        if (sbEnabled) MuxOH(sbHits, sbData.map(_(cachePhysAddr(dcache.wordOffsetRange))))
        else B(0, 32 bits)
      val hit = l1Hit || sbHit
      // 需要 refill 的需求访问:load 命中流缓冲视为命中;STD 必须落在
      // L1(store 数据经数据 RAM 提交),流缓冲命中不豁免——且 STA 时
      // 缓冲条目已失效,STD 出现时 sbHit 应为假,此分支为防御性兜底。
      val needRefill = reqValid && !l1Hit && (isSTD || !sbHit)
      // 预取窗口门控:仅对缓存窗口内的行预取(0x0/0x1/0x7 物理直通与
      // 0x8/0x9 仿真缓存窗口),避免对设备区发无意义突发
      val cacheWindowOk =
        cachePhysAddr(31 downto 28) === U"x0" ||
          cachePhysAddr(31 downto 28) === U"x1" ||
          cachePhysAddr(31 downto 28) === U"x7" ||
          cachePhysAddr(31 downto 28) === U"x8" ||
          cachePhysAddr(31 downto 28) === U"x9"

      // CACHE指令相关信息
      val wayCACHE = CombInit(hitWay)
      val cacheOp = input(ISSUE_SLOT).uop.cacheOp
      val cacheSel = input(ISSUE_SLOT).uop.cacheSel

      // 存储当前被填充的word，避免MEM2重取
      val storedWord = Reg(BWord())
      dirtyBitsManager.io.writeCmd.setIdle()

      when(reqCommit && l1Hit) {
        // Round-Robin 替换：命中不更新替换信息
        when(isSTD) {
          // STD提交写cache
          dataWs(hitWay).valid := True
          dataWs(hitWay).payload.address := std.addr(wordAddrRange)
          dataWs(hitWay).payload.data := std.data
          dataMasks(hitWay) := std.be
          dirtyBitsManager.io.writeCmd.valid := True
          dirtyBitsManager.io.writeCmd.idx := idx
          dirtyBitsManager.io.writeCmd.way := hitWay
          dirtyBitsManager.io.writeCmd.data := True
          // 并不需要重取，MEM1自然还会hit，数据可以从store buffer前传出来
          // doRefetch := True
        }
      }

      // 流缓冲一致性:store 失效已提前到 MEM1(store 地址槽经过时即清),
      // STD 到达 MEM2 时条目已失效;needRefill 的 isSTD 豁免兜底防御

      // 触发将脏块写回内存的状态机
      val triggerWriteback = False
      // 由于修复Uncached触发Writeback
      val triggerWritebackFixUncache = False
      // 由于CACHE指令触发Writeback
      val triggerWritebackCACHE = False
      // 写回块取cache需要早于读块写cache
      val lockCache = False
      // 为了write dirty line，提前fetch出来
      val dirtyLine = Reg(Vec(BWord(), dcache.lineWords))
      // 仍然是同步写，但是与读内存并行了
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
              // 写回行 L:失效流缓冲中的 L,防止陈旧副本被后续 load 命中
              if (sbEnabled) {
                for (i <- 0 until dcache.streamBufferEntries) {
                  when(sbTags(i) === input(DCACHE_INFO).tags(replaceWay) @@ idx) {
                    sbValid(i) := False
                  }
                }
              }
            } elsewhen (triggerWritebackFixUncache) {
              wayIdx := hitWay
              if (sbEnabled) {
                for (i <- 0 until dcache.streamBufferEntries) {
                  when(sbTags(i) === input(DCACHE_INFO).tags(hitWay) @@ idx) {
                    sbValid(i) := False
                  }
                }
              }
            } otherwise {
              // triggerWritebackCACHE
              wayIdx := wayCACHE
              if (sbEnabled) {
                for (i <- 0 until dcache.streamBufferEntries) {
                  when(sbTags(i) === input(DCACHE_INFO).tags(wayCACHE) @@ idx) {
                    sbValid(i) := False
                  }
                }
              }
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

      // 处理Cache命中但是地址变为uncached时的刷新逻辑
      // NOTE:
      // 1. 这个东西不会和下面的uncached store冲突，因为STA必然在STD之前，
      // 所以STD不可能触发这段逻辑
      // 2. 逻辑是isLDU或者isSTU的时候，触发dirty writeback, 写完之后，置对应cache非法
      // 3. 握手：finishWriteback
      val fixUncacheFSM = new StateMachine {
        disableAutoStart()
        setEntry(stateBoot)
        val waitWriteback = new State

        val dirty = l1Hit && setValids(hitWay) && input(DCACHE_DIRTY)(hitWay)

        stateBoot.whenIsActive {
          when((isLDU || isSTU) && hit) {
            arbitration.haltItself := True
            triggerWritebackFixUncache := dirty
            // 流缓冲中的同一行直接失效(uncached 访问后副本已不可信)
            if (sbEnabled) {
              for (i <- 0 until dcache.streamBufferEntries) {
                when(sbTags(i) === sbLineAddr) {
                  sbValid(i) := False
                }
              }
            }
            goto(waitWriteback)
          }
        }

        waitWriteback.whenIsActive {
          triggerWritebackFixUncache := False
          // 每条都从state boot开始
          when(arbitration.notStuck) {
            when(l1Hit) {
              valids(idx)(hitWay) := False // invalidate the cache
            }
            doRefetch := True // valid状态改了，需要refetch
            goto(stateBoot)
          }
        }
      }

      // 处理CACHE指令可能引发的写回操作
      val CACHEFSM = new StateMachine {
        disableAutoStart()
        setEntry(stateBoot)
        val waitWriteBack = new State
        val checkWay = new State
        val writebackWay = new State

        val finishAllWay = Reg(Bool())
        val wayCounter = Reg(UInt(log2Up(dcache.ways) bits))
        val indexCounter = Reg(UInt(log2Up(dcache.sets) bits))

        stateBoot.whenIsActive {
          when(arbitration.isValidOnEntry && isCACHE && cacheSel === CacheSelType.DCache) {
            // 缓存指令会改动 L1 内容,流缓冲副本保守全部失效
            if (sbEnabled) {
              for (i <- 0 until dcache.streamBufferEntries) {
                sbValid(i) := False
              }
            }
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
            // 检查此路是否dirty，若dirty则写回。无论是否写回均转状态
            triggerWritebackCACHE := setValids(wayCounter) && input(DCACHE_DIRTY)(wayCounter)
            when(writebackIdle) {
              goto(writebackWay)
            }
          }
        }
        writebackWay.whenIsActive {
          arbitration.haltItself.set()
          when(writebackIdle) {
            // 清除此路valid，转下一路
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

      // 解决cache miss
      // note. 向cache填充的不一定是目前的memory state，因为有store buffer未完成写的部分。
      //       但是STD会将这二者都更新，并且更新前load也可以从store buffer读到最新的(包括speculative的)数据。
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
        // 下一行预取(流缓冲):空闲时复用 dBus,需求 miss/uncached 出现即放弃
        val prefetchAR = new State
        val prefetchRead = new State
        val prefetchDrain = new State
        disableAutoStart()
        setEntry(stateBoot)
        val rspId = Counter(dcache.lineWords)
        // 反正寄存也不增加周期，还改善时序
        val refillValid = RegNext(dBus.r.fire)
        val regBusWord = RegNext(dBus.r.payload.data)
        val refillWord = CombInit(regBusWord)
        // STD直接往cache填入更新了本次写的数据
        for (i <- 0 until 4)
          when(isSTD && rspId === std.addr(dcache.wordOffsetRange) && std.be(i)) {
            refillWord(i * 8, 8 bits) := std.data(i * 8, 8 bits)
          }
        // 根据LRU选择一路
        val dirty = setValids(replaceWay) && input(DCACHE_DIRTY)(replaceWay)

        // 填充stored word
        when(refillValid && rspId === cachePhysAddr(dcache.wordOffsetRange)) {
          storedWord := refillWord
        }

        stateBoot.whenIsActive {
          // write-back write allocate, STD需要refill cache
          when(needRefill) {
            arbitration.haltItself.set()
            rspId.clear()
            triggerWriteback := dirty
            // 记录下一行预取(新 miss 覆盖旧 pending)
            prefetchPending := sbEnabledB && cacheWindowOk
            prefetchAddr := cachePhysAddr + U(dcache.lineSize)
            goto(waitAXI)
          } elsewhen (isLDU) {
            arbitration.haltItself.set()
            goto(waitAXIU)
          } elsewhen (prefetchPending) {
            // 无需求 miss 且 pending 有效:空闲发预取突发
            goto(prefetchAR)
          }
        }

        // cached load
        waitAXI.whenIsActive {
          arbitration.haltItself.set()
          val ar = dBus.ar
          ar.payload.id := 1
          // 抹去offset
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
          // 对data写入最后一个word
          dataWs(replaceWay).valid := True
          dataWs(replaceWay).payload.address := idx @@ rspId
          dataWs(replaceWay).payload.data := refillWord
          // 更新info
          val newInfo = input(DCACHE_INFO).copy()
          // 其它路tag保持
          newInfo.tags := input(DCACHE_INFO).tags
          // 选择的一路写入新tag
          newInfo.tags(replaceWay) := tag
          // Round-Robin：refill 后 victim 计数 +1（宽度截断自然回卷）
          newInfo.lru := (input(DCACHE_INFO).lru.asUInt + 1).resize(log2Up(dcache.ways)).asBits
          dirtyBitsManager.io.writeCmd.valid := True
          dirtyBitsManager.io.writeCmd.idx := idx
          dirtyBitsManager.io.writeCmd.way := replaceWay
          dirtyBitsManager.io.writeCmd.data := isSTD
          // 设置valid
          valids(idx)(replaceWay).set()
          // 写入Mem
          wPort.valid.set()
          wPort.payload.address := idx
          wPort.payload.data := newInfo
          rspId.clear()
          goto(finish)
        }

        finish.whenIsActive {
          // 每一条都从state boot开始
          when(!arbitration.isStuck) {
            doRefetch := True
            goto(stateBoot)
          }
        }

        // ---- 下一行预取(流缓冲,度1)----
        // 不 halt 流水线:刚 refill 完的需求 load 重放即可命中;
        // 预取期间出现新需求 miss 或 uncached load 时放弃本突发
        prefetchAR.whenIsActive {
          val ar = dBus.ar
          ar.payload.id := 1
          // 抹去offset
          ar.payload.addr := prefetchAddr(31 downto dcache.offsetWidth) @@
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
            goto(prefetchRead)
          }
          // 等待 grant 期间出现需求 miss/uncached load:放弃预取。
          // 冻结流水线防止该指令带垃圾数据流走;若本拍恰好被授予,
          // 必须把已授予的突发吃掉(drain)再交还总线,否则需求 refill
          // 会把预取节拍误当自己的数据(同 id 有序响应)
          when(needRefill || isLDU) {
            arbitration.haltItself.set()
            prefetchPending := False
            when(ar.ready) {
              goto(prefetchDrain)
            } otherwise {
              goto(stateBoot)
            }
          }
        }

        prefetchRead.whenIsActive {
          if (sbEnabled) {
            val r = dBus.r
            r.ready := True
            when(r.fire) {
              sbData(sbAlloc)(rspId) := r.payload.data
              rspId.increment()
              when(r.payload.last) {
                sbTags(sbAlloc) := prefetchAddr(31 downto dcache.offsetWidth)
                sbValid(sbAlloc) := True
                sbAlloc := sbAlloc + 1
                prefetchPending := False
                goto(stateBoot)
              }
            }
            // 需求 miss 或 uncached load:放弃本突发。半成品条目必须失效
            // (条目可能还挂着旧的 valid),冻结流水线,剩余节拍丢弃后由
            // 需求 refill 接管
            when(needRefill || isLDU) {
              arbitration.haltItself.set()
              sbValid(sbAlloc) := False
              when(r.valid && r.payload.last) {
                goto(stateBoot)
              } otherwise {
                goto(prefetchDrain)
              }
            }
          }
        }

        prefetchDrain.whenIsActive {
          // 丢弃剩余节拍,不写缓冲;需求指令保持冻结
          arbitration.haltItself.set()
          dBus.r.ready := True
          when(dBus.r.fire && dBus.r.payload.last) {
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
          // uncached load要等到脏行写完再进行
          // 尽量让uncached load也不要与正在进行中的uncached store重叠
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
          // 每一条都从state boot开始
          when(!arbitration.isStuck) {
            goto(stateBoot)
          }
        }
      }

      // ! Load Logic: assemble MEMORY_READ_DATA
      // L1 命中优先,其次流缓冲命中直接回送,否则 refill 填充的 storedWord
      val cacheData = Mux(l1Hit, hitData, Mux(sbHit, sbHitData, storedWord))
      val memRData = insert(MEMORY_READ_DATA)
      memRData := cacheData

      // load std前传
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

      // load查询store buffer
      storeBuffer.query.addr := physAddr
      for (i <- 0 until 4) when(storeBuffer.query.be(i)) {
        memRData(i * 8, 8 bits) := storeBuffer.query.data(i * 8, 8 bits)
      }

      // LDU必然选stored word
      when(isLDU) { memRData := storedWord }
    }
  }
}
