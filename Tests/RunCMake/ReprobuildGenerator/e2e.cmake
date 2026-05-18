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
      "provider_version=3"
      "m2_action_state=generated"
      "m3_action_state=generated"
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
      "makeDepfilePolicy("
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
  string(REPLACE ";" " " extra_args "${ARGN}")
  execute_process(
    COMMAND /bin/sh -c "\"${TEST_RUNQUOTAD}\" --socket \"${socket}\" ${extra_args} > \"${log}\" 2>&1 & echo $!"
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

function(assert_not_contains text unexpected label)
  string(FIND "${text}" "${unexpected}" found)
  if(NOT found EQUAL -1)
    message(FATAL_ERROR "${label} unexpectedly contained '${unexpected}'.\n${text}")
  endif()
endfunction()

function(write_depfile_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}/include")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.10)\n"
    "project(${project_name} C)\n"
    "add_executable(depapp main.c a.c b.c)\n"
    "target_include_directories(depapp PRIVATE include)\n")
  file(WRITE "${source_dir}/include/a.h" "#define A_VALUE 10\n")
  file(WRITE "${source_dir}/a.c" "#include \"a.h\"\nint a_value(void) { return A_VALUE; }\n")
  file(WRITE "${source_dir}/b.c" "int b_value(void) { return 20; }\n")
  file(WRITE "${source_dir}/main.c"
    "int a_value(void);\nint b_value(void);\nint main(void) { return a_value() + b_value() == 30 ? 0 : 1; }\n")
endfunction()

function(write_response_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  set(defs "IDENTITY_FLAG=1")
  foreach(i RANGE 1 360)
    list(APPEND defs "LONG_RESPONSE_DEFINE_${i}=value_${i}_${i}_${i}_${i}")
  endforeach()
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.10)\n"
    "project(${project_name} C)\n"
    "add_executable(rspapp main.c)\n"
    "target_compile_definitions(rspapp PRIVATE ${defs})\n")
  file(WRITE "${source_dir}/main.c"
    "#ifndef IDENTITY_FLAG\n#error missing response identity flag\n#endif\n"
    "int main(void) { return IDENTITY_FLAG; }\n")
endfunction()

function(write_pool_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/launcher.sh"
    "#!/bin/sh\n"
    "log=\"$1\"\n"
    "shift\n"
    "printf 'start %s %s\\n' \"$3\" \"$(date +%s)\" >> \"$log\"\n"
    "sleep 1\n"
    "printf 'end %s %s\\n' \"$3\" \"$(date +%s)\" >> \"$log\"\n"
    "exec \"$@\"\n")
  execute_process(COMMAND /bin/sh -c "chmod +x \"$1\"" sh "${source_dir}/launcher.sh")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.10)\n"
    "project(${project_name} C)\n"
    "set_property(GLOBAL PROPERTY JOB_POOLS slow_compile=1)\n"
    "set_property(GLOBAL PROPERTY RULE_LAUNCH_COMPILE \"${source_dir}/launcher.sh;${source_dir}/pool.log\")\n"
    "add_executable(poolapp main.c a.c b.c)\n"
    "set_property(TARGET poolapp PROPERTY JOB_POOL_COMPILE slow_compile)\n")
  file(WRITE "${source_dir}/main.c" "int a(void); int b(void); int main(void) { return a() + b() == 3 ? 0 : 1; }\n")
  file(WRITE "${source_dir}/a.c" "int a(void) { return 1; }\n")
  file(WRITE "${source_dir}/b.c" "int b(void) { return 2; }\n")
endfunction()

