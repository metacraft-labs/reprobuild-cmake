# Protects: a compile or link line too long for the command line (over 2048
# characters) is passed in the response file the action declares. The process
# is started with that file, in the spelling its program reads (`@<rsp>`;
# nvcc's `--options-file <rsp>`), and the file quotes each argument by the
# rules that program reads it with. A program that reads no response file
# keeps its full line and declares none: a link whose response-file flag is
# defined empty, or hands the file to the linker (`-Wl,@`), which does not
# accept the driver's options the generator would move into it. (A CUDA link
# is another; no CUDA project configures under this generator, see below.)
# The response file is named after the action id, which does not move when a
# target is added to the project.
#
# Before the fix, a compile action wrote and declared `<Var>-<n>.rsp` but
# started the compiler with the full line it had copied before, so the
# declared input was never read; a CUDA or Swift link did the same.
#
# Defect record: reprobuild-pm
# issues/2026-11-20-reprobuild-cmake-long-lines-bypass-their-response-file.md
# Spec: reprobuild-pm spec/CMake-Reprobuild-Generator.md, "Response Files".
#
# TEST_TOOLCHAIN selects one compiler family per registered test, so that
# each runs where its compiler is installed:
#
#   gnu       gcc, g++ and gfortran: C, CXX and Fortran compiles, a C++
#             link, and two C links that read no response file.
#   clang     clang and clang++ (GNU frontend): C and CXX compiles, a link.
#   clang-cl  clang-cl (MSVC frontend): C compiles, Windows quoting.
#   ispc      ispc compiles, linked by a C compiler.
#   swift     a swiftc link.
#
# Not covered: CUDA. CMake's CMakeDetermineCUDACompiler.cmake refuses every
# generator but the Makefile, Ninja, FASTBuild and Visual Studio ones, so no
# CUDA project configures under this generator (reprobuild-pm
# issues/2026-11-21-reprobuild-cmake-cannot-enable-cuda.md). nvcc reads its
# `--options-file` by GCC's rules (measured with nvcc 12.9), so the generator
# would quote for it as for gcc.
#
# Each compile and link named above is run for real, from the argv the
# generated provider holds, in the build directory, as the engine would run
# it. Nothing is mocked. Two stand-ins:
# - The compilers' identities are forced (CMAKE_<LANG>_COMPILER_FORCED)
#   because CMake's compiler checks run try_compile through the Reprobuild
#   generator, which needs a repro engine this argv test does not run (as in
#   msvc-frontend-driver.cmake). Identification is upstream CMake, not under
#   test.
# - Actions run directly rather than through repro, which would add an engine
#   build and nothing this test asserts: the argv and the files are the
#   generator's output, and running them is what the engine does with them.
#
# The include directory each compile names contains a space, an apostrophe
# and a double quote, and the compiles of C and C++ carry a
# definition holding a backslash. A response file quoted by the wrong rules
# loses the header or changes the definition, and the compile fails.
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

# Forty include (or library) directories with long names: about 3,500
# characters of line, well over the generator's 2048-character threshold.
set(long_dirs)
foreach(n RANGE 1 40)
  list(APPEND long_dirs "${source}/a_directory_with_a_deliberately_long_name_for_the_response_file_${n}")
endforeach()
file(MAKE_DIRECTORY ${long_dirs})
string(REPLACE ";" "]] [[" long_dirs_cmake "[[${long_dirs}]]")

