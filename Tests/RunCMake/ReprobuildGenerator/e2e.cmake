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

function(run_build_expect_failure binary_dir target socket out_var)
  foreach(var IN ITEMS TEST_REPROBUILD_REPRO TEST_REPROBUILD_SOURCE_ROOT)
    if(NOT DEFINED ${var} OR "${${var}}" STREQUAL "")
      message(FATAL_ERROR "${var} is required for M6 failure gates")
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
  if(result EQUAL 0)
    message(FATAL_ERROR
      "Reprobuild build succeeded unexpectedly.\n"
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

function(write_custom_target_working_directory_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/record_wd.cmake"
    "execute_process(COMMAND /bin/pwd OUTPUT_VARIABLE pwd OUTPUT_STRIP_TRAILING_WHITESPACE)\n"
    "file(WRITE wd.txt \"\${pwd}\\n\")\n")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} C)\n"
    "add_executable(anchor main.c)\n"
    "set(command_wd \"\${CMAKE_CURRENT_BINARY_DIR}/command-wd\")\n"
    "file(MAKE_DIRECTORY \"\${command_wd}\")\n"
    "add_custom_target(write_wd\n"
    "  COMMAND \"\${CMAKE_COMMAND}\" -P \"${source_dir}/record_wd.cmake\"\n"
    "  BYPRODUCTS \"\${command_wd}/wd.txt\"\n"
    "  WORKING_DIRECTORY \"\${command_wd}\"\n"
    "  VERBATIM)\n")
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

function(write_generated_source_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/generate.cmake"
    "file(READ \"\${INPUT}\" value)\n"
    "string(STRIP \"\${value}\" value)\n"
    "file(WRITE \"\${OUT}\" \"int generated_value(void) { return \${value}; }\\n\")\n"
    "file(WRITE \"\${STAMP}\" \"generated \${value}\\n\")\n")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} C)\n"
    "set_property(GLOBAL PROPERTY JOB_POOLS codegen=1)\n"
    "set(generated \"\${CMAKE_CURRENT_BINARY_DIR}/generated.c\")\n"
    "add_custom_command(OUTPUT \"\${generated}\"\n"
    "  BYPRODUCTS \"\${CMAKE_CURRENT_BINARY_DIR}/generated.stamp\"\n"
    "  COMMAND \"\${CMAKE_COMMAND}\" -DINPUT=${source_dir}/number.txt -DOUT=\${generated} -DSTAMP=\${CMAKE_CURRENT_BINARY_DIR}/generated.stamp -P \"${source_dir}/generate.cmake\"\n"
    "  DEPENDS \"${source_dir}/number.txt\"\n"
    "  WORKING_DIRECTORY \"\${CMAKE_CURRENT_BINARY_DIR}\"\n"
    "  COMMENT \"Generating C source for Reprobuild\"\n"
    "  JOB_POOL codegen\n"
    "  VERBATIM)\n"
    "add_executable(genapp main.c \"\${generated}\")\n")
  file(WRITE "${source_dir}/number.txt" "42\n")
  file(WRITE "${source_dir}/main.c"
    "int generated_value(void);\n"
    "int main(void) { return generated_value() == 42 ? 0 : 1; }\n")
endfunction()