function(write_pch_pool_project source_dir project_name)
  if(NOT DEFINED TEST_CXX_COMPILER OR "${TEST_CXX_COMPILER}" STREQUAL "")
    message(FATAL_ERROR "TEST_CXX_COMPILER is required for PCH pool build gate")
  endif()

  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.16)\n"
    "project(${project_name} CXX)\n"
    "set_property(GLOBAL PROPERTY JOB_POOLS pch_pool=1 compile_pool=2)\n"
    "add_executable(pchapp main.cxx)\n"
    "target_precompile_headers(pchapp PRIVATE \"${source_dir}/pch.hxx\")\n"
    "set_property(TARGET pchapp PROPERTY JOB_POOL_PRECOMPILE_HEADER pch_pool)\n"
    "set_property(TARGET pchapp PROPERTY JOB_POOL_COMPILE compile_pool)\n")
  file(WRITE "${source_dir}/pch.hxx"
    "#pragma once\n"
    "#define PCH_MAGIC 7\n"
    "#include <string>\n"
    "inline std::string pch_value() { return \"pch-ok\"; }\n")
  file(WRITE "${source_dir}/main.cxx"
    "#ifndef PCH_MAGIC\n"
    "#  error precompiled header was not force-included\n"
    "#endif\n"
    "int main() { std::string value = pch_value(); return value == \"pch-ok\" ? 0 : 1; }\n")
endfunction()

function(write_uses_terminal_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/terminal.sh"
    "#!/bin/sh\n"
    "log=\"$1\"\n"
    "label=\"$2\"\n"
    "printf 'start %s %s\\n' \"$label\" \"$(date +%s)\" >> \"$log\"\n"
    "sleep 1\n"
    "printf 'end %s %s\\n' \"$label\" \"$(date +%s)\" >> \"$log\"\n")
  execute_process(COMMAND /bin/sh -c "chmod +x \"$1\"" sh "${source_dir}/terminal.sh")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.10)\n"
    "project(${project_name} C)\n"
    "add_executable(anchor main.c)\n"
    "add_custom_target(terminal_a ALL COMMAND \"${source_dir}/terminal.sh\" \"${source_dir}/terminal.log\" a USES_TERMINAL)\n"
    "add_custom_target(terminal_b ALL COMMAND \"${source_dir}/terminal.sh\" \"${source_dir}/terminal.log\" b USES_TERMINAL)\n")
  file(WRITE "${source_dir}/main.c" "int main(void) { return 0; }\n")
endfunction()

function(write_clean_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.10)\n"
    "project(${project_name} C)\n"
    "add_executable(cleanapp main.c)\n"
    "target_link_options(cleanapp PRIVATE \"$<$<PLATFORM_ID:Darwin>:-Wl,-map,cleanapp.map>\" \"$<$<PLATFORM_ID:Linux>:-Wl,-Map,cleanapp.map>\")\n"
    "set_property(TARGET cleanapp PROPERTY ADDITIONAL_CLEAN_FILES \"cleanapp.map;extra.clean\")\n")
  file(WRITE "${source_dir}/main.c" "int main(void) { return 0; }\n")
endfunction()

function(write_library_matrix_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  set(event_log "${source_dir}/build-events.log")
  file(WRITE "${source_dir}/event.sh"
    "#!/bin/sh\n"
    "printf '%s\\n' \"$2\" >> \"$1\"\n")
  execute_process(COMMAND /bin/sh -c "chmod +x \"$1\"" sh "${source_dir}/event.sh")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.16)\n"
    "project(${project_name} C)\n"
    "set(CMAKE_MACOSX_RPATH ON)\n"
    "add_library(objlib OBJECT obj.c)\n"
    "add_library(stlib STATIC static.c \$<TARGET_OBJECTS:objlib>)\n"
    "add_library(shlib SHARED shared.c)\n"
    "set_target_properties(shlib PROPERTIES VERSION 1.2.3 SOVERSION 1)\n"
    "add_library(modlib MODULE module.c)\n"
    "add_executable(libapp main.c)\n"
    "target_link_libraries(libapp PRIVATE stlib shlib)\n"
    "add_custom_command(TARGET libapp PRE_BUILD COMMAND \"${source_dir}/event.sh\" \"${event_log}\" pre-build)\n"
    "add_custom_command(TARGET libapp PRE_LINK COMMAND \"${source_dir}/event.sh\" \"${event_log}\" pre-link)\n"
    "add_custom_command(TARGET libapp POST_BUILD COMMAND \"${source_dir}/event.sh\" \"${event_log}\" post-build)\n")
  file(WRITE "${source_dir}/obj.c" "int obj_value(void) { return 5; }\n")
  file(WRITE "${source_dir}/static.c" "int obj_value(void);\nint static_value(void) { return obj_value() + 7; }\n")
  file(WRITE "${source_dir}/shared.c" "int shared_value(void) { return 11; }\n")
  file(WRITE "${source_dir}/module.c" "int module_value(void) { return 13; }\n")
  file(WRITE "${source_dir}/main.c"
    "int static_value(void);\nint shared_value(void);\n"
    "int main(void) { return static_value() == 12 && shared_value() == 11 ? 0 : 1; }\n")
