cmake_minimum_required(VERSION 3.10)

foreach(var IN ITEMS CMAKE_COMMAND TEST_MODE TEST_BINARY_ROOT TEST_C_COMPILER)
  if(NOT DEFINED ${var} OR "${${var}}" STREQUAL "")
    message(FATAL_ERROR "${var} is required")
  endif()
endforeach()

function(write_c_project source_dir project_name languages)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.10)\n"
    "project(${project_name} ${languages})\n"
    "add_executable(hello main.c)\n")
  file(WRITE "${source_dir}/main.c" "int main(void) { return 0; }\n")
endfunction()

function(run_configure source_dir binary_dir expect_success expected_error)
  file(REMOVE_RECURSE "${binary_dir}")
  set(command
    "${CMAKE_COMMAND}"
    -S "${source_dir}"
    -B "${binary_dir}"
    -G Reprobuild
    "-DCMAKE_C_COMPILER=${TEST_C_COMPILER}")
  list(APPEND command ${ARGN})
  execute_process(
    COMMAND ${command}
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr
    RESULT_VARIABLE result
    ENCODING UTF8)

  if(expect_success)
    if(NOT result EQUAL 0)
      message(FATAL_ERROR
        "Reprobuild configure failed unexpectedly.\n"
        "Command: ${command}\n"
        "stdout:\n${stdout}\n"
        "stderr:\n${stderr}")
    endif()
  else()
    if(result EQUAL 0)
      message(FATAL_ERROR
        "Reprobuild configure succeeded unexpectedly.\n"
        "Command: ${command}\n"
        "stdout:\n${stdout}\n"
        "stderr:\n${stderr}")
    endif()
    string(FIND "${stderr}" "${expected_error}" found_error)
    if(found_error EQUAL -1)
      message(FATAL_ERROR
        "Reprobuild configure error did not contain '${expected_error}'.\n"
        "stdout:\n${stdout}\n"
        "stderr:\n${stderr}")
    endif()
  endif()
endfunction()

function(check_provider_metadata binary_dir source_dir)
  set(provider_dir "${binary_dir}/CMakeFiles/reprobuild")
  set(metadata_file "${provider_dir}/provider.meta")
  set(launcher_state_file "${provider_dir}/launcher-state.txt")
  if(NOT IS_DIRECTORY "${provider_dir}")
    message(FATAL_ERROR "Missing provider directory: ${provider_dir}")
  endif()
  if(NOT EXISTS "${metadata_file}")
    message(FATAL_ERROR "Missing provider metadata: ${metadata_file}")
  endif()
  if(NOT EXISTS "${launcher_state_file}")
    message(FATAL_ERROR "Missing launcher state: ${launcher_state_file}")
  endif()

  file(READ "${metadata_file}" metadata)
  foreach(expected IN ITEMS
      "generator=Reprobuild"
      "provider_version=1"
      "m1_action_state=unsupported"
      "source_dir=${source_dir}"
      "binary_dir=${binary_dir}"
      "enabled_languages=C")
    string(FIND "${metadata}" "${expected}" found)
    if(found EQUAL -1)
      message(FATAL_ERROR
        "Provider metadata missing '${expected}'.\n"
        "metadata:\n${metadata}")
    endif()
  endforeach()

  file(READ "${launcher_state_file}" launcher_state)
  if(NOT launcher_state MATCHES "unsupported_action=build")
    message(FATAL_ERROR
      "Launcher state does not record unsupported build action.\n"
      "launcher_state:\n${launcher_state}")
  endif()
endfunction()

file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
file(MAKE_DIRECTORY "${TEST_BINARY_ROOT}")

set(source_dir "${TEST_BINARY_ROOT}/src")
set(binary_dir "${TEST_BINARY_ROOT}/build")
write_c_project("${source_dir}" ReprobuildSmoke C)
run_configure("${source_dir}" "${binary_dir}" TRUE "")
check_provider_metadata("${binary_dir}" "${source_dir}")

if(TEST_MODE STREQUAL "configure")
  set(cxx_source_dir "${TEST_BINARY_ROOT}/unsupported-cxx-src")
  set(cxx_binary_dir "${TEST_BINARY_ROOT}/unsupported-cxx-build")
  write_c_project("${cxx_source_dir}" ReprobuildUnsupported CXX)
  run_configure("${cxx_source_dir}" "${cxx_binary_dir}" FALSE
    "supports only the C language")

  set(multi_binary_dir "${TEST_BINARY_ROOT}/multi-config-build")
  run_configure("${source_dir}" "${multi_binary_dir}" FALSE
    "single-config"
    "-DCMAKE_CONFIGURATION_TYPES=Debug")
elseif(TEST_MODE STREQUAL "build")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" --build "${binary_dir}"
    OUTPUT_VARIABLE build_stdout
    ERROR_VARIABLE build_stderr
    RESULT_VARIABLE build_result
    ENCODING UTF8)
  if(build_result EQUAL 0)
    message(FATAL_ERROR
      "Reprobuild launcher build unexpectedly succeeded.\n"
      "stdout:\n${build_stdout}\n"
      "stderr:\n${build_stderr}")
  endif()
  foreach(expected IN ITEMS
      "Reprobuild launcher reached"
      "unsupported-action=build")
    if(NOT "${build_stderr}" MATCHES "${expected}")
      message(FATAL_ERROR
        "Reprobuild launcher stderr missing '${expected}'.\n"
        "stdout:\n${build_stdout}\n"
        "stderr:\n${build_stderr}")
    endif()
  endforeach()
else()
  message(FATAL_ERROR "Unknown TEST_MODE: ${TEST_MODE}")
endif()
