# Protects: the HCR linkgraph action (`hcr-linkgraph-<target>`), a
# `/bin/sh` wrapper the generator itself writes
# (CMakeFiles/reprobuild/bin/reprobuild-cmake-action<N>_hcr_linkgraph_<target>),
# succeeds with nothing on its search path but the `PATH` the generated
# provider declares for it, and writes its evidence file.
#
# The engine runs every action with the `PATH` the action declares and never
# falls back to the caller's (see `ReprobuildActionPathVar` in
# Source/cmGlobalReprobuildGenerator.cxx). That `PATH` holds the wrapper
# directory, the toolchain's and binutils' directories and cmake's own
# `bin`, and no coreutils. Before the fix the wrapper ran `mkdir`, `dirname`,
# `head` and `mv`, so under the declared `PATH` it died with
# "dirname: command not found" (exit 127) and the HCR build failed.
#
# Defect record: reprobuild-pm
# issues/2026-11-23-reprobuild-cmake-hcr-linkgraph-action-calls-coreutils-absent-from-the-declared-action-path.md
# Spec: reprobuild-pm spec/CMake-Reprobuild-Generator.md, "Hot Code
# Reloading" (helper actions the generator writes).
#
# The wrapper is run for real, in the build directory, with exactly the
# provider's declared `PATH` and no other environment, as the engine runs
# it. Nothing is mocked. Two stand-ins:
# - The C compiler's identity is forced (CMAKE_C_COMPILER_FORCED), because
#   CMake's compiler checks run try_compile through the Reprobuild generator,
#   which needs a repro engine this test does not run (as in
#   scan-wrapper-quoting.cmake). Identification is upstream CMake, not under
#   test.
# - The executable the action reads is built by running the compiler
#   directly, under the ambient `PATH`, rather than through the generated
#   compile and link actions: the linkgraph action only reads the binary, and
#   how a Nix compiler wrapper finds its own utilities is not under test here.
cmake_minimum_required(VERSION 3.29)
foreach(required IN ITEMS TEST_CMAKE TEST_BINARY_ROOT TEST_C_COMPILER)
  if(NOT DEFINED ${required})
    message(FATAL_ERROR "${required} is required")
  endif()
endforeach()
file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
set(source "${TEST_BINARY_ROOT}/src")
set(binary "${TEST_BINARY_ROOT}/build")
file(MAKE_DIRECTORY "${source}")

file(WRITE "${source}/CMakeLists.txt"
  "cmake_minimum_required(VERSION 3.20)\n"
  "project(ReprobuildHcrLinkgraphPath C)\n"
  "add_executable(hcrapp main.c helper.c)\n"
  "set_property(TARGET hcrapp PROPERTY REPROBUILD_HCR ON)\n")
file(WRITE "${source}/helper.c"
  "int hcr_helper(int value) { return value + 2; }\n")
# More than 200 symbols and 400 ELF symbol-table lines, so the wrapper's
# listing bounds are exercised rather than trivially met.
set(main_c "int hcr_helper(int value);\n")
foreach(n RANGE 1 450)
  string(APPEND main_c "int hcr_filler_${n}(int v) { return v + ${n}; }\n")
endforeach()
string(APPEND main_c "int main(void) { return hcr_helper(40) == 42 ? 0 : 1; }\n")
file(WRITE "${source}/main.c" "${main_c}")

# TEST_ACTION_PATH_EXTRA (optional) is appended to the declared PATH through
# REPROBUILD_CMAKE_ACTION_PATH_EXTRA. Pointed at a coreutils directory, it
# stands in for a host whose toolchain directory also holds coreutils, which
# exercises the minimal-PATH run at the end of this file.
set(extra_path_arg)
if(DEFINED TEST_ACTION_PATH_EXTRA)
  set(extra_path_arg "-DREPROBUILD_CMAKE_ACTION_PATH_EXTRA=${TEST_ACTION_PATH_EXTRA}")
endif()
get_filename_component(compiler_dir "${TEST_C_COMPILER}" DIRECTORY)
find_program(test_make NAMES make REQUIRED)
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E env --unset=REPROBUILD_REPRO
    "PATH=${compiler_dir}"
    "${TEST_CMAKE}" -S "${source}" -B "${binary}" -G Reprobuild
    "-DCMAKE_MAKE_PROGRAM=${test_make}"
    "-DCMAKE_C_COMPILER=${TEST_C_COMPILER}"
    -DCMAKE_C_COMPILER_FORCED=TRUE -DCMAKE_C_COMPILER_ID=GNU
    -DCMAKE_REPROBUILD_HCR=OFF
    ${extra_path_arg}
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "configure failed: ${out}\n${err}")
endif()

