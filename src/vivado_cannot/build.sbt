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