endfunction()

function(versioned_shared_paths binary_dir base out_var)
  if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    set(paths
      "${binary_dir}/lib${base}.1.2.3.dylib"
      "${binary_dir}/lib${base}.1.dylib"
      "${binary_dir}/lib${base}.dylib")
  elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
    set(paths
      "${binary_dir}/lib${base}.so.1.2.3"
      "${binary_dir}/lib${base}.so.1"
      "${binary_dir}/lib${base}.so")
  else()
    set(paths "${binary_dir}/${CMAKE_SHARED_LIBRARY_PREFIX}${base}${CMAKE_SHARED_LIBRARY_SUFFIX}")
  endif()
  set(${out_var} "${paths}" PARENT_SCOPE)
endfunction()

function(assert_file_exists path label)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "${label} missing expected file: ${path}")
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
elseif(TEST_MODE STREQUAL "depfile_header_rebuild")
  set(dep_source_dir "${TEST_BINARY_ROOT}/dep-src")
  set(dep_binary_dir "${TEST_BINARY_ROOT}/dep-build")
  write_depfile_project("${dep_source_dir}" ReprobuildDepfile)
  run_configure("${dep_source_dir}" "${dep_binary_dir}" TRUE "")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${dep_binary_dir}" "depapp" "${runquota_socket}" first_output)
  report_path_from_output("${first_output}" first_report_path)
  file(READ "${first_report_path}" first_report)
  assert_contains("${first_report}" "${dep_source_dir}/include/a.h" "depfile evidence report")
  file(WRITE "${dep_source_dir}/include/a.h" "#define A_VALUE 11\n")
  run_build("${dep_binary_dir}" "depapp" "${runquota_socket}" second_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${second_output}" "a.c.o status=asSucceeded launched=true" "header rebuild output")
  assert_not_contains("${second_output}" "b.c.o status=asSucceeded launched=true" "header rebuild output")
  assert_contains("${second_output}" "b.c.o status=asCacheHit launched=false" "header rebuild output")
elseif(TEST_MODE STREQUAL "response_file_identity")
  set(rsp_source_dir "${TEST_BINARY_ROOT}/rsp-src")
  set(rsp_binary_dir "${TEST_BINARY_ROOT}/rsp-build")
  write_response_project("${rsp_source_dir}" ReprobuildResponse)
  run_configure("${rsp_source_dir}" "${rsp_binary_dir}" TRUE "")
  file(GLOB rsp_files "${rsp_binary_dir}/CMakeFiles/reprobuild/rsp/*.rsp")
  list(LENGTH rsp_files rsp_count)
  if(rsp_count LESS 1)
    message(FATAL_ERROR "Expected generated response file in ${rsp_binary_dir}/CMakeFiles/reprobuild/rsp")
  endif()
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${rsp_binary_dir}" "rspapp" "${runquota_socket}" first_output)
  list(GET rsp_files 0 rsp_file)
  file(READ "${rsp_file}" rsp_content)
  string(REPLACE "IDENTITY_FLAG=1" "IDENTITY_FLAG=2" rsp_content2 "${rsp_content}")
  if("${rsp_content2}" STREQUAL "${rsp_content}")
    stop_runquota("${runquota_pid}")
    message(FATAL_ERROR "Response file did not contain IDENTITY_FLAG=1:\n${rsp_content}")
  endif()
  file(WRITE "${rsp_file}" "${rsp_content2}")
  run_build("${rsp_binary_dir}" "rspapp" "${runquota_socket}" second_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${second_output}" "main.c.o status=asSucceeded launched=true" "response rebuild output")
  execute_process(COMMAND "${rsp_binary_dir}/rspapp" RESULT_VARIABLE rsp_result)
  if(NOT rsp_result EQUAL 2)
    message(FATAL_ERROR "Response-file identity edit did not affect executable exit code: ${rsp_result}")
  endif()
elseif(TEST_MODE STREQUAL "pool_limit")
  set(pool_source_dir "${TEST_BINARY_ROOT}/pool-src")
  set(pool_binary_dir "${TEST_BINARY_ROOT}/pool-build")
  write_pool_project("${pool_source_dir}" ReprobuildPool)
  run_configure("${pool_source_dir}" "${pool_binary_dir}" TRUE "")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid "--pool slow_compile=1")
  run_build("${pool_binary_dir}" "poolapp" "${runquota_socket}" pool_output)
  stop_runquota("${runquota_pid}")
  file(READ "${pool_source_dir}/pool.log" pool_log)
  string(REGEX MATCH "start[^\n]*\nstart" overlapping_starts "${pool_log}")
  if(overlapping_starts)
    message(FATAL_ERROR "Pool-limited compiles overlapped before an end event.\n${pool_log}")
  endif()
  report_path_from_output("${pool_output}" pool_report_path)
  file(READ "${pool_report_path}" pool_report)
  assert_contains("${pool_report}" "pool=slow_compile" "pool scheduler trace")
elseif(TEST_MODE STREQUAL "pch_pool_build")
  set(pch_source_dir "${TEST_BINARY_ROOT}/pch-src")
  set(pch_binary_dir "${TEST_BINARY_ROOT}/pch-build")
  write_pch_pool_project("${pch_source_dir}" ReprobuildPchPool)
  run_configure("${pch_source_dir}" "${pch_binary_dir}" TRUE "")
  file(READ "${pch_binary_dir}/reprobuild.nim" pch_provider)
  assert_contains("${pch_provider}" "buildPool(\"pch_pool\", 1'u32)" "PCH provider")
  assert_contains("${pch_provider}" "pool = \"pch_pool\"" "PCH provider")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid "--pool pch_pool=1 --pool compile_pool=2")
  run_build("${pch_binary_dir}" "pchapp" "${runquota_socket}" pch_output)
  stop_runquota("${runquota_pid}")
  execute_process(
    COMMAND "${pch_binary_dir}/pchapp"
    OUTPUT_VARIABLE run_stdout
    ERROR_VARIABLE run_stderr
    RESULT_VARIABLE run_result
    ENCODING UTF8)
  if(NOT run_result EQUAL 0)
    message(FATAL_ERROR
      "PCH executable did not run correctly.\n"
      "stdout:\n${run_stdout}\n"
      "stderr:\n${run_stderr}")
  endif()
  report_path_from_output("${pch_output}" pch_report_path)
  file(READ "${pch_report_path}" pch_report)
  assert_contains("${pch_report}" "cmake_pch" "PCH build report")
  assert_contains("${pch_report}" "pool=pch_pool" "PCH scheduler trace")
