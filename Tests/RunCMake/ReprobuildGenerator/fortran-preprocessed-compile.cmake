# Protects: a Fortran compile reads the file its scan preprocessed the
# source to, and reads it as Fortran in the source's own form. The file is
# named as the Ninja generator names it
# (cmNinjaTargetGenerator::GetPreprocessedFilePath): the object path with its
# object extension replaced by `-pp.<source extension>`, an upper-case
# extension lowered and `.fpp` made `.f`. The compile carries the language's
# post-process flag (`-fpreprocessed` for GNU) and names the source's own
# directory first among its include directories, as the Ninja generator's
# does, so that a Fortran INCLUDE line, which the preprocessor leaves to the
# compiler, finds a file beside the source.
#
# Before the fix the scan preprocessed every source to `<obj>.ddi.i` and the
# compile ran `gfortran -c <obj>.ddi.i`. gfortran picks the language from the
# extension, `.i` is preprocessed C, and every compile failed:
#
#   .../mathmod.f90:1:1: error: unknown type name 'module'
#
# Defect record: reprobuild-pm
# issues/2026-11-21-reprobuild-cmake-fortran-compile-hands-gfortran-a-file-it-reads-as-c.md
# Spec: reprobuild-pm spec/CMake-Reprobuild-Generator.md,
# "Dynamic Dependencies".
#
# The project has one source of each kind the naming distinguishes:
#
#   mathmod.f90  free form, lower case; a module, and an INCLUDE of a file
#                that lives only beside the source.
#   main.F90     free form, upper case (preprocessed to `.f90`); uses the
#                module and a preprocessor conditional.
#   legacy.fpp   fixed form (preprocessed to `.f`): a comment in column 1,
#                which free form rejects.
#
# Each scan and compile, and the link, is run for real, from the command
# lines the generated provider holds, in the build directory, as the engine
# would run them, and the linked program is run. Nothing is mocked. Two
# stand-ins, as in long-lines-response-file.cmake:
# - The compiler's identity is forced (CMAKE_Fortran_COMPILER_FORCED)
#   because CMake's compiler checks run try_compile through the Reprobuild
#   generator, which needs a repro engine this test does not run.
#   Identification is upstream CMake, not under test.
# - Actions run directly rather than through repro, which would add an engine
#   build and nothing this test asserts: the scan wrappers, the argv and the
#   inputs are the generator's output, and running them is what the engine
#   does with them. The engine-driven build of a Fortran program is
#   e2e.cmake's `fortran_dyndep_modules` mode.
cmake_minimum_required(VERSION 3.29)
foreach(required IN ITEMS TEST_CMAKE TEST_GFORTRAN TEST_BINARY_ROOT)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "${required} is required")
  endif()
endforeach()
file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
set(source "${TEST_BINARY_ROOT}/src")
set(binary "${TEST_BINARY_ROOT}/build")
file(MAKE_DIRECTORY "${source}")

file(WRITE "${source}/CMakeLists.txt" [[
cmake_minimum_required(VERSION 3.29)
project(FortranPreprocessed Fortran)
add_executable(fapp main.F90 mathmod.f90 legacy.fpp)
target_include_directories(fapp PRIVATE decoy)
]])
file(WRITE "${source}/answer.fi" "integer, parameter :: base = 40\n")
# A project include directory holding an `answer.fi` of its own, which an
# INCLUDE must not find before the one beside the source.
file(WRITE "${source}/decoy/answer.fi" "integer, parameter :: base = 0\n")
file(WRITE "${source}/mathmod.f90" [[
module mathmod
  implicit none
  include 'answer.fi'
contains
  integer function answer()
    integer, external :: two
    answer = base + two()
  end function answer
end module mathmod
]])
file(WRITE "${source}/main.F90" [[
program main
  use mathmod
  implicit none
#ifdef __GFORTRAN__
  if (answer() /= 42) stop 1
#else
  stop 2
#endif
end program main
]])
file(WRITE "${source}/legacy.fpp" [[
#define VALUE_TWO 2
C     A fixed-form comment in column 1, which free form rejects.
      INTEGER FUNCTION TWO()
      TWO = VALUE_TWO
      END
]])

get_filename_component(gfortran_dir "${TEST_GFORTRAN}" DIRECTORY)
# PATH holds only the toolchain's directory, and REPROBUILD_REPRO is unset:
# a configure primes the provider with a `repro` found on PATH, which this
# test does not run.
set(tool_env "${CMAKE_COMMAND}" -E env --unset=REPROBUILD_REPRO "PATH=${gfortran_dir}")
find_program(test_make NAMES make REQUIRED)
execute_process(COMMAND ${tool_env} "${TEST_CMAKE}" -S "${source}" -B "${binary}" -G Reprobuild
  "-DCMAKE_MAKE_PROGRAM=${test_make}"
  "-DCMAKE_Fortran_COMPILER=${TEST_GFORTRAN}" -DCMAKE_Fortran_COMPILER_FORCED=TRUE
  -DCMAKE_Fortran_COMPILER_ID=GNU -DCMAKE_Fortran_COMPILER_VERSION=15.0
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "configure failed: ${out}\n${err}")
endif()

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

# Runs `argv` in the build directory; fails unless it succeeds.
function(run_in_binary label)
  execute_process(COMMAND ${tool_env} ${ARGN} WORKING_DIRECTORY "${binary}"
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "${label} failed (${result}):\n${ARGN}\n${out}\n${err}")
  endif()
endfunction()

file(STRINGS "${binary}/reprobuild.nim" compile_lines REGEX "buildAction\\(\"compile-")

