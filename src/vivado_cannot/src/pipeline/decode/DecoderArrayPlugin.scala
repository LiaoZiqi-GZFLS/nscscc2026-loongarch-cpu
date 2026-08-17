package NOP.pipeline.decode

import spinal.core._
import spinal.lib._

import scala.collection._
import NOP.constants.enum._
import NOP.pipeline.decode._
import NOP.pipeline.fetch._
import NOP.pipeline._
import NOP.builder._
import NOP.constants.LoongArch.{ExceptionCode, TLBRD}
import NOP.pipeline.priviledge.ExceptionHandlerPlugin
import NOP.utils._
import NOP.{constants, _}

import scala.annotation.meta.field

/** Decoder service.
  *
  * @param config
  * @param popPorts
  *   Pop ports of fetch buffer.
  */
class DecoderArray(config: MyCPUConfig, val popPorts: Vec[Stream[InstBufferEntry]]) extends Plugin[DecodePipeline] {
  private val width = config.decode.decodeWidth
  private val defaults =
    mutable.LinkedHashMap[Stageable[_ <: Data], Data]()
  private val encodings =
    mutable.LinkedHashMap[MaskedLiteral, mutable.ArrayBuffer[(Stageable[_ <: Data], Data)]]()
  private val priorities = mutable.LinkedHashMap[MaskedLiteral, Int]()
  private val stageables = mutable.HashSet[Stageable[_ <: Data]]()

  /** 添加多个指令编码。
    *
    * @param encoding
    *   指令编码序列
    */
  def addAll(
      encodings: (MaskedLiteral, Seq[(Stageable[_ <: Data], Any)])*
  ): Unit = encodings.foreach(e => this.add(e._1, e._2))

  /** 添加一条指令编码。
    *
    * @param key
    *   指令编码
    * @param values
    *   解码信号值
    */
  def add(
      key: MaskedLiteral,
      values: Seq[(Stageable[_ <: Data], Any)]
  ): Unit = {
    if (encodings.contains(key))
      println(s"Warning: already added encoding ${key.getBitsString(32, '-')}")
    val instructionModel = encodings.getOrElseUpdate(key, mutable.ArrayBuffer())
    values.map { case (a, b) =>
      assert(!instructionModel.contains(a), s"Over specification of $a")
      b match {
        case value: Data                 => instructionModel += (a -> value)
        case value: SpinalEnumElement[_] => instructionModel += (a -> value())
        case _                           => throw new AssertionError(b.getClass().getName())
      }
    }
  }

  /** 设置默认解码。
    *
    * @param key
    *   信号key
    * @param value
    *   信号默认值
    */
  def setDefault[T <: Data](key: Stageable[T], value: T): Unit = {
    assert(!defaults.contains(key))
    defaults(key) = value
  }
  def setDefault[T <: SpinalEnum](
      key: Stageable[SpinalEnumCraft[T]],
      value: SpinalEnumElement[T]
  ): Unit = {
    assert(!defaults.contains(key))
    defaults(key) = value()
  }

  private def setDefaultDontCare[T <: Data](key: Stageable[T]): Unit =
    setDefault(key, key().assignDontCare())

  /** 设置默认解码为don't care。
    *
    * @param key
    *   信号key
    */
  def defaultDontCare(keys: Stageable[_ <: Data]*) {
    keys.foreach(setDefaultDontCare(_))
  }

  /** 设置默认值为false。
    *
    * @param keys
    */
  def defaultFalse(keys: Stageable[Bool]*) {
    keys.foreach(setDefault(_, False))
  }

  /** 设置解码优先级。用于一个编码下的子编码（例如SSNOP）
    *
    * @param key
    *   指令编码
    * @param priority
    *   优先级，越大优先级越高
    */
  def setPriority(key: MaskedLiteral, priority: Int) {
    priorities(key) = priority
  }

