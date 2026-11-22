// From https://github.dev/SpinalHDL/VexRiscv

package NOP.builder

import NOP.builder._

import spinal.core._
import spinal.lib._

import scala.collection.mutable
import scala.collection.mutable.ArrayBuffer

trait PipelineThing[T]

trait Pipeline {
  type T <: Pipeline
  val plugins = ArrayBuffer[Plugin[T]]()
  var globalCtx: Pipeline = this
  var stages = ArrayBuffer[Stage]()
  var unremovableStages = mutable.Set[Stage]()
  val things = mutable.LinkedHashMap[PipelineThing[_], Any]()

  val dangling_signals: mutable.LinkedHashMap[String, Bits] = mutable.LinkedHashMap[String, Bits]()
//  val services = ArrayBuffer[Any]()

  def stageBefore(stage: Stage) = stages(indexOf(stage) - 1)

  def newStage(): Stage = {
    val s = new Stage()
    stages += s
    s
  }

  def indexOf(stage: Stage) = stages.indexOf(stage)

  def setGlobalCtx(ctx: Pipeline): Unit = {
    globalCtx = ctx
  }

  def service[T](clazz: Class[T]) = {
    val filtered = plugins.filter(o => clazz.isAssignableFrom(o.getClass))
    assert(filtered.length == 1, s"??? ${clazz.getName}")
    filtered.head.asInstanceOf[T]
  }

  def serviceExist[T](clazz: Class[T]) = {
    val filtered = plugins.filter(o => clazz.isAssignableFrom(o.getClass))
    filtered.length != 0
  }

  def globalService[T](implicit tag: Class[T]) = globalCtx.service(tag)

  def serviceElse[T](clazz: Class[T], default: => T): T = {
    if (!serviceExist(clazz)) return default
    val filtered = plugins.filter(o => clazz.isAssignableFrom(o.getClass))
    assert(filtered.length == 1)
    filtered.head.asInstanceOf[T]
  }

  def update[T](that: PipelineThing[T], value: T): Unit = things(that) = value
  def apply[T](that: PipelineThing[T]): T = things(that).asInstanceOf[T]

  def update_signal(that: String, value: Bits): Unit = dangling_signals(that) = value
  def get_signal(that: String): Bits = dangling_signals(that)

  def setUpPlugins(): Unit = {
    plugins.foreach(_.pipeline = this.asInstanceOf[T])
    plugins.foreach(_.setup(this.asInstanceOf[T]))

    plugins.foreach { p =>
      p.parentScope = Component.current.dslBody // Put the given plugin as a child of the current component
      p.reflectNames()
    }
  }

  def buildPlugins(): Unit = {
    plugins.foreach(_.build(this.asInstanceOf[T]))
  }