# The linkgraph action's declared input (the binary it reads) and its
# declared `PATH`, read from the generated provider.
file(STRINGS "${binary}/reprobuild.nim" lines REGEX "buildAction\\(\"hcr-linkgraph-hcrapp\"")
list(LENGTH lines n)
if(NOT n EQUAL 1)
  message(FATAL_ERROR "Expected one hcr-linkgraph-hcrapp action; saw ${n}: ${lines}")
endif()
if(NOT lines MATCHES "inputs = @\\[\"([^\"]+)\"\\]")
  message(FATAL_ERROR "hcr-linkgraph-hcrapp declares no single input: ${lines}")
endif()
set(linked "${CMAKE_MATCH_1}")
if(NOT lines MATCHES "env = @\\[\\(\"PATH\", \"([^\"]+)\"\\)\\]")
  message(FATAL_ERROR "hcr-linkgraph-hcrapp declares no PATH: ${lines}")
endif()
set(declared_path "${CMAKE_MATCH_1}")
if(NOT IS_ABSOLUTE "${linked}")
  set(linked "${binary}/${linked}")
endif()

execute_process(
  COMMAND "${TEST_C_COMPILER}" -g -o "${linked}" "${source}/main.c" "${source}/helper.c"
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "building the executable failed: ${out}\n${err}")
endif()

file(GLOB wrappers "${binary}/CMakeFiles/reprobuild/bin/reprobuild-cmake-action*_hcr_linkgraph_hcrapp")
list(LENGTH wrappers n)
if(NOT n EQUAL 1)
  message(FATAL_ERROR "Expected one linkgraph wrapper; saw ${n}: ${wrappers}")
endif()
file(READ "${wrappers}" wrapper_text)

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
  COMMAND "${CMAKE_COMMAND}" -E env ${unsets} "PATH=${declared_path}" "${wrappers}"
  WORKING_DIRECTORY "${binary}"
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "The linkgraph wrapper failed (${result}) under the declared PATH ${declared_path}:\n${out}\n${err}\nwrapper:\n${wrapper_text}")
endif()

file(GLOB linkgraphs "${binary}/CMakeFiles/reprobuild/hcr/*.linkgraph")
list(LENGTH linkgraphs n)
if(NOT n EQUAL 1)
  message(FATAL_ERROR "Expected one linkgraph file; saw ${n}: ${linkgraphs}")
endif()
file(GLOB leftovers "${binary}/CMakeFiles/reprobuild/hcr/*.tmp")
if(leftovers)
  message(FATAL_ERROR "The linkgraph wrapper left its temporary file: ${leftovers}")
endif()
# Compared as text, not as CMake lists: a list cannot hold a leading empty
# line, and `readelf -Ws` starts with one.
file(READ "${linkgraphs}" evidence)

# The text between the line `begin` and the line `end` of the evidence.
function(section begin end out_var)
  string(FIND "${evidence}" "\n${begin}\n" at)
  if(at EQUAL -1)
    message(FATAL_ERROR "The linkgraph evidence has no ${begin} section:\n${evidence}")
  endif()
  string(LENGTH "\n${begin}\n" skip)
  math(EXPR at "${at} + ${skip}")
  string(SUBSTRING "${evidence}" ${at} -1 rest)
  string(FIND "${rest}" "${end}\n" stop)
  if(NOT stop EQUAL 0)
    string(FIND "${rest}" "\n${end}\n" stop)
    if(stop EQUAL -1)
      message(FATAL_ERROR "The linkgraph evidence's ${begin} section has no ${end}:\n${evidence}")
    endif()
    math(EXPR stop "${stop} + 1")
  endif()
  string(SUBSTRING "${rest}" 0 ${stop} body)
  set(${out_var} "${body}" PARENT_SCOPE)
endfunction()

# The first `count` lines of `text`, each with its newline.
function(first_lines text count out_var)
  set(head "")
  foreach(i RANGE 1 ${count})
    string(FIND "${text}" "\n" nl)
    if(nl EQUAL -1)
      string(APPEND head "${text}")
      break()
    endif()
    math(EXPR nl "${nl} + 1")
    string(SUBSTRING "${text}" 0 ${nl} line)
    string(SUBSTRING "${text}" ${nl} -1 text)
    string(APPEND head "${line}")
  endforeach()
  set(${out_var} "${head}" PARENT_SCOPE)
