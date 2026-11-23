# Protects: each entry of the compile_commands.json the generator exports
# holds, in its `command` field, the argv of the compile it describes as one
# shell-escaped string: split by a POSIX shell, it gives back the program and
# each argument the compile action runs, unchanged, whatever characters an
# argument holds.
#
# Before the fix, the program and its arguments were joined with spaces and
# nothing was quoted. A tool reading the database (clangd, clang-tidy, an IDE)
# split an include directory holding a space into several arguments and lost
# its apostrophe, double quotes and backslashes; `$` and backticks were left
# for its shell to expand.
#
# Defect record: reprobuild-pm
# issues/2026-11-23-reprobuild-cmake-compile-commands-json-does-not-quote-its-arguments.md
# Spec: reprobuild-pm spec/CMake-Reprobuild-Generator.md, "Compile Actions"
# (the `compile_commands.json` export) and the JSON Compilation Database
# format, https://clang.llvm.org/docs/JSONCompilationDatabase.html, which
# defines `command` as "the compile command as a single shell-escaped
# string".
#
# TEST_TOOLCHAIN selects the languages per registered test, so that each runs
# where its tools are installed:
#
#   gnu     gcc, g++ and gfortran: C and C++ compiles (inline-exec actions)
#           and a Fortran compile (a tool-profile call).
#   swift   swiftc: a Swift target's compile (one tool-profile call for the
#           target's sources).
#
# The reference for "shell-escaped" is /bin/sh itself: the test has the shell
# split each `command` (`eval "set -- $command"`) and compares the words with
# the argv the provider's action runs. The C compile is also run, from its
# `command`, through the shell, in the entry's `directory`. Nothing is
# mocked. One stand-in: the compilers' identities are forced
# (CMAKE_<LANG>_COMPILER_FORCED), because CMake's compiler checks run
# try_compile through the Reprobuild generator, which needs a repro engine
# this test does not run (as in long-lines-response-file.cmake).
# Identification is upstream CMake, not under test.
#
# The include directory's name holds a space, an apostrophe, a double quote,
# `$HOME` and a backtick command (not a backslash: CMake reads one in a path
# as a directory separator), and the definition's value holds `$HOME`, a
# backtick command, a double quote and a backslash.
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

