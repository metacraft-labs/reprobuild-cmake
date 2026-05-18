cmake_minimum_required(VERSION 3.10)

foreach(var IN ITEMS CMAKE_COMMAND TEST_MODE TEST_BINARY_ROOT TEST_C_COMPILER)
  if(NOT DEFINED ${var} OR "${${var}}" STREQUAL "")
    message(FATAL_ERROR "${var} is required")
  endif()
endforeach()

function(write_c_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}/include")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.10)\n"
    "project(${project_name} C)\n"
    "add_executable(hello main.c)\n"
    "target_compile_definitions(hello PRIVATE MSG=\"hello-m2\")\n"
    "target_include_directories(hello PRIVATE include)\n"
    "target_compile_options(hello PRIVATE -Wall)\n"
    "target_link_options(hello PRIVATE \"$<$<PLATFORM_ID:Darwin>:-Wl,-dead_strip>\" \"$<$<PLATFORM_ID:Linux>:-Wl,--as-needed>\")\n")
  file(WRITE "${source_dir}/include/config.h" "#define HELLO_STATUS 0\n")
  file(WRITE "${source_dir}/main.c"
    "#include <stdio.h>\n"
    "#include \"config.h\"\n"
    "#ifndef MSG\n"
    "#  define MSG \"missing\"\n"
    "#endif\n"
    "int main(void) { puts(MSG); return HELLO_STATUS; }\n")
endfunction()

function(write_cxx_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.10)\n"
    "project(${project_name} CXX)\n"
    "add_executable(hello main.cxx)\n")
  file(WRITE "${source_dir}/main.cxx" "int main() { return 0; }\n")
endfunction()

function(write_hyphen_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}/src-dir")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.10)\n"
    "project(${project_name} C)\n"
    "add_executable(my-tool src-dir/main.tool.c)\n"
    "target_compile_definitions(my-tool PRIVATE MSG=\"hyphen-m2\")\n")
  file(WRITE "${source_dir}/src-dir/main.tool.c"
    "#include <stdio.h>\n"
    "#ifndef MSG\n"
    "#  define MSG \"missing\"\n"
    "#endif\n"
    "int main(void) { puts(MSG); return 0; }\n")
endfunction()

function(run_configure source_dir binary_dir expect_success expected_error)
  file(REMOVE_RECURSE "${binary_dir}")
  set(command
    "${CMAKE_COMMAND}"
    -S "${source_dir}"
    -B "${binary_dir}"
    -G Reprobuild
    "-DCMAKE_C_COMPILER=${TEST_C_COMPILER}")
  if(DEFINED TEST_CXX_COMPILER AND NOT "${TEST_CXX_COMPILER}" STREQUAL "")
    list(APPEND command "-DCMAKE_CXX_COMPILER=${TEST_CXX_COMPILER}")
  endif()
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
  set(provider_file "${binary_dir}/reprobuild.nim")
  set(compile_commands "${binary_dir}/compile_commands.json")
  foreach(path IN ITEMS "${provider_dir}" "${metadata_file}" "${launcher_state_file}" "${provider_file}" "${compile_commands}")
    if(NOT EXISTS "${path}")
      message(FATAL_ERROR "Missing Reprobuild generated file: ${path}")
    endif()
  endforeach()

  file(READ "${metadata_file}" metadata)
  foreach(expected IN ITEMS
      "generator=Reprobuild"
      "provider_version=2"
      "m2_action_state=generated"
      "source_dir=${source_dir}"
      "binary_dir=${binary_dir}"
      "default_target=all"
      "targets=all,default,hello")
    string(FIND "${metadata}" "${expected}" found)
    if(found EQUAL -1)
      message(FATAL_ERROR
        "Provider metadata missing '${expected}'.\n"
        "metadata:\n${metadata}")
    endif()
  endforeach()

  file(READ "${provider_file}" provider)
  foreach(expected IN ITEMS
      "buildAction(\"compile-hello"
      "buildAction(\"link-hello"
      "target(\"hello\""
      "aggregate(\"all\""
      "exportTarget(\"default\", allTarget)"
      "defaultTarget(allTarget)")
    string(FIND "${provider}" "${expected}" found)
    if(found EQUAL -1)
      message(FATAL_ERROR
        "Generated provider missing '${expected}'.\n"
        "provider:\n${provider}")
    endif()
  endforeach()

  file(READ "${compile_commands}" commands_json)
  foreach(expected IN ITEMS
      "\"file\": \"${source_dir}/main.c\""
      "-DMSG=\\\"hello-m2\\\""
      "-I${source_dir}/include")
    string(FIND "${commands_json}" "${expected}" found)
    if(found EQUAL -1)
      message(FATAL_ERROR
        "compile_commands.json missing '${expected}'.\n"
        "compile_commands:\n${commands_json}")
    endif()
  endforeach()
