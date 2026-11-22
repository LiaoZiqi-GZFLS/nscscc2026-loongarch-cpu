package NOP.utils

import spinal.core._
import spinal.lib._
import scala.collection.mutable

import NOP.pipeline.core._
import NOP.pipeline._
import NOP.builder._
import NOP._

/** 闁告ê顑囩紓澶愭⒓閻斿嘲鐏欓柕?
  *
  * 闁告ê顑囩紓澶愭⒓閻斿嘲鐏欓柟绋款槷缁鳖參宕楅崼銏ょ崜濞寸姴绨肩紞鍡涘礆娴煎褰柨?
  *
  *   1. 濞戞挸绉寸敮鍥╃磽閳哄倹顦ч柤濂変海闂娾晠鎮╅懜纰樺亾娴ｈ姤绁紒澶嬬湽閳ь剙鍊搁幃鎾愁潰閵夈劌娈緎tateNext闁?
  *
  * 2. 闁稿繈鍎靛Σ锕傚籍閹偊娲柛鎰懁鐠愮喖宕氬┑鍥ｅ亾娴ｇ鍋撻崒姘€辨慨婵勫劥閸ゎ洐tateNext闁?
  *
  * 3. 闁告ê顑囩紓澶愬籍閸洍鍋撳宕囩畺stateNext闁告艾鏈鐐烘偐閼哥鍋撴担鑺ョギ缂佸鐪归埀?
  *
  * 4. flush闁哄啫澧庡ú鍧楀箳閵夛妇顏搁梻鍕╁€栨晶宥夊嫉婵夌笢lid闁靛棗鍊诲ú鍧楀箳閵夈儱鏅搁柕鍡楀€瑰〒鑸殿殗濡湱鍠橀柛蹇撶墢妤犲洭鏁嶇仦鑲╃憹闂傚洠鍋撻悷鏇氬tateNext闁告艾鏈鐐哄Υ?
  *
  * @param issConfig
  * @param decodeWidth
  * @param slotType
  */