function(write_custom_depfile_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/make_generated.cmake"
    "file(READ \"\${VISIBLE}\" visible)\n"
    "file(READ \"\${HIDDEN}\" hidden)\n"
    "string(STRIP \"\${visible}\" visible)\n"
    "string(STRIP \"\${hidden}\" hidden)\n"
    "file(WRITE \"\${OUT}\" \"int generated_value(void) { return \${visible} + \${hidden}; }\\n\")\n"
    "file(WRITE \"\${DEP}\" \"\${OUT}: \${VISIBLE} \${HIDDEN}\\n\")\n")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} C)\n"
    "set(generated \"\${CMAKE_CURRENT_BINARY_DIR}/generated.c\")\n"
    "set(depfile \"\${CMAKE_CURRENT_BINARY_DIR}/generated.d\")\n"
    "add_custom_command(OUTPUT \"\${generated}\"\n"
    "  COMMAND \"\${CMAKE_COMMAND}\" -DOUT=\${generated} -DDEP=\${depfile} -DVISIBLE=${source_dir}/visible.txt -DHIDDEN=${source_dir}/hidden.txt -P \"${source_dir}/make_generated.cmake\"\n"
    "  DEPENDS \"${source_dir}/visible.txt\"\n"
    "  DEPFILE \"\${depfile}\"\n"
    "  WORKING_DIRECTORY \"\${CMAKE_CURRENT_BINARY_DIR}\"\n"
    "  COMMENT \"Generating C source with hidden depfile input\"\n"
    "  VERBATIM)\n"
    "add_executable(depgen main.c \"\${generated}\")\n")
  file(WRITE "${source_dir}/visible.txt" "30\n")
  file(WRITE "${source_dir}/hidden.txt" "12\n")
  file(WRITE "${source_dir}/main.c"
    "int generated_value(void);\n"
    "int main(void) { return generated_value() == 42 ? 0 : 1; }\n")
endfunction()

function(write_builtin_project source_dir project_name install_prefix)
  file(REMOVE_RECURSE "${source_dir}" "${install_prefix}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} C)\n"
    "include(CTest)\n"
    "set(CPACK_GENERATOR TGZ)\n"
    "set(CPACK_SOURCE_GENERATOR TGZ)\n"
    "set(CPACK_PACKAGE_FILE_NAME reprobuild-builtins-pkg)\n"
    "set(CPACK_SOURCE_PACKAGE_FILE_NAME reprobuild-builtins-src)\n"
    "set(CPACK_SOURCE_IGNORE_FILES \"/builtin-build/;/.git/\")\n"
    "add_executable(instapp main.c)\n"
    "add_test(NAME instapp_runs COMMAND instapp)\n"
    "install(TARGETS instapp RUNTIME DESTINATION bin)\n"
    "include(CPack)\n")
  file(WRITE "${source_dir}/main.c" "int main(void) { return 0; }\n")
endfunction()

function(write_regeneration_project source_dir project_name value)
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} C)\n"
    "add_executable(regenapp main.c)\n"
    "target_compile_definitions(regenapp PRIVATE REGEN_VALUE=${value})\n")
  file(WRITE "${source_dir}/main.c"
    "/* regeneration source value ${value} */\n"
    "#ifndef REGEN_VALUE\n"
    "#  error REGEN_VALUE missing\n"
    "#endif\n"
    "int main(void) { return REGEN_VALUE; }\n")
endfunction()

function(write_glob_regeneration_project source_dir project_name with_extra)
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} C)\n"
    "file(GLOB glob_sources CONFIGURE_DEPENDS \"\${CMAKE_CURRENT_SOURCE_DIR}/*.c\")\n"
    "add_executable(globapp \${glob_sources})\n")
  if(with_extra)
    file(WRITE "${source_dir}/main.c"
      "int base_value(void); int extra_value(void);\n"
      "int main(void) { return base_value() + extra_value() == 9 ? 0 : 1; }\n")
    file(WRITE "${source_dir}/extra.c" "int extra_value(void) { return 4; }\n")
  else()
    file(REMOVE "${source_dir}/extra.c")
    file(WRITE "${source_dir}/main.c"
      "int base_value(void);\n"
      "int main(void) { return base_value() == 5 ? 0 : 1; }\n")
  endif()
  file(WRITE "${source_dir}/base.c" "int base_value(void) { return 5; }\n")
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

function(assert_file_not_exists path label)
  if(EXISTS "${path}")
    message(FATAL_ERROR "${label} unexpectedly produced file: ${path}")
  endif()
endfunction()