endfunction()

function(check_hyphen_provider_metadata binary_dir source_dir)
  set(metadata_file "${binary_dir}/CMakeFiles/reprobuild/provider.meta")
  set(provider_file "${binary_dir}/reprobuild.nim")
  foreach(path IN ITEMS "${metadata_file}" "${provider_file}")
    if(NOT EXISTS "${path}")
      message(FATAL_ERROR "Missing Reprobuild generated file: ${path}")
    endif()
  endforeach()

  file(READ "${metadata_file}" metadata)
  assert_contains("${metadata}" "targets=all,default,my-tool" "hyphen metadata")

  file(READ "${provider_file}" provider)
  foreach(expected IN ITEMS
      "buildAction(\"compile-my-tool"
      "buildAction(\"link-my-tool"
      "target(\"my-tool\"")
    assert_contains("${provider}" "${expected}" "hyphen provider")
  endforeach()
  if(provider MATCHES "let [A-Za-z0-9_]*[-.]")
    message(FATAL_ERROR
      "Generated provider contains an invalid Nim let identifier.\n"
      "provider:\n${provider}")
  endif()
endfunction()

function(require_tool path label)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing ${label}: ${path}")
  endif()
endfunction()

function(start_runquota root socket_var pid_var)
  foreach(var IN ITEMS TEST_RUNQUOTAD)
    if(NOT DEFINED ${var} OR "${${var}}" STREQUAL "")
      message(FATAL_ERROR "${var} is required for M2 build gates")
    endif()
  endforeach()
  require_tool("${TEST_RUNQUOTAD}" "runquotad")
  string(MD5 socket_hash "${root}")
  if(DEFINED ENV{TMPDIR} AND NOT "$ENV{TMPDIR}" STREQUAL "")
    set(socket_dir "$ENV{TMPDIR}")
  else()
    set(socket_dir "/tmp")
  endif()
  set(socket "${socket_dir}/rq-${socket_hash}.sock")
  set(log "${root}/runquotad.log")
  file(REMOVE "${socket}")
  execute_process(
    COMMAND /bin/sh -c "\"${TEST_RUNQUOTAD}\" --socket \"${socket}\" > \"${log}\" 2>&1 & echo $!"
    OUTPUT_VARIABLE pid
    ERROR_VARIABLE daemon_error
    RESULT_VARIABLE daemon_result
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ENCODING UTF8)
  if(NOT daemon_result EQUAL 0 OR "${pid}" STREQUAL "")
    message(FATAL_ERROR "Could not start runquotad.\n${daemon_error}")
  endif()
  foreach(_i RANGE 1 100)
    if(EXISTS "${socket}")
      set(${socket_var} "${socket}" PARENT_SCOPE)
      set(${pid_var} "${pid}" PARENT_SCOPE)
      return()
    endif()
    execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 0.1)
  endforeach()
  execute_process(COMMAND /bin/sh -c "kill ${pid} >/dev/null 2>&1 || true")
  if(EXISTS "${log}")
    file(READ "${log}" daemon_log)
  endif()
  message(FATAL_ERROR "runquotad socket did not appear: ${socket}\n${daemon_log}")
endfunction()

function(stop_runquota pid)
  if(NOT "${pid}" STREQUAL "")
    execute_process(COMMAND /bin/sh -c "kill ${pid} >/dev/null 2>&1 || true")
  endif()
endfunction()

