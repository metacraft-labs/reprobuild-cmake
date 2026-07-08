import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package reprobuild_cmake:
  defaultToolProvisioning "path"

  executable cmake:
    name: "cmake"

  build:
    # Compile cmake by running make inside the pre-configured build directory
    discard sh.runAction(
      actionId = "reprobuild-cmake.build",
      argv = @["make", "-C", "build", "-j4"],
      inputs = @["CMakeLists.txt"],
      outputs = @["build/bin/cmake"]
    )