function(write_cxx_modules_project source_dir project_name)
  if(NOT DEFINED TEST_CXX_COMPILER OR "${TEST_CXX_COMPILER}" STREQUAL "")
    message(FATAL_ERROR "TEST_CXX_COMPILER is required for C++20 module gates")
  endif()

  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 4.1)\n"
    "project(${project_name} CXX)\n"
    "set(CMAKE_CXX_STANDARD 20)\n"
    "set(CMAKE_CXX_SCAN_FOR_MODULES ON)\n"
    "add_executable(app main.cpp)\n"
    "target_sources(app PRIVATE FILE_SET CXX_MODULES FILES m.cppm)\n")
  file(WRITE "${source_dir}/m.cppm"
    "export module m;\n"
    "export int answer() { return 42; }\n")
  file(WRITE "${source_dir}/main.cpp"
    "import m;\n"
    "int main() { return answer() == 42 ? 0 : 1; }\n")
endfunction()

function(write_fortran_modules_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} Fortran)\n"
    "add_executable(fapp main.f90 mathmod.f90)\n")
  file(WRITE "${source_dir}/mathmod.f90"
    "module mathmod\n"
    "contains\n"
    "  integer function answer()\n"
    "    answer = 42\n"
    "  end function answer\n"
    "end module mathmod\n")
  file(WRITE "${source_dir}/main.f90"
    "program main\n"
    "  use mathmod\n"
    "  if (answer() /= 42) stop 1\n"
    "end program main\n")
endfunction()

function(resolve_fortran_compiler out_var)
  if(DEFINED TEST_FORTRAN_COMPILER AND
      NOT "${TEST_FORTRAN_COMPILER}" STREQUAL "" AND
      NOT "${TEST_FORTRAN_COMPILER}" MATCHES "NOTFOUND$")
    set(${out_var} "${TEST_FORTRAN_COMPILER}" PARENT_SCOPE)
    return()
  endif()
  find_program(found_fortran NAMES gfortran flang ifx ifort)
  if(found_fortran)
    set(${out_var} "${found_fortran}" PARENT_SCOPE)
  else()
    set(${out_var} "" PARENT_SCOPE)
  endif()
endfunction()