function(run_build binary_dir target socket out_var)
  foreach(var IN ITEMS TEST_REPROBUILD_REPRO TEST_REPROBUILD_SOURCE_ROOT)
    if(NOT DEFINED ${var} OR "${${var}}" STREQUAL "")
      message(FATAL_ERROR "${var} is required for M2 build gates")
    endif()
  endforeach()
  require_tool("${TEST_REPROBUILD_REPRO}" "repro")
  set(command
    "${CMAKE_COMMAND}" -E env
      "RUNQUOTA_SOCKET=${socket}"
      "REPROBUILD_REPRO=${TEST_REPROBUILD_REPRO}"
      "REPROBUILD_SOURCE_ROOT=${TEST_REPROBUILD_SOURCE_ROOT}"
      "${CMAKE_COMMAND}" --build "${binary_dir}")
  if(NOT "${target}" STREQUAL "")
    list(APPEND command --target "${target}")
  endif()
  execute_process(
    COMMAND ${command}
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr
    RESULT_VARIABLE result
    ENCODING UTF8)
  set(output "${stdout}\n${stderr}")
  if(NOT result EQUAL 0)
    message(FATAL_ERROR
      "Reprobuild build failed.\n"
      "Command: ${command}\n"
      "Output:\n${output}")
  endif()
  set(${out_var} "${output}" PARENT_SCOPE)
endfunction()

function(report_path_from_output output out_var)
  string(REGEX MATCH "buildReport: ([^\n\r]+)" match "${output}")
  if(NOT CMAKE_MATCH_1)
    message(FATAL_ERROR "Build output did not include buildReport path.\n${output}")
  endif()
  set(${out_var} "${CMAKE_MATCH_1}" PARENT_SCOPE)
endfunction()

function(assert_contains text expected label)
  string(FIND "${text}" "${expected}" found)
  if(found EQUAL -1)
    message(FATAL_ERROR "${label} missing '${expected}'.\n${text}")
  endif()
endfunction()

file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
file(MAKE_DIRECTORY "${TEST_BINARY_ROOT}")

set(source_dir "${TEST_BINARY_ROOT}/src")
set(binary_dir "${TEST_BINARY_ROOT}/build")
write_c_project("${source_dir}" ReprobuildSmoke)
run_configure("${source_dir}" "${binary_dir}" TRUE "")
check_provider_metadata("${binary_dir}" "${source_dir}")

if(TEST_MODE STREQUAL "configure")
  if(DEFINED TEST_CXX_COMPILER AND NOT "${TEST_CXX_COMPILER}" STREQUAL "")
    set(cxx_source_dir "${TEST_BINARY_ROOT}/cxx-src")
    set(cxx_binary_dir "${TEST_BINARY_ROOT}/cxx-build")
    write_cxx_project("${cxx_source_dir}" ReprobuildCxx)
    run_configure("${cxx_source_dir}" "${cxx_binary_dir}" TRUE "")
  endif()

  set(multi_binary_dir "${TEST_BINARY_ROOT}/multi-config-build")
  run_configure("${source_dir}" "${multi_binary_dir}" FALSE
    "single-config"
    "-DCMAKE_CONFIGURATION_TYPES=Debug")