  def connectStages(): Unit = {

    // Interconnect stages
    class KeyInfo {
      var insertStageId = Int.MaxValue
      var lastInputStageId = Int.MinValue
      var lastOutputStageId = Int.MinValue

      def addInputStageIndex(stageId: Int): Unit = {
        require(stageId >= insertStageId)
        lastInputStageId = Math.max(lastInputStageId, stageId)
        lastOutputStageId = Math.max(lastOutputStageId, stageId - 1)
      }

      def addOutputStageIndex(stageId: Int): Unit = {
        require(stageId >= insertStageId)
        lastInputStageId = Math.max(lastInputStageId, stageId)
        lastOutputStageId = Math.max(lastOutputStageId, stageId)
      }

      def setInsertStageId(stageId: Int) = insertStageId = stageId
    }

    val inputOutputKeys = mutable.LinkedHashMap[Stageable[Data], KeyInfo]()
    val insertedStageable = mutable.Set[Stageable[Data]]()
    for (stageIndex <- 0 until stages.length; stage = stages(stageIndex)) {
      stage.inserts.keysIterator.foreach(signal =>
        inputOutputKeys.getOrElseUpdate(signal, new KeyInfo).setInsertStageId(stageIndex)
      )
      stage.inserts.keysIterator.foreach(insertedStageable += _)
    }

    val missingInserts = mutable.Set[Stageable[Data]]()
    for (stageIndex <- 0 until stages.length; stage = stages(stageIndex)) {
      stage.inputs.keysIterator.foreach(key => if (!insertedStageable.contains(key)) missingInserts += key)
      stage.outputs.keysIterator.foreach(key => if (!insertedStageable.contains(key)) missingInserts += key)
    }

    if (missingInserts.nonEmpty) {
      throw new Exception("Missing inserts : " + missingInserts.map(_.getName()).mkString(", "))
    }

    for (stageIndex <- 0 until stages.length; stage = stages(stageIndex)) {
      stage.inputs.keysIterator.foreach(key => {
        // Print key
//        println(key.getName())
        inputOutputKeys
          .getOrElseUpdate(key, new KeyInfo)
          .addInputStageIndex(stageIndex)
      })
      stage.outputs.keysIterator.foreach(key =>
        inputOutputKeys.getOrElseUpdate(key, new KeyInfo).addOutputStageIndex(stageIndex)
      )
    }

    for ((key, info) <- inputOutputKeys) {
      // Interconnect inputs -> outputs
      for (
        stageIndex <- info.insertStageId to info.lastOutputStageId;
        stage = stages(stageIndex)
      ) {
        stage.output(key)
        val outputDefault = stage.outputsDefault.getOrElse(key, null)
        if (outputDefault != null) {
          outputDefault := stage.input(key)
        }
      }

      // Interconnect outputs -> inputs
      for (stageIndex <- info.insertStageId to info.lastInputStageId) {
        val stage = stages(stageIndex)
        stage.input(key)
        val inputDefault = stage.inputsDefault.getOrElse(key, null)
        if (inputDefault != null) {
          if (stageIndex == info.insertStageId) {
            inputDefault := stage.inserts(key)
          } else {
            val stageBefore = stages(stageIndex - 1)
            // round-4: 级间寄存器的采样使能(!isStuck)是 fo≈1000 的广播网
            // (round-3 布线 top60 中 dataVec CE 类路径 83% 为布线延迟)。
            // max_fanout 提示综合器按消费组复制驱动,不改任何语义。
            val sampleEn = stage.dontSample
              .getOrElse(key, Nil)
              .foldLeft(!stage.arbitration.isStuck)(_ && !_)
            sampleEn.addAttribute("max_fanout", "250")
            // round-14:X-sweep 级间负载寄存器复位清零:消费端均由
            // arbitration.isValid 门控,init 不改功能语义,只消除
            // xsim 中未初始化寄存器在不同网表间的 X 抖动。
            val initValue = key()
            initValue.assignFromBits(B(0, widthOf(initValue) bits))
            inputDefault := RegNextWhen(
              stageBefore.output(key),
              sampleEn,
              init = initValue
            ).setName(s"${stageBefore.getName()}_to_${stage.getName()}_${key.getName()}")
          }
        }
      }
    }

    // Arbitration
    for (stageIndex <- 0 until stages.length; stage = stages(stageIndex)) {
      stage.arbitration.isFlushed := stages.drop(stageIndex + 1).map(_.arbitration.flushNext).orR || stages
        .drop(stageIndex)
        .map(_.arbitration.flushIt)
        .orR
      if (!unremovableStages.contains(stage))
        stage.arbitration.removeIt setWhen stage.arbitration.isFlushed
      else
        assert(stage.arbitration.removeIt === False, "removeIt should never be asserted on this stage")

    }

    for (stageIndex <- 0 until stages.length; stage = stages(stageIndex)) {
      stage.arbitration.isStuckByOthers := stage.arbitration.haltByOther || stages
        .takeRight(stages.length - stageIndex - 1)
        .map(s => s.arbitration.isStuck /* && !s.arbitration.removeIt*/ )
        .foldLeft(False)(_ || _)
      stage.arbitration.isStuck := stage.arbitration.haltItself || stage.arbitration.isStuckByOthers
      stage.arbitration.isMoving := !stage.arbitration.isStuck && !stage.arbitration.removeIt
      stage.arbitration.isFiring := stage.arbitration.isValid && !stage.arbitration.isStuck && !stage.arbitration.removeIt
    }

    if (stages.nonEmpty) {
      // stage 0 特殊
      val stage = stages(0)
      // round-18: isValid/isValidOnEntry 是各级所有负载寄存器 CE 的公共
      // 驱动(r12: RENAME isValid fo=1545,布线主导)。max_fanout 提示综合器
      // 按消费组复制驱动 FF,纯提示、不改语义(round-13 曾加过,ba34d1c
      // 随 X-sweep 一起回退,现恢复)。
      stage.arbitration.isValid.setAsReg().addAttribute("max_fanout", "250") init True
      stage.arbitration.isValidOnEntry := True
      // 立即记录removeIt
      stage.arbitration.isValid clearWhen (stage.arbitration.removeIt)
      // 每次新进来都是True
      stage.arbitration.isValid setWhen (!stage.arbitration.isStuck)
    }

    for (stageIndex <- 1 until stages.length) {
      val stageBefore = stages(stageIndex - 1)
      val stage = stages(stageIndex)

      stage.arbitration.isValid.setAsReg().addAttribute("max_fanout", "250") init (False)
      stage.arbitration.isValidOnEntry.setAsReg().addAttribute("max_fanout", "250") init (False)

      when(!stage.arbitration.isStuck || stage.arbitration.removeIt) {
        stage.arbitration.isValid := False
      }
      stage.arbitration.isValidOnEntry clearWhen (!stage.arbitration.isStuck)

      when(!stageBefore.arbitration.isStuck && !stageBefore.arbitration.removeIt) {
        stage.arbitration.isValid := stageBefore.arbitration.isValid
        stage.arbitration.isValidOnEntry := stageBefore.arbitration.isValid
      }
    }
  }

  def build(): Unit = {
    throw new Exception("You should call build() on a Multi-pipeline")
  }

  // Component.current.addPrePopTask(() => build())
}
