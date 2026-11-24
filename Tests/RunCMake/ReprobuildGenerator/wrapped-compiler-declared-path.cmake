# Protects: a compile action whose configured compiler is a wrapper script
# that runs a program of its own by bare name succeeds with nothing on its
# search path but the `PATH` the generated provider declares for it.
#
# The engine runs every action with the `PATH` the action declares and never
# falls back to the caller's (see `ReprobuildActionPathVar` in
# Source/cmGlobalReprobuildGenerator.cxx). Before the fix that `PATH` held
# the configured tools' own directories and nothing they run, so nixpkgs'
# wrapped `swiftc`, which runs `basename` before it sets its own `PATH`,
# died with "basename: command not found" (exit 127) and every Swift compile
# failed, where the Ninja generator, inheriting the caller's `PATH`, builds.
#
# Defect record: reprobuild-pm
# issues/2026-11-23-reprobuild-cmake-action-path-omits-what-a-wrapped-swiftc-runs.md
# Spec: reprobuild-pm spec/CMake-Reprobuild-Generator.md, "The declared
# action PATH".
#
# The wrapper below has the shape of nixpkgs' `swift-wrapper` and
# `cc-wrapper`: a `#!` script that runs a utility by bare name first, then
# names that utility's directory in a `PATH=` assignment, then execs the
# real compiler by absolute path. Its utility lives in a directory of its
# own, which no configured tool lives in, so the test fails without the fix
# on every host (a stand-in for coreutils could share the real compiler's
# directory, as `/usr/bin` does, and pass without it). The real compiler is
# the host's; nothing about it is mocked.
#
# The wrapper is run for real, with exactly the provider's declared `PATH`
# and no other environment, as the engine runs it. One stand-in: the C
# compiler's identity is forced (CMAKE_C_COMPILER_FORCED), because CMake's
# compiler checks run try_compile through the Reprobuild generator, which
# needs a repro engine this test does not run (as in
# hcr-linkgraph-declared-path.cmake). Identification is upstream CMake, not
# under test.
cmake_minimum_required(VERSION 3.29)
foreach(required IN ITEMS TEST_CMAKE TEST_BINARY_ROOT TEST_C_COMPILER)
  if(NOT DEFINED ${required})
    message(FATAL_ERROR "${required} is required")
  endif()
endforeach()
file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
set(source "${TEST_BINARY_ROOT}/src")
set(utils_dir "${TEST_BINARY_ROOT}/wrapper-utils/bin")
set(wrapper_dir "${TEST_BINARY_ROOT}/wrapped-cc/bin")
set(ambient_dir "${TEST_BINARY_ROOT}/ambient-only/bin")
set(wrapper "${wrapper_dir}/cc")
file(MAKE_DIRECTORY "${source}" "${utils_dir}" "${wrapper_dir}" "${ambient_dir}")

file(WRITE "${source}/CMakeLists.txt"
  "cmake_minimum_required(VERSION 3.20)\n"
  "project(ReprobuildWrappedCompilerPath C)\n"
  "add_executable(hello main.c)\n")
file(WRITE "${source}/main.c" "int main(void) { return 0; }\n")

# The wrapper's utility: a `basename` stand-in.
file(WRITE "${utils_dir}/wrapper-basename"
  "#!/bin/sh\n"
  "p=\"$1\"\n"
  "printf '%s\\n' \"\${p##*/}\"\n")
file(CHMOD "${utils_dir}/wrapper-basename"
  PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE
  WORLD_READ WORLD_EXECUTE)
file(WRITE "${wrapper}"
  "#!/bin/sh\n"
  "set -eu\n"
  "# Run before this wrapper sets its own PATH, as nixpkgs' swiftc runs\n"
  "# basename on the caller's.\n"
  "progName=\"$(wrapper-basename \"$0\")\"\n"
  "path_backup=\"$PATH\"\n"
  "PATH=\"${utils_dir}\"\n"
  "PATH=\"$path_backup\"\n"
  "exec '${TEST_C_COMPILER}' \"$@\"\n")
file(CHMOD "${wrapper}"
  PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE
  WORLD_READ WORLD_EXECUTE)

get_filename_component(compiler_dir "${TEST_C_COMPILER}" DIRECTORY)
find_program(test_make NAMES make REQUIRED)