# The sources in module order (mathmod before main, which uses it), and the
# name each one's preprocessed copy must carry.
set(stems mathmod.f90 legacy.fpp main.F90)
set(pp_names mathmod.f90-pp.f90 legacy.fpp-pp.f main.F90-pp.f90)

# The scans run first, as the dynamic-dependency step orders them before
# every compile: each source's scan wrapper, which preprocesses it.
foreach(stem IN LISTS stems)
  set(scan_wrapper "")
  file(GLOB wrappers "${binary}/CMakeFiles/reprobuild/bin/*scan*")
  foreach(wrapper IN LISTS wrappers)
    file(READ "${wrapper}" content)
    if(content MATCHES "/${stem}' -o ")
      set(scan_wrapper "${wrapper}")
    endif()
  endforeach()
  if(scan_wrapper STREQUAL "")
    message(FATAL_ERROR "No scan wrapper preprocesses ${stem}: ${wrappers}")
  endif()
  run_in_binary("scan of ${stem}" "${scan_wrapper}")
  set_property(GLOBAL PROPERTY scan_${stem} "${scan_wrapper}")
endforeach()

# Each compile, run as the action holds it: a tool-profile call whose
# arguments are given to gfortran. This is where a compile of a file the
# compiler does not read as Fortran fails.
foreach(stem IN LISTS stems)
  set(line "")
  string(REPLACE "." "\\." stem_regex "${stem}")
  foreach(candidate IN LISTS compile_lines)
    if(candidate MATCHES "buildAction\\(\"compile-fapp-[^\"]*_${stem_regex}\\.o\"")
      set(line "${candidate}")
    endif()
  endforeach()
  if(line STREQUAL "")
    message(FATAL_ERROR "No compile action for ${stem}:\n${compile_lines}")
  endif()
  if(NOT line MATCHES "cliArgSeq\\(\"args\", @(\\[.*\\]), cpkPositional, 0\\)\\]\\), deps = @\\[[^]]*\\], inputs = @(\\[[^]]*\\]), outputs = ")
    message(FATAL_ERROR "Unreadable compile action for ${stem}: ${line}")
  endif()
  json_array_to_list("${CMAKE_MATCH_1}" args)
  json_array_to_list("${CMAKE_MATCH_2}" inputs)
  set_property(GLOBAL PROPERTY args_${stem} "${args}")
  set_property(GLOBAL PROPERTY inputs_${stem} "${inputs}")
  run_in_binary("compile of ${stem}" "${TEST_GFORTRAN}" ${args})
endforeach()

# What makes those compiles read Fortran: each scan writes, and each compile
# declares and compiles, the preprocessed copy named after the source's
# extension; each compile carries the post-process flag and names the source
# directory first among its includes, as the Ninja generator's compile does.
# (gfortran 15 also finds mathmod.f90's INCLUDE through the preprocessed
# file's line markers, so the compile above does not show the include
# directory is there; the project's `decoy` include directory makes the
# order checkable.)
foreach(stem pp_name IN ZIP_LISTS stems pp_names)
  set(pp "CMakeFiles/fapp.dir/${pp_name}")
  get_property(scan_wrapper GLOBAL PROPERTY scan_${stem})
  get_property(args GLOBAL PROPERTY args_${stem})
  get_property(inputs GLOBAL PROPERTY inputs_${stem})
  file(READ "${scan_wrapper}" content)
  string(FIND "${content}" " -o '${pp}'" at)
  if(at EQUAL -1 OR NOT EXISTS "${binary}/${pp}")
    message(FATAL_ERROR "The scan of ${stem} does not preprocess it to ${pp}:\n${content}")
  endif()
  if(NOT inputs STREQUAL pp)
    message(FATAL_ERROR "The compile of ${stem} declares ${inputs}, not its preprocessed source ${pp}")
  endif()
  list(GET args -1 compiled)
  if(NOT compiled STREQUAL pp)
    message(FATAL_ERROR "The compile of ${stem} compiles ${compiled}, not ${pp}: ${args}")
  endif()
  if(NOT "-fpreprocessed" IN_LIST args)
    message(FATAL_ERROR "The compile of ${stem} lacks the post-process flag: ${args}")
  endif()
  set(all_args "${args}")
  list(FILTER args INCLUDE REGEX "^-I")
  set(expected_includes "-I${source}" "-I${source}/decoy")
  if(NOT args STREQUAL expected_includes)
    message(FATAL_ERROR "The compile of ${stem} does not name the source directory first among its includes.\n  expected: ${expected_includes}\n  includes: ${args}\n  args: ${all_args}")
  endif()
endforeach()

file(STRINGS "${binary}/reprobuild.nim" link_lines REGEX "buildAction\\(\"link-fapp\"")
list(LENGTH link_lines link_count)
if(NOT link_count EQUAL 1)
  message(FATAL_ERROR "Expected one link-fapp action: ${link_lines}")
endif()
if(link_lines MATCHES "inlineExecCall\\(@(\\[.*\\])(, cwd = \"[^\"]*\")?\\), deps = ")
  json_array_to_list("${CMAKE_MATCH_1}" link_argv)
elseif(link_lines MATCHES "cliArgSeq\\(\"args\", @(\\[.*\\]), cpkPositional, 0\\)")
  json_array_to_list("${CMAKE_MATCH_1}" link_argv)
  list(PREPEND link_argv "${TEST_GFORTRAN}")
else()
  message(FATAL_ERROR "Unreadable link action: ${link_lines}")
endif()
run_in_binary("link of fapp" ${link_argv})
run_in_binary("fapp" "${binary}/fapp")
