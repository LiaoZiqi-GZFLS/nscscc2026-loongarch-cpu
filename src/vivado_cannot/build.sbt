ThisBuild / version := "1.0"
ThisBuild / scalaVersion := "2.12.16"
ThisBuild / organization := "NOP"

val spinalVersion = "1.8.1"

lazy val projectname = project.in(file("."))
  .settings(
    Compile / scalaSource := baseDirectory.value / "src",
    Test / scalaSource := baseDirectory.value / "test",
    libraryDependencies ++= Seq(
        "com.github.spinalhdl" %% "spinalhdl-core" % spinalVersion, 
        "com.github.spinalhdl" %% "spinalhdl-lib" % spinalVersion, 
        "com.github.scopt" %% "scopt" % "4.0.1",
        "com.github.spinalhdl" %% "spinalhdl-sim" % spinalVersion % Test,
        "org.scalatest" %% "scalatest" % "3.2.16" % Test,
        compilerPlugin("com.github.spinalhdl" %% "spinalhdl-idsl-plugin" % spinalVersion),
        compilerPlugin("org.scalamacros" % "paradise" % "2.1.1" cross CrossVersion.full)
    )
  )

// fork := true
// stage1: SpinalSim 的 Verilator 后端要求在独立 JVM 中运行;add-opens 供
// SpinalHDL 反射在 Java 17 下工作(与 SPEC §0 的 elaborate 命令一致)。
// javaHome: 系统 JRE 缺 jni.h,Verilator C++ 包装编译需要 JDK 头文件;
// NOP_SIM_JDK_HOME 指向补了 include/jni.h 的 JDK 目录(默认回退系统 JVM)。
Test / fork := true
Test / javaHome := sys.env.get("NOP_SIM_JDK_HOME").map(file(_))
Test / javaOptions ++= Seq(
  "--add-opens", "java.base/java.lang=ALL-UNNAMED",
  "--add-opens", "java.base/java.util=ALL-UNNAMED",
  "--add-opens", "java.base/java.lang.reflect=ALL-UNNAMED"
)