endfunction()

if(NOT evidence MATCHES "^schema_id=reprobuild\\.hcr\\.linkgraph-evidence\\.v1\ntarget=hcrapp\nbinary=")
  message(FATAL_ERROR "Unexpected evidence header:\n${evidence}")
endif()

# The symbol listings are bounded: the first 200 lines of `nm -an` and the
# first 400 of `readelf -Ws`, each line verbatim. The reference listings run
# in the wrapper's environment, because `nm` sorts by the locale's collation.
set(wrapper_env "${CMAKE_COMMAND}" -E env ${unsets} "PATH=${declared_path}")
foreach(listing IN ITEMS "nm;-an;symbols;200" "readelf;-Ws;elf_symbols;400")
  list(GET listing 0 tool)
  list(GET listing 1 flag)
  list(GET listing 2 name)
  list(GET listing 3 bound)
  execute_process(COMMAND ${wrapper_env} ${tool} ${flag} "${linked}"
    RESULT_VARIABLE result OUTPUT_VARIABLE full)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "${tool} ${flag} failed (${result}) under the declared PATH")
  endif()
  string(REGEX MATCHALL "\n" newlines "${full}")
  list(LENGTH newlines total)
  if(NOT total GREATER bound)
    message(FATAL_ERROR "${tool} ${flag} printed ${total} lines, too few to test its bound of ${bound}")
  endif()
  first_lines("${full}" ${bound} expected)
  section(${name}_begin ${name}_end actual)
  if(NOT actual STREQUAL expected)
    message(FATAL_ERROR "The ${name} section is not the first ${bound} lines of ${tool} ${flag}:\n${actual}")
  endif()
endforeach()

# Where the declared PATH happens to provide coreutils (a toolchain installed
# in /usr/bin, say), the run above cannot tell a wrapper that needs them from
# one that does not. Run the wrapper again on a PATH holding only the tools
# the wrapper is allowed to need, `nm` and `readelf`, taken from the declared
# PATH, so the test discriminates on every host.
string(REPLACE ":" ";" declared_dirs "${declared_path}")
set(coreutils_on_declared_path)
foreach(tool IN ITEMS mkdir dirname head mv)
  unset(found CACHE)
  unset(found)
  find_program(found NAMES ${tool} PATHS ${declared_dirs} NO_DEFAULT_PATH NO_CACHE)
  if(found)
    list(APPEND coreutils_on_declared_path "${found}")
  endif()
endforeach()
if(DEFINED TEST_ACTION_PATH_EXTRA AND NOT coreutils_on_declared_path)
  message(FATAL_ERROR "TEST_ACTION_PATH_EXTRA=${TEST_ACTION_PATH_EXTRA} put no "
    "coreutils on the declared PATH ${declared_path}, so the minimal-PATH run "
    "would not be exercised")
endif()
if(coreutils_on_declared_path)
  message(STATUS "The declared PATH provides ${coreutils_on_declared_path}; "
    "also running the wrapper with only nm and readelf on PATH")
  set(minimal "${TEST_BINARY_ROOT}/minimal-path")
  file(MAKE_DIRECTORY "${minimal}")
  foreach(tool IN ITEMS nm readelf)
    unset(found)
    find_program(found NAMES ${tool} PATHS ${declared_dirs} NO_DEFAULT_PATH NO_CACHE REQUIRED)
    file(CREATE_LINK "${found}" "${minimal}/${tool}" SYMBOLIC)
  endforeach()
  file(REMOVE ${linkgraphs})
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env ${unsets} "PATH=${minimal}" "${wrappers}"
    WORKING_DIRECTORY "${binary}"
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "The linkgraph wrapper failed (${result}) with only nm and readelf on PATH:\n${out}\n${err}\nwrapper:\n${wrapper_text}")
  endif()
  file(READ "${linkgraphs}" minimal_evidence)
  # `file` is optional and is not on the minimal PATH; drop its section.
  string(REGEX REPLACE "\nfile_begin\n.*\nfile_end\n" "\n" evidence_wo_file "${evidence}")
  if(NOT minimal_evidence STREQUAL evidence_wo_file)
    message(FATAL_ERROR "The linkgraph evidence differs with only nm and readelf on PATH:\n${minimal_evidence}")
  endif()
endif()