  // Build array of decoder
  override def build(pipeline: DecodePipeline): Unit = {

    BuildLoongArch(pipeline)

    // ---- 共享的 elaboration 期数据(两个译码拍共用)----
    stageables ++= encodings.flatMap(_._2.map(_._1))
    val noDefaultList = mutable.ArrayBuffer[Stageable[_ <: Data]]()
    for (s <- stageables) {
      if (!defaults.contains(s)) {
        noDefaultList += s
      }
    }
    if (!noDefaultList.isEmpty) {
      val msg = noDefaultList.mkString(", ") + " have no default decode value"
      throw new Exception(msg)
    }
    for (s <- defaults.keys) {
      if (!stageables.contains(s)) {
        println(
          s"Warning: ${s.getName()} has default value but is never used in decoding"
        )
      }
      stageables += s
    }

    val normalEncodings =
      mutable.ArrayBuffer[(MaskedLiteral, mutable.ArrayBuffer[(Stageable[_ <: Data], Data)])]()
    val priorEncodings = mutable.ArrayBuffer[(Int, MaskedLiteral)]()
    for ((encoding, actions) <- encodings) {
      priorities.get(encoding) match {
        case Some(value) => priorEncodings += (value -> encoding)
        case None        => normalEncodings += (encoding -> actions)
      }
    }
    val encodingsByPriority = priorEncodings.sortBy(_._1).map(_._2)
    println(
      s"Decoder array: ${normalEncodings.size} normal encoding(s) and ${priorEncodings.size} priority encoding(s)"
    )

    val orderedEncodings: Seq[(MaskedLiteral, Seq[(Stageable[_ <: Data], Data)])] =
      normalEncodings.toSeq.map { case (e, a) => (e, a.toSeq) } ++
        encodingsByPriority.map(e => (e, encodings(e).toSeq))

    def valueFor(s: Stageable[_ <: Data], acts: Seq[(Stageable[_ <: Data], Data)]): Data =
      acts.collectFirst { case (k, v) if k eq s => v }.getOrElse(defaults(s))

    // object Stageable 的反射命名在本环境为空,改用 Scala object
    // 类名("MicroOpSignals$fuType$" -> "fuType")与元素名匹配。
    def stName(s: Stageable[_ <: Data]): String =
      s.getClass.getSimpleName.stripSuffix("$")

    import MicroOpSignals._
    def encBool(acts: Seq[(Stageable[_ <: Data], Data)], s: Stageable[Bool]): Bool =
      acts.collectFirst { case (k, v) if k eq s => v }
        .getOrElse(defaults(s))
        .asInstanceOf[Bool]
    def encTlbOpNonNone(acts: Seq[(Stageable[_ <: Data], Data)]): Bool =
      acts.collectFirst { case (k, v) if k eq tlbOp => v } match {
        case Some(v) =>
          v.asInstanceOf[SpinalEnumCraft[TLBOpType.type]] =/= TLBOpType.NONE
        case None => False
      }

    // round-5: 两拍译码。ID 拍 = 取指缓冲 pop 负载(已寄存)上的
    // 65 路匹配 + 每字段 MuxOH + 折叠组合基;ID2 拍 = epilogue。
    // 原单拍 15 级(round-3 top1)拆成两段 ≤8 级。
    pipeline.ID plug new Area {
      import pipeline.ID._

      def buildStage1(input: InstBufferEntry) =
        new Composite(input) {
          val entry = input
          val illegalEncoding = Bool() // Flag if the instruction is illegal, i.e. no encoding matches

          // P12(译码级数压缩):指令编码互斥(65 normal + 0 priority),
          // 一次性比较向量(65 位 one-hot,2-3 级)+ 每字段 MuxOH(约 3 级)。
          // 无匹配(非法指令)时各字段保持默认值(追加一个默认输入,
          // 选择位 = !anyMatch),与旧 when 链语义一致。
          val matchBits = orderedEncodings.map { case (enc, _) => entry.inst === enc }
          val anyMatch = matchBits.orR
          illegalEncoding := !anyMatch

          // 注意: 不能用 matchBits.asBits() ## !anyMatch —— asBits 是
          // MSB-first 拼接,经 asBools 回读后与 vals 整体错位 1 位
          // (实测 ADDI 按下一编码 ANDI 译码,功能测试全挂)。
          // 直接用 Seq[Bool] 按索引一一对应: matchBits(k) -> vals(k),
          // !anyMatch -> vals.last(默认值),与旧 when 链语义一致。
          val sel: IndexedSeq[Bool] = matchBits.toIndexedSeq :+ !anyMatch

          val d = DecodeFieldsBundle(config)
          private val dElements = d.elements.toMap

          for (s <- stageables) {
            val vals = orderedEncodings.map { case (_, acts) => valueFor(s, acts) } :+ defaults(s)
            val muxed = MuxOH(sel, vals)
            dElements(stName(s)).asInstanceOf[Data].allowOverride()
            dElements(stName(s)).asInstanceOf[Data] := muxed
          }

          // round-4:epilogue 的组合 OR 链(flushState/branchLike/uniqueRetire)
          // 原先是"字段 mux 输出再串 2-3 级 OR",这里按编码常量直接折叠
          // 成 matchBits 驱动的一次性 MuxOH。writeCSR(依赖 rj)/predInfo
          // (来自取指)保留在 ID2 拍组合。
          val flushStateVals = orderedEncodings.map { case (_, acts) =>
            encBool(acts, isErtn) || encBool(acts, isWait) || encTlbOpNonNone(acts) ||
              encBool(acts, operateCache) || encBool(acts, isBar) ||
              encBool(acts, isLL) || encBool(acts, isSC)
          } :+ False
          val branchLikeVals = orderedEncodings.map { case (_, acts) =>
            encBool(acts, isBranch) || encBool(acts, isJump) || encBool(acts, isJR)
          } :+ False
          val uniqueRetireVals = orderedEncodings.zipWithIndex.map { case ((_, acts), i) =>
            flushStateVals(i) || branchLikeVals(i) ||
              encBool(acts, isLoad) || encBool(acts, isStore)
          } :+ False
          d.flushStateBase := MuxOH(sel, flushStateVals)
          d.branchLikeBase := MuxOH(sel, branchLikeVals)
          d.uniqueRetireBase := MuxOH(sel, uniqueRetireVals)
          d.illegalEncoding := illegalEncoding

          // 直通
          d.pc := entry.pc
          d.inst := entry.inst
          d.except := entry.except
          d.predInfo := entry.predInfo
          d.predRecover := entry.predRecover
        }

      // 生成decoder阵列(ID 拍)
      val stage1s = for (i <- 0 until width) yield buildStage1(popPorts(i).payload)
      val decodeFields = insert(pipeline.signals.DECODE_FIELDS)
      for (i <- 0 until width) {
        decodeFields(i).valid := popPorts(i).valid
        decodeFields(i).payload := stage1s(i).d
        popPorts(i).ready := arbitration.isFiring
      }
    }

    pipeline.ID2 plug new Area {
      import pipeline.ID2._

      def buildStage2(input: DecodeFieldsBundle) =
        new Composite(input) {
          val d = input
          val fields = InstructionParser(d.inst) // Parse
          val uop = MicroOp(config)

          // ! Epilogue: override some fields
          import NOP.constants.LoongArch
          // Start Assigning retval (uop)
          uop.pc := d.pc
          uop.inst := d.inst

          // Branch Prediction
          uop.predInfo := d.predInfo
          uop.predRecover := d.predRecover

          // 主字段
          uop.fuType := d.fuType
          uop.useRk := d.useRk
          uop.immExtendType := d.immExtendType
          uop.aluOp := d.aluOp
          uop.lsType := d.lsType
          uop.isLoad := d.isLoad
          uop.isStore := d.isStore
          uop.cmpOp := d.cmpOp
          uop.isBranch := d.isBranch
          uop.isJump := d.isJump
          uop.isJR := d.isJR
          uop.signed := d.signed
          uop.readCSR := d.readCSR
          uop.readTimer64H := d.readTimer64H
          uop.tlbOp.allowOverride()
          uop.tlbOp := d.tlbOp
          uop.operateCache := d.operateCache
          uop.isWait := d.isWait
          uop.isLL := d.isLL
          uop.isSC := d.isSC
          uop.isErtn := d.isErtn

          // CSR(useRj/useRd 由 CSR 条件或上,避免覆盖链)
          uop.writeCSR := d.readCSR && (fields.rj =/= 0)
          uop.useRd := d.useRd || uop.writeCSR
          uop.useRj := d.useRj || (uop.writeCSR && fields.rj =/= 1)

          // Timer
          uop.readTimer64L := False
          uop.readTimer64ID := False
          when(d.fuType === FUType.TIMER && ~d.readTimer64H) {
            when(fields.rd === 0) {
              uop.readTimer64ID := True
              uop.wbAddr := fields.rj
            } otherwise {
              uop.readTimer64L := True
              uop.wbAddr := fields.rd
            }
          } otherwise {
            // REG W
            when(d.overrideRdToRA) {
              uop.wbAddr := U(1, config.regFile.arfAddrWidth bits)
            } otherwise {
              when(d.overrideRdToRj) {
                uop.wbAddr := fields.rj
              } otherwise {
                uop.wbAddr := fields.rd
              }
            }
          }
          uop.doRegWrite := d.isRegWrite & (uop.wbAddr =/= 0)

          // decode异常
          uop.except.allowOverride()
          uop.except := d.except
          when(!d.except.valid) {
            uop.except.payload.isTLBRefill := False
            when(d.isSyscall) {
              uop.except.valid := True
              uop.except.payload.code := ExceptionCode.SYS.ecode
              uop.except.payload.subcode := ExceptionCode.SYS.esubcode
            }
            when(d.isBreak) {
              uop.except.valid := True
              uop.except.payload.code := ExceptionCode.BRK.ecode
              uop.except.payload.subcode := ExceptionCode.BRK.esubcode
            }
            when(d.illegalEncoding) {
              uop.except.valid := True
              uop.except.payload.code := ExceptionCode.INE.ecode
              uop.except.payload.subcode := ExceptionCode.INE.esubcode
            }

            // TLB
            when(LoongArch.INVTLB === d.inst && d.useRj && d.useRk) {
              // INVTLB
              val opCode = d.inst(4 downto 0)
              switch(opCode) {
                is(0, 1) {
                  uop.tlbOp := TLBOpType.INVTLB1
                }
                is(2) {
                  uop.tlbOp := TLBOpType.INVTLB2
                }
                is(3) {
                  uop.tlbOp := TLBOpType.INVTLB3
                }
                is(4) {
                  uop.tlbOp := TLBOpType.INVTLB4
                }
                is(5) {
                  uop.tlbOp := TLBOpType.INVTLB5
                }
                is(6) {
                  uop.tlbOp := TLBOpType.INVTLB6
                }
                default {
                  uop.except.valid := True
                  uop.except.payload.code := ExceptionCode.INE.ecode
                  uop.except.payload.subcode := ExceptionCode.INE.esubcode
                }
              }
            }

            // IPE
            import NOP.constants.LoongArch
            val privInst =
              d.inst === LoongArch.CSR || d.inst === LoongArch.CACOP || d.inst === LoongArch.ERTN ||
                d.inst === LoongArch.IDLE || d.inst === LoongArch.TLBRD || d.inst === LoongArch.TLBWR ||
                d.inst === LoongArch.TLBSRCH || d.inst === LoongArch.TLBFILL || d.inst === LoongArch.INVTLB

            val privLvl = pipeline.globalService(classOf[ExceptionHandlerPlugin]).CRMD_PLV
            when(privLvl =/= 0 && privInst) {
              uop.except.valid := True
              uop.except.payload.code := ExceptionCode.IPE.ecode
              uop.except.payload.subcode := ExceptionCode.IPE.esubcode
            }
          }

          uop.branchLike := d.branchLikeBase
          // 处理unique retire类指令
          uop.flushState := d.flushStateBase || uop.writeCSR
          // flushState 是 uniqueRetire 的子集

          if (config.decode.allUnique) {
            println("[Warning] All Unique retire enabled")
            uop.uniqueRetire := True
          } else {
            uop.uniqueRetire := d.uniqueRetireBase ||
              uop.writeCSR ||
              d.predInfo.predictBranch
          }
        }

      // epilogue 阵列(ID2 拍)
      val decodeFields = input(pipeline.signals.DECODE_FIELDS)
      val stage2s = for (i <- 0 until width) yield buildStage2(decodeFields(i).payload)
      val decodePacket = insert(pipeline.signals.DECODE_PACKET)
      for (i <- 0 until width) {
        decodePacket(i).valid := decodeFields(i).valid
        decodePacket(i).payload := stage2s(i).uop
      }
    }
  }

