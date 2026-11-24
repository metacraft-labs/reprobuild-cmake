# Protects: a target's dyndep action runs the dynamic-dependency fragment
# converter (`repro-cmake-dyndep-fragment`) of the Reprobuild installation the
# project is configured against -- the file of that name beside its `repro`
# -- by absolute path, and nothing else.
#
# Before the fix, the dyndep wrapper
# (CMakeFiles/reprobuild/bin/reprobuild-cmake-action<N>_dyndep_<target>_<lang>)
# tried one developer's home directory
# (`/Users/<developer>/metacraft/reprobuild/build/bin/...`) and otherwise
# looked the bare name up on the action's PATH. On any other machine the
# converter was not found ("repro-cmake-dyndep-fragment: command not found",
# exit 127), so every Fortran-module and C++20-module build failed at its
# dyndep step; and whatever a PATH held under that name was run in its place.
#
# Defect record: reprobuild-pm
# issues/2026-11-23-reprobuild-cmake-dyndep-wrapper-finds-its-fragment-converter-at-a-developers-home-path.md
# Spec: reprobuild-pm spec/CMake-Reprobuild-Generator.md, "Dynamic
# Dependencies".
#
# Cases, each a fresh configure of one Fortran module library:
#
#   beside-cli    CMAKE_MAKE_PROGRAM is TEST_REPROBUILD_REPRO, whose
#                 directory holds the converter. The dyndep wrapper names
#                 that converter and writes the fragment.
#   through-link  CMAKE_MAKE_PROGRAM is a symlink to TEST_REPROBUILD_REPRO in
#                 a directory without a converter (a profile or PATH link):
#                 the converter is found beside the file the link resolves
#                 to.
#   no-cli        No Reprobuild CLI is configured or on PATH. The dyndep
#                 wrapper fails closed and says why, and does not run the
#                 `repro-cmake-dyndep-fragment` on the action's PATH.
#
# The scan and dyndep wrappers are run for real, in the build directory, as
# the engine runs them, with the real converter and the real `cmake -E
# cmake_ninja_dyndep`. Two stand-ins, both justified:
#
# - The compiler's identity is forced (CMAKE_Fortran_COMPILER_FORCED):
#   CMake's compiler checks run try_compile through the Reprobuild generator,
#   which this test does not exercise (as in scan-wrapper-quoting.cmake).
#   Identification is upstream CMake, not under test.
# - In `no-cli`, a decoy `repro-cmake-dyndep-fragment` script on the action's
#   PATH. It is the condition under test: it records that it ran, and the
#   test fails if it did. No real converter can play that part, because the
#   point is that an unrelated program of that name is not trusted.
cmake_minimum_required(VERSION 3.29)
foreach(required IN ITEMS TEST_CMAKE TEST_BINARY_ROOT TEST_GFORTRAN
                          TEST_REPROBUILD_REPRO)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "${required} is required")
  endif()
endforeach()
get_filename_component(repro_dir "${TEST_REPROBUILD_REPRO}" DIRECTORY)
set(converter "${repro_dir}/repro-cmake-dyndep-fragment")
if(NOT EXISTS "${converter}")
  message(FATAL_ERROR "TEST_REPROBUILD_REPRO must be a complete installation: no ${converter}")