elseif(TEST_MODE STREQUAL "uses_terminal_pool")
  set(term_source_dir "${TEST_BINARY_ROOT}/terminal-src")
  set(term_binary_dir "${TEST_BINARY_ROOT}/terminal-build")
  write_uses_terminal_project("${term_source_dir}" ReprobuildUsesTerminal)
  run_configure("${term_source_dir}" "${term_binary_dir}" TRUE "")
  file(READ "${term_binary_dir}/reprobuild.nim" term_provider)
  assert_contains("${term_provider}" "buildPool(\"console\", 1'u32)" "USES_TERMINAL provider")
  assert_contains("${term_provider}" "pool = \"console\"" "USES_TERMINAL provider")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid "--pool console=1")
  run_build("${term_binary_dir}" "" "${runquota_socket}" term_output)
  stop_runquota("${runquota_pid}")
  file(READ "${term_source_dir}/terminal.log" term_log)
  string(REGEX MATCH "start[^\n]*\nstart" overlapping_starts "${term_log}")
  if(overlapping_starts)
    message(FATAL_ERROR "USES_TERMINAL custom targets overlapped before an end event.\n${term_log}")
  endif()
  report_path_from_output("${term_output}" term_report_path)
  file(READ "${term_report_path}" term_report)
  assert_contains("${term_report}" "\"id\": \"terminal_a\"" "USES_TERMINAL build report")
  assert_contains("${term_report}" "\"id\": \"terminal_b\"" "USES_TERMINAL build report")
  assert_contains("${term_report}" "pool=console" "USES_TERMINAL scheduler trace")