set(probe_dir_name [[o'brien "dq" sp $HOME `echo cmdsub`]])
set(probe_dir "${source}/${probe_dir_name}")
file(MAKE_DIRECTORY "${probe_dir}")
set(probe_definition [[PROBE_WORD=w$HOME`echo cmdsub`q"d\x]])

find_program(test_sh NAMES sh REQUIRED)
set(tool_env "${CMAKE_COMMAND}" -E env --unset=REPROBUILD_REPRO)
find_program(test_make NAMES make REQUIRED)

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

# Configures the project in `source` and reads the argv of every compile
# action of the generated provider (the inline argv, or the arguments a
# tool-profile call passes after its program). PATH holds only the
# toolchain's directories (`run_path`): a reconfigure primes the provider
# with a `repro` found on PATH, which this test does not run.
function(configure_and_read)
  string(JOIN ":" path ${run_path})
  execute_process(COMMAND ${tool_env} "PATH=${path}" "${TEST_CMAKE}" -S "${source}" -B "${binary}" -G Reprobuild
    "-DCMAKE_MAKE_PROGRAM=${test_make}" ${ARGN}
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "configure failed: ${out}\n${err}")
  endif()
  file(STRINGS "${binary}/reprobuild.nim" lines REGEX "buildAction\\(\"compile-")
  foreach(line IN LISTS lines)
    if(line MATCHES "buildAction\\(\"([^\"]+)\", inlineExecCall\\(@(\\[.*\\])(, cwd = \"[^\"]*\")?\\), deps = ")
      set_property(GLOBAL PROPERTY kind_${CMAKE_MATCH_1} inline)
    elseif(line MATCHES "buildAction\\(\"([^\"]+)\", publicCliCall\\(.*cliArgSeq\\(\"args\", @(\\[.*\\]), cpkPositional, 0\\)\\]\\), deps = ")
      set_property(GLOBAL PROPERTY kind_${CMAKE_MATCH_1} tool)
    else()
      message(FATAL_ERROR "Unreadable action: ${line}")
    endif()
    json_array_to_list("${CMAKE_MATCH_2}" argv)
    set_property(GLOBAL PROPERTY argv_${CMAKE_MATCH_1} "${argv}")
  endforeach()
  file(READ "${binary}/compile_commands.json" database)
  set(database "${database}" PARENT_SCOPE)
endfunction()

# The words /bin/sh splits `command` into, one list item each.
function(shell_words command out_var)
  execute_process(COMMAND "${test_sh}" -c [[eval "set -- $1" || exit 3; for a do printf '%s\n' "$a"; done]] sh "${command}"
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "The shell could not split the command (${result}): ${err}\n  command: ${command}")
  endif()
  string(REGEX REPLACE "\n$" "" out "${out}")
  string(REPLACE "\n" ";" words "${out}")
  set(${out_var} "${words}" PARENT_SCOPE)
endfunction()

# The `command` of the one database entry whose `file` matches `file_regex`
# and whose command holds `command_regex` and, when it is given, not
# `exclude_regex` (an empty `command_regex` matches any).
function(database_command file_regex command_regex out_var)
  set(exclude_regex "${ARGN}")
  string(JSON n LENGTH "${database}")
  math(EXPR last "${n} - 1")
  set(found)
  foreach(i RANGE 0 ${last})
    string(JSON file GET "${database}" ${i} file)
    string(JSON command GET "${database}" ${i} command)
    string(JSON directory GET "${database}" ${i} directory)
    if(file MATCHES "${file_regex}" AND command MATCHES "${command_regex}" AND
       (exclude_regex STREQUAL "" OR NOT command MATCHES "${exclude_regex}"))
      list(APPEND found "${i}")
      set(match_command "${command}")
      set(match_directory "${directory}")
    endif()
  endforeach()
  list(LENGTH found count)
  if(NOT count EQUAL 1)
    message(FATAL_ERROR "Expected one compile_commands.json entry for ${file_regex} (${command_regex}); saw ${count}:\n${database}")
  endif()
  set(${out_var} "${match_command}" PARENT_SCOPE)
  set(${out_var}_directory "${match_directory}" PARENT_SCOPE)
endfunction()

# Asserts that the database's `command` for `file_regex` (and
# `command_regex`, not `exclude_regex`) splits into `program` followed by
# exactly the arguments action `id` runs, and holds each of the ARGN
# arguments as one word.
function(expect_entry file_regex command_regex exclude_regex id program)
  database_command("${file_regex}" "${command_regex}" command "${exclude_regex}")
  shell_words("${command}" words)
  get_property(kind GLOBAL PROPERTY kind_${id})
  get_property(argv GLOBAL PROPERTY argv_${id})
  if(kind STREQUAL "")
    message(FATAL_ERROR "No compile action ${id} in the provider.")
  elseif(kind STREQUAL "tool")
    list(PREPEND argv "${program}")
  endif()
  if(NOT words STREQUAL argv)
    string(REPLACE ";" "]\n    [" words_text "[${words}]")
    string(REPLACE ";" "]\n    [" argv_text "[${argv}]")
    message(FATAL_ERROR "The compile_commands.json command for ${file_regex} is not the argv of ${id}.\n  command: ${command}\n  the shell splits it into:\n    ${words_text}\n  the action runs:\n    ${argv_text}")
  endif()
  list(GET words 0 first)
  if(NOT first STREQUAL program)
    message(FATAL_ERROR "The command for ${file_regex} starts with [${first}], not [${program}].")
  endif()
  foreach(word IN LISTS ARGN)
    if(NOT word IN_LIST words)
      message(FATAL_ERROR "The command for ${file_regex} holds no word [${word}]: ${command}")
    endif()
  endforeach()
endfunction()

if(TEST_TOOLCHAIN STREQUAL "gnu")
  require(TEST_GCC TEST_GXX TEST_GFORTRAN)
  get_filename_component(gcc_dir "${TEST_GCC}" DIRECTORY)
  set(run_path "${gcc_dir}")
  file(WRITE "${probe_dir}/probe.h" "#define PROBE_VALUE 7\n")
  file(WRITE "${probe_dir}/probe.inc" "integer, parameter :: probe_marker = 7\n")
  set(c_source "#include \"probe.h\"\nint probe_value(void) { return PROBE_VALUE; }\n")
  file(WRITE "${source}/unit.c" "${c_source}")
  file(WRITE "${source}/unit.cpp" "${c_source}")
  file(WRITE "${source}/f.F90" "module f\n#include \"probe.inc\"\nend module f\n")
  file(WRITE "${source}/CMakeLists.txt" "cmake_minimum_required(VERSION 3.29)
project(CompileCommandsQuoting C CXX Fortran)
add_library(u STATIC unit.c unit.cpp)
add_library(f STATIC f.F90)
foreach(t IN ITEMS u f)
  target_include_directories(\${t} PRIVATE [[${probe_dir}]])
  target_compile_definitions(\${t} PRIVATE [[${probe_definition}]])
endforeach()
")
  set(forced)
  set(langs C CXX Fortran)
  set(compilers TEST_GCC TEST_GXX TEST_GFORTRAN)
  foreach(lang compiler IN ZIP_LISTS langs compilers)
    list(APPEND forced "-DCMAKE_${lang}_COMPILER=${${compiler}}"
      -DCMAKE_${lang}_COMPILER_FORCED=TRUE -DCMAKE_${lang}_COMPILER_ID=GNU
      -DCMAKE_${lang}_COMPILER_VERSION=15.0)
  endforeach()
  configure_and_read(${forced})
  set(probe_words "-I${probe_dir}" "-D${probe_definition}")
  expect_entry("/unit\\.c$" "" "" "compile-u-CMakeFiles_u.dir_unit.c.o" "${TEST_GCC}" ${probe_words})
  expect_entry("/unit\\.cpp$" "" "" "compile-u-CMakeFiles_u.dir_unit.cpp.o" "${TEST_GXX}" ${probe_words})
  expect_entry("f\\.F90" "" "" "compile-f-CMakeFiles_f.dir_f.F90.o" "${TEST_GFORTRAN}" ${probe_words})

  # The C entry, run through the shell from its `command` in its
  # `directory`, compiles: the header is found in the include directory.
  database_command("/unit\\.c$" "" c_command)
  string(JOIN ":" path ${run_path} "$ENV{PATH}")
  execute_process(COMMAND ${tool_env} "PATH=${path}" "${test_sh}" -c "${c_command}"
    WORKING_DIRECTORY "${c_command_directory}"
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "The C entry's command failed (${result}):\n${out}\n${err}\n  command: ${c_command}")
  endif()
  if(NOT EXISTS "${c_command_directory}/CMakeFiles/u.dir/unit.c.o")
    message(FATAL_ERROR "The C entry's command did not create its object:\n${out}\n${err}")
  endif()

elseif(TEST_TOOLCHAIN STREQUAL "swift")
  require(TEST_SWIFTC)
  get_filename_component(swift_dir "${TEST_SWIFTC}" DIRECTORY)
  # A wrapped swiftc (Nix's) runs `basename`.
  find_program(test_basename NAMES basename REQUIRED)
  get_filename_component(coreutils_dir "${test_basename}" DIRECTORY)
  set(run_path "${swift_dir}" "${coreutils_dir}")
  file(WRITE "${source}/lib.swift" "public func probe() -> Int { return 7 }\n")
  file(WRITE "${source}/CMakeLists.txt" "cmake_minimum_required(VERSION 3.29)
project(CompileCommandsQuoting Swift)
add_library(lib STATIC lib.swift)
target_include_directories(lib PRIVATE [[${probe_dir}]])
")
  configure_and_read(
    "-DCMAKE_Swift_COMPILER=${TEST_SWIFTC}" -DCMAKE_Swift_COMPILER_FORCED=TRUE
    -DCMAKE_Swift_COMPILER_ID=Apple -DCMAKE_Swift_COMPILER_VERSION=5.10)
  # Only the include directory is probed here. A Swift target's definitions
  # and options reach its compile through CMake's flag string, which writes
  # a `$` as `$$` in the action's own argv (reprobuild-pm issues/
  # 2026-11-24-reprobuild-cmake-compile-options-reach-the-compile-with-dollar-doubled.md);
  # the database matching that argv is what expect_entry checks.
  set(probe_words "-I${probe_dir}")
  expect_entry("lib\\.swift$" "" "" "compile-lib-Swift" "${TEST_SWIFTC}" ${probe_words})

else()
  message(FATAL_ERROR "Unknown TEST_TOOLCHAIN=${TEST_TOOLCHAIN}")
endif()
