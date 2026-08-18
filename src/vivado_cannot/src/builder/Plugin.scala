// From vexriscv
package NOP.builder

import NOP.builder._

import spinal.core.{Area, ClockDomain, Nameable}

/** Created by PIC32F_USER on 03/03/2017.
  */
trait Plugin[T <: Pipeline] extends Nameable {
  var pipeline: T = null.asInstanceOf[T]

  // stage1 reset tree split: optional explicit clock domain for build().
  // null (default) -> inherit pipeline.clockDomain -> ambient domain: legacy behavior, zero change.
  var clockDomain: ClockDomain = null

  def resolveClockDomain: ClockDomain = {
    if (clockDomain != null) clockDomain
    else if (pipeline != null && pipeline.groupCd != null) pipeline.groupCd
    else ClockDomain.current
  }

  setName(this.getClass.getSimpleName.replace("$", ""))

  // Used to setup things with other plugins
  def setup(pipeline: T): Unit = {}

  // Used to flush out the required hardware (called after setup)
  def build(pipeline: T): Unit

  implicit class implicitsStage(stage: Stage) {
    def plug[T <: Area](area: T): T = { area.setCompositeName(stage, getName()).reflectNames(); area }
  }
  implicit class implicitsPipeline(stage: Pipeline) {
    def plug[T <: Area](area: T) = { area.setName(getName()).reflectNames(); area }
  }
}