elseif(TEST_MODE STREQUAL "clean_outputs")
  set(clean_source_dir "${TEST_BINARY_ROOT}/clean-src")
  set(clean_binary_dir "${TEST_BINARY_ROOT}/clean-build")
  write_clean_project("${clean_source_dir}" ReprobuildClean)
  run_configure("${clean_source_dir}" "${clean_binary_dir}" TRUE "")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${clean_binary_dir}" "cleanapp" "${runquota_socket}" clean_output)
  stop_runquota("${runquota_pid}")
  file(WRITE "${clean_binary_dir}/extra.clean" "extra\n")
  foreach(path IN ITEMS "${clean_binary_dir}/cleanapp" "${clean_binary_dir}/cleanapp.map" "${clean_binary_dir}/extra.clean")
    if(NOT EXISTS "${path}")
      message(FATAL_ERROR "Expected build/clean fixture output missing before clean: ${path}")
    endif()
  endforeach()
  set(store_dir "${clean_binary_dir}/CMakeFiles/reprobuild/worktrees")
  if(NOT EXISTS "${store_dir}")
    message(FATAL_ERROR "Expected Reprobuild work root missing before clean: ${store_dir}")
  endif()
  execute_process(
    COMMAND "${CMAKE_COMMAND}" --build "${clean_binary_dir}" --target clean
    OUTPUT_VARIABLE clean_stdout
    ERROR_VARIABLE clean_stderr
    RESULT_VARIABLE clean_result
    ENCODING UTF8)
  if(NOT clean_result EQUAL 0)
    message(FATAL_ERROR "Clean failed.\nstdout:\n${clean_stdout}\nstderr:\n${clean_stderr}")
  endif()
  foreach(path IN ITEMS "${clean_binary_dir}/cleanapp" "${clean_binary_dir}/cleanapp.map" "${clean_binary_dir}/extra.clean")
    if(EXISTS "${path}")
      message(FATAL_ERROR "Clean did not remove ${path}")
    endif()
  endforeach()
  if(NOT EXISTS "${store_dir}")
    message(FATAL_ERROR "Clean removed Reprobuild store/work root: ${store_dir}")
  endif()
elseif(TEST_MODE STREQUAL "library_target_matrix")
  set(lib_source_dir "${TEST_BINARY_ROOT}/lib-src")
  set(lib_binary_dir "${TEST_BINARY_ROOT}/lib-build")
  write_library_matrix_project("${lib_source_dir}" ReprobuildLibraries)
  run_configure("${lib_source_dir}" "${lib_binary_dir}" TRUE "")
  file(READ "${lib_binary_dir}/reprobuild.nim" provider)
  foreach(expected IN ITEMS
      "target(\"objlib\""
      "target(\"stlib\""
      "target(\"shlib\""
      "target(\"modlib\""
      "target(\"libapp\""
      "buildAction(\"link-stlib\""
      "buildAction(\"link-shlib\""
      "buildAction(\"link-modlib\""
      "buildAction(\"pre-build-libapp"
      "buildAction(\"pre-link-libapp"
      "buildAction(\"post-build-libapp")
    assert_contains("${provider}" "${expected}" "library matrix provider")
  endforeach()
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${lib_binary_dir}" "" "${runquota_socket}" matrix_output)
  stop_runquota("${runquota_pid}")
  assert_file_exists("${lib_binary_dir}/libstlib.a" "library matrix")
  versioned_shared_paths("${lib_binary_dir}" "shlib" shlib_paths)
  foreach(path IN LISTS shlib_paths)
    assert_file_exists("${path}" "library matrix")
  endforeach()
  if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    assert_file_exists("${lib_binary_dir}/libmodlib.so" "library matrix")
  elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
    assert_file_exists("${lib_binary_dir}/libmodlib.so" "library matrix")
  endif()
  execute_process(COMMAND "${lib_binary_dir}/libapp" RESULT_VARIABLE app_result)
  if(NOT app_result EQUAL 0)
    message(FATAL_ERROR "Library matrix executable failed with ${app_result}")
  endif()
  file(READ "${lib_source_dir}/build-events.log" event_log)
  string(REGEX MATCH "pre-build\npre-link\npost-build\n" ordered_events "${event_log}")
  if(NOT ordered_events)
    message(FATAL_ERROR "Target build events did not run in order.\n${event_log}")
  endif()
