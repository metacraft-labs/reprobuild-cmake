# Protects: an ISPC target configures and generates under the Reprobuild
# generator with CMake's own ISPC compiler module (Compiler/Intel-ISPC.cmake)
# and no project-side variables, as it does under the Makefile and Ninja
# generators. Its compile asks ispc for a GCC-format depfile (`-M -MT <obj>
# -MF <obj>.d`), the action reads that depfile as its dependency evidence,
# and running the compile writes a depfile that names the header the source
# includes.
#
# Before the fix, the generator took an ISPC compile only when
# CMAKE_ISPC_DEPENDS_USE_COMPILER was on. Intel-ISPC.cmake sets it, and
# CMAKE_ISPC_DEPFILE_FORMAT, for the Makefile generators only, so generation
# stopped with "supports depfiles only for GCC-compatible C/CXX compilers;
# compiler id 'Intel' is not supported" unless the project passed both.
#
# Defect record: reprobuild-pm
# issues/2026-11-21-reprobuild-cmake-refuses-ispc-unless-the-project-sets-ispc-depends-use-compiler.md
# Spec: reprobuild-pm spec/CMake-Reprobuild-Generator.md, "Dependency
# Reports" and "CUDA And Other Multi-Output Languages".
#
# Nothing is mocked. One stand-in: the compilers' identities are forced
# (CMAKE_<LANG>_COMPILER_FORCED with the ids CMake detects for gcc and ispc)
# because CMake's compiler checks run try_compile through the Reprobuild
# generator, which needs a repro engine this test does not run (as in
# long-lines-response-file.cmake). A forced id still loads the compiler
# module, Compiler/Intel-ISPC.cmake, through CMakeISPCInformation.cmake, so
# the variables under test are exactly the ones CMake itself sets. The
# compile runs directly from the generated provider's argv, in the build
# directory, as the engine would run it.
cmake_minimum_required(VERSION 3.29)
foreach(required IN ITEMS TEST_CMAKE TEST_BINARY_ROOT TEST_ISPC TEST_C_COMPILER)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "${required} is required")
  endif()
endforeach()
file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
set(source "${TEST_BINARY_ROOT}/src")
set(binary "${TEST_BINARY_ROOT}/build")
file(MAKE_DIRECTORY "${source}/inc")

file(WRITE "${source}/CMakeLists.txt" [[
cmake_minimum_required(VERSION 3.29)
project(IspcDefaults C ISPC)
add_library(k STATIC k.ispc)
target_include_directories(k PRIVATE inc)
]])
file(WRITE "${source}/inc/k_value.h" "#define K_VALUE 7\n")
file(WRITE "${source}/k.ispc"
  "#include \"k_value.h\"\nexport uniform int k_value() { return K_VALUE; }\n")

# PATH holds only the toolchain's directories: a reconfigure primes the
# provider with a `repro` found on PATH, which this test does not run.
get_filename_component(ispc_dir "${TEST_ISPC}" DIRECTORY)
get_filename_component(c_dir "${TEST_C_COMPILER}" DIRECTORY)
set(path "${ispc_dir}:${c_dir}")
set(tool_env "${CMAKE_COMMAND}" -E env --unset=REPROBUILD_REPRO "PATH=${path}")
find_program(test_make NAMES make REQUIRED)

execute_process(COMMAND ${tool_env} "${TEST_CMAKE}" -S "${source}" -B "${binary}" -G Reprobuild
  "-DCMAKE_MAKE_PROGRAM=${test_make}"
  "-DCMAKE_C_COMPILER=${TEST_C_COMPILER}" -DCMAKE_C_COMPILER_FORCED=TRUE
  -DCMAKE_C_COMPILER_ID=GNU -DCMAKE_C_COMPILER_VERSION=15.0
  "-DCMAKE_ISPC_COMPILER=${TEST_ISPC}" -DCMAKE_ISPC_COMPILER_FORCED=TRUE
  -DCMAKE_ISPC_COMPILER_ID=Intel -DCMAKE_ISPC_COMPILER_VERSION=1.30
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "An ISPC project with CMake's default ISPC settings does not configure:\n${out}\n${err}")
endif()

# The ISPC compile action, its argv and its dependency evidence.
file(STRINGS "${binary}/reprobuild.nim" lines REGEX "buildAction\\(\"compile-k-.*k\\.ispc\\.o\"")
list(LENGTH lines n)
if(NOT n EQUAL 1)
  message(FATAL_ERROR "Expected one compile action for k.ispc; saw ${n}:\n${lines}")
endif()
if(NOT lines MATCHES "inlineExecCall\\(@(\\[.*\\])(, cwd = \"[^\"]*\")?\\), deps = ")
  message(FATAL_ERROR "The k.ispc compile is not an inline argv: ${lines}")
endif()
set(argv_json "${CMAKE_MATCH_1}")
set(argv)
string(JSON length LENGTH "${argv_json}")
math(EXPR last "${length} - 1")
foreach(i RANGE 0 ${last})
  string(JSON item GET "${argv_json}" ${i})
  list(APPEND argv "${item}")
endforeach()

list(GET argv 0 program)
if(NOT program STREQUAL TEST_ISPC)
  message(FATAL_ERROR "The k.ispc compile does not run ispc: ${argv}")
endif()
list(FIND argv "-MF" mf_at)
if(mf_at EQUAL -1)
  message(FATAL_ERROR "The k.ispc compile asks ispc for no depfile: ${argv}")
endif()
math(EXPR dep_at "${mf_at} + 1")
list(GET argv ${dep_at} depfile)
list(FIND argv "-M" m_at)
list(FIND argv "-MT" mt_at)
math(EXPR obj_at "${mt_at} + 1")
list(GET argv ${obj_at} object)
if(m_at EQUAL -1 OR mt_at EQUAL -1 OR NOT depfile STREQUAL "${object}.d")
  message(FATAL_ERROR "The k.ispc compile does not ask ispc for a GCC-format depfile of its object: ${argv}")
endif()
string(REPLACE "." "\\." depfile_re "${depfile}")
if(NOT lines MATCHES ", depfile = \"${depfile_re}\", dependencyPolicy = makeDepfilePolicy\\(\"${depfile_re}\"\\)")
  message(FATAL_ERROR "The k.ispc compile does not read ${depfile} as its dependency evidence: ${lines}")
endif()

# Run the compile as the engine would; its depfile names the header.
get_filename_component(object_dir "${binary}/${object}" DIRECTORY)
file(MAKE_DIRECTORY "${object_dir}")
execute_process(COMMAND ${tool_env} ${argv} WORKING_DIRECTORY "${binary}"
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0 OR NOT EXISTS "${binary}/${object}")
  message(FATAL_ERROR "The k.ispc compile failed (${result}):\n${argv}\n${out}\n${err}")
endif()
if(NOT EXISTS "${binary}/${depfile}")
  message(FATAL_ERROR "The k.ispc compile wrote no depfile at ${depfile}.")
endif()
file(READ "${binary}/${depfile}" depfile_text)
if(NOT depfile_text MATCHES "k_value\\.h")
  message(FATAL_ERROR "The k.ispc depfile does not name the header k.ispc includes:\n${depfile_text}")
endif()