# The directory with the header every compile includes.
set(probe_dir_name [[in c'l "d" sp]])
set(probe_dir "${source}/${probe_dir_name}")
file(MAKE_DIRECTORY "${probe_dir}")
file(WRITE "${probe_dir}/probe.h" "#define PROBE_VALUE 7\n")
# The definition's value is the C string literal "x\\y": three characters.
set(probe_definition [[PROBE_TEXT="x\\y"]])
set(c_source [[
#include "probe.h"
typedef char probe_text_has_one_backslash[sizeof(PROBE_TEXT) == 4 ? 1 : -1];
int probe_value(void) { return PROBE_VALUE; }
]])

function(json_array_to_list json out_var)
  string(JSON length LENGTH "${json}")
  set(items)
  if(length GREATER 0)
    math(EXPR last "${length} - 1")
    foreach(i RANGE 0 ${last})
      string(JSON item GET "${json}" ${i})
      list(APPEND items "${item}")
    endforeach()
  endif()
  set(${out_var} "${items}" PARENT_SCOPE)
endfunction()

# Configures the project in `source` with the given cache entries and reads
# every action of the generated provider: its argv (the inline argv, or the
# arguments a tool-profile call passes after its program) and its declared
# inputs. PATH holds only the toolchain's directories (`run_path`, set by
# each toolchain below): a reconfigure primes the provider with a `repro`
# found on PATH, which this test does not run.
set(tool_env "${CMAKE_COMMAND}" -E env --unset=REPROBUILD_REPRO)
find_program(test_make NAMES make REQUIRED)
function(configure_and_read)
  string(JOIN ":" path ${run_path})
  execute_process(COMMAND ${tool_env} "PATH=${path}" "${TEST_CMAKE}" -S "${source}" -B "${binary}" -G Reprobuild
    "-DCMAKE_MAKE_PROGRAM=${test_make}" ${ARGN}
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "configure failed: ${out}\n${err}")
  endif()
  file(STRINGS "${binary}/reprobuild.nim" lines REGEX "buildAction\\(\"(compile|link)-")
  set(ids)
  foreach(line IN LISTS lines)
    if(line MATCHES "buildAction\\(\"([^\"]+)\", inlineExecCall\\(@(\\[.*\\])(, cwd = \"[^\"]*\")?\\), deps = @\\[[^]]*\\], inputs = @(\\[[^]]*\\]), outputs = ")
      set(kind inline)
      set(inputs_json "${CMAKE_MATCH_4}")
    elseif(line MATCHES "buildAction\\(\"([^\"]+)\", publicCliCall\\(.*cliArgSeq\\(\"args\", @(\\[.*\\]), cpkPositional, 0\\)\\]\\), deps = @\\[[^]]*\\], inputs = @(\\[[^]]*\\]), outputs = ")
      set(kind tool)
      set(inputs_json "${CMAKE_MATCH_3}")
    else()
      message(FATAL_ERROR "Unreadable action: ${line}")
    endif()
    set(id "${CMAKE_MATCH_1}")
    json_array_to_list("${CMAKE_MATCH_2}" argv)
    json_array_to_list("${inputs_json}" inputs)
    set_property(GLOBAL PROPERTY kind_${id} "${kind}")
    set_property(GLOBAL PROPERTY argv_${id} "${argv}")
    set_property(GLOBAL PROPERTY inputs_${id} "${inputs}")
    list(APPEND ids "${id}")
  endforeach()
  set_property(GLOBAL PROPERTY action_ids "${ids}")
endfunction()

# The ids of the configured actions whose id matches `regex`; fails unless
# there are `count` of them.
function(actions_matching regex count out_var)
  get_property(ids GLOBAL PROPERTY action_ids)
  list(FILTER ids INCLUDE REGEX "${regex}")
  list(LENGTH ids n)
  if(NOT n EQUAL count)
    message(FATAL_ERROR "Expected ${count} actions matching ${regex}; saw ${n}: ${ids}")
  endif()
  set(${out_var} "${ids}" PARENT_SCOPE)
endfunction()

# Asserts that action `id` starts its program with exactly `before` followed
# by its response file, which is named after the id, exists and is a
# declared input; `program` is the inline argv's first element, or empty for
# a tool-profile call.
function(expect_response_file id program prefix)
  get_property(kind GLOBAL PROPERTY kind_${id})
  get_property(argv GLOBAL PROPERTY argv_${id})
  get_property(inputs GLOBAL PROPERTY inputs_${id})
  set(rsp "CMakeFiles/reprobuild/rsp/${id}.rsp")
  set(expected ${program} ${ARGN} "${prefix}${rsp}")
  if(NOT argv STREQUAL expected)
    message(FATAL_ERROR "${id} is not started with its response file.\n  expected: ${expected}\n  argv:     ${argv}")
  endif()
  if(NOT rsp IN_LIST inputs)
    message(FATAL_ERROR "${id} does not declare its response file ${rsp}: ${inputs}")
  endif()
  if(NOT EXISTS "${binary}/${rsp}")
    message(FATAL_ERROR "${id}'s response file ${rsp} was not written.")
  endif()
endfunction()

# Asserts that action `id` keeps its full line and declares and writes no
# response file.
function(expect_no_response_file id)
  get_property(argv GLOBAL PROPERTY argv_${id})
  get_property(inputs GLOBAL PROPERTY inputs_${id})
  string(JOIN " " line ${argv})
  string(LENGTH "${line}" line_length)
  if(line_length LESS 2048)
    message(FATAL_ERROR "${id}'s line is ${line_length} characters, too short to test: ${argv}")
  endif()
  foreach(item IN LISTS argv inputs)
    if(item MATCHES "\\.rsp$")
      message(FATAL_ERROR "${id} names a response file its program does not read: ${item}\n  argv: ${argv}\n  inputs: ${inputs}")
    endif()
  endforeach()
  file(GLOB rsp_files "${binary}/CMakeFiles/reprobuild/rsp/${id}*")
  if(rsp_files)
    message(FATAL_ERROR "${id} wrote a response file its program does not read: ${rsp_files}")
  endif()
endfunction()

# Runs action `id` in the build directory. A tool-profile call's arguments
# are given to `program`.
function(run_action id)
  cmake_parse_arguments(PARSE_ARGV 1 run "" "PROGRAM;CREATES" "PATH")
  get_property(argv GLOBAL PROPERTY argv_${id})
  get_property(kind GLOBAL PROPERTY kind_${id})
  if(kind STREQUAL "tool")
    set(argv "${run_PROGRAM}" ${argv})
  endif()
  string(JOIN ":" path ${run_PATH})
  execute_process(COMMAND ${tool_env} "PATH=${path}" ${argv} WORKING_DIRECTORY "${binary}"
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT result EQUAL 0 OR (run_CREATES AND NOT EXISTS "${binary}/${run_CREATES}"))
    set(rsp_text "")
    if(EXISTS "${binary}/CMakeFiles/reprobuild/rsp/${id}.rsp")
      file(READ "${binary}/CMakeFiles/reprobuild/rsp/${id}.rsp" rsp_text)
    endif()
    message(FATAL_ERROR "${id} failed (${result}):\n${argv}\n${out}\n${err}\nresponse file:\n${rsp_text}")
  endif()
endfunction()

# The project's text: `languages`, then the body.
function(write_project languages body)
  file(WRITE "${source}/CMakeLists.txt" "cmake_minimum_required(VERSION 3.29)
project(LongLines ${languages})
${body}
")
endfunction()

set(include_body "
set(long_dirs ${long_dirs_cmake})
set(probe_dir [[${probe_dir}]])
")

if(TEST_TOOLCHAIN STREQUAL "gnu")
  require(TEST_GCC TEST_GXX TEST_GFORTRAN)
  get_filename_component(gcc_dir "${TEST_GCC}" DIRECTORY)
  get_filename_component(gfortran_dir "${TEST_GFORTRAN}" DIRECTORY)
  set(run_path "${gcc_dir}" "${gfortran_dir}")
  file(WRITE "${source}/unit.c" "${c_source}")
  file(WRITE "${source}/unit.cpp" "${c_source}")
  file(WRITE "${source}/main.c" "int main(void) { return 0; }\n")
  file(WRITE "${source}/unit.f90" "subroutine unit\nend subroutine\n")
  write_project("C CXX Fortran" "${include_body}
add_executable(app main.c unit.c unit.cpp)
target_include_directories(app PRIVATE \${long_dirs} \"\${probe_dir}\")
target_compile_definitions(app PRIVATE [[${probe_definition}]])
target_link_directories(app PRIVATE \${long_dirs})
add_library(funit STATIC unit.f90)
target_include_directories(funit PRIVATE \${long_dirs})
add_subdirectory(forwards)
add_subdirectory(reads_none)
")
  # Two C links whose driver reads no response file of the generator's: one
  # whose flag hands the file to the linker (`-Wl,@`, as Windows-GNU.cmake
  # sets for GCC 3), which would get the driver's options (`-static-libgcc`,
  # which ld refuses), and one whose flag is defined empty. Each keeps its
  # full line.
  foreach(dir IN ITEMS forwards reads_none)
    set(flag "")
    if(dir STREQUAL "forwards")
      set(flag "-Wl,@")
    endif()
    file(MAKE_DIRECTORY "${source}/${dir}")
    file(WRITE "${source}/${dir}/CMakeLists.txt" "
set(CMAKE_C_RESPONSE_FILE_LINK_FLAG \"${flag}\")
add_executable(${dir} \${CMAKE_CURRENT_SOURCE_DIR}/../main.c)
target_link_directories(${dir} PRIVATE \${long_dirs})
target_link_options(${dir} PRIVATE -static-libgcc)
")
  endforeach()
  set(forced)
  set(langs C CXX Fortran)
  set(compilers TEST_GCC TEST_GXX TEST_GFORTRAN)
  foreach(lang compiler IN ZIP_LISTS langs compilers)
    list(APPEND forced "-DCMAKE_${lang}_COMPILER=${${compiler}}"
      -DCMAKE_${lang}_COMPILER_FORCED=TRUE -DCMAKE_${lang}_COMPILER_ID=GNU
      -DCMAKE_${lang}_COMPILER_VERSION=15.0)
  endforeach()
  configure_and_read(${forced})

  actions_matching("^compile-app-.*unit\\.(c|cpp)\\.o$" 2 compiles)
  foreach(id IN LISTS compiles)
    if(id MATCHES "cpp")
      set(compiler "${TEST_GXX}")
    else()
      set(compiler "${TEST_GCC}")
    endif()
    expect_response_file("${id}" "${compiler}" "@")
    run_action("${id}" PATH ${run_path})
  endforeach()
  actions_matching("^compile-app-.*main\\.c\\.o$" 1 main_compile)
  run_action("${main_compile}" PATH ${run_path})
  # Fortran compiles through its tool profile, which runs gfortran with the
  # arguments: `@<rsp>`. The action is not run: it compiles the scan step's
  # `<obj>.ddi.i`, which gfortran takes for preprocessed C whatever the
  # response file says (reprobuild-pm issues/2026-11-21-reprobuild-cmake-
  # fortran-compile-hands-gfortran-a-file-it-reads-as-c.md). gfortran reads
  # its response file with GCC's reader, run above through gcc and g++.
  actions_matching("^compile-funit-.*unit\\.f90\\.o$" 1 fortran)
  expect_response_file("${fortran}" "" "@")
  file(STRINGS "${binary}/CMakeFiles/reprobuild/rsp/${fortran}.rsp" fortran_rsp)
  list(GET fortran_rsp -1 fortran_input)
  if(NOT fortran_input MATCHES "unit\\.f90\\.o\\.ddi\\.i$")
    message(FATAL_ERROR "The Fortran response file does not hold the compile's line: ${fortran_rsp}")
  endif()
  # The C++ unit makes C++ the link language.
  expect_response_file(link-app "${TEST_GXX}" "@")
  run_action(link-app PATH ${run_path} CREATES app)
  foreach(dir IN ITEMS forwards reads_none)
    actions_matching("^compile-${dir}-" 1 dir_compile)
    run_action("${dir_compile}" PATH ${run_path})
    expect_no_response_file("link-${dir}")
    run_action("link-${dir}" PATH ${run_path} CREATES "${dir}/${dir}")
  endforeach()

elseif(TEST_TOOLCHAIN STREQUAL "clang")
  require(TEST_CLANG TEST_CLANGXX)
  get_filename_component(clang_dir "${TEST_CLANG}" DIRECTORY)
  set(run_path "${clang_dir}")
  file(WRITE "${source}/unit.c" "${c_source}")
  file(WRITE "${source}/unit.cpp" "${c_source}")
  file(WRITE "${source}/main.c" "int main(void) { return 0; }\n")
  write_project("C CXX" "${include_body}
add_executable(app main.c unit.c unit.cpp)
target_include_directories(app PRIVATE \${long_dirs} \"\${probe_dir}\")
target_compile_definitions(app PRIVATE [[${probe_definition}]])
target_link_directories(app PRIVATE \${long_dirs} \"\${probe_dir}\")
")
  set(forced)
  set(langs C CXX)
  set(compilers TEST_CLANG TEST_CLANGXX)
  foreach(lang compiler IN ZIP_LISTS langs compilers)
    list(APPEND forced "-DCMAKE_${lang}_COMPILER=${${compiler}}"
      -DCMAKE_${lang}_COMPILER_FORCED=TRUE -DCMAKE_${lang}_COMPILER_ID=Clang
      -DCMAKE_${lang}_COMPILER_VERSION=18.1
      -DCMAKE_${lang}_COMPILER_FRONTEND_VARIANT=GNU)
  endforeach()
  configure_and_read(${forced})
  actions_matching("^compile-app-.*\\.o$" 3 compiles)
  foreach(id IN LISTS compiles)
    if(id MATCHES "cpp")
      set(compiler "${TEST_CLANGXX}")
    else()
      set(compiler "${TEST_CLANG}")
    endif()
    if(NOT id MATCHES "main")
      expect_response_file("${id}" "${compiler}" "@")
    endif()
    run_action("${id}" PATH ${run_path})
  endforeach()
  # The C++ unit makes C++ the link language.
  expect_response_file(link-app "${TEST_CLANGXX}" "@")
  run_action(link-app PATH ${run_path} CREATES app)

elseif(TEST_TOOLCHAIN STREQUAL "clang-cl")
  # clang-cl cross-compiles for Windows without an SDK: the units include
  # only the probe header.
  require(TEST_CLANG_CL)
  set(tool_path "${TEST_BINARY_ROOT}/tools")
  file(MAKE_DIRECTORY "${tool_path}")
  set(run_path "${tool_path}")
  # clang selects its cl mode from the name it is run as.
  set(clang_cl "${tool_path}/clang-cl")
  file(CREATE_LINK "${TEST_CLANG_CL}" "${clang_cl}" SYMBOLIC)
  foreach(tool IN ITEMS lld-link llvm-lib llvm-rc)
    find_program(tool_${tool} NAMES ${tool} REQUIRED)
    file(CREATE_LINK "${tool_${tool}}" "${tool_path}/${tool}" SYMBOLIC)
  endforeach()
  file(WRITE "${source}/unit.c" "${c_source}")
  write_project(C "${include_body}
add_library(st STATIC unit.c)
target_include_directories(st PRIVATE \${long_dirs} \"\${probe_dir}\")
target_compile_definitions(st PRIVATE [[${probe_definition}]])
")
  configure_and_read(
    -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=AMD64
    "-DCMAKE_AR=${tool_path}/llvm-lib"
    "-DCMAKE_LINKER=${tool_path}/lld-link"
    "-DCMAKE_RC_COMPILER=${tool_path}/llvm-rc"
    "-DCMAKE_C_COMPILER=${clang_cl}"
    -DCMAKE_C_COMPILER_FORCED=TRUE -DCMAKE_C_COMPILER_ID=Clang
    -DCMAKE_C_COMPILER_VERSION=18.1
    -DCMAKE_C_SIMULATE_ID=MSVC -DCMAKE_C_SIMULATE_VERSION=19.40
    -DCMAKE_C_COMPILER_FRONTEND_VARIANT=MSVC
    -DCMAKE_C_COMPILER_ARCHITECTURE_ID=x64 -DMSVC_C_ARCHITECTURE_ID=x64
    -DCMAKE_C_STANDARD_LIBRARIES=)
  actions_matching("^compile-st-" 1 compile)
  expect_response_file("${compile}" "${clang_cl}" "@")
  # Quoted by the Windows rules: an argument with a double quote is written
  # with `\"`, and the backslashes of the definition stay as they are. The
  # file is one line: clang-cl marks each line end of a response file, so
  # `-o` and its value on separate lines would part.
  file(READ "${binary}/CMakeFiles/reprobuild/rsp/${compile}.rsp" rsp_text)
  string(FIND "${rsp_text}" [["-DPROBE_TEXT=\"x\\y\""]] quoted_at)
  if(quoted_at EQUAL -1)
    message(FATAL_ERROR "The clang-cl response file does not quote by the Windows rules:\n${rsp_text}")
  endif()
  run_action("${compile}" PATH ${run_path})

elseif(TEST_TOOLCHAIN STREQUAL "ispc")
  require(TEST_ISPC TEST_C_COMPILER)
  get_filename_component(ispc_dir "${TEST_ISPC}" DIRECTORY)
  get_filename_component(c_dir "${TEST_C_COMPILER}" DIRECTORY)
  set(run_path "${ispc_dir}" "${c_dir}")
  file(WRITE "${source}/unit.ispc" "#include \"probe.h\"\nexport uniform int probe_value() { return PROBE_VALUE; }\n")
  file(WRITE "${source}/main.c" "int probe_value(void);\nint main(void) { return probe_value() == 7 ? 0 : 1; }\n")
  write_project("C ISPC" "${include_body}
add_executable(app main.c unit.ispc)
target_include_directories(app PRIVATE \${long_dirs} \"\${probe_dir}\")
")
  configure_and_read(
    "-DCMAKE_C_COMPILER=${TEST_C_COMPILER}" -DCMAKE_C_COMPILER_FORCED=TRUE
    -DCMAKE_C_COMPILER_ID=GNU -DCMAKE_C_COMPILER_VERSION=15.0
    "-DCMAKE_ISPC_COMPILER=${TEST_ISPC}" -DCMAKE_ISPC_COMPILER_FORCED=TRUE
    -DCMAKE_ISPC_COMPILER_ID=Intel -DCMAKE_ISPC_COMPILER_VERSION=1.30)
  actions_matching("^compile-app-.*unit\\.ispc\\.o$" 1 compile)
  expect_response_file("${compile}" "${TEST_ISPC}" "@")
  # ispc's reader toggles a quoted run at each `"` or `'` and has no escape
  # character, so the apostrophe and the double quote are each written
  # inside the other kind of quote.
  file(READ "${binary}/CMakeFiles/reprobuild/rsp/${compile}.rsp" rsp_text)
  string(FIND "${rsp_text}" [['-I]] quoted_at)
  if(quoted_at EQUAL -1)
    message(FATAL_ERROR "The ispc response file does not quote by ispc's rules:\n${rsp_text}")
  endif()
  run_action("${compile}" PATH ${run_path})
  actions_matching("^compile-app-.*main\\.c\\.o$" 1 main_compile)
  run_action("${main_compile}" PATH ${run_path})
  run_action(link-app PATH ${run_path} CREATES app)

elseif(TEST_TOOLCHAIN STREQUAL "swift")
  require(TEST_SWIFTC)
  get_filename_component(swift_dir "${TEST_SWIFTC}" DIRECTORY)
  # A wrapped swiftc (Nix's) runs `basename`.
  find_program(test_basename NAMES basename REQUIRED)
  get_filename_component(coreutils_dir "${test_basename}" DIRECTORY)
  set(run_path "${swift_dir}" "${coreutils_dir}")
  file(WRITE "${source}/main.swift" "print(7)\n")
  write_project(Swift "${include_body}
add_executable(app main.swift)
target_link_directories(app PRIVATE \${long_dirs} \"\${probe_dir}\")
")
  configure_and_read(
    "-DCMAKE_Swift_COMPILER=${TEST_SWIFTC}" -DCMAKE_Swift_COMPILER_FORCED=TRUE
    -DCMAKE_Swift_COMPILER_ID=Apple -DCMAKE_Swift_COMPILER_VERSION=5.10)
  run_action(compile-app-Swift PROGRAM "${TEST_SWIFTC}" PATH ${run_path})
  expect_response_file(link-app "${TEST_SWIFTC}" "@")
  run_action(link-app PATH ${run_path} CREATES app)

else()
  message(FATAL_ERROR "Unknown TEST_TOOLCHAIN '${TEST_TOOLCHAIN}'")
endif()

# The response files are named after the actions, so the same project gives
# the same paths however many targets come before it. Configure again with a
# copy of the target, long lines included, defined ahead of it, and compare.
get_property(ids_before GLOBAL PROPERTY action_ids)
set(rsp_before)
foreach(id IN LISTS ids_before)
  get_property(inputs GLOBAL PROPERTY inputs_${id})
  list(FILTER inputs INCLUDE REGEX "\\.rsp$")
  list(APPEND rsp_before ${inputs})
endforeach()
if(NOT rsp_before)
  message(FATAL_ERROR "No action declared a response file.")
endif()
file(STRINGS "${source}/CMakeLists.txt" project_lines)
set(copy)
set(original)
foreach(line IN LISTS project_lines)
  if(line MATCHES "^(add_executable|add_library|target_[a-z_]+|set_target_properties)\\((app|st|funit) ")
    string(REGEX REPLACE "^([a-z_]+)\\((app|st|funit) " "\\1(added_\\2 " copied "${line}")
    string(APPEND copy "${copied}\n")
    string(APPEND original "${line}\n")
  elseif(NOT original)
    string(APPEND copy "${line}\n")
  else()
    string(APPEND original "${line}\n")
  endif()
endforeach()
file(WRITE "${source}/CMakeLists.txt" "${copy}${original}")
# Reuses the cache: the forced identities are kept.
configure_and_read()
set(rsp_after)
foreach(id IN LISTS ids_before)
  get_property(inputs GLOBAL PROPERTY inputs_${id})
  list(FILTER inputs INCLUDE REGEX "\\.rsp$")
  list(APPEND rsp_after ${inputs})
endforeach()
if(NOT rsp_before STREQUAL rsp_after)
  message(FATAL_ERROR "Adding a target moved the response files:\n  before: ${rsp_before}\n  after:  ${rsp_after}")
endif()
message(STATUS "${TEST_TOOLCHAIN}: every long line was passed in the response file its program reads.")