elseif(TEST_MODE STREQUAL "link_byproducts")
  set(by_source_dir "${TEST_BINARY_ROOT}/by-src")
  set(by_binary_dir "${TEST_BINARY_ROOT}/by-build")
  write_library_matrix_project("${by_source_dir}" ReprobuildByproducts)
  run_configure("${by_source_dir}" "${by_binary_dir}" TRUE "")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${by_binary_dir}" "shlib" "${runquota_socket}" by_output)
  stop_runquota("${runquota_pid}")
  file(READ "${by_binary_dir}/CMakeFiles/reprobuild/provider.meta" metadata)
  assert_contains("${metadata}" "m4_action_state=generated" "M4 metadata")
  assert_contains("${metadata}" "m4_symlink_outputs=generated" "M4 metadata")
  assert_contains("${metadata}" "m4_import_library_outputs=not_applicable_on_host" "M4 metadata")
  assert_contains("${metadata}" "m4_debug_symbol_outputs=not_applicable_on_host" "M4 metadata")
  file(READ "${by_binary_dir}/reprobuild.nim" provider)
  versioned_shared_paths("${by_binary_dir}" "shlib" shlib_paths)
  foreach(path IN LISTS shlib_paths)
    assert_file_exists("${path}" "link byproducts")
    file(RELATIVE_PATH rel "${by_binary_dir}" "${path}")
    assert_contains("${provider}" "${rel}" "link byproducts provider")
  endforeach()
  report_path_from_output("${by_output}" by_report_path)
  file(READ "${by_report_path}" by_report)
  assert_contains("${by_report}" "\"id\": \"link-shlib\"" "link byproducts report")
  assert_contains("${by_report}" "\"id\": \"symlink-shlib\"" "link byproducts report")
elseif(TEST_MODE STREQUAL "library_incremental_relink")
  set(inc_source_dir "${TEST_BINARY_ROOT}/inc-src")
  set(inc_binary_dir "${TEST_BINARY_ROOT}/inc-build")
  write_library_matrix_project("${inc_source_dir}" ReprobuildIncremental)
  run_configure("${inc_source_dir}" "${inc_binary_dir}" TRUE "")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${inc_binary_dir}" "libapp" "${runquota_socket}" first_output)
  file(WRITE "${inc_source_dir}/shared.c" "int shared_value(void) { return 12; }\n")
  run_build("${inc_binary_dir}" "libapp" "${runquota_socket}" second_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${second_output}" "shared.c.o status=asSucceeded launched=true" "incremental relink output")
  assert_contains("${second_output}" "action: link-shlib status=asSucceeded launched=true" "incremental relink output")
  assert_contains("${second_output}" "action: link-libapp status=asSucceeded launched=true" "incremental relink output")
  assert_not_contains("${second_output}" "static.c.o status=asSucceeded launched=true" "incremental relink output")
  report_path_from_output("${second_output}" inc_report_path)
  file(READ "${inc_report_path}" inc_report)
  assert_contains("${inc_report}" "\"id\": \"link-libapp\"" "incremental relink report")
else()
  message(FATAL_ERROR "Unknown TEST_MODE: ${TEST_MODE}")
endif()
