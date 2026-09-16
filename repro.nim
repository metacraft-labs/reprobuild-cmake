import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package reprobuild_cmake:
  defaultToolProvisioning "path"

  executable cmake:
    name: "cmake"

  build:
    # Compile cmake by running make inside the pre-configured build directory.
    #
    # `sh.shell` is the ONLY action-building entry point this module
    # exports; `sh.runAction` (with `argv` / `inputs` / `outputs`) no
    # longer exists and this recipe failed to compile against it with
    # `undeclared identifier: 'runAction'`. `command` is handed to
    # `sh -c` as one string -- words split out into `args` would land in
    # the shell's positional parameters, not on make's command line.
    #
    # The dependency policy is left at `shell`'s default,
    # `automaticMonitorPolicy()`: make is an opaque tool here and the
    # engine must observe its real read-set rather than trust
    # `extraInputs`.
    discard sh.shell(
      command = "make -C build -j4",
      actionId = "reprobuild-cmake.build",
      extraInputs = @["CMakeLists.txt"],
      extraOutputs = @["build/bin/cmake"]
    )