abstract class CompressedFIFO[T <: IssueSlot](
    issConfig: IssueConfig,
    val decodeWidth: Int,
    val slotType: HardType[T]
) extends Plugin[MyCPUCore] {
  val issueWidth = issConfig.issueWidth
  val depth = issConfig.depth

  val busyAddrs: Vec[UInt]
  var busyRsps: Vec[Bool] = null
  def fuMatch(uop: MicroOp): Bool

  val queue = out(Vec(RegFlow(slotType()), depth)) // 闁稿纰嶈潕缂佸顕ф慨?
  val queueNext = CombInit(queue) // 闁哄秴娲ょ换鏃傗偓鐢垫嚀缁ㄦ彃危閻ｅ本鐣卞☉鎾愁儎缁斿瓨绋夐鍕ㄥ亾绾绀勫☉鎾崇Х閳ь剙鍟冲濠氬储鐎ｎ剛绱氶柨?

  val issueReq = Bool
  val issueFire = True // issue闁轰胶绻濈紞瀣媴閼愁垰鍘?
  val queueFlush = False // 婵炴挸鎳樺▍搴ㄥ极缂堢娀鍤婭Q
  // round-12(IQ 闁煎磭鍋涢崢鎾诲礌?:闁哥偑鍊濋崯瀣媴瀹ュ妗ㄩ柣娆樺墰閻濇盯鎳楅悙鎻掑笚閻庨潧瀚悺銊╁闯?闁告娲栭崯鎾绘嚀?,妤犵偞瀵ч幐杈┾偓闈涘閻°劍绋夐埀顒勫箯?
  var rReadyBank: Vec[Vec[Bool]] = null
  // 濞达絽绉瑰浼存儍閸曨厾鐭嬮柛?next(闂傗偓濠婂啫鍓?queueNext):闁哥偑鍊濋崯?闁稿繈鍎靛Σ锕傚礃?next,闁告ê顑囩紓澶愬箹?next闁炽儲鏌￠埀?
  // 濞ｅ洦绻嗛惁?闁哥偑鍊濋崯瀣箯瀹ュ嫮鐟㈤柛妯侯儑缂傚骞栭鍌傗晠宕ョ仦鎯ь€?闁哄啯婀圭粭澶嬬▔閵忕姵鏆呴梺?妤犵偞瀵ч幐?RegNext 闁告瑯浜滈悺銊ッ?1 闁?闁?
  var rReadyBankNext: Vec[Vec[Bool]] = null

  // round-12(IQ 闁煎磭鍋涢崢鎾诲礌?:濞达絽绉瑰鎵偓闈涘閻°劑宕抽妸銉﹁含 build 闁哄牏鍠庨崹鍗烆嚈?闁圭瑳鍡╂斀闁圭粯甯婂▎?ISS 闁?build 闁?
  // 閻犲洩顔婄紞鍛存?闁兼澘鏈﹢浼村箵閹哄秵顐介柛蹇撶墔缁剟骞嶈椤㈡垿骞撻幒宥嗩偨 build,濞撴碍绻嗙粋鍡樻償韫囧海绠介悹鍥︽缂嶅懘妫冮姀鐘插殥閻庢稒锚濠€?闁?
  def createReadyBank(rPorts: Int): Unit = {
    rReadyBank = Vec(Vec(RegInit(False), rPorts), depth)
    rReadyBankNext = CombInit(rReadyBank)
  }

  val queueIO = new Area {
    val pushPorts = Vec(Stream(slotType), decodeWidth)
  }

  def genEnqueueLogic() = {
    val validFall = !queue(0).valid +: (for (i <- 1 until depth)
      yield queue(i - 1).valid && !queue(i).valid)
    // 闁稿繈鍎靛Σ锕傛焻閺勫繒甯?
    for (i <- 0 until decodeWidth) {
      // 0闁告瑯鏌沞ady鐟滅増鎸风粭鏍ㄧ閸涱厾绉糳epth-1闁哄嫷鍨抽埞鏍儍?
      queueIO.pushPorts(i).ready := !queue(depth - i - 1).valid
      for (j <- i until depth) {
        when(queueIO.pushPorts(i).valid && validFall(j - i)) {
          // 閻庤鐭紞鍛村礌瑜版帒甯抽柨娑樿嫰閸垳浜搁崱妯烆偊宕楅妷鈺傂?
          queue(j).push(queueIO.pushPorts(i).payload)
          queueNext(j).push(queueIO.pushPorts(i).payload)
          // round-12(IQ 闁煎磭鍋涢崢鎾诲礌?:濞达絽绉瑰鎵啺閸℃鏅稿☉鎾虫惈閸欏棝姊奸悢宄扮仴濠殿喖顑呴埀?濞村吋锚閸樻稓鐥閻濐喗绂嶆惔鈩冩殔闂?;
          // 濞?payload 濞戞挴鍋撻柤?閻庨潧瀚悺銊︾▔?next 闁告瑥鑻崯?闁告ê顑囩紓澶愬箹?next)闁?
          if (rReadyBank != null) {
            for (k <- 0 until rReadyBank(j).size) {
              rReadyBank(j)(k) := queueIO.pushPorts(i).payload.rRegs(k).valid
              rReadyBankNext(j)(k) := queueIO.pushPorts(i).payload.rRegs(k).valid
            }
          }
        }
      }
    }
  }

  def genCompressLogic() = {
    // 闁告ê顑囩紓澶愭焻閺勫繒甯?
    val popCount = issueReq && issueFire
    require(issueWidth == 1)
    for (i <- 0 until depth) {
      when(popCount) {
        if (i + 1 < depth) {
          queue(i) := queueNext(i + 1)
          // round-12(IQ 闁煎磭鍋涢崢鎾诲礌?:濞达絽绉瑰浼村箹?next闁炽儲鏌￠埀顒佹煥閺佹粓鏌嬮幒鎾愁€炲☉鎾抽鐢洨绱撻埡浣瑰€遍柟宄扮У濡?
          // 闁哥偑鍊濋崯瀣啅閹绘帒鏅搁柛?next,闁圭⒈鍓涗簺濞戞挸绉冲☉顏堝Υ?
          if (rReadyBank != null) {
            rReadyBank(i) := rReadyBankNext(i + 1)
          }
        }
        else queue(i).valid := False
      }
    }
  }

  def genFlushLogic() = when(queueFlush) {
    // flush闁哄牃鍋撳Δ鍌浢肩槐顓㈠礂閸垽鐛?
    for (i <- 0 until depth) {
      queue(i).valid := False
      // round-12(IQ 闁煎磭鍋涢崢鎾诲礌?:濞达絽绉瑰鐗堢▔閳ь剟鐛懜鐢殿伕闂?
      if (rReadyBank != null) {
        for (j <- 0 until rReadyBank(i).size) {
          rReadyBank(i)(j) := False
        }
      }
    }
  }

  // round-12(EXE 闁圭粯鍔曟晶鐘绘煂瀹ュ懐鏆伴柛?:闂侇偄顦扮€氥劑骞€瑜庣粩濠氭⒔閵堝倵鍋撻弬琛″亾閺傚灝娑ч柡澶嗗亾妤犵偟顥愭禍銈嗙鎼淬劌娅㈤悗瑙勮壘閹粓宕氶崱妯绘殰闁汇劌瀚潕,
  // 濞村吋锚閸樻稓鐥缁?flush 闁告艾鐬兼?闁告劖鐟ュ﹢顏堝礂鐠虹儤鍊?闁靛棗鍊婚獮鍡氥亹閵忋垻宕堕柛娆欑稻閻︻喗娼?dSlot > dK(unsigned)闁?
  def genEarlyKill() = {
    val robFIFO = pipeline.globalService(classOf[ROBFIFOPlugin])
    when(robFIFO.earlyRedirect.valid) {
      val dK = robFIFO.earlyRedirect.robIdx - robFIFO.popPtr
      for (i <- 0 until depth) {
        when(queue(i).valid && (queue(i).payload.robIdx - robFIFO.popPtr) > dK) {
          queue(i).valid := False
          if (rReadyBank != null) {
            for (j <- 0 until rReadyBank(i).size) {
              rReadyBank(i)(j) := False
            }
          }
        }
      }
    }
  }

  def genIssueSelect() = {
    // issue闂侇偄顦扮€?
  }

  def genGlobalWakeup(prf: PhysRegFilePlugin, rPorts: Int) = {
    // round-12(IQ 闁煎磭鍋涢崢鎾诲礌?:闁哥偑鍊濋崯瀣媴瀹ュ妗ㄩ柣娆樺墰閻濇盯鎳楅悙鎻掑笚閻庨潧瀚悺銊╁闯?+ 妤犵偞瀵ч幐杈┾偓闈涘閻°劍绋夐埀顒勫箯瀹ュ啠鍋?
    // 婵?(婵?婵? 濞达絽绉磋ぐ褔寮垫径瀣嫳闁煎磭鍋涢崢鎾诲礃?闁告娲栭崯鎾绘嚀?;妤犵偞瀵ч幐鍗炩攦?= WB 闁?clearBusy tag 闁?
    // 閻庨潧瀚悺銊╁礈椤栨稒鎷?婵☆垪鈧櫕鍋ラ弶鍫濇贡閺?閻庨潧瀚悺銊╁闯?闁哥偑鍊濋崯?+1 闁?闁靛棗鍊哥换鈧銈堫嚙濠€?afterElaboration 閻犲鍟伴弫?
    // (clearBusy 缂佹棏鍨拌ぐ娑橆潰閵堝棙顦х€瑰憡褰冮崣蹇涙焾閵婏附鏆堥柛?;濞达絽绉瑰浼村捶?build 闁哄牏鍠撻弫?createReadyBank 闁告帗绋戠紓鎾诲Υ?
    val ports = prf.clearBusys
    // 宪法版: 广播寄存一拍(RegNext)——WB 扇出只剩捕获寄存器,比较在本地
    // 胞元完成。功能与组合版等价,perf 用此版。
    val bcast = ports.map(p => {
      val b = Flow(p.payload)
      b.valid := RegNext(p.valid)
      b.payload := RegNext(p.payload)
      b
    })
    for (i <- 0 until depth) {
      for (j <- 0 until rPorts) {
        val waken = bcast
          .map(b => b.valid && b.payload === queue(i).payload.rRegs(j).payload)
          .reduceBalancedTree(_ || _)
        when(waken) {
          rReadyBank(i)(j) := True
          rReadyBankNext(i)(j) := True
        }
      }
    }
  }

  override def setup(pipeline: MyCPUCore): Unit = {
    val PRF = pipeline.service(classOf[PhysRegFilePlugin])
    busyRsps = Vec(busyAddrs.map(PRF.readBusy(_)))
  }
}
