# Protects: the scan step of a Fortran source and of a C++ module source runs
# the arguments CMake computed for the compile, each as one argument, whatever
# characters it holds. The scan is a `/bin/sh` wrapper script
# (CMakeFiles/reprobuild/bin/reprobuild-cmake-action<N>_scan_...), so each
# argument is single-quoted for the shell.
#
# Before the fix, the wrapper joined the compile's arguments with spaces and
# quoted only the program and file names around them. An include directory
# holding an apostrophe ended the wrapper with "unexpected EOF while looking
# for matching `''"; a space split the argument in two; `$`, a backtick and a
# backslash were expanded, run or consumed by the shell.
#
# Defect record: reprobuild-pm
# issues/2026-11-21-reprobuild-cmake-fortran-scan-wrapper-does-not-quote-its-arguments.md
# Spec: reprobuild-pm spec/CMake-Reprobuild-Generator.md, "Compile Actions"
# ("Keep CMake-expanded command templates authoritative for command
# content") and "Dynamic Dependencies".
#
# TEST_TOOLCHAIN selects one scanner per registered test, so that each runs
# where its tools are installed:
#
#   fortran      gfortran: the Fortran scan (`gfortran -cpp -E`, then
#                `cmake -E cmake_ninja_depends`).
#   cxx-modules  clang++ and clang-scan-deps: the C++ module scan
#                (`clang-scan-deps -format=p1689 -- clang++ ...`).
#
# The scan wrapper is run for real, in the build directory, as the engine
# runs it. Nothing is mocked. One stand-in: the compilers' identities are
# forced (CMAKE_<LANG>_COMPILER_FORCED), because CMake's compiler checks run
# try_compile through the Reprobuild generator, which needs a repro engine
# this test does not run (as in long-lines-response-file.cmake).
# Identification is upstream CMake, not under test.
#
# Every source includes a header from a directory whose name holds a space,
# an apostrophe, a double quote, `$HOME` and a backtick command. (Not a
# backslash: CMake reads one in a path as a directory separator.) The Fortran
# source also expands a definition whose value holds `$HOME`, a backtick
# command and a backslash, and the test reads the preprocessed output for
# that value, byte for byte.
cmake_minimum_required(VERSION 3.29)
foreach(required IN ITEMS TEST_CMAKE TEST_BINARY_ROOT TEST_TOOLCHAIN)
  if(NOT DEFINED ${required})
    message(FATAL_ERROR "${required} is required")
  endif()
endforeach()
file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
set(source "${TEST_BINARY_ROOT}/src")
set(binary "${TEST_BINARY_ROOT}/build")
file(MAKE_DIRECTORY "${source}")

function(require)
  foreach(var IN LISTS ARGN)
    if(NOT DEFINED ${var} OR "${${var}}" STREQUAL "")
      message(FATAL_ERROR "${var} is required for TEST_TOOLCHAIN=${TEST_TOOLCHAIN}")
    endif()
  endforeach()
endfunction()