  def BuildLoongArch(pipeline: DecodePipeline): Unit = {
    import NOP.constants.LoongArch
    val decoder = pipeline.service(classOf[DecoderArray])

    import MicroOpSignals._

    // 保持与micro op一样的顺序
    setDefault(fuType, FUType.ALU)
    setDefault(tlbOp, TLBOpType.NONE)
    setDefault(operateCache, False)
    defaultFalse(useRj, useRk, useRd, isRegWrite, overrideRdToRA, overrideRdToRj)
    defaultFalse(readCSR, readTimer64H)
    setDefault(immExtendType, ExtendType.SIGN)
    defaultDontCare(aluOp, cmpOp, signed)
    setDefault(lsType, LoadStoreType.BYTE)
    defaultFalse(isLoad, isStore, isLL, isSC)
    defaultFalse(isBranch, isJump, isJR)
    defaultFalse(isSyscall, isErtn, isBreak, isWait, isBar)

    // These actions are common to all instructions
    // Therefore, they are defined here, which can be reused by all instructions
    val reg1WActions = Seq(isRegWrite -> True)
    val reg1RActions = Seq(useRj -> True)
    val reg1R1WActions = reg1RActions ++ Seq(isRegWrite -> True)
    val reg2RActions = Seq(useRj -> True, useRk -> True)
    val reg2R1WActions = reg2RActions ++ Seq(isRegWrite -> True)
    val useUnsignedImm = Seq(immExtendType -> ExtendType.ZERO)

    // Integer
    addAll(
      LoongArch.ADD -> (reg2R1WActions ++ Seq(aluOp -> ALUOpType.ADD)),
      LoongArch.SUB -> (reg2R1WActions ++ Seq(aluOp -> ALUOpType.SUB)),
      LoongArch.SLT -> (reg2R1WActions ++ Seq(aluOp -> ALUOpType.SLT)),
      LoongArch.SLTU -> (reg2R1WActions ++ Seq(aluOp -> ALUOpType.SLTU)),
      LoongArch.NOR -> (reg2R1WActions ++ Seq(aluOp -> ALUOpType.NOR)),
      LoongArch.AND -> (reg2R1WActions ++ Seq(aluOp -> ALUOpType.AND)),
      LoongArch.OR -> (reg2R1WActions ++ Seq(aluOp -> ALUOpType.OR)),
      LoongArch.XOR -> (reg2R1WActions ++ Seq(aluOp -> ALUOpType.XOR)),
      LoongArch.SLL -> (reg2R1WActions ++ Seq(aluOp -> ALUOpType.SLL)),
      LoongArch.SRL -> (reg2R1WActions ++ Seq(aluOp -> ALUOpType.SRL)),
      LoongArch.SRA -> (reg2R1WActions ++ Seq(aluOp -> ALUOpType.SRA))
    )

    // Integer Immediate
    addAll(
      LoongArch.SLLI -> (reg1R1WActions ++ Seq(aluOp -> ALUOpType.SLL)),
      LoongArch.SRLI -> (reg1R1WActions ++ Seq(aluOp -> ALUOpType.SRL)),
      LoongArch.SRAI -> (reg1R1WActions ++ Seq(aluOp -> ALUOpType.SRA)),
      LoongArch.SLTI -> (reg1R1WActions ++ Seq(aluOp -> ALUOpType.SLT)),
      LoongArch.SLTUI -> (reg1R1WActions ++ Seq(aluOp -> ALUOpType.SLTU)),
      LoongArch.ADDI -> (reg1R1WActions ++ Seq(aluOp -> ALUOpType.ADD)),
      LoongArch.ANDI -> (useUnsignedImm ++ reg1R1WActions ++ Seq(aluOp -> ALUOpType.AND)),
      LoongArch.ORI -> (useUnsignedImm ++ reg1R1WActions ++ Seq(aluOp -> ALUOpType.OR)),
      LoongArch.XORI -> (useUnsignedImm ++ reg1R1WActions ++ Seq(aluOp -> ALUOpType.XOR))
    )

    addAll(
      LoongArch.LU12I -> (reg1WActions ++ Seq(aluOp -> ALUOpType.LU12I)),
      LoongArch.PCADDI -> (reg1WActions ++ Seq(aluOp -> ALUOpType.PCADDI)),
      LoongArch.PCADDU12I -> (reg1WActions ++ Seq(aluOp -> ALUOpType.PCADDU12I))
    )

    // Branch
    // ! Note that branch instructions use Rj (0) and **Rd** (1)
    val branchActions = Seq(fuType -> FUType.CMP, isBranch -> True, useRd -> True)
    addAll(
      LoongArch.BEQ -> (branchActions ++ reg1RActions ++ Seq(cmpOp -> CompareOpType.EQ)),
      LoongArch.BNE -> (branchActions ++ reg1RActions ++ Seq(cmpOp -> CompareOpType.NE)),
      LoongArch.BLT -> (branchActions ++ reg1RActions ++ Seq(cmpOp -> CompareOpType.LT)),
      LoongArch.BGE -> (branchActions ++ reg1RActions ++ Seq(cmpOp -> CompareOpType.GE)),
      LoongArch.BLTU -> (branchActions ++ reg1RActions ++ Seq(cmpOp -> CompareOpType.LTU)),
      LoongArch.BGEU -> (branchActions ++ reg1RActions ++ Seq(cmpOp -> CompareOpType.GEU))
    )

    // Jump
    val jumpActions = Seq(fuType -> FUType.CMP, isJump -> True)
    val jumpLinkActions = Seq(fuType -> FUType.CMP, isJR -> True, useRj -> True)
    addAll(
      LoongArch.B -> jumpActions,
      LoongArch.BL -> (jumpActions ++ Seq(isRegWrite -> True, overrideRdToRA -> True)),
      LoongArch.JIRL -> (jumpLinkActions ++ Seq(isRegWrite -> True))
    )

    // Mul or Div
    addAll(
      LoongArch.MUL -> (reg2R1WActions ++ Seq(fuType -> FUType.MUL, signed -> True)),
      LoongArch.MULH -> (reg2R1WActions ++ Seq(fuType -> FUType.MULH, signed -> True)),
      LoongArch.MULHU -> (reg2R1WActions ++ Seq(fuType -> FUType.MULH, signed -> False)),
      LoongArch.DIV -> (reg2R1WActions ++ Seq(fuType -> FUType.DIV, signed -> True)),
      LoongArch.DIVU -> (reg2R1WActions ++ Seq(fuType -> FUType.DIV, signed -> False)),
      LoongArch.MOD -> (reg2R1WActions ++ Seq(fuType -> FUType.MOD, signed -> True)),
      LoongArch.MODU -> (reg2R1WActions ++ Seq(fuType -> FUType.MOD, signed -> False))
    )

    // Load or store
    val memActions = Seq[(Stageable[_ <: Data], Any)](fuType -> FUType.LSU)
    val loadActions = memActions ++ reg1R1WActions ++ Seq(isLoad -> True)
    val storeActions = memActions ++ reg1RActions ++ Seq(isStore -> True, useRd -> True)
    addAll(
      LoongArch.LDW -> (loadActions ++ Seq(lsType -> LoadStoreType.WORD)),
      LoongArch.LDH -> (loadActions ++ Seq(lsType -> LoadStoreType.HALF)),
      LoongArch.LDHU -> (loadActions ++ Seq(lsType -> LoadStoreType.HALF_U)),
      LoongArch.LDB -> (loadActions ++ Seq(lsType -> LoadStoreType.BYTE)),
      LoongArch.LDBU -> (loadActions ++ Seq(lsType -> LoadStoreType.BYTE_U)),
      LoongArch.STW -> (storeActions ++ Seq(lsType -> LoadStoreType.WORD)),
      LoongArch.STH -> (storeActions ++ Seq(lsType -> LoadStoreType.HALF)),
      LoongArch.STB -> (storeActions ++ Seq(lsType -> LoadStoreType.BYTE))
    )
    addAll(
      LoongArch.LL -> Seq(
        fuType -> FUType.LSU,
        useRj -> True,
        isRegWrite -> True,
        isLoad -> True,
        lsType -> LoadStoreType.WORD,
        isLL -> True
      ),
      LoongArch.SC -> Seq(
        fuType -> FUType.LSU,
        useRj -> True,
        useRd -> True,
        isRegWrite -> True,
        isStore -> True,
        lsType -> LoadStoreType.WORD,
        isSC -> True
      )
    )

    // CSR
    addAll(
      LoongArch.CSR -> Seq(fuType -> FUType.CSR, isRegWrite -> True, readCSR -> True)
    )

    // Timer
    addAll(
      LoongArch.RDCNTVL -> Seq(fuType -> FUType.TIMER, isRegWrite -> True),
      LoongArch.RDCNTVH -> Seq(fuType -> FUType.TIMER, isRegWrite -> True, readTimer64H -> True)
    )

    // CPUCFG（2026 perf start.S 需要；走 ALU 恒写 0）
    addAll(
      LoongArch.CPUCFG -> (reg1R1WActions ++ Seq(aluOp -> ALUOpType.CPUCFG))
    )

    addAll(
      LoongArch.SYSCALL -> Seq(fuType -> FUType.NONE, isSyscall -> True),
      LoongArch.BREAK -> Seq(fuType -> FUType.NONE, isBreak -> True),
      LoongArch.ERTN -> Seq(fuType -> FUType.NONE, isErtn -> True),
      LoongArch.IDLE -> Seq(fuType -> FUType.NONE, isWait -> True)
    )

    addAll(
      LoongArch.TLBSRCH -> Seq(fuType -> FUType.NONE, tlbOp -> TLBOpType.TLBSRCH),
      LoongArch.TLBRD -> Seq(fuType -> FUType.NONE, tlbOp -> TLBOpType.TLBRD),
      LoongArch.TLBWR -> Seq(fuType -> FUType.NONE, tlbOp -> TLBOpType.TLBWR),
      LoongArch.TLBFILL -> Seq(fuType -> FUType.NONE, tlbOp -> TLBOpType.TLBFILL),
      LoongArch.INVTLB -> (Seq(useRj -> True, useRk -> True, fuType -> FUType.INVTLB, tlbOp -> TLBOpType.INVTLB1))
    )

    addAll(
      LoongArch.IBAR -> Seq(fuType -> FUType.NONE, isBar -> True),
      LoongArch.DBAR -> Seq(fuType -> FUType.NONE, isBar -> True)
    )

    addAll(
      LoongArch.CACOP -> Seq(fuType -> FUType.LSU, operateCache -> True, useRj -> True, lsType -> LoadStoreType.CACOP)
    )
  }

}
