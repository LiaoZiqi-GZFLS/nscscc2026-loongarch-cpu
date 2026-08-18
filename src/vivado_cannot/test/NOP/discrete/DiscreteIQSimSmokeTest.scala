package NOP.discrete

import org.scalatest.funsuite.AnyFunSuite

import scala.collection.mutable
import scala.util.Random

/**
 * DiscreteIQSim 冒烟检查引擎（被 scalatest 套件与 runMain 兜底入口共用）。
 *
 * 策略：影子模型（shadow）逐槽位跟踪 {uopId, ready, age}，
 * 随机 enqueue/wakeup/issue 混合序列下，每步与 DiscreteIQSim 全状态比对，并断言：
 *   1. 队列不满时 enqueue 必成功，且分配到先前为空的槽位；
 *   2. issue 结果必为 ready 胞元中 age 最小（最老）者；无 ready 时必为 None；
 *   3. 模型每胞元的 valid/ready/age/uopId 与影子模型逐拍一致。
 */
object DiscreteIQSimSmoke {

  /** 影子胞元：slot -> (uopId, ready, age)。 */
  type Shadow = mutable.LinkedHashMap[Int, (Int, Boolean, Long)]

  /**
   * 跑一条随机序列。
   * @param seed    本序列种子
   * @param numCells 胞元数
   * @param steps   随机步数
   */
  def runSequence(seed: Long, numCells: Int = 7, steps: Int = 200): Unit = {
    val rng = new Random(seed)
    val model = new DiscreteIQSim(numCells)
    val shadow: Shadow = mutable.LinkedHashMap.empty
    var nextUop = 0

    def checkConsistency(step: Int): Unit = {
      val snap = model.snapshot
      assert(snap.length == numCells, s"step $step: snapshot size mismatch")
      var slot = 0
      while (slot < numCells) {
        val c = snap(slot)
        shadow.get(slot) match {
          case Some((uop, ready, age)) =>
            assert(c.valid, s"step $step: slot $slot should be valid")
            assert(c.uopId == uop, s"step $step: slot $slot uopId ${c.uopId} != shadow $uop")
            assert(c.ready == ready, s"step $step: slot $slot ready ${c.ready} != shadow $ready")
            assert(c.age == age, s"step $step: slot $slot age ${c.age} != shadow $age")
          case None =>
            assert(!c.valid, s"step $step: slot $slot should be empty (uopId=${c.uopId})")
        }
        slot += 1
      }
      assert(model.occupancy == shadow.size, s"step $step: occupancy mismatch")
      assert(model.isFull == (shadow.size == numCells), s"step $step: isFull mismatch")
    }

    var step = 0
    while (step < steps) {
      val op = rng.nextFloat()
      if (op < 0.40f) {
        // ---- enqueue ----
        val uop = nextUop
        nextUop += 1
        val wasFull = model.isFull
        val slot = model.enqueue(uop)
        if (wasFull) {
          assert(slot == -1, s"step $step: enqueue on full queue must fail, got slot $slot")
        } else {
          assert(slot >= 0 && slot < numCells, s"step $step: enqueue must succeed when not full, got $slot")
          assert(!shadow.contains(slot), s"step $step: enqueue allocated non-empty slot $slot")
          shadow(slot) = (uop, false, model.snapshot(slot).age)
        }
      } else if (op < 0.75f) {
        // ---- wakeup：50% 挑存活 uopId，50% 随机 tag（可能未命中） ----
        val tag =
          if (shadow.nonEmpty && rng.nextBoolean()) shadow.values.toVector(rng.nextInt(shadow.size))._1
          else rng.nextInt(nextUop + numCells + 1)
        model.wakeup(tag)
        shadow.keys.foreach { s =>
          val (uop, ready, age) = shadow(s)
          if (!ready && uop == tag) shadow(s) = (uop, true, age)
        }
      } else {
        // ---- issue：期望 = ready 影子胞元中 age 最小者 ----
        val expected: Option[Int] =
          shadow.toList.collect { case (s, (_, true, age)) => (s, age) } match {
            case Nil     => None
            case entries => Some(entries.minBy(_._2)._1)
          }
        val got = model.issue()
        assert(got == expected, s"step $step: issue $got != expected oldest-ready $expected")
        got.foreach(s => shadow.remove(s))
      }
      checkConsistency(step)
      step += 1
    }
  }

  /** 跑 numSeq 条随机序列（种子由 baseSeed 确定性派生）。 */
  def runAll(numSeq: Int = 100, baseSeed: Long = 0x5eed0cL, numCells: Int = 7, steps: Int = 200): Unit = {
    val seedRng = new Random(baseSeed)
    var i = 0
    while (i < numSeq) {
      runSequence(seedRng.nextLong(), numCells, steps)
      i += 1
    }
  }
}

/** scalatest 冒烟套件：`sbt test` 入口。 */
class DiscreteIQSimSmokeTest extends AnyFunSuite {
  test("DiscreteIQSim: 100 random sequences keep ready/oldest/invariant assertions") {
    DiscreteIQSimSmoke.runAll(numSeq = 100)
  }
}

/**
 * runMain 兜底入口（不依赖 verilator / SimConfig）：
 *   sbt "Test / runMain NOP.discrete.DiscreteIQSimSmokeMain"
 */
object DiscreteIQSimSmokeMain {
  def main(args: Array[String]): Unit = {
    DiscreteIQSimSmoke.runAll(numSeq = 100)
    println("DiscreteIQSimSmokeMain: PASS (100 random sequences, all assertions held)")
  }
}