function(find_module_scan_wrapper binary_dir needle out_var)
  file(GLOB wrappers "${binary_dir}/CMakeFiles/reprobuild/bin/*scan*")
  foreach(wrapper IN LISTS wrappers)
    file(READ "${wrapper}" content)
    string(FIND "${content}" "${needle}" found)
    if(NOT found EQUAL -1)
      set(${out_var} "${wrapper}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  message(FATAL_ERROR "Could not find scan wrapper containing '${needle}' in ${binary_dir}")
endfunction()

function(assert_report_order report first second label)
  string(FIND "${report}" "${first}" first_pos)
  string(FIND "${report}" "${second}" second_pos)
  if(first_pos EQUAL -1 OR second_pos EQUAL -1 OR NOT first_pos LESS second_pos)
    message(FATAL_ERROR
      "${label} did not contain expected ordering.\n"
      "first: ${first}\n"
      "second: ${second}\n"
      "report:\n${report}")
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

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid "--pool console=1")
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
elseif(TEST_MODE STREQUAL "custom_target_working_directory")
  set(wd_source_dir "${TEST_BINARY_ROOT}/working-directory-src")
  set(wd_binary_dir "${TEST_BINARY_ROOT}/working-directory-build")
  write_custom_target_working_directory_project("${wd_source_dir}" ReprobuildWorkingDirectory)
  run_configure("${wd_source_dir}" "${wd_binary_dir}" TRUE "")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${wd_binary_dir}" "write_wd" "${runquota_socket}" wd_output)
  stop_runquota("${runquota_pid}")
  set(expected_wd "${wd_binary_dir}/command-wd")
  set(actual_file "${expected_wd}/wd.txt")
  assert_file_exists("${actual_file}" "custom target working directory")
  file(READ "${actual_file}" actual_wd)
  string(STRIP "${actual_wd}" actual_wd)
  if(NOT "${actual_wd}" STREQUAL "${expected_wd}")
    message(FATAL_ERROR
      "Custom target WORKING_DIRECTORY was not honored.\n"
      "expected: ${expected_wd}\n"
      "actual: ${actual_wd}\n"
      "output:\n${wd_output}")
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
elseif(TEST_MODE STREQUAL "generated_source_custom_command")
  set(gen_source_dir "${TEST_BINARY_ROOT}/generated-src")
  set(gen_binary_dir "${TEST_BINARY_ROOT}/generated-build")
  write_generated_source_project("${gen_source_dir}" ReprobuildGeneratedSource)
  run_configure("${gen_source_dir}" "${gen_binary_dir}" TRUE "")
  file(READ "${gen_binary_dir}/reprobuild.nim" gen_provider)
  foreach(expected IN ITEMS
      "custom-command-genapp"
      "generated.c"
      "generated.stamp"
      "pool = \"codegen\"")
    assert_contains("${gen_provider}" "${expected}" "generated source provider")
  endforeach()
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid "--pool codegen=1")
  run_build("${gen_binary_dir}" "genapp" "${runquota_socket}" gen_output)
  stop_runquota("${runquota_pid}")
  foreach(path IN ITEMS "${gen_binary_dir}/generated.c" "${gen_binary_dir}/generated.stamp" "${gen_binary_dir}/genapp")
    assert_file_exists("${path}" "generated source custom command")
  endforeach()
  execute_process(COMMAND "${gen_binary_dir}/genapp" RESULT_VARIABLE gen_result)
  if(NOT gen_result EQUAL 0)
    message(FATAL_ERROR "Generated-source executable failed with ${gen_result}")
  endif()
  report_path_from_output("${gen_output}" gen_report_path)
  file(READ "${gen_report_path}" gen_report)
  assert_contains("${gen_report}" "\"id\": \"custom-command-genapp" "generated source report")
  assert_contains("${gen_report}" "\"id\": \"compile-genapp" "generated source report")