endif()
file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
set(source "${TEST_BINARY_ROOT}/src")
file(MAKE_DIRECTORY "${source}")
file(WRITE "${source}/f.F90" "module f
integer, parameter :: marker = 7
end module f
")
file(WRITE "${source}/CMakeLists.txt" "cmake_minimum_required(VERSION 3.29)
project(DyndepConverter Fortran)
add_library(f STATIC f.F90)
")

get_filename_component(gfortran_dir "${TEST_GFORTRAN}" DIRECTORY)
find_program(test_make NAMES make REQUIRED)
# REPROBUILD_REPRO would outrank CMAKE_MAKE_PROGRAM; each case says which
# CLI it configures against.
set(tool_env "${CMAKE_COMMAND}" -E env --unset=REPROBUILD_REPRO)

# Configures `source` into `binary` with `make_program` as
# CMAKE_MAKE_PROGRAM. PATH holds only the compiler's directory, so no
# `repro` (and no converter) is found there.
function(configure binary make_program)
  execute_process(COMMAND ${tool_env} "PATH=${gfortran_dir}" "${TEST_CMAKE}"
    -S "${source}" -B "${binary}" -G Reprobuild
    "-DCMAKE_MAKE_PROGRAM=${make_program}"
    "-DCMAKE_Fortran_COMPILER=${TEST_GFORTRAN}"
    -DCMAKE_Fortran_COMPILER_FORCED=TRUE -DCMAKE_Fortran_COMPILER_ID=GNU
    -DCMAKE_Fortran_COMPILER_VERSION=15.0
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "configure failed: ${out}\n${err}")
  endif()
endfunction()

# Runs the one wrapper in `binary` whose name matches `glob`, as the engine
# runs it, with `path` as PATH. Sets wrapper_result, wrapper_output and
# wrapper_text in the caller.
function(run_wrapper binary glob path)
  file(GLOB wrappers "${binary}/CMakeFiles/reprobuild/bin/${glob}")
  list(LENGTH wrappers n)
  if(NOT n EQUAL 1)
    message(FATAL_ERROR "Expected one wrapper matching ${glob}; saw ${n}: ${wrappers}")
  endif()
  file(READ "${wrappers}" text)
  execute_process(COMMAND ${tool_env} "PATH=${path}" "${wrappers}"
    WORKING_DIRECTORY "${binary}"
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  set(wrapper_result "${result}" PARENT_SCOPE)
  set(wrapper_output "${out}${err}" PARENT_SCOPE)
  set(wrapper_text "${text}" PARENT_SCOPE)
endfunction()

# The action's PATH: the compiler's directory, then the directories that
# really hold the utilities a Nix compiler wrapper script and the wrappers
# run (`basename`, `sed`, ...). Each utility is resolved through its links,
# so a profile directory such as ~/.nix-profile/bin -- which holds an
# installed Reprobuild's converter on a developer machine -- is not on it.
set(action_path "${gfortran_dir}")
foreach(tool IN ITEMS sh basename dirname cat cp mv rm mkdir touch tr sed grep awk expr)
  find_program(tool_path_${tool} NAMES ${tool} NO_CACHE)
  if(tool_path_${tool})
    file(REAL_PATH "${tool_path_${tool}}" tool_real)
    get_filename_component(tool_dir "${tool_real}" DIRECTORY)
    list(APPEND action_path "${tool_dir}")
  endif()
endforeach()
list(REMOVE_DUPLICATES action_path)
foreach(dir IN LISTS action_path)
  if(EXISTS "${dir}/repro-cmake-dyndep-fragment")
    message(FATAL_ERROR "The action PATH directory ${dir} holds a converter; this test needs a PATH without one")
  endif()
endforeach()
string(JOIN ":" action_path ${action_path})

set(scan_glob "*_scan_f_*")
set(dyndep_glob "*_dyndep_f_Fortran")

# Scans, then runs the dyndep step of `binary` and requires it to write the
# fragment with the converter at `expected_converter`.
function(expect_converter binary expected_converter)
  run_wrapper("${binary}" "${scan_glob}" "${action_path}")
  if(NOT wrapper_result EQUAL 0)
    message(FATAL_ERROR "The scan wrapper failed (${wrapper_result}):\n${wrapper_output}\nwrapper:\n${wrapper_text}")
  endif()
  run_wrapper("${binary}" "${dyndep_glob}" "${action_path}")
  if(NOT wrapper_result EQUAL 0)
    message(FATAL_ERROR "The dyndep wrapper failed (${wrapper_result}):\n${wrapper_output}\nwrapper:\n${wrapper_text}")
  endif()
  string(FIND "${wrapper_text}" "'${expected_converter}' --out " at)
  if(at EQUAL -1)
    message(FATAL_ERROR "The dyndep wrapper does not run ${expected_converter}:\n${wrapper_text}")
  endif()
  # ... and names no other: no fixed location is tried first.
  string(REGEX MATCHALL "repro-cmake-dyndep-fragment" named "${wrapper_text}")
  list(LENGTH named named_count)
  if(NOT named_count EQUAL 1)
    message(FATAL_ERROR "The dyndep wrapper names a converter other than ${expected_converter}:\n${wrapper_text}")
  endif()
  # The converter wrote the fragment the compile reads (the action's
  # declared DynamicDepsFile, `-out`).
  string(REGEX MATCH "--out '([^']+)'" _ "${wrapper_text}")
  set(fragment "${CMAKE_MATCH_1}")
  if(fragment STREQUAL "" OR NOT EXISTS "${binary}/${fragment}")
    message(FATAL_ERROR "The dyndep wrapper did not write its fragment [${fragment}]:\n${wrapper_output}\nwrapper:\n${wrapper_text}")
  endif()
endfunction()

# beside-cli
set(binary "${TEST_BINARY_ROOT}/beside-cli")
configure("${binary}" "${TEST_REPROBUILD_REPRO}")
expect_converter("${binary}" "${converter}")

# through-link
set(link_dir "${TEST_BINARY_ROOT}/link-bin")
file(MAKE_DIRECTORY "${link_dir}")
file(CREATE_LINK "${TEST_REPROBUILD_REPRO}" "${link_dir}/repro" SYMBOLIC)
file(REAL_PATH "${TEST_REPROBUILD_REPRO}" real_repro)
get_filename_component(real_repro_dir "${real_repro}" DIRECTORY)
set(binary "${TEST_BINARY_ROOT}/through-link")
configure("${binary}" "${link_dir}/repro")
expect_converter("${binary}" "${real_repro_dir}/repro-cmake-dyndep-fragment")

# no-cli
set(decoy_dir "${TEST_BINARY_ROOT}/decoy-bin")
set(decoy_ran "${TEST_BINARY_ROOT}/decoy-ran")
file(MAKE_DIRECTORY "${decoy_dir}")
file(WRITE "${decoy_dir}/repro-cmake-dyndep-fragment"
  "#!/bin/sh\ntouch '${decoy_ran}'\nexit 0\n")
file(CHMOD "${decoy_dir}/repro-cmake-dyndep-fragment"
  PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE)
set(binary "${TEST_BINARY_ROOT}/no-cli")
configure("${binary}" "${test_make}")
run_wrapper("${binary}" "${scan_glob}" "${action_path}")
if(NOT wrapper_result EQUAL 0)
  message(FATAL_ERROR "The scan wrapper failed (${wrapper_result}):\n${wrapper_output}\nwrapper:\n${wrapper_text}")
endif()
run_wrapper("${binary}" "${dyndep_glob}" "${decoy_dir}:${action_path}")
if(EXISTS "${decoy_ran}")
  message(FATAL_ERROR "The dyndep wrapper ran the repro-cmake-dyndep-fragment on its PATH:\n${wrapper_text}")
endif()
if(wrapper_result EQUAL 0)
  message(FATAL_ERROR "The dyndep wrapper succeeded with no converter:\n${wrapper_output}\nwrapper:\n${wrapper_text}")
endif()
if(NOT wrapper_output MATCHES "there is no repro-cmake-dyndep-fragment beside the Reprobuild CLI")
  message(FATAL_ERROR "The dyndep wrapper failed (${wrapper_result}) without saying the converter is missing:\n${wrapper_output}\nwrapper:\n${wrapper_text}")
endif()
if(wrapper_text MATCHES "/repro-cmake-dyndep-fragment")
  message(FATAL_ERROR "The dyndep wrapper names a converter at a fixed location:\n${wrapper_text}")
endif()