# The include directory. Each character class the shell treats specially in
# a path appears once: a space, an apostrophe, a double quote, a parameter
# expansion and a command substitution.
set(probe_dir_name [[o'brien "dq" sp $HOME `echo cmdsub`]])
set(probe_dir "${source}/${probe_dir_name}")
file(MAKE_DIRECTORY "${probe_dir}")

set(tool_env "${CMAKE_COMMAND}" -E env --unset=REPROBUILD_REPRO)
find_program(test_make NAMES make REQUIRED)

# Configures the project in `source`. PATH holds only the toolchain's
# directories (`run_path`): a reconfigure primes the provider with a `repro`
# found on PATH, which this test does not run.
function(configure)
  string(JOIN ":" path ${run_path})
  execute_process(COMMAND ${tool_env} "PATH=${path}" "${TEST_CMAKE}" -S "${source}" -B "${binary}" -G Reprobuild
    "-DCMAKE_MAKE_PROGRAM=${test_make}" ${ARGN}
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "configure failed: ${out}\n${err}")
  endif()
endfunction()

# Runs the one scan wrapper whose name matches `glob`, as the engine runs it,
# and fails unless it exits 0 and creates every file in CREATES (relative to
# the build directory). The toolchain's directories come first on PATH, ahead
# of the ambient PATH, which supplies the utilities a Nix compiler wrapper
# script runs (`basename`, ...).
function(run_scan glob)
  cmake_parse_arguments(PARSE_ARGV 1 scan "" "" "CREATES")
  file(GLOB wrappers "${binary}/CMakeFiles/reprobuild/bin/${glob}")
  list(LENGTH wrappers n)
  if(NOT n EQUAL 1)
    message(FATAL_ERROR "Expected one scan wrapper matching ${glob}; saw ${n}: ${wrappers}")
  endif()
  file(READ "${wrappers}" wrapper_text)
  string(JOIN ":" path ${run_path} "$ENV{PATH}")
  execute_process(COMMAND ${tool_env} "PATH=${path}" "${wrappers}" WORKING_DIRECTORY "${binary}"
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "The scan wrapper failed (${result}):\n${out}\n${err}\nwrapper:\n${wrapper_text}")
  endif()
  foreach(created IN LISTS scan_CREATES)
    if(NOT EXISTS "${binary}/${created}")
      message(FATAL_ERROR "The scan wrapper did not create ${created}:\n${out}\n${err}\nwrapper:\n${wrapper_text}")
    endif()
  endforeach()
  set(wrapper_text "${wrapper_text}" PARENT_SCOPE)
endfunction()

if(TEST_TOOLCHAIN STREQUAL "fortran")
  require(TEST_GFORTRAN)
  get_filename_component(gfortran_dir "${TEST_GFORTRAN}" DIRECTORY)
  set(run_path "${gfortran_dir}")
  file(WRITE "${probe_dir}/probe.inc" "integer, parameter :: probe_marker = 7\n")
  # The definition's value, which the preprocessed output must hold
  # unchanged.
  set(probe_word [[w$HOME`echo cmdsub`q\x]])
  file(WRITE "${source}/f.F90" "module f
#include \"probe.inc\"
end module f
")
  file(WRITE "${source}/CMakeLists.txt" "cmake_minimum_required(VERSION 3.29)
project(ScanQuoting Fortran)
add_library(f STATIC f.F90)
target_include_directories(f PRIVATE [[${probe_dir}]])
target_compile_definitions(f PRIVATE [[PROBE_WORD=${probe_word}]])
")
  configure("-DCMAKE_Fortran_COMPILER=${TEST_GFORTRAN}"
    -DCMAKE_Fortran_COMPILER_FORCED=TRUE -DCMAKE_Fortran_COMPILER_ID=GNU
    -DCMAKE_Fortran_COMPILER_VERSION=15.0)
  set(pp "CMakeFiles/f.dir/f.F90.o.ddi.i")
  run_scan("*_scan_f_*" CREATES "${pp}" "CMakeFiles/f.dir/f.F90.o.ddi")
  file(READ "${binary}/${pp}" preprocessed)
  # The header was found: the include directory reached gfortran whole.
  string(FIND "${preprocessed}" "probe_marker = 7" at)
  if(at EQUAL -1)
    message(FATAL_ERROR "The scan did not include probe.inc from [${probe_dir}]:\n${preprocessed}\nwrapper:\n${wrapper_text}")
  endif()
  # The definition reached gfortran unchanged: a line holding only the
  # macro's name is preprocessed to exactly its value.
  file(APPEND "${source}/f.F90" "PROBE_WORD\n")
  run_scan("*_scan_f_*" CREATES "${pp}")
  file(STRINGS "${binary}/${pp}" pp_lines)
  if(NOT probe_word IN_LIST pp_lines)
    message(FATAL_ERROR "The scan expanded PROBE_WORD to something other than [${probe_word}]:\n${pp_lines}\nwrapper:\n${wrapper_text}")
  endif()
  # The module the source defines was scanned.
  file(READ "${binary}/CMakeFiles/f.dir/f.F90.o.ddi" ddi)
  if(NOT ddi MATCHES "\"logical-name\" *: *\"f\\.mod\"")
    message(FATAL_ERROR "The scan's .ddi does not provide module f:\n${ddi}")
  endif()
elseif(TEST_TOOLCHAIN STREQUAL "cxx-modules")
  require(TEST_CLANGXX TEST_CLANG_SCAN_DEPS)
  get_filename_component(clang_dir "${TEST_CLANGXX}" DIRECTORY)
  get_filename_component(scan_deps_dir "${TEST_CLANG_SCAN_DEPS}" DIRECTORY)
  set(run_path "${clang_dir}" "${scan_deps_dir}")
  file(WRITE "${probe_dir}/probe.h" "#define PROBE_VALUE 7\n")
  file(WRITE "${source}/m.cppm" "module;
#include \"probe.h\"
export module m;
export int f() { return PROBE_VALUE; }
")
  file(WRITE "${source}/CMakeLists.txt" "cmake_minimum_required(VERSION 4.1)
project(ScanQuoting CXX)
add_library(mod STATIC)
target_compile_features(mod PUBLIC cxx_std_20)
target_sources(mod PUBLIC FILE_SET CXX_MODULES FILES m.cppm)
target_include_directories(mod PRIVATE [[${probe_dir}]])
")
  configure("-DCMAKE_CXX_COMPILER=${TEST_CLANGXX}"
    -DCMAKE_CXX_COMPILER_FORCED=TRUE -DCMAKE_CXX_COMPILER_ID=Clang
    -DCMAKE_CXX_COMPILER_FRONTEND_VARIANT=GNU
    -DCMAKE_CXX_COMPILER_VERSION=21.1
    "-DCMAKE_CXX_COMPILER_CLANG_SCAN_DEPS=${TEST_CLANG_SCAN_DEPS}"
    -DCMAKE_CXX_COMPILE_FEATURES=cxx_std_20
    -DCMAKE_CXX20_COMPILE_FEATURES=cxx_std_20
    -DCMAKE_CXX_STANDARD_COMPUTED_DEFAULT=17
    -DCMAKE_CXX_STANDARD_DEFAULT=17)
  set(ddi "CMakeFiles/mod.dir/m.cppm.o.ddi")
  run_scan("*_scan_mod_*" CREATES "${ddi}" "${ddi}.d")
  file(READ "${binary}/${ddi}" ddi_text)
  if(NOT ddi_text MATCHES "\"logical-name\" *: *\"m\"")
    message(FATAL_ERROR "The scan's .ddi does not provide module m:\n${ddi_text}")
  endif()
  # The header was found in the include directory: the depfile names it.
  file(READ "${binary}/${ddi}.d" depfile)
  string(FIND "${depfile}" "probe.h" at)
  if(at EQUAL -1)
    message(FATAL_ERROR "The scan's depfile does not name probe.h:\n${depfile}\nwrapper:\n${wrapper_text}")
  endif()
else()
  message(FATAL_ERROR "Unknown TEST_TOOLCHAIN=${TEST_TOOLCHAIN}")
endif()