elseif(TEST_MODE STREQUAL "custom_depfile_hidden_input")
  set(depcc_source_dir "${TEST_BINARY_ROOT}/custom-dep-src")
  set(depcc_binary_dir "${TEST_BINARY_ROOT}/custom-dep-build")
  write_custom_depfile_project("${depcc_source_dir}" ReprobuildCustomDepfile)
  run_configure("${depcc_source_dir}" "${depcc_binary_dir}" TRUE "")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${depcc_binary_dir}" "depgen" "${runquota_socket}" first_output)
  report_path_from_output("${first_output}" first_report_path)
  file(READ "${first_report_path}" first_report)
  assert_contains("${first_report}" "${depcc_source_dir}/hidden.txt" "custom depfile evidence")
  file(WRITE "${depcc_source_dir}/hidden.txt" "13\n")
  run_build("${depcc_binary_dir}" "depgen" "${runquota_socket}" second_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${second_output}" "custom-command-depgen" "custom depfile rebuild output")
  assert_contains("${second_output}" "generated.c.o status=asSucceeded launched=true" "custom depfile rebuild output")
  assert_contains("${second_output}" "main.c.o status=asCacheHit launched=false" "custom depfile rebuild output")
  report_path_from_output("${second_output}" second_report_path)
  file(READ "${second_report_path}" second_report)
  assert_contains("${second_report}" "\"id\": \"custom-command-depgen" "custom depfile report")
elseif(TEST_MODE STREQUAL "builtin_install_and_test_targets")
  set(builtin_source_dir "${TEST_BINARY_ROOT}/builtin-src")
  set(builtin_binary_dir "${TEST_BINARY_ROOT}/builtin-build")
  set(builtin_install_dir "${TEST_BINARY_ROOT}/install-root")
  write_builtin_project("${builtin_source_dir}" ReprobuildBuiltins "${builtin_install_dir}")
  run_configure("${builtin_source_dir}" "${builtin_binary_dir}" TRUE ""
    "-DCMAKE_INSTALL_PREFIX=${builtin_install_dir}")
  file(READ "${builtin_binary_dir}/CMakeFiles/reprobuild/provider.meta" builtin_metadata)
  foreach(expected IN ITEMS "install" "install/local" "install/strip" "preinstall" "test" "package" "package_source" "rebuild_cache" "help")
    assert_contains("${builtin_metadata}" "${expected}" "builtin metadata")
  endforeach()
  file(GLOB help_wrappers "${builtin_binary_dir}/CMakeFiles/reprobuild/bin/*help*")
  list(LENGTH help_wrappers help_wrapper_count)
  if(NOT help_wrapper_count EQUAL 1)
    message(FATAL_ERROR "Expected exactly one generated help wrapper, found ${help_wrapper_count}: ${help_wrappers}")
  endif()
  list(GET help_wrappers 0 help_wrapper)
  file(READ "${help_wrapper}" help_wrapper_content)
  assert_contains("${help_wrapper_content}" "preinstall" "help wrapper")
  assert_contains("${help_wrapper_content}" "package_source" "help wrapper")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid "--pool console=1")
  run_build("${builtin_binary_dir}" "help" "${runquota_socket}" help_output)
  assert_contains("${help_output}" "selectedTarget: help" "help target output")
  run_build("${builtin_binary_dir}" "preinstall" "${runquota_socket}" preinstall_output)
  assert_file_exists("${builtin_binary_dir}/instapp" "preinstall target")
  run_build("${builtin_binary_dir}" "rebuild_cache" "${runquota_socket}" rebuild_cache_output)
  run_build("${builtin_binary_dir}" "install" "${runquota_socket}" install_output)
  assert_file_exists("${builtin_install_dir}/bin/instapp" "install target")
  file(REMOVE "${builtin_install_dir}/bin/instapp")
  run_build("${builtin_binary_dir}" "install/local" "${runquota_socket}" install_local_output)
  assert_file_exists("${builtin_install_dir}/bin/instapp" "install/local target")
  file(REMOVE "${builtin_install_dir}/bin/instapp")
  run_build("${builtin_binary_dir}" "install/strip" "${runquota_socket}" install_strip_output)
  assert_file_exists("${builtin_install_dir}/bin/instapp" "install/strip target")
  run_build("${builtin_binary_dir}" "test" "${runquota_socket}" test_output)
  run_build("${builtin_binary_dir}" "package" "${runquota_socket}" package_output)
  run_build("${builtin_binary_dir}" "package_source" "${runquota_socket}" package_source_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${preinstall_output}" "selectedTarget: preinstall" "preinstall target output")
  assert_contains("${rebuild_cache_output}" "selectedTarget: rebuild_cache" "rebuild_cache target output")
  assert_contains("${install_output}" "selectedTarget: install" "install target output")
  assert_contains("${install_local_output}" "selectedTarget: install/local" "install/local target output")
  assert_contains("${install_strip_output}" "selectedTarget: install/strip" "install/strip target output")
  assert_contains("${test_output}" "selectedTarget: test" "test target output")
  assert_contains("${package_output}" "selectedTarget: package" "package target output")
  assert_contains("${package_source_output}" "selectedTarget: package_source" "package_source target output")
  assert_file_exists("${builtin_binary_dir}/reprobuild-builtins-pkg.tar.gz" "package target")
  assert_file_exists("${builtin_binary_dir}/reprobuild-builtins-src.tar.gz" "package_source target")
elseif(TEST_MODE STREQUAL "regeneration_refresh")
  set(regen_source_dir "${TEST_BINARY_ROOT}/regen-src")
  set(regen_binary_dir "${TEST_BINARY_ROOT}/regen-build")
  file(REMOVE_RECURSE "${regen_source_dir}")
  write_regeneration_project("${regen_source_dir}" ReprobuildRegen 1)
  run_configure("${regen_source_dir}" "${regen_binary_dir}" TRUE "")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${regen_binary_dir}" "regenapp" "${runquota_socket}" regen_first)
  execute_process(COMMAND "${regen_binary_dir}/regenapp" RESULT_VARIABLE regen_first_result)
  if(NOT regen_first_result EQUAL 1)
    stop_runquota("${runquota_pid}")
    message(FATAL_ERROR "Expected first regenapp exit 1, got ${regen_first_result}")
  endif()
  execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 1.1)
  write_regeneration_project("${regen_source_dir}" ReprobuildRegen 2)
  run_build("${regen_binary_dir}" "regenapp" "${runquota_socket}" regen_second)
  execute_process(COMMAND "${regen_binary_dir}/regenapp" RESULT_VARIABLE regen_second_result)
  if(NOT regen_second_result EQUAL 2)
    stop_runquota("${runquota_pid}")
    message(FATAL_ERROR "Expected regenerated regenapp exit 2, got ${regen_second_result}")
  endif()

  set(glob_source_dir "${TEST_BINARY_ROOT}/glob-src")
  set(glob_binary_dir "${TEST_BINARY_ROOT}/glob-build")
  file(REMOVE_RECURSE "${glob_source_dir}")
  write_glob_regeneration_project("${glob_source_dir}" ReprobuildGlob FALSE)
  run_configure("${glob_source_dir}" "${glob_binary_dir}" TRUE "")
  run_build("${glob_binary_dir}" "globapp" "${runquota_socket}" glob_first)
  execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 1.1)
  write_glob_regeneration_project("${glob_source_dir}" ReprobuildGlob TRUE)
  run_build("${glob_binary_dir}" "globapp" "${runquota_socket}" glob_second)
  stop_runquota("${runquota_pid}")
  execute_process(COMMAND "${glob_binary_dir}/globapp" RESULT_VARIABLE glob_result)
  if(NOT glob_result EQUAL 0)
    message(FATAL_ERROR "Glob-regenerated executable failed with ${glob_result}")
  endif()
  file(READ "${glob_binary_dir}/reprobuild.nim" glob_provider)
  assert_contains("${glob_provider}" "extra.c" "glob regeneration provider")
  assert_contains("${regen_second}" "main.c.o status=asSucceeded launched=true" "regeneration build output")
  assert_contains("${glob_second}" "extra.c.o status=asSucceeded launched=true" "glob regeneration build output")