# Configure with the wrapper's utility on the caller's PATH, as a developer
# shell that builds the project with Ninja would have it, plus a directory
# nothing names: the declaration must not take either from the caller.
function(configure binary)
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env --unset=REPROBUILD_REPRO
      "PATH=${ambient_dir}:${utils_dir}:${compiler_dir}"
      "${TEST_CMAKE}" -S "${source}" -B "${binary}" -G Reprobuild
      "-DCMAKE_MAKE_PROGRAM=${test_make}"
      "-DCMAKE_C_COMPILER=${wrapper}"
      -DCMAKE_C_COMPILER_FORCED=TRUE -DCMAKE_C_COMPILER_ID=GNU
      ${ARGN}
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "configure failed: ${out}\n${err}")
  endif()
endfunction()

# The declared PATH of the compile action of main.c, read from the provider.
function(read_compile_path binary out_var)
  file(STRINGS "${binary}/reprobuild.nim" lines REGEX "buildAction\\(\"compile-hello-")
  list(LENGTH lines n)
  if(NOT n EQUAL 1)
    message(FATAL_ERROR "Expected one compile-hello action; saw ${n}: ${lines}")
  endif()
  if(NOT lines MATCHES "\\(\"PATH\", \"([^\"]*)\"\\)")
    message(FATAL_ERROR "compile-hello declares no PATH: ${lines}")
  endif()
  string(REPLACE ":" ";" dirs "${CMAKE_MATCH_1}")
  set(${out_var} "${dirs}" PARENT_SCOPE)
endfunction()

# The derived declaration.
set(binary "${TEST_BINARY_ROOT}/build")
configure("${binary}")
read_compile_path("${binary}" declared_dirs)
list(JOIN declared_dirs ":" declared_path)
# `env -i` semantics through cmake: every variable unset but PATH.
execute_process(COMMAND "${CMAKE_COMMAND}" -E environment OUTPUT_VARIABLE ambient)
string(REGEX MATCHALL "(^|\n)[^=\n]+=" names "${ambient}")
set(unsets)
foreach(name IN LISTS names)
  string(REGEX REPLACE "^\n|=$" "" name "${name}")
  if(NOT name STREQUAL "" AND NOT name STREQUAL "PATH")
    list(APPEND unsets "--unset=${name}")
  endif()
endforeach()
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E env ${unsets} "PATH=${declared_path}"
    "${wrapper}" -c "${source}/main.c" -o "${TEST_BINARY_ROOT}/main.o"
  WORKING_DIRECTORY "${binary}"
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0 OR NOT EXISTS "${TEST_BINARY_ROOT}/main.o")
  message(FATAL_ERROR "The wrapped compiler failed (${result}) under the declared PATH ${declared_path}:\n${out}\n${err}")
endif()

# The declaration holds what the wrapper runs, and nothing from the caller.
foreach(dir IN ITEMS "${wrapper_dir}" "${utils_dir}" "${compiler_dir}")
  if(NOT dir IN_LIST declared_dirs)
    message(FATAL_ERROR "The declared PATH lacks ${dir}, which the wrapped compiler runs from: ${declared_path}")
  endif()
endforeach()
if("${ambient_dir}" IN_LIST declared_dirs)
  message(FATAL_ERROR "The declared PATH took ${ambient_dir} from the caller's PATH: ${declared_path}")
endif()
# The configured compiler's own directory comes first: a directory a wrapper
# names must never shadow a tool CMake resolved.
list(FIND declared_dirs "${wrapper_dir}" wrapper_at)
list(FIND declared_dirs "${utils_dir}" utils_at)
if(NOT wrapper_at LESS utils_at)
  message(FATAL_ERROR "The wrapper's directory is not ahead of what it names: ${declared_path}")
endif()

# REPROBUILD_CMAKE_ACTION_PATH is taken verbatim: a project that spells the
# search path out owns it, and nothing is read from its tools.
set(explicit_binary "${TEST_BINARY_ROOT}/build-explicit")
configure("${explicit_binary}" "-DREPROBUILD_CMAKE_ACTION_PATH=${wrapper_dir}")
read_compile_path("${explicit_binary}" explicit_dirs)
if(NOT explicit_dirs STREQUAL "${wrapper_dir}")
  message(FATAL_ERROR "REPROBUILD_CMAKE_ACTION_PATH was not taken verbatim: ${explicit_dirs}")
endif()