elseif(TEST_MODE STREQUAL "hello_c_build")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${binary_dir}" "" "${runquota_socket}" default_output)
  execute_process(
    COMMAND "${binary_dir}/hello"
    OUTPUT_VARIABLE run_stdout
    ERROR_VARIABLE run_stderr
    RESULT_VARIABLE run_result
    ENCODING UTF8)
  if(NOT run_result EQUAL 0 OR NOT run_stdout MATCHES "hello-m2")
    stop_runquota("${runquota_pid}")
    message(FATAL_ERROR
      "Built executable did not run correctly.\n"
      "stdout:\n${run_stdout}\n"
      "stderr:\n${run_stderr}")
  endif()
  assert_contains("${default_output}" "defaultTarget: all" "default build output")
  assert_contains("${default_output}" "selectedTarget: all" "default build output")
  run_build("${binary_dir}" "all" "${runquota_socket}" all_output)
  run_build("${binary_dir}" "default" "${runquota_socket}" explicit_default_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${all_output}" "selectedTarget: all" "all target build output")
  assert_contains("${explicit_default_output}" "selectedTarget: default" "explicit default target build output")
elseif(TEST_MODE STREQUAL "hyphen_target_build")
  set(hyphen_source_dir "${TEST_BINARY_ROOT}/hyphen-src")
  set(hyphen_binary_dir "${TEST_BINARY_ROOT}/hyphen-build")
  write_hyphen_project("${hyphen_source_dir}" ReprobuildHyphenTarget)
  run_configure("${hyphen_source_dir}" "${hyphen_binary_dir}" TRUE "")
  check_hyphen_provider_metadata("${hyphen_binary_dir}" "${hyphen_source_dir}")

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${hyphen_binary_dir}" "my-tool" "${runquota_socket}" hyphen_output)
  execute_process(
    COMMAND "${hyphen_binary_dir}/my-tool"
    OUTPUT_VARIABLE run_stdout
    ERROR_VARIABLE run_stderr
    RESULT_VARIABLE run_result
    ENCODING UTF8)
  stop_runquota("${runquota_pid}")
  if(NOT run_result EQUAL 0 OR NOT run_stdout MATCHES "hyphen-m2")
    message(FATAL_ERROR
      "Hyphenated executable did not run correctly.\n"
      "stdout:\n${run_stdout}\n"
      "stderr:\n${run_stderr}")
  endif()
  assert_contains("${hyphen_output}" "selectedTarget: my-tool" "hyphen build output")
elseif(TEST_MODE STREQUAL "actions_use_runquota")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${binary_dir}" "hello" "${runquota_socket}" build_output)
  stop_runquota("${runquota_pid}")
  report_path_from_output("${build_output}" report_path)
  file(READ "${report_path}" report)
  foreach(expected IN ITEMS
      "\"id\": \"compile-hello"
      "\"id\": \"hello\""
      "\"status\": \"asSucceeded\""
      "\"launched\": true"
      "\"runQuotaBackend\": \"posix-fork-exec-poll\""
      "\"runQuotaSocket\": \"${runquota_socket}\"")
    assert_contains("${report}" "${expected}" "RunQuota build report")
  endforeach()
elseif(TEST_MODE STREQUAL "rebuild_cache_hit")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${binary_dir}" "hello" "${runquota_socket}" first_output)
  run_build("${binary_dir}" "hello" "${runquota_socket}" second_output)
  stop_runquota("${runquota_pid}")
  foreach(expected IN ITEMS
      "action: compile-hello"
      "status=asCacheHit"
      "launched=false"
      "action: hello status=asCacheHit launched=false")
    assert_contains("${second_output}" "${expected}" "second build output")
  endforeach()
  report_path_from_output("${second_output}" report_path)
  file(READ "${report_path}" report)
  assert_contains("${report}" "\"status\": \"asCacheHit\"" "second build report")
  assert_contains("${report}" "\"launched\": false" "second build report")
  execute_process(
    COMMAND /bin/sh -c "test -x \"$1\"" sh "${binary_dir}/hello"
    RESULT_VARIABLE executable_result
    ERROR_VARIABLE executable_stderr
    ENCODING UTF8)
  if(NOT executable_result EQUAL 0)
    message(FATAL_ERROR
      "Cache-hit restored executable is not executable: ${binary_dir}/hello\n"
      "stderr:\n${executable_stderr}")
  endif()
  execute_process(
    COMMAND "${binary_dir}/hello"
    OUTPUT_VARIABLE run_stdout
    ERROR_VARIABLE run_stderr
    RESULT_VARIABLE run_result
    ENCODING UTF8)
  if(NOT run_result EQUAL 0 OR NOT run_stdout MATCHES "hello-m2")
    message(FATAL_ERROR
      "Cache-hit restored executable did not run correctly.\n"
      "stdout:\n${run_stdout}\n"
      "stderr:\n${run_stderr}")
  endif()
else()
  message(FATAL_ERROR "Unknown TEST_MODE: ${TEST_MODE}")
endif()