elseif(TEST_MODE STREQUAL "fortran_dyndep_modules")
  resolve_fortran_compiler(fortran_compiler)
  if("${fortran_compiler}" STREQUAL "")
    file(WRITE "${TEST_BINARY_ROOT}/support-profile.txt"
      "e2e_cmake_reprobuild_fortran_dyndep_modules=skipped\n"
      "reason=no Fortran compiler found on host PATH or TEST_FORTRAN_COMPILER\n")
    message(STATUS "support-profile: Fortran compiler unavailable; M6 Fortran dyndep gate skipped truthfully")
    return()
  endif()

  set(ftn_source_dir "${TEST_BINARY_ROOT}/fortran-src")
  set(ftn_binary_dir "${TEST_BINARY_ROOT}/fortran-build")
  write_fortran_modules_project("${ftn_source_dir}" ReprobuildFortranModules)
  run_configure("${ftn_source_dir}" "${ftn_binary_dir}" TRUE ""
    "-DCMAKE_Fortran_COMPILER=${fortran_compiler}")
  file(READ "${ftn_binary_dir}/reprobuild.nim" ftn_provider)
  foreach(expected IN ITEMS
      "scan-fapp"
      "dyndep-fapp-Fortran"
      "cmake_ninja_depends"
      "cmake_ninja_dyndep"
      "dynamicDepsFile")
    assert_contains("${ftn_provider}" "${expected}" "Fortran dyndep provider")
  endforeach()

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${ftn_binary_dir}" "fapp" "${runquota_socket}" ftn_output)
  stop_runquota("${runquota_pid}")
  execute_process(COMMAND "${ftn_binary_dir}/fapp" RESULT_VARIABLE ftn_result)
  if(NOT ftn_result EQUAL 0)
    message(FATAL_ERROR "Fortran module executable failed with ${ftn_result}")
  endif()

  file(GLOB ftn_fragments "${ftn_binary_dir}/CMakeFiles/reprobuild/dyndep/*-Fortran.rbdyn")
  list(LENGTH ftn_fragments ftn_fragment_count)
  if(NOT ftn_fragment_count EQUAL 1)
    message(FATAL_ERROR "Expected one Fortran dynamic graph fragment, found ${ftn_fragment_count}: ${ftn_fragments}")
  endif()
  list(GET ftn_fragments 0 ftn_fragment)
  file(READ "${ftn_fragment}" ftn_fragment_content)
  assert_contains("${ftn_fragment_content}" "repro-dynamic-graph-v1" "Fortran dynamic graph fragment")
  assert_contains("${ftn_fragment_content}" "dep\t" "Fortran dynamic graph fragment")
  report_path_from_output("${ftn_output}" ftn_report_path)
  file(READ "${ftn_report_path}" ftn_report)
  assert_contains("${ftn_report}" "dynamic-deps" "Fortran scheduler report")
  assert_contains("${ftn_report}" "waiting=1" "Fortran scheduler report")
elseif(TEST_MODE STREQUAL "cxx20_modules_dyndep")
  set(cxxmod_source_dir "${TEST_BINARY_ROOT}/cxx20-mod-src")
  set(cxxmod_binary_dir "${TEST_BINARY_ROOT}/cxx20-mod-build")
  write_cxx_modules_project("${cxxmod_source_dir}" ReprobuildCxx20Modules)
  run_configure("${cxxmod_source_dir}" "${cxxmod_binary_dir}" TRUE ""
    "-DCMAKE_CXX_COMPILER=${TEST_CXX_COMPILER}")
  file(READ "${cxxmod_binary_dir}/reprobuild.nim" cxxmod_provider)
  foreach(expected IN ITEMS
      "scan-app"
      "dyndep-app-CXX"
      "dynamicDepsFile")
    assert_contains("${cxxmod_provider}" "${expected}" "C++20 module provider")
  endforeach()
  find_module_scan_wrapper("${cxxmod_binary_dir}" "m.cppm" cxxmod_scan_wrapper)
  file(READ "${cxxmod_scan_wrapper}" cxxmod_scan_wrapper_content)
  assert_contains("${cxxmod_scan_wrapper_content}" "clang-scan-deps" "C++20 module scan wrapper")
  file(GLOB cxxmod_dyndep_wrappers "${cxxmod_binary_dir}/CMakeFiles/reprobuild/bin/*dyndep*")
  list(LENGTH cxxmod_dyndep_wrappers cxxmod_dyndep_wrapper_count)
  if(NOT cxxmod_dyndep_wrapper_count EQUAL 1)
    message(FATAL_ERROR "Expected one C++20 dyndep wrapper, found ${cxxmod_dyndep_wrapper_count}: ${cxxmod_dyndep_wrappers}")
  endif()
  list(GET cxxmod_dyndep_wrappers 0 cxxmod_dyndep_wrapper)
  file(READ "${cxxmod_dyndep_wrapper}" cxxmod_dyndep_wrapper_content)
  assert_contains("${cxxmod_dyndep_wrapper_content}" "cmake_ninja_dyndep" "C++20 dyndep wrapper")

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${cxxmod_binary_dir}" "app" "${runquota_socket}" cxxmod_output)
  stop_runquota("${runquota_pid}")
  execute_process(COMMAND "${cxxmod_binary_dir}/app" RESULT_VARIABLE cxxmod_result)
  if(NOT cxxmod_result EQUAL 0)
    message(FATAL_ERROR "C++20 module executable failed with ${cxxmod_result}")
  endif()

  assert_file_exists("${cxxmod_binary_dir}/CMakeFiles/app.dir/m.pcm" "C++20 BMI")
  assert_file_exists("${cxxmod_binary_dir}/CMakeFiles/app.dir/m.cppm.o" "C++20 module object")
  assert_file_exists("${cxxmod_binary_dir}/CMakeFiles/app.dir/main.cpp.o" "C++20 importer object")
  assert_file_exists("${cxxmod_binary_dir}/CMakeFiles/reprobuild/dyndep/target0_app-CXX.rbdyn" "C++20 dynamic graph")
  file(READ "${cxxmod_binary_dir}/CMakeFiles/reprobuild/dyndep/target0_app-CXX.rbdyn" cxxmod_fragment)
  assert_contains("${cxxmod_fragment}"
    "dep\tcompile-app-CMakeFiles_app.dir_main.cpp.o\tcompile-app-CMakeFiles_app.dir_m.cppm.o"
    "C++20 dynamic graph")

  report_path_from_output("${cxxmod_output}" cxxmod_report_path)
  file(READ "${cxxmod_report_path}" cxxmod_report)
  assert_contains("${cxxmod_report}" "dynamic-deps" "C++20 scheduler report")
  assert_contains("${cxxmod_report}" "waiting=1" "C++20 scheduler report")
  assert_report_order("${cxxmod_report}"
    "\"actionId\": \"compile-app-CMakeFiles_app.dir_m.cppm.o\",\n      \"event\": \"asSucceeded\""
    "\"actionId\": \"compile-app-CMakeFiles_app.dir_main.cpp.o\",\n      \"event\": \"launched\""
    "C++20 provider/importer scheduler report")
elseif(TEST_MODE STREQUAL "dyndep_corruption_fails_closed")
  set(corrupt_source_dir "${TEST_BINARY_ROOT}/dyndep-corrupt-src")
  set(corrupt_binary_dir "${TEST_BINARY_ROOT}/dyndep-corrupt-build")
  write_cxx_modules_project("${corrupt_source_dir}" ReprobuildDyndepCorrupt)
  run_configure("${corrupt_source_dir}" "${corrupt_binary_dir}" TRUE ""
    "-DCMAKE_CXX_COMPILER=${TEST_CXX_COMPILER}")
  find_module_scan_wrapper("${corrupt_binary_dir}" "m.cppm" module_scan_wrapper)
  file(APPEND "${module_scan_wrapper}"
    "printf '%s\\n' '{bad-json' > 'CMakeFiles/app.dir/m.cppm.o.ddi'\n")

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build_expect_failure("${corrupt_binary_dir}" "app" "${runquota_socket}" corrupt_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${corrupt_output}" "action: dyndep-app-CXX status=asFailed" "corrupt dyndep output")
  assert_contains("${corrupt_output}" "compile-app-CMakeFiles_app.dir_main.cpp.o status=asBlocked" "corrupt dyndep output")
  assert_contains("${corrupt_output}" "compile-app-CMakeFiles_app.dir_m.cppm.o status=asBlocked" "corrupt dyndep output")
  assert_file_not_exists("${corrupt_binary_dir}/app" "corrupt dyndep fail-closed")
  assert_file_not_exists("${corrupt_binary_dir}/CMakeFiles/app.dir/main.cpp.o" "corrupt dyndep fail-closed")
  assert_file_not_exists("${corrupt_binary_dir}/CMakeFiles/app.dir/m.cppm.o" "corrupt dyndep fail-closed")
else()
  message(FATAL_ERROR "Unknown TEST_MODE: ${TEST_MODE}")
endif()
