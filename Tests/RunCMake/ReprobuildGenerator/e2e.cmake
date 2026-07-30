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

function(write_source_flags_subdir_link_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}/libdir")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} C)\n"
    "add_subdirectory(libdir)\n"
    "add_executable(app main.c)\n"
    "target_link_libraries(app PRIVATE nested)\n")
  file(WRITE "${source_dir}/libdir/CMakeLists.txt"
    "add_library(nested STATIC nested.c)\n"
    "set_source_files_properties(nested.c PROPERTIES COMPILE_FLAGS \"-DSOURCE_COMPILE_FLAGS=1\" COMPILE_OPTIONS \"-DSOURCE_COMPILE_OPTION=1\")\n")
  file(WRITE "${source_dir}/libdir/nested.c"
    "#ifndef SOURCE_COMPILE_FLAGS\n"
    "#  error SOURCE_COMPILE_FLAGS missing\n"
    "#endif\n"
    "#ifndef SOURCE_COMPILE_OPTION\n"
    "#  error SOURCE_COMPILE_OPTION missing\n"
    "#endif\n"
    "int nested_value(void) { return 42; }\n")
  file(WRITE "${source_dir}/main.c"
    "int nested_value(void);\n"
    "int main(void) { return nested_value() == 42 ? 0 : 1; }\n")
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
  foreach(arg IN LISTS ARGN)
    string(REPLACE ";" "\\;" escaped_arg "${arg}")
    list(APPEND command "${escaped_arg}")
  endforeach()
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
      "cmake_regeneration=enabled"
      "cmake_regeneration_suppressed=false"
      "cmake_regeneration_check_file=CMakeFiles/Makefile.cmake"
      "cmake_regeneration_provider_file=${binary_dir}/reprobuild.nim"
      "cmake_regeneration_provider_state=${provider_dir}/provider.last"
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
      "REPROBUILD_WORK_ROOT=${binary_dir}/CMakeFiles/reprobuild/work-root"
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

function(run_direct_repro_build binary_dir target socket out_var)
  foreach(var IN ITEMS TEST_REPROBUILD_REPRO TEST_REPROBUILD_SOURCE_ROOT)
    if(NOT DEFINED ${var} OR "${${var}}" STREQUAL "")
      message(FATAL_ERROR "${var} is required for direct Reprobuild build gates")
    endif()
  endforeach()
  require_tool("${TEST_REPROBUILD_REPRO}" "repro")
  set(command
    "${CMAKE_COMMAND}" -E env
      "RUNQUOTA_SOCKET=${socket}"
      "REPROBUILD_WORK_ROOT=${binary_dir}/CMakeFiles/reprobuild/work-root"
      "REPROBUILD_SOURCE_ROOT=${TEST_REPROBUILD_SOURCE_ROOT}"
      "${TEST_REPROBUILD_REPRO}" build
      "${binary_dir}#${target}"
      --tool-provisioning=path
      "--work-root=${binary_dir}/CMakeFiles/reprobuild")
  execute_process(
    COMMAND ${command}
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr
    RESULT_VARIABLE result
    ENCODING UTF8)
  set(output "${stdout}\n${stderr}")
  if(NOT result EQUAL 0)
    message(FATAL_ERROR
      "Direct Reprobuild build failed.\n"
      "Command: ${command}\n"
      "Output:\n${output}")
  endif()
  set(${out_var} "${output}" PARENT_SCOPE)
endfunction()

function(prepare_reprobuild_provider binary_dir target)
  foreach(var IN ITEMS TEST_REPROBUILD_REPRO TEST_REPROBUILD_SOURCE_ROOT)
    if(NOT DEFINED ${var} OR "${${var}}" STREQUAL "")
      message(FATAL_ERROR "${var} is required for provider preparation")
    endif()
  endforeach()
  require_tool("${TEST_REPROBUILD_REPRO}" "repro")
  set(command
    "${CMAKE_COMMAND}" -E env
      "REPROBUILD_WORK_ROOT=${binary_dir}/CMakeFiles/reprobuild/work-root"
      "REPROBUILD_SOURCE_ROOT=${TEST_REPROBUILD_SOURCE_ROOT}"
      "${TEST_REPROBUILD_REPRO}" build
      "${binary_dir}#${target}"
      --tool-provisioning=path
      "--work-root=${binary_dir}/CMakeFiles/reprobuild"
      --prepare-only
      --skip-cmake-regeneration
      --progress=none
      --measure=none
      --no-write-report
      --log=quiet)
  execute_process(
    COMMAND ${command}
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr
    RESULT_VARIABLE result
    ENCODING UTF8)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR
      "Reprobuild provider preparation failed.\n"
      "Command: ${command}\n"
      "stdout:\n${stdout}\n"
      "stderr:\n${stderr}")
  endif()
endfunction()

function(run_build_config binary_dir config target socket out_var)
  foreach(var IN ITEMS TEST_REPROBUILD_REPRO TEST_REPROBUILD_SOURCE_ROOT)
    if(NOT DEFINED ${var} OR "${${var}}" STREQUAL "")
      message(FATAL_ERROR "${var} is required for M7 build gates")
    endif()
  endforeach()
  require_tool("${TEST_REPROBUILD_REPRO}" "repro")
  set(command
    "${CMAKE_COMMAND}" -E env
      "RUNQUOTA_SOCKET=${socket}"
      "REPROBUILD_WORK_ROOT=${binary_dir}/CMakeFiles/reprobuild/work-root"
      "REPROBUILD_REPRO=${TEST_REPROBUILD_REPRO}"
      "REPROBUILD_SOURCE_ROOT=${TEST_REPROBUILD_SOURCE_ROOT}"
      "${CMAKE_COMMAND}" --build "${binary_dir}")
  if(NOT "${config}" STREQUAL "")
    list(APPEND command --config "${config}")
  endif()
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
      "REPROBUILD_WORK_ROOT=${binary_dir}/CMakeFiles/reprobuild/work-root"
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
    set(text_compact "${text}")
    set(expected_compact "${expected}")
    string(REGEX REPLACE "[ \t\r\n]+" "" text_compact "${text_compact}")
    string(REGEX REPLACE "[ \t\r\n]+" "" expected_compact "${expected_compact}")
    string(FIND "${text_compact}" "${expected_compact}" found_compact)
    if(found_compact EQUAL -1)
      message(FATAL_ERROR "${label} missing '${expected}'.\n${text}")
    endif()
  endif()
endfunction()

function(assert_matches text expected_regex label)
  string(REGEX MATCH "${expected_regex}" found "${text}")
  if(NOT found)
    message(FATAL_ERROR "${label} did not match '${expected_regex}'.\n${text}")
  endif()
endfunction()

function(assert_not_contains text unexpected label)
  string(FIND "${text}" "${unexpected}" found)
  if(NOT found EQUAL -1)
    message(FATAL_ERROR "${label} unexpectedly contained '${unexpected}'.\n${text}")
  endif()
endfunction()

function(assert_contains_any text label)
  foreach(expected IN LISTS ARGN)
    string(FIND "${text}" "${expected}" found)
    if(NOT found EQUAL -1)
      return()
    endif()
    set(text_compact "${text}")
    set(expected_compact "${expected}")
    string(REGEX REPLACE "[ \t\r\n]+" "" text_compact "${text_compact}")
    string(REGEX REPLACE "[ \t\r\n]+" "" expected_compact "${expected_compact}")
    string(FIND "${text_compact}" "${expected_compact}" found_compact)
    if(NOT found_compact EQUAL -1)
      return()
    endif()
  endforeach()
  message(FATAL_ERROR "${label} missing any of '${ARGN}'.\n${text}")
endfunction()

function(assert_regeneration_action_fresh_or_cached output label)
  assert_contains_any("${output}" "${label}"
    "cmakeRegenerationAction: __repro_cmake_regenerate status=asSucceeded launched=true"
    "cmakeRegenerationAction: __repro_cmake_regenerate status=asCacheHit launched=false cache=cdHit")
endfunction()

function(write_hcr_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} C)\n"
    "add_executable(hcrapp main.c helper.c)\n"
    "set_property(TARGET hcrapp PROPERTY REPROBUILD_HCR ON)\n"
    "target_compile_options(hcrapp PRIVATE -Wall)\n"
    "add_executable(plain plain.c)\n"
    "set_property(TARGET plain PROPERTY REPROBUILD_HCR OFF)\n"
    "add_executable(globalhcr global.c)\n")
  file(WRITE "${source_dir}/helper.c"
    "int hcr_helper(int value) { return value + 2; }\n")
  file(WRITE "${source_dir}/main.c"
    "int hcr_helper(int value);\n"
    "int main(void) { return hcr_helper(40) == 42 ? 0 : 1; }\n")
  file(WRITE "${source_dir}/plain.c"
    "int main(void) { return 0; }\n")
  file(WRITE "${source_dir}/global.c"
    "int main(void) { return 0; }\n")
endfunction()

function(write_hcr_reject_project source_dir project_name case_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/main.c" "int main(void) { return 0; }\n")
  file(WRITE "${source_dir}/helper.c" "int hcr_helper(void) { return 1; }\n")

  if(case_name STREQUAL "compile-flto")
    file(WRITE "${source_dir}/CMakeLists.txt"
      "cmake_minimum_required(VERSION 3.20)\n"
      "project(${project_name} C)\n"
      "add_executable(badhcr main.c)\n"
      "set_property(TARGET badhcr PROPERTY REPROBUILD_HCR ON)\n"
      "target_compile_options(badhcr PRIVATE -flto)\n")
  elseif(case_name STREQUAL "link-lto")
    file(WRITE "${source_dir}/CMakeLists.txt"
      "cmake_minimum_required(VERSION 3.20)\n"
      "project(${project_name} C)\n"
      "add_executable(badhcr main.c)\n"
      "set_property(TARGET badhcr PROPERTY REPROBUILD_HCR ON)\n"
      "target_link_options(badhcr PRIVATE -fuse-linker-plugin)\n")
  elseif(case_name STREQUAL "no-debug")
    file(WRITE "${source_dir}/CMakeLists.txt"
      "cmake_minimum_required(VERSION 3.20)\n"
      "project(${project_name} C)\n"
      "add_executable(badhcr main.c)\n"
      "set_property(TARGET badhcr PROPERTY REPROBUILD_HCR ON)\n"
      "target_compile_options(badhcr PRIVATE -g0)\n")
  elseif(case_name STREQUAL "ipo")
    file(WRITE "${source_dir}/CMakeLists.txt"
      "cmake_minimum_required(VERSION 3.20)\n"
      "project(${project_name} C)\n"
      "add_executable(badhcr main.c)\n"
      "set_property(TARGET badhcr PROPERTY REPROBUILD_HCR ON)\n"
      "set_property(TARGET badhcr PROPERTY INTERPROCEDURAL_OPTIMIZATION ON)\n")
  elseif(case_name STREQUAL "static-library")
    file(WRITE "${source_dir}/CMakeLists.txt"
      "cmake_minimum_required(VERSION 3.20)\n"
      "project(${project_name} C)\n"
      "add_library(badhcr STATIC helper.c)\n"
      "set_property(TARGET badhcr PROPERTY REPROBUILD_HCR ON)\n")
  elseif(case_name STREQUAL "object-library")
    file(WRITE "${source_dir}/CMakeLists.txt"
      "cmake_minimum_required(VERSION 3.20)\n"
      "project(${project_name} C)\n"
      "add_library(badhcr OBJECT helper.c)\n"
      "set_property(TARGET badhcr PROPERTY REPROBUILD_HCR ON)\n")
  elseif(case_name STREQUAL "asm-source")
    file(WRITE "${source_dir}/CMakeLists.txt"
      "cmake_minimum_required(VERSION 3.20)\n"
      "project(${project_name} C ASM)\n"
      "add_executable(badhcr main.c hcr_entry.S)\n"
      "set_source_files_properties(hcr_entry.S PROPERTIES LANGUAGE ASM)\n"
      "set_property(TARGET badhcr PROPERTY REPROBUILD_HCR ON)\n")
    if(APPLE)
      file(WRITE "${source_dir}/hcr_entry.S"
        ".globl _hcr_asm_entry\n"
        "_hcr_asm_entry:\n"
        "  ret\n")
    else()
      file(WRITE "${source_dir}/hcr_entry.S"
        ".globl hcr_asm_entry\n"
        "hcr_asm_entry:\n"
        "  ret\n")
    endif()
  else()
    message(FATAL_ERROR "Unknown HCR reject case: ${case_name}")
  endif()
endfunction()

function(assert_rejected_hcr_target_not_reloadable binary_dir case_name)
  set(provider_dir "${binary_dir}/CMakeFiles/reprobuild")
  if(EXISTS "${provider_dir}/hcr.metadata.json")
    message(FATAL_ERROR
      "Rejected HCR case '${case_name}' still produced HCR metadata: "
      "${provider_dir}/hcr.metadata.json")
  endif()
  if(EXISTS "${provider_dir}/provider.meta")
    file(READ "${provider_dir}/provider.meta" rejected_provider_metadata)
    assert_not_contains("${rejected_provider_metadata}" "m10_hcr_targets=generated"
      "rejected HCR provider metadata for ${case_name}")
    assert_not_contains("${rejected_provider_metadata}" "hcr_targets=badhcr"
      "rejected HCR provider metadata for ${case_name}")
  endif()
  if(EXISTS "${binary_dir}/reprobuild.nim")
    file(READ "${binary_dir}/reprobuild.nim" rejected_provider)
    assert_not_contains("${rejected_provider}" "hcr-linkgraph-badhcr"
      "rejected HCR provider for ${case_name}")
    assert_not_contains("${rejected_provider}" "target(\"badhcr\""
      "rejected HCR provider for ${case_name}")
  endif()
endfunction()

function(run_hcr_reject_case case_name expected_error)
  set(reject_source_dir "${TEST_BINARY_ROOT}/${case_name}-src")
  set(reject_binary_dir "${TEST_BINARY_ROOT}/${case_name}-build")
  write_hcr_reject_project("${reject_source_dir}" ReprobuildHcrReject
    "${case_name}")
  run_configure("${reject_source_dir}" "${reject_binary_dir}" FALSE
    "${expected_error}")
  assert_rejected_hcr_target_not_reloadable("${reject_binary_dir}" "${case_name}")
endfunction()

function(run_hcr_metadata_reader binary_dir mode source_path out_var)
  foreach(var IN ITEMS TEST_REPROBUILD_SOURCE_ROOT)
    if(NOT DEFINED ${var} OR "${${var}}" STREQUAL "")
      message(FATAL_ERROR "${var} is required for M10 HCR metadata reader gates")
    endif()
  endforeach()
  find_program(NIM_EXECUTABLE nim)
  if(NOT NIM_EXECUTABLE)
    message(FATAL_ERROR "nim is required for M10 HCR metadata reader gates")
  endif()
  set(reader_dir "${binary_dir}/CMakeFiles/reprobuild/hcr-reader")
  file(MAKE_DIRECTORY "${reader_dir}")
  set(reader "${reader_dir}/reader.nim")
  file(WRITE "${reader}"
    "import std/os\n"
    "import repro_hcr_linkgraph/cmake_metadata\n"
    "let buildDir = paramStr(1)\n"
    "let mode = paramStr(2)\n"
    "let metadata = readCMakeHcrMetadataForBuildDir(buildDir)\n"
    "requireHcrTargets(metadata)\n"
    "if mode == \"validate\":\n"
    "  for target in metadata.targets:\n"
    "    echo \"target=\", target.name, \" profile=\", target.profile, \" objects=\", target.objects.len\n"
    "    echo \"linkgraph=\", target.linkGraph, \" action=\", target.linkGraphAction\n"
    "elif mode == \"affected\":\n"
    "  let source = paramStr(3)\n"
    "  let affected = affectedObjectsForSource(metadata, source)\n"
    "  if affected.len == 0:\n"
    "    quit \"no affected objects for \" & source, 2\n"
    "  for relation in affected:\n"
    "    echo \"affected=\", relation.source, \" object=\", relation.objectPath, \" compile=\", relation.compileAction, \" link=\", relation.linkAction, \" linkgraph=\", relation.linkGraph\n"
    "else:\n"
    "  quit \"unknown mode: \" & mode, 3\n")
  execute_process(
    COMMAND "${NIM_EXECUTABLE}" c -r
      --verbosity:0
      --hints:off
      "--nimcache:${reader_dir}/nimcache"
      "--path:${TEST_REPROBUILD_SOURCE_ROOT}/libs/repro_hcr_linkgraph/src"
      "--out:${reader_dir}/reader"
      "${reader}"
      "${binary_dir}" "${mode}" "${source_path}"
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr
    RESULT_VARIABLE result
    ENCODING UTF8)
  set(output "${stdout}\n${stderr}")
  if(NOT result EQUAL 0)
    message(FATAL_ERROR
      "HCR metadata reader failed.\n"
      "Output:\n${output}")
  endif()
  set(${out_var} "${output}" PARENT_SCOPE)
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
    "get_filename_component(pwd \".\" ABSOLUTE)\n"
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

function(write_multi_config_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} C)\n"
    "add_executable(app main.c)\n"
    "add_executable(side side.c)\n"
    "target_compile_definitions(app PRIVATE $<$<CONFIG:Debug>:APP_CONFIG=\\\"debug\\\"> $<$<CONFIG:Release>:APP_CONFIG=\\\"release\\\">)\n"
    "target_compile_definitions(side PRIVATE SIDE_CONFIG=\\\"side\\\")\n")
  file(WRITE "${source_dir}/main.c"
    "#include <stdio.h>\n"
    "#ifndef APP_CONFIG\n"
    "#  define APP_CONFIG \"missing\"\n"
    "#endif\n"
    "int main(void) { puts(APP_CONFIG); return 0; }\n")
  file(WRITE "${source_dir}/side.c"
    "#include <stdio.h>\n"
    "int main(void) { puts(SIDE_CONFIG); return 0; }\n")
endfunction()

function(write_multi_config_unprefixed_custom_command_project source_dir project_name)
  # M27 regression fixture. Mirrors zlib's MinGW resource-compile pattern:
  # an ``add_custom_command(OUTPUT <binDir>/<file>)`` with NO ``$<CONFIG>``
  # in the path. Both Debug and Release builds must succeed even though
  # the custom command writes to the same unprefixed binary-dir path for
  # both configurations — exactly how Ninja Multi-Config, Visual Studio
  # and Xcode behave when the user does not opt into per-config outputs.
  # Before M27 the Reprobuild generator unconditionally rewrote OUTPUT to
  # ``<config>/<file>``, but the COMMAND argv still wrote to the literal
  # unprefixed path, so the link step looked for ``Debug/<file>`` and
  # failed with "no such file or directory".
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  # The COMMAND uses ``cmake -P write_gen.cmake`` instead of ``cmake -E
  # echo > file`` because the Reprobuild engine's inline-exec path does
  # NOT interpret shell redirection — ``>`` and the filename would just
  # be appended to echo's positional args. ``cmake -P`` keeps the COMMAND
  # a single self-contained call that produces the file at ``OUT``.
  file(WRITE "${source_dir}/write_gen.cmake"
    "file(WRITE \"\${OUT}\" \"int generated_value(void) { return 42; }\\n\")\n")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} C)\n"
    "set(gen_c \"\${CMAKE_CURRENT_BINARY_DIR}/generated.c\")\n"
    "add_custom_command(OUTPUT \"\${gen_c}\"\n"
    "  COMMAND \"\${CMAKE_COMMAND}\" -DOUT=\${gen_c} -P \"${source_dir}/write_gen.cmake\"\n"
    "  VERBATIM)\n"
    "set_source_files_properties(\"\${gen_c}\" PROPERTIES GENERATED 1)\n"
    "add_executable(app main.c \"\${gen_c}\")\n"
    "target_compile_definitions(app PRIVATE $<$<CONFIG:Debug>:APP_CONFIG=\\\"debug\\\"> $<$<CONFIG:Release>:APP_CONFIG=\\\"release\\\">)\n")
  file(WRITE "${source_dir}/main.c"
    "#include <stdio.h>\n"
    "#ifndef APP_CONFIG\n"
    "#  define APP_CONFIG \"missing\"\n"
    "#endif\n"
    "int generated_value(void);\n"
    "int main(void) { puts(APP_CONFIG); return generated_value() == 42 ? 0 : 1; }\n")
endfunction()

function(write_cross_config_generated_source_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} C)\n"
    "add_executable(gen gen.c)\n"
    "foreach(cfg Debug Release)\n"
    "  set(src_\${cfg} \"\${CMAKE_CURRENT_BINARY_DIR}/\${cfg}/generated.c\")\n"
    "  set_source_files_properties(\"\${src_\${cfg}}\" PROPERTIES GENERATED 1)\n"
    "endforeach()\n"
    "add_custom_command(OUTPUT \"\${CMAKE_CURRENT_BINARY_DIR}/$<CONFIG>/generated.c\"\n"
    "  COMMAND gen \"$<COMMAND_CONFIG:$<CONFIG>>\" \"$<OUTPUT_CONFIG:$<CONFIG>>\" \"\${CMAKE_CURRENT_BINARY_DIR}/$<OUTPUT_CONFIG:$<CONFIG>>/generated.c\"\n"
    "  DEPENDS gen\n"
    "  VERBATIM)\n"
    "add_executable(app main.c \"$<$<CONFIG:Debug>:\${src_Debug}>\" \"$<$<CONFIG:Release>:\${src_Release}>\")\n")
  file(WRITE "${source_dir}/gen.c"
    "#include <stdio.h>\n"
    "#include <string.h>\n"
    "int main(int argc, char** argv) {\n"
    "  if (argc != 4) return 2;\n"
    "  FILE* f = fopen(argv[3], \"w\");\n"
    "  if (!f) return 3;\n"
    "#ifdef NDEBUG\n"
    "  int release_generator = 1;\n"
    "#else\n"
    "  int release_generator = 0;\n"
    "#endif\n"
    "  int ok = (strcmp(argv[1], argv[2]) == 0) || (release_generator && strcmp(argv[1], \"Release\") == 0 && strcmp(argv[2], \"Debug\") == 0);\n"
    "  fprintf(f, \"int generated_value(void) { return %d; }\\n\", ok ? 42 : 7);\n"
    "  fclose(f);\n"
    "  return ok ? 0 : 4;\n"
    "}\n")
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

function(resolve_swift_compiler out_var)
  if(DEFINED TEST_SWIFT_COMPILER AND
      NOT "${TEST_SWIFT_COMPILER}" STREQUAL "" AND
      NOT "${TEST_SWIFT_COMPILER}" MATCHES "NOTFOUND$")
    set(${out_var} "${TEST_SWIFT_COMPILER}" PARENT_SCOPE)
    return()
  endif()
  if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    set(xcode_swift "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc")
    if(EXISTS "${xcode_swift}")
      set(${out_var} "${xcode_swift}" PARENT_SCOPE)
      return()
    endif()
    execute_process(COMMAND xcrun --find swiftc
      OUTPUT_VARIABLE xcrun_swift
      RESULT_VARIABLE xcrun_swift_result
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET)
    if(xcrun_swift_result EQUAL 0 AND EXISTS "${xcrun_swift}")
      set(${out_var} "${xcrun_swift}" PARENT_SCOPE)
      return()
    endif()
  endif()
  find_program(found_swift NAMES swiftc)
  if(found_swift)
    set(${out_var} "${found_swift}" PARENT_SCOPE)
  else()
    set(${out_var} "" PARENT_SCOPE)
  endif()
endfunction()

function(swift_config_args out_var swift_compiler)
  set(args "-DCMAKE_Swift_COMPILER=${swift_compiler}" "-DCMAKE_Swift_COMPILER_WORKS=1")
  if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    set(xcode_sdk "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
    if(EXISTS "${xcode_sdk}")
      list(APPEND args "-DCMAKE_OSX_SYSROOT=${xcode_sdk}")
    else()
      execute_process(COMMAND xcrun --show-sdk-path
        OUTPUT_VARIABLE xcrun_sdk
        RESULT_VARIABLE xcrun_sdk_result
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
      if(xcrun_sdk_result EQUAL 0 AND EXISTS "${xcrun_sdk}")
        list(APPEND args "-DCMAKE_OSX_SYSROOT=${xcrun_sdk}")
      endif()
    endif()
  endif()
  set(${out_var} "${args}" PARENT_SCOPE)
endfunction()

function(resolve_ispc_compiler out_var)
  if(DEFINED TEST_ISPC_COMPILER AND
      NOT "${TEST_ISPC_COMPILER}" STREQUAL "" AND
      NOT "${TEST_ISPC_COMPILER}" MATCHES "NOTFOUND$")
    set(${out_var} "${TEST_ISPC_COMPILER}" PARENT_SCOPE)
    return()
  endif()
  find_program(found_ispc NAMES ispc)
  if(found_ispc)
    set(${out_var} "${found_ispc}" PARENT_SCOPE)
  else()
    set(${out_var} "" PARENT_SCOPE)
  endif()
endfunction()

function(resolve_cuda_compiler out_var)
  if(DEFINED TEST_CUDA_COMPILER AND
      NOT "${TEST_CUDA_COMPILER}" STREQUAL "" AND
      NOT "${TEST_CUDA_COMPILER}" MATCHES "NOTFOUND$" AND
      (NOT DEFINED TEST_CUDA_COMPILER_ID OR
        "${TEST_CUDA_COMPILER_ID}" STREQUAL "" OR
        "${TEST_CUDA_COMPILER_ID}" STREQUAL "NVIDIA"))
    set(${out_var} "${TEST_CUDA_COMPILER}" PARENT_SCOPE)
    return()
  endif()
  find_program(found_cuda NAMES nvcc)
  if(found_cuda)
    set(${out_var} "${found_cuda}" PARENT_SCOPE)
  else()
    set(${out_var} "" PARENT_SCOPE)
  endif()
endfunction()

function(resolve_clang_cuda_compiler out_var)
  if(DEFINED TEST_CUDA_COMPILER AND
      NOT "${TEST_CUDA_COMPILER}" STREQUAL "" AND
      NOT "${TEST_CUDA_COMPILER}" MATCHES "NOTFOUND$" AND
      (("${TEST_CUDA_COMPILER_ID}" STREQUAL "Clang") OR
       ("${TEST_CUDA_COMPILER_ID}" STREQUAL "AppleClang")))
    set(${out_var} "${TEST_CUDA_COMPILER}" PARENT_SCOPE)
  else()
    set(${out_var} "" PARENT_SCOPE)
  endif()
endfunction()

function(write_swift_profile_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 4.1)\n"
    "cmake_policy(SET CMP0157 NEW)\n"
    "cmake_policy(SET CMP0215 NEW)\n"
    "project(${project_name} Swift)\n"
    "set(CMAKE_Swift_COMPILATION_MODE incremental)\n"
    "set(CMAKE_Swift_NUM_THREADS 2)\n"
    "add_executable(swiftapp main.swift helper.swift)\n"
    "set_source_files_properties(helper.swift PROPERTIES Swift_DEPENDENCIES_FILE \"\${CMAKE_CURRENT_BINARY_DIR}/helper.custom.swiftdeps\" Swift_DIAGNOSTICS_FILE \"\${CMAKE_CURRENT_BINARY_DIR}/helper.custom.dia\")\n")
  file(WRITE "${source_dir}/helper.swift"
    "func answer() -> Int32 { return 42 }\n")
  file(WRITE "${source_dir}/main.swift"
    "#if os(macOS)\n"
    "import Darwin\n"
    "#else\n"
    "import Glibc\n"
    "#endif\n"
    "exit(answer() == 42 ? 0 : 1)\n")
endfunction()

function(write_swift_split_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 4.1)\n"
    "cmake_policy(SET CMP0157 NEW)\n"
    "cmake_policy(SET CMP0215 NEW)\n"
    "project(${project_name} Swift)\n"
    "add_executable(splitapp main.swift helper.swift)\n"
    "set_target_properties(splitapp PROPERTIES Swift_SEPARATE_MODULE_EMISSION ON Swift_MODULE_NAME SplitApp)\n")
  file(WRITE "${source_dir}/helper.swift" "func value() -> Int32 { return 7 }\n")
  file(WRITE "${source_dir}/main.swift"
    "#if os(macOS)\n"
    "import Darwin\n"
    "#else\n"
    "import Glibc\n"
    "#endif\n"
    "exit(value() == 7 ? 0 : 1)\n")
endfunction()

function(write_apple_bundle_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}/Assets" "${source_dir}/FrameworkAssets" "${source_dir}/PluginAssets")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} C)\n"
    "add_executable(bundleapp MACOSX_BUNDLE main.c Assets/data.txt)\n"
    "set_source_files_properties(Assets/data.txt PROPERTIES MACOSX_PACKAGE_LOCATION Resources)\n"
    "set_target_properties(bundleapp PROPERTIES MACOSX_BUNDLE_INFO_PLIST \"${source_dir}/Info.plist.in\" MACOSX_BUNDLE_BUNDLE_NAME ReproBundle MACOSX_BUNDLE_GUI_IDENTIFIER org.reprobuild.bundle)\n"
    "add_library(ReproKit SHARED framework.c framework.h FrameworkAssets/fwdata.txt)\n"
    "set_source_files_properties(FrameworkAssets/fwdata.txt PROPERTIES MACOSX_PACKAGE_LOCATION Resources)\n"
    "set_target_properties(ReproKit PROPERTIES FRAMEWORK TRUE FRAMEWORK_VERSION A PUBLIC_HEADER framework.h MACOSX_FRAMEWORK_INFO_PLIST \"${source_dir}/FrameworkInfo.plist.in\")\n"
    "add_library(reproplug MODULE plug.c PluginAssets/plugdata.txt)\n"
    "set_source_files_properties(PluginAssets/plugdata.txt PROPERTIES MACOSX_PACKAGE_LOCATION Resources)\n"
    "set_target_properties(reproplug PROPERTIES BUNDLE TRUE BUNDLE_EXTENSION bundle MACOSX_BUNDLE_INFO_PLIST \"${source_dir}/PluginInfo.plist.in\")\n")
  file(WRITE "${source_dir}/Info.plist.in"
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>${MACOSX_BUNDLE_EXECUTABLE_NAME}</string><key>CFBundleIdentifier</key><string>${MACOSX_BUNDLE_GUI_IDENTIFIER}</string><key>CFBundleName</key><string>${MACOSX_BUNDLE_BUNDLE_NAME}</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>\n")
  file(WRITE "${source_dir}/FrameworkInfo.plist.in"
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>${MACOSX_FRAMEWORK_NAME}</string><key>CFBundleIdentifier</key><string>org.reprobuild.framework</string><key>CFBundleName</key><string>${MACOSX_FRAMEWORK_NAME}</string><key>CFBundlePackageType</key><string>FMWK</string></dict></plist>\n")
  file(WRITE "${source_dir}/PluginInfo.plist.in"
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>${MACOSX_BUNDLE_EXECUTABLE_NAME}</string><key>CFBundleIdentifier</key><string>org.reprobuild.plugin</string><key>CFBundleName</key><string>reproplug</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>\n")
  file(WRITE "${source_dir}/Assets/data.txt" "bundle-resource\n")
  file(WRITE "${source_dir}/FrameworkAssets/fwdata.txt" "framework-resource\n")
  file(WRITE "${source_dir}/PluginAssets/plugdata.txt" "plugin-resource\n")
  file(WRITE "${source_dir}/framework.h" "int reprokit_value(void);\n")
  file(WRITE "${source_dir}/framework.c" "int reprokit_value(void) { return 42; }\n")
  file(WRITE "${source_dir}/plug.c" "int reproplug_value(void) { return 7; }\n")
  file(WRITE "${source_dir}/main.c" "int main(void) { return 0; }\n")
endfunction()

function(write_cuda_unavailable_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} CUDA)\n"
    "add_executable(cudaapp main.cu)\n"
    "set_target_properties(cudaapp PROPERTIES CUDA_SEPARABLE_COMPILATION ON CUDA_RESOLVE_DEVICE_SYMBOLS ON)\n")
  file(WRITE "${source_dir}/main.cu" "__global__ void k() {}\nint main() { k<<<1,1>>>(); return 0; }\n")
endfunction()

function(write_cuda_available_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} CUDA)\n"
    "add_library(cudalib STATIC kernels.cu)\n"
    "set_target_properties(cudalib PROPERTIES CUDA_SEPARABLE_COMPILATION ON CUDA_RESOLVE_DEVICE_SYMBOLS ON POSITION_INDEPENDENT_CODE ON)\n"
    "add_executable(cudaapp main.cu)\n"
    "target_link_libraries(cudaapp PRIVATE cudalib)\n"
    "set_target_properties(cudaapp PROPERTIES CUDA_SEPARABLE_COMPILATION ON CUDA_RESOLVE_DEVICE_SYMBOLS ON)\n")
  file(WRITE "${source_dir}/kernels.cu" "__device__ int device_value() { return 42; }\n")
  file(WRITE "${source_dir}/main.cu" "int main() { return 0; }\n")
endfunction()

function(write_clang_cuda_available_project source_dir project_name)
  write_cuda_available_project("${source_dir}" "${project_name}")
  file(APPEND "${source_dir}/CMakeLists.txt"
    "set_property(TARGET cudalib cudaapp PROPERTY CUDA_ARCHITECTURES 52)\n")
endfunction()

function(write_ispc_unavailable_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} CXX ISPC)\n"
    "add_executable(ispcapp main.cxx kernel.ispc)\n"
    "set_property(TARGET ispcapp PROPERTY ISPC_INSTRUCTION_SETS sse2-i32x4;sse4-i32x4)\n")
  file(WRITE "${source_dir}/kernel.ispc" "export void fill(uniform int n, uniform int v[], uniform int x) { foreach (i = 0 ... n) v[i] = x; }\n")
  file(WRITE "${source_dir}/main.cxx" "int main() { return 0; }\n")
endfunction()

function(write_ispc_available_project source_dir project_name)
  file(REMOVE_RECURSE "${source_dir}")
  file(MAKE_DIRECTORY "${source_dir}")
  file(WRITE "${source_dir}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.20)\n"
    "project(${project_name} ISPC)\n"
    "set(CMAKE_ISPC_FLAGS \"--arch=x86\")\n"
    "add_library(ispc_objects OBJECT kernel.ispc)\n"
    "set_property(TARGET ispc_objects PROPERTY ISPC_INSTRUCTION_SETS sse2-i32x4;sse4-i32x4)\n")
  file(WRITE "${source_dir}/kernel.ispc" "export void fill(uniform int n, uniform int v[], uniform int x) { foreach (i = 0 ... n) v[i] = x; }\n")
endfunction()

function(run_cuda_available_fixture label cuda_compiler extra_args)
  set(cuda_source_dir "${TEST_BINARY_ROOT}/${label}-src")
  set(cuda_binary_dir "${TEST_BINARY_ROOT}/${label}-build")
  write_cuda_available_project("${cuda_source_dir}" ReprobuildCudaAvailable)
  run_configure("${cuda_source_dir}" "${cuda_binary_dir}" TRUE ""
    "-DCMAKE_CUDA_COMPILER=${cuda_compiler}"
    "-DCMAKE_CUDA_ARCHITECTURES=52"
    ${extra_args})
  file(READ "${cuda_binary_dir}/CMakeFiles/reprobuild/provider.meta" cuda_metadata)
  assert_contains("${cuda_metadata}" "m8_cuda_device_link=generated" "CUDA metadata")
  file(READ "${cuda_binary_dir}/reprobuild.nim" cuda_provider)
  assert_contains("${cuda_provider}" "device-link-cudalib" "CUDA provider")
  assert_contains("${cuda_provider}" "cmake_device_link" "CUDA provider")
  file(READ "${cuda_binary_dir}/CMakeFiles/reprobuild/clean.manifest" cuda_clean)
  assert_contains("${cuda_clean}" "cmake_device_link" "CUDA clean manifest")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${cuda_binary_dir}" "cudaapp" "${runquota_socket}" cuda_output)
  stop_runquota("${runquota_pid}")
  report_path_from_output("${cuda_output}" cuda_report_path)
  file(READ "${cuda_report_path}" cuda_report)
  assert_contains("${cuda_report}" "device-link-cudalib" "CUDA scheduler report")
endfunction()

function(run_clang_cuda_available_fixture label clang_cuda_compiler)
  set(cuda_source_dir "${TEST_BINARY_ROOT}/${label}-src")
  set(cuda_binary_dir "${TEST_BINARY_ROOT}/${label}-build")
  write_clang_cuda_available_project("${cuda_source_dir}" ReprobuildClangCudaAvailable)
  run_configure("${cuda_source_dir}" "${cuda_binary_dir}" TRUE ""
    "-DCMAKE_CUDA_COMPILER=${clang_cuda_compiler}"
    "-DCMAKE_CUDA_ARCHITECTURES=52"
    "-DCMAKE_REPROBUILD_CUDA_PROFILE=ClangFatbinary")
  file(READ "${cuda_binary_dir}/CMakeFiles/reprobuild/provider.meta" cuda_metadata)
  assert_contains("${cuda_metadata}" "m8_cuda_clang_fatbinary=generated" "Clang CUDA metadata")
  file(READ "${cuda_binary_dir}/reprobuild.nim" cuda_provider)
  foreach(expected IN ITEMS
      "cuda-device-link-cudalib-sm-52"
      "cuda-fatbinary-cudalib"
      "cuda-registration-stub-cudalib"
      "cmake_cuda_fatbin.h"
      "cmake_cuda_register.h")
    assert_contains("${cuda_provider}" "${expected}" "Clang CUDA provider")
  endforeach()
  file(READ "${cuda_binary_dir}/CMakeFiles/reprobuild/clean.manifest" cuda_clean)
  assert_contains("${cuda_clean}" "cmake_cuda_fatbin.h" "Clang CUDA clean manifest")
  assert_contains("${cuda_clean}" "cmake_cuda_register.h" "Clang CUDA clean manifest")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${cuda_binary_dir}" "cudaapp" "${runquota_socket}" cuda_output)
  stop_runquota("${runquota_pid}")
  report_path_from_output("${cuda_output}" cuda_report_path)
  file(READ "${cuda_report_path}" cuda_report)
  assert_contains("${cuda_report}" "cuda-registration-stub-cudalib" "Clang CUDA scheduler report")
endfunction()

function(run_ispc_available_fixture label ispc_compiler)
  set(ispc_source_dir "${TEST_BINARY_ROOT}/${label}-src")
  set(ispc_binary_dir "${TEST_BINARY_ROOT}/${label}-build")
  write_ispc_available_project("${ispc_source_dir}" ReprobuildIspcAvailable)
  run_configure("${ispc_source_dir}" "${ispc_binary_dir}" TRUE ""
    "-DCMAKE_CXX_COMPILER=${TEST_CXX_COMPILER}"
    "-DCMAKE_ISPC_COMPILER=${ispc_compiler}")
  file(READ "${ispc_binary_dir}/CMakeFiles/reprobuild/provider.meta" ispc_metadata)
  assert_contains("${ispc_metadata}" "m8_ispc_multiple_outputs=generated" "ISPC metadata")
  file(READ "${ispc_binary_dir}/reprobuild.nim" ispc_provider)
  assert_contains("${ispc_provider}" "kernel_ispc.h" "ISPC provider")
  assert_contains("${ispc_provider}" "kernel_sse2" "ISPC provider")
  assert_contains("${ispc_provider}" "kernel_sse4" "ISPC provider")
  file(READ "${ispc_binary_dir}/CMakeFiles/reprobuild/clean.manifest" ispc_clean)
  assert_contains("${ispc_clean}" "kernel_ispc.h" "ISPC clean manifest")
  assert_contains("${ispc_clean}" "kernel_sse2" "ISPC clean manifest")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${ispc_binary_dir}" "ispc_objects" "${runquota_socket}" ispc_output)
  stop_runquota("${runquota_pid}")
  report_path_from_output("${ispc_output}" ispc_report_path)
  file(READ "${ispc_report_path}" ispc_report)
  assert_contains("${ispc_report}" "compile-ispc_objects" "ISPC scheduler report")
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
  if(first_pos EQUAL -1 OR second_pos EQUAL -1)
    set(report_compact "${report}")
    set(first_compact "${first}")
    set(second_compact "${second}")
    string(REGEX REPLACE "[ \t\r\n]+" "" report_compact "${report_compact}")
    string(REGEX REPLACE "[ \t\r\n]+" "" first_compact "${first_compact}")
    string(REGEX REPLACE "[ \t\r\n]+" "" second_compact "${second_compact}")
    string(FIND "${report_compact}" "${first_compact}" first_pos)
    string(FIND "${report_compact}" "${second_compact}" second_pos)
  endif()
  if(first_pos EQUAL -1 OR second_pos EQUAL -1 OR NOT first_pos LESS second_pos)
    message(FATAL_ERROR
      "${label} did not contain expected ordering.\n"
      "first: ${first}\n"
      "second: ${second}\n"
      "report:\n${report}")
  endif()
endfunction()

function(m11_support_line text)
  file(APPEND "${TEST_BINARY_ROOT}/support-profile.txt" "${text}\n")
endfunction()

function(m11_project_field key field out_var)
  include("${CMAKE_CURRENT_LIST_DIR}/real-project-locks.cmake")
  set(var_name "M11_PROJECT_${key}_${field}")
  if(DEFINED ${var_name})
    set(${out_var} "${${var_name}}" PARENT_SCOPE)
  else()
    set(${out_var} "" PARENT_SCOPE)
  endif()
endfunction()

function(run_m11_submode mode)
  set(sub_root "${TEST_BINARY_ROOT}/${mode}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      -DCMAKE_COMMAND=${CMAKE_COMMAND}
      -DTEST_MODE=${mode}
      -DTEST_BINARY_ROOT=${sub_root}
      -DTEST_C_COMPILER=${TEST_C_COMPILER}
      -DTEST_CXX_COMPILER=${TEST_CXX_COMPILER}
      -DTEST_FORTRAN_COMPILER=${TEST_FORTRAN_COMPILER}
      -DTEST_REPROBUILD_SOURCE_ROOT=${TEST_REPROBUILD_SOURCE_ROOT}
      -DTEST_REPROBUILD_REPO=${TEST_REPROBUILD_REPO}
      -DTEST_REPROBUILD_REPRO=${TEST_REPROBUILD_REPRO}
      -DTEST_RUNQUOTAD=${TEST_RUNQUOTAD}
      -P "${CMAKE_CURRENT_LIST_FILE}"
    OUTPUT_VARIABLE sub_stdout
    ERROR_VARIABLE sub_stderr
    RESULT_VARIABLE sub_result
    ENCODING UTF8)
  file(WRITE "${sub_root}.log" "${sub_stdout}\n${sub_stderr}")
  if(NOT sub_result EQUAL 0)
    message(FATAL_ERROR
      "M11 submode ${mode} failed; see ${sub_root}.log\n"
      "${sub_stdout}\n${sub_stderr}")
  endif()
endfunction()

function(configure_imported_runcmake_fixture suite case bin_var)
  set(src "${CMAKE_CURRENT_LIST_DIR}/../${suite}")
  set(bin "${TEST_BINARY_ROOT}/upstream-${suite}-${case}")
  file(REMOVE_RECURSE "${bin}")
  file(MAKE_DIRECTORY "${bin}")
  string(RANDOM LENGTH 16 ALPHABET "0123456789abcdef" compat_nonce)
  set(configure_args ${ARGN})
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      -S "${src}"
      -B "${bin}"
      -G Reprobuild
      -DRunCMake_TEST=${case}
      -DCMAKE_BUILD_TYPE=Debug
      -DCMAKE_C_COMPILER=${TEST_C_COMPILER}
      -DCMAKE_CXX_COMPILER=${TEST_CXX_COMPILER}
      "-DCMAKE_C_FLAGS=-DREPROBUILD_COMPAT_NONCE=${compat_nonce}"
      "-DCMAKE_CXX_FLAGS=-DREPROBUILD_COMPAT_NONCE=${compat_nonce}"
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
      ${configure_args}
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr
    RESULT_VARIABLE result
    ENCODING UTF8)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR
      "Imported RunCMake fixture failed to configure: ${suite}/${case}\n"
      "stdout:\n${stdout}\nstderr:\n${stderr}")
  endif()
  file(READ "${bin}/CMakeFiles/reprobuild/provider.meta" metadata)
  assert_contains("${metadata}" "generator=Reprobuild" "${suite}/${case} metadata")
  set(${bin_var} "${bin}" PARENT_SCOPE)
endfunction()

function(run_imported_runcmake_configure suite case)
  configure_imported_runcmake_fixture("${suite}" "${case}" bin ${ARGN})
  m11_support_line("upstream:${suite}/${case}=ran-configure generator=Reprobuild")
endfunction()

function(run_imported_runcmake_fixture suite case target)
  set(options NO_DEPFILE NONCACHEABLE)
  set(oneValueArgs CONFIG)
  set(multiValueArgs CONFIGURE_ARGS)
  cmake_parse_arguments(RIRF "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  configure_imported_runcmake_fixture("${suite}" "${case}" bin ${RIRF_CONFIGURE_ARGS})
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid "--pool console=1")
  if("${RIRF_CONFIG}" STREQUAL "")
    run_build("${bin}" "${target}" "${runquota_socket}" first_output)
    report_path_from_output("${first_output}" first_report_path)
    file(READ "${first_report_path}" first_report)
    if(NOT RIRF_NONCACHEABLE)
      run_build("${bin}" "${target}" "${runquota_socket}" second_output)
    endif()
  else()
    run_build_config("${bin}" "${RIRF_CONFIG}" "${target}" "${runquota_socket}" first_output)
    report_path_from_output("${first_output}" first_report_path)
    file(READ "${first_report_path}" first_report)
    if(NOT RIRF_NONCACHEABLE)
      run_build_config("${bin}" "${RIRF_CONFIG}" "${target}" "${runquota_socket}" second_output)
    endif()
  endif()
  stop_runquota("${runquota_pid}")
  assert_contains("${first_report}" "\"runQuotaSocket\": \"${runquota_socket}\"" "${suite}/${case} first report")
  assert_contains("${first_report}" "\"evidence\"" "${suite}/${case} report")
  if(NOT RIRF_NONCACHEABLE)
    report_path_from_output("${second_output}" report_path)
    file(READ "${report_path}" report)
    assert_contains("${second_output}" "status=asCacheHit" "${suite}/${case} second build cache evidence")
    assert_contains("${report}" "\"cacheDecision\": \"cdHit\"" "${suite}/${case} cache report")
  endif()
  if(NOT RIRF_NO_DEPFILE)
    assert_contains("${first_output}" "evidence=depfile:" "${suite}/${case} first build dependency evidence")
    if(RIRF_NONCACHEABLE)
      assert_contains("${first_report}" "\"depfileInputs\"" "${suite}/${case} dependency report")
    else()
      assert_contains("${report}" "\"depfileInputs\"" "${suite}/${case} dependency report")
    endif()
  endif()
  if("${RIRF_CONFIG}" STREQUAL "")
    m11_support_line("upstream:${suite}/${case}=ran-build target=${target} generator=Reprobuild")
  else()
    m11_support_line("upstream:${suite}/${case}=ran-build config=${RIRF_CONFIG} target=${target} generator=Reprobuild")
  endif()
endfunction()

function(run_imported_runcmake_rerun_ninja)
  set(src "${CMAKE_CURRENT_LIST_DIR}/../Configure")
  set(bin "${TEST_BINARY_ROOT}/upstream-Configure-RerunCMakeNinja")
  file(REMOVE_RECURSE "${bin}")
  file(MAKE_DIRECTORY "${bin}")
  string(RANDOM LENGTH 16 ALPHABET "0123456789abcdef" compat_nonce)
  file(WRITE "${bin}/input.txt" "before\n")
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      -S "${src}"
      -B "${bin}"
      -G Reprobuild
      -DRunCMake_TEST=RerunCMakeNinja
      -DCMAKE_BUILD_TYPE=Debug
      -DCMAKE_C_COMPILER=${TEST_C_COMPILER}
      -DCMAKE_CXX_COMPILER=${TEST_CXX_COMPILER}
      "-DCMAKE_C_FLAGS=-DREPROBUILD_COMPAT_NONCE=${compat_nonce}"
      "-DCMAKE_CXX_FLAGS=-DREPROBUILD_COMPAT_NONCE=${compat_nonce}"
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr
    RESULT_VARIABLE result
    ENCODING UTF8)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR
      "Imported RunCMake fixture failed to configure: Configure/RerunCMakeNinja\n"
      "stdout:\n${stdout}\nstderr:\n${stderr}")
  endif()
  file(READ "${bin}/CMakeFiles/reprobuild/provider.meta" metadata)
  assert_contains("${metadata}" "generator=Reprobuild" "Configure/RerunCMakeNinja metadata")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${bin}" "" "${runquota_socket}" first_output)
  execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 1.1)
  file(REMOVE "${bin}/cmake_install.cmake")
  file(WRITE "${bin}/input.txt" "after\n")
  run_build("${bin}" "" "${runquota_socket}" second_output)
  stop_runquota("${runquota_pid}")
  file(READ "${bin}/stamp.txt" stamp_content)
  assert_contains("${stamp_content}" "after" "Configure/RerunCMakeNinja regenerated stamp")
  report_path_from_output("${second_output}" report_path)
  file(READ "${report_path}" report)
  assert_contains("${report}" "\"runQuotaSocket\": \"${runquota_socket}\"" "Configure/RerunCMakeNinja report")
  m11_support_line("upstream:Configure/RerunCMakeNinja=ran-rerun-build generator=Reprobuild")
endfunction()

function(run_imported_runcmake_rerun_ninja_configure)
  set(src "${CMAKE_CURRENT_LIST_DIR}/../Configure")
  set(bin "${TEST_BINARY_ROOT}/upstream-Configure-RerunCMakeNinja")
  file(REMOVE_RECURSE "${bin}")
  file(MAKE_DIRECTORY "${bin}")
  file(WRITE "${bin}/input.txt" "configure-only\n")
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      -S "${src}"
      -B "${bin}"
      -G Reprobuild
      -DRunCMake_TEST=RerunCMakeNinja
      -DCMAKE_BUILD_TYPE=Debug
      -DCMAKE_C_COMPILER=${TEST_C_COMPILER}
      -DCMAKE_CXX_COMPILER=${TEST_CXX_COMPILER}
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr
    RESULT_VARIABLE result
    ENCODING UTF8)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR
      "Imported RunCMake fixture failed to configure: Configure/RerunCMakeNinja\n"
      "stdout:\n${stdout}\nstderr:\n${stderr}")
  endif()
  file(READ "${bin}/CMakeFiles/reprobuild/provider.meta" metadata)
  assert_contains("${metadata}" "generator=Reprobuild" "Configure/RerunCMakeNinja metadata")
  m11_support_line("upstream:Configure/RerunCMakeNinja=ran-configure generator=Reprobuild")
endfunction()

function(require_m11_locked_project key)
  include("${CMAKE_CURRENT_LIST_DIR}/real-project-locks.cmake")
  foreach(field IN ITEMS NAME VERSION PROFILE URL SHA256 SOURCE_SUBDIR BUILD_TARGET INSTALL_TARGET)
    m11_project_field("${key}" "${field}" value)
    if("${value}" STREQUAL "")
      message(FATAL_ERROR
        "M11 real-project lock for '${key}' is missing ${field}. "
        "Runnable locked projects must have complete immutable source metadata.")
    endif()
  endforeach()
endfunction()

function(download_m11_project key out_source out_archive)
  require_m11_locked_project("${key}")
  m11_project_field("${key}" URL url)
  m11_project_field("${key}" SHA256 sha)
  m11_project_field("${key}" SOURCE_SUBDIR subdir)
  set(archive "${TEST_BINARY_ROOT}/source-cache/${key}.tar.gz")
  file(MAKE_DIRECTORY "${TEST_BINARY_ROOT}/source-cache")
  if(NOT EXISTS "${archive}")
    find_program(M11_CURL curl)
    if(NOT M11_CURL)
      message(FATAL_ERROR "curl is required to fetch pinned ${key} source archive")
    endif()
    execute_process(
      COMMAND "${M11_CURL}" -L --fail --silent --show-error -o "${archive}" "${url}"
      RESULT_VARIABLE download_code
      OUTPUT_VARIABLE download_stdout
      ERROR_VARIABLE download_stderr
      ENCODING UTF8)
    if(NOT download_code EQUAL 0)
      message(FATAL_ERROR
        "Could not fetch pinned ${key} source archive.\n"
        "url=${url}\nstdout=${download_stdout}\nstderr=${download_stderr}")
    endif()
  endif()
  file(SHA256 "${archive}" actual_sha)
  if(NOT "${actual_sha}" STREQUAL "${sha}")
    message(FATAL_ERROR
      "Pinned ${key} archive hash mismatch.\n"
      "expected=${sha}\nactual=${actual_sha}\narchive=${archive}")
  endif()
  set(unpack_root "${TEST_BINARY_ROOT}/sources/${key}")
  file(REMOVE_RECURSE "${unpack_root}")
  file(MAKE_DIRECTORY "${unpack_root}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar xzf "${archive}"
    WORKING_DIRECTORY "${unpack_root}"
    RESULT_VARIABLE extract_result
    OUTPUT_VARIABLE extract_stdout
    ERROR_VARIABLE extract_stderr
    ENCODING UTF8)
  if(NOT extract_result EQUAL 0)
    message(FATAL_ERROR
      "Could not extract pinned ${key} archive.\n"
      "${extract_stdout}\n${extract_stderr}")
  endif()
  set(${out_source} "${unpack_root}/${subdir}" PARENT_SCOPE)
  set(${out_archive} "${archive}" PARENT_SCOPE)
endfunction()

function(run_cmake_project_build generator binary_dir target label)
  set(command "${CMAKE_COMMAND}" --build "${binary_dir}")
  if(NOT "${target}" STREQUAL "")
    list(APPEND command --target "${target}")
  endif()
  execute_process(
    COMMAND ${command}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr
    ENCODING UTF8)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR
      "${generator} ${label} failed for ${binary_dir}.\n"
      "command=${command}\nstdout:\n${stdout}\nstderr:\n${stderr}")
  endif()
endfunction()

function(run_cmake_project_build_expect_failure generator binary_dir target label failure_needle)
  set(command "${CMAKE_COMMAND}" --build "${binary_dir}")
  if(NOT "${target}" STREQUAL "")
    list(APPEND command --target "${target}")
  endif()
  execute_process(
    COMMAND ${command}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr
    ENCODING UTF8)
  if(result EQUAL 0)
    message(FATAL_ERROR
      "${generator} ${label} unexpectedly succeeded for ${binary_dir}.\n"
      "command=${command}\nstdout:\n${stdout}\nstderr:\n${stderr}")
  endif()
  set(combined "${stdout}\n${stderr}")
  assert_contains("${combined}" "${failure_needle}" "${generator} expected ${label} failure")
endfunction()

function(configure_with_generator generator source_dir binary_dir)
  file(REMOVE_RECURSE "${binary_dir}")
  set(command
    "${CMAKE_COMMAND}"
    -S "${source_dir}"
    -B "${binary_dir}"
    -G "${generator}"
    -DCMAKE_BUILD_TYPE=Debug
    -DCMAKE_C_COMPILER=${TEST_C_COMPILER}
    -DCMAKE_CXX_COMPILER=${TEST_CXX_COMPILER}
    -DCMAKE_INSTALL_PREFIX=${binary_dir}-install
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON)
  if("${generator}" STREQUAL "Ninja")
    find_program(M11_NINJA ninja)
    if(NOT M11_NINJA)
      file(GLOB M11_NIX_NINJA "/nix/store/*ninja*/bin/ninja")
      list(SORT M11_NIX_NINJA)
      if(M11_NIX_NINJA)
        list(GET M11_NIX_NINJA 0 M11_NINJA)
      endif()
    endif()
    if(NOT M11_NINJA)
      message(FATAL_ERROR "Ninja build tool is required for M11 real-project comparison")
    endif()
    list(APPEND command -DCMAKE_MAKE_PROGRAM=${M11_NINJA})
  endif()
  foreach(arg IN LISTS ARGN)
    list(APPEND command "${arg}")
  endforeach()
  execute_process(
    COMMAND ${command}
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr
    RESULT_VARIABLE result
    ENCODING UTF8)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR
      "${generator} configure failed for ${source_dir}\n"
      "command=${command}\nstdout:\n${stdout}\nstderr:\n${stderr}")
  endif()
endfunction()

function(configure_with_generator_expect_failure generator source_dir binary_dir failure_needle)
  file(REMOVE_RECURSE "${binary_dir}")
  set(command
    "${CMAKE_COMMAND}"
    -S "${source_dir}"
    -B "${binary_dir}"
    -G "${generator}"
    -DCMAKE_BUILD_TYPE=Debug
    -DCMAKE_C_COMPILER=${TEST_C_COMPILER}
    -DCMAKE_CXX_COMPILER=${TEST_CXX_COMPILER}
    -DCMAKE_INSTALL_PREFIX=${binary_dir}-install
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON)
  foreach(arg IN LISTS ARGN)
    list(APPEND command "${arg}")
  endforeach()
  execute_process(
    COMMAND ${command}
    OUTPUT_VARIABLE stdout
    ERROR_VARIABLE stderr
    RESULT_VARIABLE result
    ENCODING UTF8)
  if(result EQUAL 0)
    message(FATAL_ERROR
      "${generator} configure unexpectedly succeeded for ${source_dir}\n"
      "command=${command}\nstdout:\n${stdout}\nstderr:\n${stderr}")
  endif()
  set(combined "${stdout}\n${stderr}")
  assert_contains("${combined}" "${failure_needle}" "${generator} expected configure failure")
endfunction()

function(assert_m11_project_outputs key ninja_bin rb_bin)
  m11_project_field("${key}" BUILD_OUTPUTS build_outputs)
  m11_project_field("${key}" INSTALL_OUTPUTS install_outputs)
  foreach(output IN LISTS build_outputs)
    assert_file_exists("${rb_bin}/${output}" "${key} Reprobuild build output")
    assert_file_exists("${ninja_bin}/${output}" "${key} Ninja build output")
  endforeach()
  foreach(output IN LISTS install_outputs)
    set(rb_output "${rb_bin}-install/${output}")
    set(ninja_output "${ninja_bin}-install/${output}")
    if(output MATCHES "^lib/" AND NOT EXISTS "${rb_output}")
      string(REGEX REPLACE "^lib/" "lib64/" output64 "${output}")
      set(rb_output "${rb_bin}-install/${output64}")
    endif()
    if(output MATCHES "^lib/" AND NOT EXISTS "${ninja_output}")
      string(REGEX REPLACE "^lib/" "lib64/" output64 "${output}")
      set(ninja_output "${ninja_bin}-install/${output64}")
    endif()
    assert_file_exists("${rb_output}" "${key} Reprobuild install")
    assert_file_exists("${ninja_output}" "${key} Ninja install")
  endforeach()
endfunction()

function(assert_m11_compile_commands key ninja_bin rb_bin)
  m11_project_field("${key}" COMPILE_COMMAND_NEEDLE needle)
  if("${needle}" STREQUAL "")
    return()
  endif()
  file(READ "${rb_bin}/compile_commands.json" rb_compile_commands)
  file(READ "${ninja_bin}/compile_commands.json" ninja_compile_commands)
  assert_contains("${rb_compile_commands}" "${needle}" "${key} Reprobuild compile commands")
  assert_contains("${ninja_compile_commands}" "${needle}" "${key} Ninja compile commands")
endfunction()

function(assert_m11_reprobuild_evidence key rb_first rb_second runquota_socket rb_first_report_snapshot)
  m11_project_field("${key}" EXPECT_COMPILE_ACTIONS expect_compile_actions)
  if(expect_compile_actions)
    report_path_from_output("${rb_second}" rb_report_path)
    file(READ "${rb_first_report_snapshot}" rb_first_report)
    file(READ "${rb_report_path}" rb_report)
    assert_contains("${rb_first_report}" "\"runQuotaSocket\": \"${runquota_socket}\"" "${key} RunQuota report")
    assert_contains("${rb_second}" "status=asCacheHit" "${key} second build cache evidence")
    assert_contains("${rb_first}" "evidence=depfile:" "${key} first build dependency evidence")
    assert_contains("${rb_report}" "\"cacheDecision\": \"cdHit\"" "${key} cache report")
    assert_contains("${rb_report}" "\"depfileInputs\"" "${key} dependency evidence report")
  else()
    assert_contains("${rb_second}" "runQuotaSocket:" "${key} RunQuota output")
    assert_contains("${rb_second}" "scheduler: actions=0" "${key} header-only scheduler output")
  endif()
endfunction()

function(run_m11_real_project key)
  require_m11_locked_project("${key}")
  download_m11_project("${key}" project_src project_archive)
  m11_project_field("${key}" CONFIGURE_ARGS project_args)
  m11_project_field("${key}" BUILD_TARGET build_target)
  m11_project_field("${key}" INSTALL_TARGET install_target)
  m11_project_field("${key}" PROFILE profile)
  m11_project_field("${key}" SHA256 project_sha)

  set(ninja_bin "${TEST_BINARY_ROOT}/${key}-ninja-build")
  configure_with_generator("Ninja" "${project_src}" "${ninja_bin}" ${project_args})
  m11_project_field("${key}" EXPECT_NINJA_BUILD_FAILURE expect_ninja_build_failure)
  if(expect_ninja_build_failure)
    m11_project_field("${key}" EXPECT_NINJA_BUILD_FAILURE_NEEDLE failure_needle)
    if("${failure_needle}" STREQUAL "")
      message(FATAL_ERROR "${key} expected Ninja build failure is missing failure needle")
    endif()
    run_cmake_project_build_expect_failure("Ninja" "${ninja_bin}" "${build_target}" "build" "${failure_needle}")
    set(rb_bin "${TEST_BINARY_ROOT}/${key}-reprobuild-build")
    configure_with_generator("Reprobuild" "${project_src}" "${rb_bin}" ${project_args})
    file(READ "${rb_bin}/CMakeFiles/reprobuild/provider.meta" metadata)
    assert_contains("${metadata}" "generator=Reprobuild" "${key} provider metadata")
    m11_support_line("real-project:${key}=host-toolchain-unavailable profile=${profile} archive=${project_archive} sha256=${project_sha} ninja-build-failure=${failure_needle} reprobuild-configure=ran")
    return()
  endif()
  run_cmake_project_build("Ninja" "${ninja_bin}" "${build_target}" "build")
  run_cmake_project_build("Ninja" "${ninja_bin}" "${install_target}" "install")

  m11_project_field("${key}" EXPECT_REPROBUILD_CONFIGURE_FAILURE expect_reprobuild_configure_failure)
  if(expect_reprobuild_configure_failure)
    m11_project_field("${key}" EXPECT_REPROBUILD_CONFIGURE_FAILURE_NEEDLE failure_needle)
    if("${failure_needle}" STREQUAL "")
      message(FATAL_ERROR "${key} expected Reprobuild configure failure is missing failure needle")
    endif()
    set(rb_bin "${TEST_BINARY_ROOT}/${key}-reprobuild-build")
    configure_with_generator_expect_failure("Reprobuild" "${project_src}" "${rb_bin}" "${failure_needle}" ${project_args})
    m11_support_line("real-project:${key}=ran-ninja-and-reprobuild-configure-diagnostic profile=${profile} archive=${project_archive} sha256=${project_sha} reprobuild-configure-gap=${failure_needle}")
    return()
  endif()

  set(rb_bin "${TEST_BINARY_ROOT}/${key}-reprobuild-build")
  configure_with_generator("Reprobuild" "${project_src}" "${rb_bin}" ${project_args})
  file(READ "${rb_bin}/CMakeFiles/reprobuild/provider.meta" metadata)
  assert_contains("${metadata}" "generator=Reprobuild" "${key} provider metadata")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid "--pool console=1")
  run_build("${rb_bin}" "${build_target}" "${runquota_socket}" rb_first)
  m11_project_field("${key}" EXPECT_COMPILE_ACTIONS expect_compile_actions)
  if(expect_compile_actions)
    report_path_from_output("${rb_first}" rb_first_report_path)
    set(rb_first_report_snapshot "${TEST_BINARY_ROOT}/${key}-first-build-report.json")
    file(READ "${rb_first_report_path}" rb_first_report)
    file(WRITE "${rb_first_report_snapshot}" "${rb_first_report}")
  else()
    set(rb_first_report_snapshot "")
  endif()
  run_build("${rb_bin}" "${build_target}" "${runquota_socket}" rb_second)
  m11_project_field("${key}" EXPECT_REPROBUILD_INSTALL_FAILURE expect_reprobuild_install_failure)
  if(expect_reprobuild_install_failure)
    m11_project_field("${key}" EXPECT_REPROBUILD_INSTALL_FAILURE_NEEDLE install_failure_needle)
    if("${install_failure_needle}" STREQUAL "")
      message(FATAL_ERROR "${key} expected Reprobuild install failure is missing failure needle")
    endif()
    run_build_expect_failure("${rb_bin}" "${install_target}" "${runquota_socket}" rb_install)
    assert_contains("${rb_install}" "${install_failure_needle}" "${key} expected Reprobuild install failure")
    stop_runquota("${runquota_pid}")
    assert_m11_compile_commands("${key}" "${ninja_bin}" "${rb_bin}")
    assert_m11_reprobuild_evidence("${key}" "${rb_first}" "${rb_second}" "${runquota_socket}" "${rb_first_report_snapshot}")
    m11_support_line("real-project:${key}=ran-build-cache-diagnostic profile=${profile} archive=${project_archive} sha256=${project_sha} reprobuild-install-gap=${install_failure_needle}")
    return()
  endif()
  run_build("${rb_bin}" "${install_target}" "${runquota_socket}" rb_install)
  stop_runquota("${runquota_pid}")

  assert_m11_project_outputs("${key}" "${ninja_bin}" "${rb_bin}")
  assert_m11_compile_commands("${key}" "${ninja_bin}" "${rb_bin}")
  assert_m11_reprobuild_evidence("${key}" "${rb_first}" "${rb_second}" "${runquota_socket}" "${rb_first_report_snapshot}")
  m11_support_line("real-project:${key}=ran profile=${profile} archive=${project_archive} sha256=${project_sha}")
endfunction()

function(m11_projects_for_profile profile out_var)
  include("${CMAKE_CURRENT_LIST_DIR}/real-project-locks.cmake")
  if("${profile}" STREQUAL "" OR "${profile}" STREQUAL "default")
    set(projects ${M11_REAL_PROJECT_DEFAULT_PROJECTS})
  elseif("${profile}" STREQUAL "medium")
    set(projects ${M11_REAL_PROJECT_MEDIUM_PROJECTS})
  elseif("${profile}" STREQUAL "nightly")
    set(projects ${M11_REAL_PROJECT_NIGHTLY_PROJECTS})
  else()
    message(FATAL_ERROR
      "Unknown TEST_REAL_PROJECT_PROFILE='${profile}'. "
      "Use default, medium, or nightly.")
  endif()
  set(${out_var} "${projects}" PARENT_SCOPE)
endfunction()

function(write_m11_real_project_availability active_projects)
  include("${CMAKE_CURRENT_LIST_DIR}/real-project-locks.cmake")
  foreach(key IN LISTS M11_REAL_PROJECT_ALL_PROJECTS)
    require_m11_locked_project("${key}")
  endforeach()
  foreach(key IN LISTS M11_REAL_PROJECT_ALL_PROJECTS)
    if(NOT key IN_LIST active_projects)
      m11_project_field("${key}" PROFILE profile)
      m11_project_field("${key}" URL url)
      m11_project_field("${key}" SHA256 sha)
      m11_support_line("real-project:${key}=available-not-run profile=${profile} url=${url} sha256=${sha}")
    endif()
  endforeach()
  m11_support_line("real-project-control:default=ctest --output-on-failure -R '^e2e_cmake_reprobuild_real_project_matrix$'")
  m11_support_line("real-project-control:medium=configure with -DCMake_TEST_REPROBUILD_REAL_PROJECT_MEDIUM=ON then run ctest -R '^e2e_cmake_reprobuild_real_project_matrix_medium$'")
  m11_support_line("real-project-control:nightly=configure with -DCMake_TEST_REPROBUILD_REAL_PROJECT_NIGHTLY=ON then run ctest -R '^e2e_cmake_reprobuild_real_project_matrix_nightly$'")
endfunction()

function(write_m11_platform_support_profile)
  if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    m11_support_line("platform:macos=ran host=${CMAKE_HOST_SYSTEM_NAME}")
    m11_support_line("platform:linux=unavailable host=${CMAKE_HOST_SYSTEM_NAME} evidence=not-this-host")
    m11_support_line("platform:windows=unavailable host=${CMAKE_HOST_SYSTEM_NAME} evidence=not-this-host")
  elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
    m11_support_line("platform:linux=ran host=${CMAKE_HOST_SYSTEM_NAME}")
    m11_support_line("platform:macos=unavailable host=${CMAKE_HOST_SYSTEM_NAME} evidence=not-this-host")
    m11_support_line("platform:windows=unavailable host=${CMAKE_HOST_SYSTEM_NAME} evidence=not-this-host")
  elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
    m11_support_line("platform:windows=ran host=${CMAKE_HOST_SYSTEM_NAME}")
    m11_support_line("platform:linux=unavailable host=${CMAKE_HOST_SYSTEM_NAME} evidence=not-this-host")
    m11_support_line("platform:macos=unavailable host=${CMAKE_HOST_SYSTEM_NAME} evidence=not-this-host")
  else()
    m11_support_line("platform:unknown=unavailable host=${CMAKE_HOST_SYSTEM_NAME}")
  endif()
endfunction()

if(TEST_MODE STREQUAL "compatibility_suite")
  file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
  file(MAKE_DIRECTORY "${TEST_BINARY_ROOT}")
  write_m11_platform_support_profile()
  run_imported_runcmake_fixture(Ninja Executable hello)
  run_imported_runcmake_fixture(Ninja StaticLib hello)
  run_imported_runcmake_fixture(Ninja SharedLib hello)
  run_imported_runcmake_fixture(Ninja NoWorkToDo hello)
  run_imported_runcmake_fixture(Ninja VerboseBuild hello)
  run_imported_runcmake_configure(Ninja CustomCommandDepfile)
  run_imported_runcmake_configure(Ninja CustomCommandDepfileAsOutput)
  run_imported_runcmake_configure(Ninja CustomCommandDepfileAsByproduct)
  run_imported_runcmake_configure(Ninja CustomCommandJobPool)
  m11_support_line("upstream:Ninja/CustomCommandJobPool runtime=covered-by-generated-pool-limit custom-command-output=known-gap evidence=provider-declared-input-output-inversion")
  run_imported_runcmake_configure(Ninja RspFileC)
  run_imported_runcmake_configure(Ninja RspFileCXX)
  run_imported_runcmake_fixture(NinjaMultiConfig CompileCommands exe
    CONFIG Debug
    CONFIGURE_ARGS
      "-DCMAKE_CONFIGURATION_TYPES=Debug\\;Release"
      "-DCMAKE_DEFAULT_BUILD_TYPE=Debug"
      "-DCMAKE_DEFAULT_CONFIGS=Debug")
  run_imported_runcmake_configure(NinjaMultiConfig CustomCommandDepfile
    "-DCMAKE_CONFIGURATION_TYPES=Debug\\;Release"
    "-DCMAKE_DEFAULT_BUILD_TYPE=Debug"
    "-DCMAKE_DEFAULT_CONFIGS=Debug")
  run_imported_runcmake_fixture(ObjectLibrary LinkObjRHSStatic exe)
  run_imported_runcmake_fixture(Byproducts CleanByproducts foo NO_DEPFILE)
  run_imported_runcmake_fixture(BuiltinTargets TestDependsAll-Yes test NO_DEPFILE NONCACHEABLE)
  run_imported_runcmake_configure(LinkFlags LINK_FLAGS)
  run_imported_runcmake_configure(InstallParallel install
    "-DINSTALL_PARALLEL=ON")
  m11_support_line("upstream:InstallParallel runtime=covered-by-real-project-install-targets parallel-install-upstream-target=known-gap")
  run_imported_runcmake_configure(try_compile LinkOptions)
  run_imported_runcmake_configure(file GLOB-CONFIGURE_DEPENDS-RerunCMake)
  run_imported_runcmake_rerun_ninja_configure()
  m11_support_line("upstream:Configure/RerunCMakeNinja runtime=known-gap evidence=missing-cmake_install-triggered-regeneration")
  m11_support_line("upstream:CXXModules=delegated-to-e2e_cmake_reprobuild_cxx20_modules_dyndep with real C++20 module build or support-profile")
  m11_support_line("upstream:CXXModulesCompile=delegated-to-e2e_cmake_reprobuild_cxx20_modules_dyndep with real C++20 module build or support-profile")
  m11_support_line("upstream:CommandLine=covered-by-Reprobuild configure/build command invocations and generated built-in target matrix")
  m11_support_line("upstream:ctest_build=covered-by-generated builtin test target; full upstream ctest_build scripts remain registered as follow-up")
  if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    m11_support_line("upstream:Framework=covered-by-e2e_cmake_reprobuild_language_profile_matrix Apple framework build on macOS")
  else()
    m11_support_line("upstream:Framework=unavailable host=${CMAKE_HOST_SYSTEM_NAME} evidence=not-apple-platform")
  endif()
  m11_support_line("upstream:CUDA_architectures=covered-by-profile_unavailable_diagnostics or CUDA available fixture with explicit toolchain evidence")
  return()
elseif(TEST_MODE STREQUAL "generated_feature_matrix")
  file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
  file(MAKE_DIRECTORY "${TEST_BINARY_ROOT}")
  write_m11_platform_support_profile()
  foreach(mode IN ITEMS
      response_file_identity
      generated_source_custom_command
      custom_depfile_hidden_input
      pool_limit
      runquota_memory_budget_rejection
      uses_terminal_pool
      regeneration_refresh
      cross_config_generated_source
      link_byproducts
      builtin_install_and_test_targets
      hcr_rejects_incompatible_target)
    run_m11_submode("${mode}")
    m11_support_line("generated-feature:${mode}=ran")
  endforeach()
  m11_support_line("generated-feature:fortran-modules=delegated-to-e2e_cmake_reprobuild_fortran_dyndep_modules with explicit compiler support-profile")
  m11_support_line("generated-feature:cxx20-modules=delegated-to-e2e_cmake_reprobuild_cxx20_modules_dyndep")
  return()
elseif(TEST_MODE STREQUAL "real_project_matrix")
  file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
  file(MAKE_DIRECTORY "${TEST_BINARY_ROOT}")
  write_m11_platform_support_profile()
  if(NOT DEFINED TEST_REAL_PROJECT_PROFILE)
    set(TEST_REAL_PROJECT_PROFILE default)
  endif()
  if(DEFINED TEST_REAL_PROJECT_KEYS AND NOT "${TEST_REAL_PROJECT_KEYS}" STREQUAL "")
    set(real_projects ${TEST_REAL_PROJECT_KEYS})
  else()
    m11_projects_for_profile("${TEST_REAL_PROJECT_PROFILE}" real_projects)
  endif()
  foreach(project_key IN LISTS real_projects)
    run_m11_real_project("${project_key}")
  endforeach()
  m11_support_line("real-project-summary:profile=${TEST_REAL_PROJECT_PROFILE} ran=${real_projects}")
  write_m11_real_project_availability("${real_projects}")
  return()
endif()

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
  run_configure("${source_dir}" "${multi_binary_dir}" TRUE ""
    "-DCMAKE_CONFIGURATION_TYPES=Debug\\;Release"
    "-DCMAKE_DEFAULT_BUILD_TYPE=Debug"
    "-DCMAKE_DEFAULT_CONFIGS=Debug")
  file(READ "${multi_binary_dir}/CMakeFiles/reprobuild/provider.meta" multi_metadata)
  foreach(expected IN ITEMS
      "configurations=Debug,Release"
      "default_build_type=Debug"
      "default_configs=Debug"
      "targets=all,default,hello:Debug,hello:Release")
    assert_contains("${multi_metadata}" "${expected}" "multi-config configure metadata")
  endforeach()
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
elseif(TEST_MODE STREQUAL "source_flags_subdir_link")
  set(source_flags_source_dir "${TEST_BINARY_ROOT}/source-flags-src")
  set(source_flags_binary_dir "${TEST_BINARY_ROOT}/source-flags-build")
  write_source_flags_subdir_link_project("${source_flags_source_dir}" ReprobuildSourceFlagsSubdirLink)
  run_configure("${source_flags_source_dir}" "${source_flags_binary_dir}" TRUE ""
    "-DCMAKE_BUILD_TYPE=Debug")
  file(READ "${source_flags_binary_dir}/reprobuild.nim" source_flags_provider)
  foreach(expected IN ITEMS
      "\"-g\""
      "\"-DSOURCE_COMPILE_FLAGS=1\""
      "\"-DSOURCE_COMPILE_OPTION=1\""
      "\"libdir/libnested.a\"")
    assert_contains("${source_flags_provider}" "${expected}" "source flags/subdir link provider")
  endforeach()

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${source_flags_binary_dir}" "app" "${runquota_socket}" source_flags_output)
  stop_runquota("${runquota_pid}")
  execute_process(
    COMMAND "${source_flags_binary_dir}/app"
    RESULT_VARIABLE source_flags_result
    OUTPUT_VARIABLE source_flags_stdout
    ERROR_VARIABLE source_flags_stderr
    ENCODING UTF8)
  if(NOT source_flags_result EQUAL 0)
    message(FATAL_ERROR
      "Source-flags/subdir-link executable did not run correctly.\n"
      "stdout:\n${source_flags_stdout}\n"
      "stderr:\n${source_flags_stderr}\n"
      "build output:\n${source_flags_output}")
  endif()
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
elseif(TEST_MODE STREQUAL "runquota_memory_budget_rejection")
  prepare_reprobuild_provider("${binary_dir}" "hello")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid "--memory-bytes 67108864")
  run_build_expect_failure("${binary_dir}" "hello" "${runquota_socket}" memory_output)
  stop_runquota("${runquota_pid}")
  report_path_from_output("${memory_output}" memory_report_path)
  file(READ "${memory_report_path}" memory_report)
  assert_contains("${memory_report}" "\"status\": \"asFailed\"" "RunQuota memory report")
  assert_contains_any("${memory_report}" "RunQuota memory report"
    "\"runQuotaBackend\": \"runquota-client\""
    "\"runQuotaBackend\": \"runquota-inline\"")
  assert_contains("${memory_report}" "\"status\": \"asBlocked\"" "RunQuota memory report")
  assert_contains("${memory_report}" "runquota denied lease" "RunQuota memory report")
  assert_contains("${memory_report}" "memory budget" "RunQuota memory report")
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
  run_build("${rsp_binary_dir}" "clean" "${runquota_socket}" rsp_clean_output)
  assert_file_exists("${rsp_file}" "response file after clean")
  run_build("${rsp_binary_dir}" "rspapp" "${runquota_socket}" post_clean_output)
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
elseif(TEST_MODE STREQUAL "multi_config_debug_release")
  set(multi_source_dir "${TEST_BINARY_ROOT}/multi-src")
  set(multi_binary_dir "${TEST_BINARY_ROOT}/multi-build")
  write_multi_config_project("${multi_source_dir}" ReprobuildMultiConfig)
  run_configure("${multi_source_dir}" "${multi_binary_dir}" TRUE ""
    "-DCMAKE_CONFIGURATION_TYPES=Debug\\;Release"
    "-DCMAKE_DEFAULT_BUILD_TYPE=Debug"
    "-DCMAKE_DEFAULT_CONFIGS=Debug")
  file(READ "${multi_binary_dir}/reprobuild.nim" multi_provider)
  foreach(expected IN ITEMS
      "target(\"app:Debug\""
      "target(\"app:Release\""
      "aggregate(\"app:all\""
      "aggregate(\"app\"")
    assert_contains("${multi_provider}" "${expected}" "multi-config provider")
  endforeach()

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build_config("${multi_binary_dir}" "Debug" "app" "${runquota_socket}" debug_output)
  run_build_config("${multi_binary_dir}" "Release" "app" "${runquota_socket}" release_output)
  stop_runquota("${runquota_pid}")
  foreach(expected IN ITEMS
      "selectedTarget: app:Debug"
      "action: app:Debug status=asSucceeded launched=true")
    assert_contains("${debug_output}" "${expected}" "Debug multi-config build output")
  endforeach()
  foreach(expected IN ITEMS
      "selectedTarget: app:Release"
      "action: app:Release status=asSucceeded launched=true")
    assert_contains("${release_output}" "${expected}" "Release multi-config build output")
  endforeach()
  execute_process(COMMAND "${multi_binary_dir}/Debug/app"
    OUTPUT_VARIABLE debug_run OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE debug_result)
  execute_process(COMMAND "${multi_binary_dir}/Release/app"
    OUTPUT_VARIABLE release_run OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE release_result)
  if(NOT debug_result EQUAL 0 OR NOT "${debug_run}" STREQUAL "debug")
    message(FATAL_ERROR "Debug app output mismatch: result=${debug_result} output=${debug_run}")
  endif()
  if(NOT release_result EQUAL 0 OR NOT "${release_run}" STREQUAL "release")
    message(FATAL_ERROR "Release app output mismatch: result=${release_result} output=${release_run}")
  endif()

  execute_process(
    COMMAND "${CMAKE_COMMAND}" --build "${multi_binary_dir}" --config Debug --target clean
    OUTPUT_VARIABLE clean_stdout ERROR_VARIABLE clean_stderr RESULT_VARIABLE clean_result ENCODING UTF8)
  if(NOT clean_result EQUAL 0)
    message(FATAL_ERROR "Per-config clean failed.\nstdout:\n${clean_stdout}\nstderr:\n${clean_stderr}")
  endif()
  assert_file_not_exists("${multi_binary_dir}/Debug/app" "Debug per-config clean")
  assert_file_exists("${multi_binary_dir}/Release/app" "Release output after Debug clean")
elseif(TEST_MODE STREQUAL "multi_config_target_selection")
  set(sel_source_dir "${TEST_BINARY_ROOT}/selection-src")
  set(sel_binary_dir "${TEST_BINARY_ROOT}/selection-build")
  write_multi_config_project("${sel_source_dir}" ReprobuildMultiSelection)
  run_configure("${sel_source_dir}" "${sel_binary_dir}" TRUE ""
    "-DCMAKE_CONFIGURATION_TYPES=Debug\\;Release"
    "-DCMAKE_DEFAULT_BUILD_TYPE=Debug"
    "-DCMAKE_DEFAULT_CONFIGS=Debug")

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build_config("${sel_binary_dir}" "Debug" "app" "${runquota_socket}" selection_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${selection_output}" "selectedTarget: app:Debug" "multi-config selection output")
  assert_contains("${selection_output}" "action: app:Debug status=asSucceeded launched=true" "multi-config selection output")
  assert_not_contains("${selection_output}" "link-side-Debug status=asSucceeded launched=true" "multi-config selection output")
  assert_not_contains("${selection_output}" "link-app-Release status=asSucceeded launched=true" "multi-config selection output")
  assert_file_exists("${sel_binary_dir}/Debug/app" "selected Debug app")
  assert_file_not_exists("${sel_binary_dir}/Debug/side" "unselected Debug side")
  assert_file_not_exists("${sel_binary_dir}/Release/app" "unselected Release app")

  set(order_source_dir "${TEST_BINARY_ROOT}/default-order-src")
  set(order_binary_dir "${TEST_BINARY_ROOT}/default-order-build")
  write_multi_config_project("${order_source_dir}" ReprobuildDefaultOrder)
  run_configure("${order_source_dir}" "${order_binary_dir}" TRUE ""
    "-DCMAKE_CONFIGURATION_TYPES=Release\\;Debug")
  file(READ "${order_binary_dir}/CMakeFiles/reprobuild/provider.meta" order_metadata)
  assert_contains("${order_metadata}" "configurations=Release,Debug" "default-order metadata")
  assert_contains("${order_metadata}" "default_build_type=Release" "default-order metadata")
  assert_contains("${order_metadata}" "default_configs=Release" "default-order metadata")

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build_config("${order_binary_dir}" "" "app" "${runquota_socket}" order_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${order_output}" "selectedTarget: app" "default-order build output")
  assert_contains("${order_output}" "action: app:Release status=asSucceeded launched=true" "default-order build output")
  assert_not_contains("${order_output}" "link-app-Debug status=asSucceeded launched=true" "default-order build output")
  assert_file_exists("${order_binary_dir}/Release/app" "implicit Release app")
  assert_file_not_exists("${order_binary_dir}/Debug/app" "implicit default should not build Debug app")
elseif(TEST_MODE STREQUAL "multi_config_unprefixed_custom_command")
  # M27 regression gate. ``add_custom_command(OUTPUT <binDir>/generated.c)``
  # without ``$<CONFIG>`` must build under both Debug and Release. The
  # provider must declare the custom-command OUTPUT and the link-line
  # external-object input at the literal (unprefixed) path the COMMAND
  # writes to. Before M27 the OUTPUT and link-line both got an erroneous
  # ``Debug/``/``Release/`` prefix while the COMMAND argv wrote to the
  # unprefixed path, so the link step looked for a file that did not
  # exist and the build failed.
  set(unprefixed_source_dir "${TEST_BINARY_ROOT}/unprefixed-src")
  set(unprefixed_binary_dir "${TEST_BINARY_ROOT}/unprefixed-build")
  write_multi_config_unprefixed_custom_command_project(
    "${unprefixed_source_dir}" ReprobuildUnprefixedCustomCommand)
  run_configure("${unprefixed_source_dir}" "${unprefixed_binary_dir}" TRUE ""
    "-DCMAKE_CONFIGURATION_TYPES=Debug\\;Release"
    "-DCMAKE_DEFAULT_BUILD_TYPE=Debug"
    "-DCMAKE_DEFAULT_CONFIGS=Debug")

  # Generated reprobuild.nim must reference the custom-command output at
  # the literal unprefixed path. The graph emits a ``custom-command-app-…``
  # action whose Outputs entry should be ``generated.c`` (no ``Debug/``
  # or ``Release/`` prefix). This is the load-bearing assertion: a
  # passing build alone could hide a regression if the engine masked the
  # path mismatch by falling back to the unprefixed file silently.
  file(READ "${unprefixed_binary_dir}/reprobuild.nim" unprefixed_provider)
  assert_contains("${unprefixed_provider}"
    "custom-command-app-generated.c"
    "M27 unprefixed custom-command action id")
  if(unprefixed_provider MATCHES "custom-command-app-Debug_generated.c")
    message(FATAL_ERROR
      "M27 regression: provider still config-prefixes the unprefixed "
      "custom-command output. Expected the OUTPUT to land at "
      "``generated.c`` (matching where the COMMAND argv writes), not "
      "``Debug/generated.c``.")
  endif()
  if(unprefixed_provider MATCHES "custom-command-app-Release_generated.c")
    message(FATAL_ERROR
      "M27 regression: provider still config-prefixes the unprefixed "
      "custom-command output for the Release variant.")
  endif()

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build_config("${unprefixed_binary_dir}" "Debug" "app"
    "${runquota_socket}" unprefixed_debug_output)
  run_build_config("${unprefixed_binary_dir}" "Release" "app"
    "${runquota_socket}" unprefixed_release_output)
  stop_runquota("${runquota_pid}")
  foreach(expected IN ITEMS
      "selectedTarget: app:Debug"
      "action: app:Debug status=asSucceeded launched=true")
    assert_contains("${unprefixed_debug_output}" "${expected}"
      "M27 Debug build output")
  endforeach()
  foreach(expected IN ITEMS
      "selectedTarget: app:Release"
      "action: app:Release status=asSucceeded launched=true")
    assert_contains("${unprefixed_release_output}" "${expected}"
      "M27 Release build output")
  endforeach()
  assert_file_exists("${unprefixed_binary_dir}/generated.c"
    "M27 unprefixed custom command writes to literal binary-dir path")
  assert_file_exists("${unprefixed_binary_dir}/Debug/app"
    "M27 Debug app link succeeded against unprefixed custom-command output")
  assert_file_exists("${unprefixed_binary_dir}/Release/app"
    "M27 Release app link succeeded against unprefixed custom-command output")
elseif(TEST_MODE STREQUAL "cross_config_generated_source")
  set(cross_source_dir "${TEST_BINARY_ROOT}/cross-src")
  set(cross_binary_dir "${TEST_BINARY_ROOT}/cross-build")
  write_cross_config_generated_source_project("${cross_source_dir}" ReprobuildCrossGenerated)
  run_configure("${cross_source_dir}" "${cross_binary_dir}" TRUE ""
    "-DCMAKE_CONFIGURATION_TYPES=Debug\\;Release"
    "-DCMAKE_DEFAULT_BUILD_TYPE=Release"
    "-DCMAKE_DEFAULT_CONFIGS=Release"
    "-DCMAKE_CROSS_CONFIGS=all")
  file(READ "${cross_binary_dir}/reprobuild.nim" cross_provider)
  foreach(expected IN ITEMS
      "target(\"app:Debug\""
      "target(\"app:Release\""
      "target(\"app:Debug:Release\""
      "aggregate(\"app:all:Release\""
      "$<COMMAND_CONFIG:"
      "Debug/generated.c"
      "commandStatsId = \"compile-app-CMakeFiles_app.dir_Debug_generated")
    if("${expected}" STREQUAL "$<COMMAND_CONFIG:")
      assert_contains("${cross_provider}" "custom-command-app-Debug_generated.c-Debug-from-Release" "cross-config provider")
    else()
      assert_contains("${cross_provider}" "${expected}" "cross-config provider")
    endif()
  endforeach()

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build_config("${cross_binary_dir}" "Release" "app:Debug" "${runquota_socket}" cross_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${cross_output}" "selectedTarget: app:Debug:Release" "cross-config build output")
  assert_contains("${cross_output}" "custom-command-app-Debug_generated.c-Debug-from-Release status=asSucceeded launched=true" "cross-config build output")
  assert_contains("${cross_output}" "compile-app-CMakeFiles_app.dir_Debug_generated.c.o-Debug-from-Release status=asSucceeded launched=true" "cross-config build output")
  assert_contains("${cross_output}" "gen:Release status=asSucceeded launched=true" "cross-config build output")
  assert_file_exists("${cross_binary_dir}/Debug/generated.c" "cross-config generated source")
  assert_file_exists("${cross_binary_dir}/Debug/app" "cross-config app")
  execute_process(COMMAND "${cross_binary_dir}/Debug/app" RESULT_VARIABLE cross_result)
  if(NOT cross_result EQUAL 0)
    message(FATAL_ERROR "Cross-config generated-source executable failed with ${cross_result}")
  endif()
  file(READ "${cross_binary_dir}/Debug/generated.c" generated_content)
  assert_contains("${generated_content}" "return 42" "cross-config generated source")

  set(native_cross_binary_dir "${TEST_BINARY_ROOT}/cross-native-build")
  run_configure("${cross_source_dir}" "${native_cross_binary_dir}" TRUE ""
    "-DCMAKE_CONFIGURATION_TYPES=Debug\\;Release"
    "-DCMAKE_DEFAULT_BUILD_TYPE=Release"
    "-DCMAKE_DEFAULT_CONFIGS=Release"
    "-DCMAKE_CROSS_CONFIGS=all")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build_config("${native_cross_binary_dir}" "Debug" "app" "${runquota_socket}" native_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${native_output}" "selectedTarget: app:Debug" "native-with-cross-config build output")
  assert_contains("${native_output}" "custom-command-app-Debug_generated.c-Debug status=asSucceeded launched=true" "native-with-cross-config build output")
  assert_contains("${native_output}" "compile-app-CMakeFiles_app.dir_Debug_generated.c.o-Debug status=asSucceeded launched=true" "native-with-cross-config build output")
  assert_not_contains("${native_output}" "unknown build target/action id: app:Debug" "native-with-cross-config build output")
  assert_file_exists("${native_cross_binary_dir}/Debug/app" "native Debug app with cross configs enabled")
  execute_process(COMMAND "${native_cross_binary_dir}/Debug/app" RESULT_VARIABLE native_result)
  if(NOT native_result EQUAL 0)
    message(FATAL_ERROR "Native Debug executable failed with ${native_result}")
  endif()

  set(default_all_binary_dir "${TEST_BINARY_ROOT}/cross-default-all-build")
  run_configure("${cross_source_dir}" "${default_all_binary_dir}" TRUE ""
    "-DCMAKE_CONFIGURATION_TYPES=Debug\\;Release"
    "-DCMAKE_DEFAULT_BUILD_TYPE=Release"
    "-DCMAKE_DEFAULT_CONFIGS=all"
    "-DCMAKE_CROSS_CONFIGS=Debug")
  file(READ "${default_all_binary_dir}/CMakeFiles/reprobuild/provider.meta" default_all_metadata)
  assert_contains("${default_all_metadata}" "default_build_type=Release" "default-all metadata")
  assert_contains("${default_all_metadata}" "default_configs=Debug" "default-all metadata")
  assert_contains("${default_all_metadata}" "cross_configs=Debug" "default-all metadata")
  assert_not_contains("${default_all_metadata}" "default_configs=Debug,Release" "default-all metadata")

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build_config("${default_all_binary_dir}" "" "app" "${runquota_socket}" default_all_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${default_all_output}" "selectedTarget: app" "default-all build output")
  assert_contains("${default_all_output}" "custom-command-app-Debug_generated.c-Debug-from-Release status=asSucceeded launched=true" "default-all build output")
  assert_contains("${default_all_output}" "compile-app-CMakeFiles_app.dir_Debug_generated.c.o-Debug-from-Release status=asSucceeded launched=true" "default-all build output")
  assert_contains("${default_all_output}" "gen:Release status=asSucceeded launched=true" "default-all build output")
  assert_not_contains("${default_all_output}" "action: app:Release status=asSucceeded launched=true" "default-all build output")
  assert_file_exists("${default_all_binary_dir}/Debug/app" "default-all Debug app")
  assert_file_not_exists("${default_all_binary_dir}/Release/app" "default-all must not build Release app")
  execute_process(COMMAND "${default_all_binary_dir}/Debug/app" RESULT_VARIABLE default_all_result)
  if(NOT default_all_result EQUAL 0)
    message(FATAL_ERROR "Default-all Debug executable failed with ${default_all_result}")
  endif()

  set(target_all_binary_dir "${TEST_BINARY_ROOT}/cross-target-all-build")
  run_configure("${cross_source_dir}" "${target_all_binary_dir}" TRUE ""
    "-DCMAKE_CONFIGURATION_TYPES=Debug\\;Release"
    "-DCMAKE_DEFAULT_BUILD_TYPE=Release"
    "-DCMAKE_DEFAULT_CONFIGS=Release"
    "-DCMAKE_CROSS_CONFIGS=Debug")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build_config("${target_all_binary_dir}" "Release" "app:all" "${runquota_socket}" target_all_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${target_all_output}" "selectedTarget: app:all:Release" "target-all build output")
  assert_contains("${target_all_output}" "custom-command-app-Debug_generated.c-Debug-from-Release status=asSucceeded launched=true" "target-all build output")
  assert_contains("${target_all_output}" "compile-app-CMakeFiles_app.dir_Debug_generated.c.o-Debug-from-Release status=asSucceeded launched=true" "target-all build output")
  assert_contains("${target_all_output}" "gen:Release status=asSucceeded launched=true" "target-all build output")
  assert_not_contains("${target_all_output}" "action: app:Release status=asSucceeded launched=true" "target-all build output")
  assert_file_exists("${target_all_binary_dir}/Debug/app" "target-all Debug app")
  assert_file_not_exists("${target_all_binary_dir}/Release/app" "target-all must not build Release app")
  execute_process(COMMAND "${target_all_binary_dir}/Debug/app" RESULT_VARIABLE target_all_result)
  if(NOT target_all_result EQUAL 0)
    message(FATAL_ERROR "Target-all Debug executable failed with ${target_all_result}")
  endif()
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
  assert_regeneration_action_fresh_or_cached("${regen_first}" "initial regeneration edge")
  execute_process(COMMAND "${regen_binary_dir}/regenapp" RESULT_VARIABLE regen_first_result)
  if(NOT regen_first_result EQUAL 1)
    stop_runquota("${runquota_pid}")
    message(FATAL_ERROR "Expected first regenapp exit 1, got ${regen_first_result}")
  endif()
  run_build("${regen_binary_dir}" "regenapp" "${runquota_socket}" regen_noop)
  assert_contains("${regen_noop}" "cmakeRegenerationAction: __repro_cmake_regenerate status=asCacheHit launched=false cache=cdHit" "no-op regeneration edge")
  report_path_from_output("${regen_noop}" regen_noop_report_path)
  file(READ "${regen_noop_report_path}" regen_noop_report)
  assert_contains("${regen_noop_report}" "\"cmakeRegenerationActions\"" "no-op regeneration report")
  assert_matches("${regen_noop_report}" "\"id\"[ \t\r\n]*:[ \t\r\n]*\"__repro_cmake_regenerate\"" "no-op regeneration report")
  assert_matches("${regen_noop_report}" "\"cacheDecision\"[ \t\r\n]*:[ \t\r\n]*\"cdHit\"" "no-op regeneration report")
  execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 1.1)
  write_regeneration_project("${regen_source_dir}" ReprobuildRegen 2)
  run_build("${regen_binary_dir}" "regenapp" "${runquota_socket}" regen_second)
  assert_regeneration_action_fresh_or_cached("${regen_second}" "dirty regeneration edge")
  assert_contains("${regen_second}" "cmakeRegeneration: complete providerChanged=true" "dirty regeneration helper")
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
elseif(TEST_MODE STREQUAL "regeneration_direct_mode")
  set(direct_source_dir "${TEST_BINARY_ROOT}/direct-regen-src")
  set(direct_binary_dir "${TEST_BINARY_ROOT}/direct-regen-build")
  file(REMOVE_RECURSE "${direct_source_dir}")
  write_regeneration_project("${direct_source_dir}" ReprobuildDirectRegen 3)
  run_configure("${direct_source_dir}" "${direct_binary_dir}" TRUE "")
  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_direct_repro_build("${direct_binary_dir}" "regenapp" "${runquota_socket}" direct_first)
  assert_regeneration_action_fresh_or_cached("${direct_first}" "direct initial regeneration edge")
  run_direct_repro_build("${direct_binary_dir}" "regenapp" "${runquota_socket}" direct_noop)
  assert_contains("${direct_noop}" "cmakeRegenerationAction: __repro_cmake_regenerate status=asCacheHit launched=false cache=cdHit" "direct no-op regeneration edge")
  execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 1.1)
  write_regeneration_project("${direct_source_dir}" ReprobuildDirectRegen 4)
  run_direct_repro_build("${direct_binary_dir}" "regenapp" "${runquota_socket}" direct_dirty)
  stop_runquota("${runquota_pid}")
  assert_regeneration_action_fresh_or_cached("${direct_dirty}" "direct dirty regeneration edge")
  execute_process(COMMAND "${direct_binary_dir}/regenapp" RESULT_VARIABLE direct_result)
  if(NOT direct_result EQUAL 4)
    message(FATAL_ERROR "Expected direct-regenerated regenapp exit 4, got ${direct_result}")
  endif()
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
  find_program(TEST_CXX_MODULES_COMPILER NAMES clang++)
  find_program(TEST_CXX_MODULES_SCAN_DEPS NAMES clang-scan-deps)
  if(NOT TEST_CXX_MODULES_COMPILER OR NOT TEST_CXX_MODULES_SCAN_DEPS)
    file(MAKE_DIRECTORY "${TEST_BINARY_ROOT}")
    file(WRITE "${TEST_BINARY_ROOT}/support-profile.txt"
      "e2e_cmake_reprobuild_cxx20_modules_dyndep=skipped\n"
      "reason=clang++ and clang-scan-deps are required for C++20 module scanning\n")
    return()
  endif()
  write_cxx_modules_project("${cxxmod_source_dir}" ReprobuildCxx20Modules)
  run_configure("${cxxmod_source_dir}" "${cxxmod_binary_dir}" TRUE ""
    "-DCMAKE_CXX_COMPILER=${TEST_CXX_MODULES_COMPILER}"
    "-DCMAKE_CXX_COMPILER_CLANG_SCAN_DEPS=${TEST_CXX_MODULES_SCAN_DEPS}")
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
  find_program(TEST_CXX_MODULES_COMPILER NAMES clang++)
  find_program(TEST_CXX_MODULES_SCAN_DEPS NAMES clang-scan-deps)
  if(NOT TEST_CXX_MODULES_COMPILER OR NOT TEST_CXX_MODULES_SCAN_DEPS)
    file(MAKE_DIRECTORY "${TEST_BINARY_ROOT}")
    file(WRITE "${TEST_BINARY_ROOT}/support-profile.txt"
      "e2e_cmake_reprobuild_dyndep_corruption_fails_closed=skipped\n"
      "reason=clang++ and clang-scan-deps are required for C++20 module scanning\n")
    return()
  endif()
  write_cxx_modules_project("${corrupt_source_dir}" ReprobuildDyndepCorrupt)
  run_configure("${corrupt_source_dir}" "${corrupt_binary_dir}" TRUE ""
    "-DCMAKE_CXX_COMPILER=${TEST_CXX_MODULES_COMPILER}"
    "-DCMAKE_CXX_COMPILER_CLANG_SCAN_DEPS=${TEST_CXX_MODULES_SCAN_DEPS}")
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
elseif(TEST_MODE STREQUAL "language_profile_matrix")
  resolve_swift_compiler(swift_compiler)
  if(NOT "${swift_compiler}" STREQUAL "")
    set(swift_source_dir "${TEST_BINARY_ROOT}/swift-src")
    set(swift_binary_dir "${TEST_BINARY_ROOT}/swift-build")
    write_swift_profile_project("${swift_source_dir}" ReprobuildSwiftProfile)
    swift_config_args(swift_args "${swift_compiler}")
    run_configure("${swift_source_dir}" "${swift_binary_dir}" TRUE ""
      ${swift_args})
    file(READ "${swift_binary_dir}/reprobuild.nim" swift_provider)
    foreach(expected IN ITEMS
        "compile-swiftapp-Swift"
        "output-file-map.json"
        "helper.custom.swiftdeps"
        "helper.custom.dia")
      assert_contains("${swift_provider}" "${expected}" "Swift profile provider")
    endforeach()
    start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
    run_build("${swift_binary_dir}" "swiftapp" "${runquota_socket}" swift_output)
    stop_runquota("${runquota_pid}")
    execute_process(COMMAND "${swift_binary_dir}/swiftapp" RESULT_VARIABLE swift_result)
    if(NOT swift_result EQUAL 0)
      message(FATAL_ERROR "Swift profile executable failed with ${swift_result}")
    endif()
    assert_file_exists("${swift_binary_dir}/CMakeFiles/swiftapp.dir/output-file-map.json" "Swift output map")
    assert_file_exists("${swift_binary_dir}/helper.custom.swiftdeps" "Swift custom swiftdeps")
    assert_file_exists("${swift_binary_dir}/helper.custom.dia" "Swift custom diagnostics")
  endif()

  if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    set(bundle_source_dir "${TEST_BINARY_ROOT}/bundle-src")
    set(bundle_binary_dir "${TEST_BINARY_ROOT}/bundle-build")
    write_apple_bundle_project("${bundle_source_dir}" ReprobuildAppleBundle)
    run_configure("${bundle_source_dir}" "${bundle_binary_dir}" TRUE "")
    file(READ "${bundle_binary_dir}/reprobuild.nim" bundle_provider)
    assert_contains("${bundle_provider}" "bundle-content-bundleapp" "Apple bundle provider")
    assert_contains("${bundle_provider}" "bundle-content-ReproKit" "Apple framework provider")
    assert_contains("${bundle_provider}" "bundle-content-reproplug" "Apple CFBundle provider")
    start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
    run_build("${bundle_binary_dir}" "" "${runquota_socket}" bundle_output)
    stop_runquota("${runquota_pid}")
    assert_file_exists("${bundle_binary_dir}/bundleapp.app/Contents/MacOS/bundleapp" "Apple bundle executable")
    assert_file_exists("${bundle_binary_dir}/bundleapp.app/Contents/Info.plist" "Apple bundle Info.plist")
    assert_file_exists("${bundle_binary_dir}/bundleapp.app/Contents/Resources/data.txt" "Apple bundle resource")
    assert_file_exists("${bundle_binary_dir}/ReproKit.framework/Versions/A/ReproKit" "Apple framework library")
    assert_file_exists("${bundle_binary_dir}/ReproKit.framework/Versions/A/Resources/Info.plist" "Apple framework Info.plist")
    assert_file_exists("${bundle_binary_dir}/ReproKit.framework/Versions/A/Resources/fwdata.txt" "Apple framework resource")
    assert_file_exists("${bundle_binary_dir}/reproplug.bundle/Contents/MacOS/reproplug" "Apple CFBundle library")
    assert_file_exists("${bundle_binary_dir}/reproplug.bundle/Contents/Info.plist" "Apple CFBundle Info.plist")
    assert_file_exists("${bundle_binary_dir}/reproplug.bundle/Contents/Resources/plugdata.txt" "Apple CFBundle resource")
  endif()

  resolve_cuda_compiler(cuda_compiler)
  if(NOT "${cuda_compiler}" STREQUAL "")
    run_cuda_available_fixture("cuda-available" "${cuda_compiler}" "")
  else()
    set(cuda_source_dir "${TEST_BINARY_ROOT}/cuda-unavailable-src")
    set(cuda_binary_dir "${TEST_BINARY_ROOT}/cuda-unavailable-build")
    write_cuda_unavailable_project("${cuda_source_dir}" ReprobuildCudaUnavailable)
    run_configure("${cuda_source_dir}" "${cuda_binary_dir}" FALSE
      "Reprobuild profile unavailable: CUDA compiler")
  endif()

  resolve_clang_cuda_compiler(clang_cuda_compiler)
  if(NOT "${clang_cuda_compiler}" STREQUAL "")
    run_clang_cuda_available_fixture("clang-cuda-available" "${clang_cuda_compiler}")
  else()
    set(clang_cuda_source_dir "${TEST_BINARY_ROOT}/clang-cuda-unavailable-src")
    set(clang_cuda_binary_dir "${TEST_BINARY_ROOT}/clang-cuda-unavailable-build")
    write_cuda_unavailable_project("${clang_cuda_source_dir}" ReprobuildClangCudaUnavailable)
    run_configure("${clang_cuda_source_dir}" "${clang_cuda_binary_dir}" FALSE
      "Reprobuild profile unavailable: Clang CUDA fatbinary"
      "-DCMAKE_REPROBUILD_CUDA_PROFILE=ClangFatbinary")
  endif()

  resolve_ispc_compiler(ispc_compiler)
  if(NOT "${ispc_compiler}" STREQUAL "")
    run_ispc_available_fixture("ispc-available" "${ispc_compiler}")
  else()
    set(ispc_source_dir "${TEST_BINARY_ROOT}/ispc-unavailable-src")
    set(ispc_binary_dir "${TEST_BINARY_ROOT}/ispc-unavailable-build")
    write_ispc_unavailable_project("${ispc_source_dir}" ReprobuildIspcUnavailable)
    run_configure("${ispc_source_dir}" "${ispc_binary_dir}" FALSE
      "Reprobuild profile unavailable: ISPC compiler"
      "-DCMAKE_CXX_COMPILER=${TEST_CXX_COMPILER}")
  endif()
elseif(TEST_MODE STREQUAL "profile_unavailable_diagnostics")
  resolve_cuda_compiler(cuda_compiler)
  if("${cuda_compiler}" STREQUAL "")
    set(cuda_source_dir "${TEST_BINARY_ROOT}/cuda-unavailable-src")
    set(cuda_binary_dir "${TEST_BINARY_ROOT}/cuda-unavailable-build")
    write_cuda_unavailable_project("${cuda_source_dir}" ReprobuildCudaUnavailable)
    run_configure("${cuda_source_dir}" "${cuda_binary_dir}" FALSE
      "Reprobuild profile unavailable: CUDA compiler")
  else()
    run_cuda_available_fixture("cuda-available" "${cuda_compiler}" "")
  endif()

  resolve_clang_cuda_compiler(clang_cuda_compiler)
  if("${clang_cuda_compiler}" STREQUAL "")
    set(clang_cuda_source_dir "${TEST_BINARY_ROOT}/clang-cuda-unavailable-src")
    set(clang_cuda_binary_dir "${TEST_BINARY_ROOT}/clang-cuda-unavailable-build")
    write_cuda_unavailable_project("${clang_cuda_source_dir}" ReprobuildClangCudaUnavailable)
    run_configure("${clang_cuda_source_dir}" "${clang_cuda_binary_dir}" FALSE
      "Reprobuild profile unavailable: Clang CUDA fatbinary"
      "-DCMAKE_REPROBUILD_CUDA_PROFILE=ClangFatbinary")
  else()
    run_clang_cuda_available_fixture("clang-cuda-available" "${clang_cuda_compiler}")
  endif()

  resolve_ispc_compiler(ispc_compiler)
  if("${ispc_compiler}" STREQUAL "")
    set(ispc_source_dir "${TEST_BINARY_ROOT}/ispc-unavailable-src")
    set(ispc_binary_dir "${TEST_BINARY_ROOT}/ispc-unavailable-build")
    write_ispc_unavailable_project("${ispc_source_dir}" ReprobuildIspcUnavailable)
    run_configure("${ispc_source_dir}" "${ispc_binary_dir}" FALSE
      "Reprobuild profile unavailable: ISPC compiler"
      "-DCMAKE_CXX_COMPILER=${TEST_CXX_COMPILER}")
  else()
    run_ispc_available_fixture("ispc-available" "${ispc_compiler}")
  endif()

  if(NOT CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    set(bundle_source_dir "${TEST_BINARY_ROOT}/apple-unavailable-src")
    set(bundle_binary_dir "${TEST_BINARY_ROOT}/apple-unavailable-build")
    write_apple_bundle_project("${bundle_source_dir}" ReprobuildAppleUnavailable)
    run_configure("${bundle_source_dir}" "${bundle_binary_dir}" FALSE
      "Reprobuild profile unavailable: Apple bundle")
  else()
    set(bundle_source_dir "${TEST_BINARY_ROOT}/apple-available-src")
    set(bundle_binary_dir "${TEST_BINARY_ROOT}/apple-available-build")
    write_apple_bundle_project("${bundle_source_dir}" ReprobuildAppleAvailable)
    run_configure("${bundle_source_dir}" "${bundle_binary_dir}" TRUE "")
    start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
    run_build("${bundle_binary_dir}" "" "${runquota_socket}" bundle_output)
    stop_runquota("${runquota_pid}")
    assert_file_exists("${bundle_binary_dir}/ReproKit.framework/Versions/A/Resources/Info.plist" "Apple framework Info.plist")
    assert_file_exists("${bundle_binary_dir}/reproplug.bundle/Contents/Info.plist" "Apple CFBundle Info.plist")
  endif()
elseif(TEST_MODE STREQUAL "language_byproduct_metadata")
  resolve_swift_compiler(swift_compiler)
  if(NOT "${swift_compiler}" STREQUAL "")
    set(split_source_dir "${TEST_BINARY_ROOT}/swift-split-src")
    set(split_binary_dir "${TEST_BINARY_ROOT}/swift-split-build")
    write_swift_split_project("${split_source_dir}" ReprobuildSwiftSplit)
    swift_config_args(swift_args "${swift_compiler}")
    run_configure("${split_source_dir}" "${split_binary_dir}" TRUE ""
      ${swift_args})
    file(READ "${split_binary_dir}/CMakeFiles/reprobuild/provider.meta" split_metadata)
    assert_contains("${split_metadata}" "m8_swift_output_maps=generated" "Swift split metadata")
    assert_contains("${split_metadata}" "m8_swift_split=generated" "Swift split metadata")
    file(READ "${split_binary_dir}/reprobuild.nim" split_provider)
    assert_contains("${split_provider}" "emit-module-splitapp" "Swift split provider")
    assert_contains("${split_provider}" ".swiftdeps" "Swift split provider")
    assert_contains("${split_provider}" ".dia" "Swift split provider")
    start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
    run_build("${split_binary_dir}" "splitapp" "${runquota_socket}" split_output)
    stop_runquota("${runquota_pid}")
    execute_process(COMMAND "${split_binary_dir}/splitapp" RESULT_VARIABLE split_result)
    if(NOT split_result EQUAL 0)
      message(FATAL_ERROR "Swift split executable failed with ${split_result}")
    endif()
    file(READ "${split_binary_dir}/CMakeFiles/reprobuild/clean.manifest" split_clean)
    assert_contains("${split_clean}" "output-file-map.json" "Swift clean manifest")
    assert_contains("${split_clean}" ".swiftdeps" "Swift clean manifest")
    report_path_from_output("${split_output}" split_report_path)
    file(READ "${split_report_path}" split_report)
    assert_contains("${split_report}" "emit-module-splitapp" "Swift split scheduler report")
  endif()

  if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    set(bundle_source_dir "${TEST_BINARY_ROOT}/bundle-meta-src")
    set(bundle_binary_dir "${TEST_BINARY_ROOT}/bundle-meta-build")
    write_apple_bundle_project("${bundle_source_dir}" ReprobuildAppleBundleMeta)
    run_configure("${bundle_source_dir}" "${bundle_binary_dir}" TRUE "")
    file(READ "${bundle_binary_dir}/CMakeFiles/reprobuild/provider.meta" bundle_metadata)
    assert_contains("${bundle_metadata}" "m8_apple_bundles=generated" "Apple bundle metadata")
    file(READ "${bundle_binary_dir}/CMakeFiles/reprobuild/clean.manifest" bundle_clean)
    assert_contains("${bundle_clean}" "Info.plist" "Apple bundle clean manifest")
    assert_contains("${bundle_clean}" "Resources/data.txt" "Apple bundle clean manifest")
    assert_contains("${bundle_clean}" "ReproKit.framework" "Apple framework clean manifest")
    assert_contains("${bundle_clean}" "reproplug.bundle" "Apple CFBundle clean manifest")
    start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
    run_build("${bundle_binary_dir}" "" "${runquota_socket}" bundle_output)
    stop_runquota("${runquota_pid}")
    report_path_from_output("${bundle_output}" bundle_report_path)
    file(READ "${bundle_report_path}" bundle_report)
    assert_contains("${bundle_report}" "bundle-content-bundleapp" "Apple bundle scheduler report")
    assert_contains("${bundle_report}" "bundle-content-ReproKit" "Apple framework scheduler report")
    assert_contains("${bundle_report}" "bundle-content-reproplug" "Apple CFBundle scheduler report")
    assert_file_exists("${bundle_binary_dir}/ReproKit.framework/Versions/A/Resources/Info.plist" "Apple framework Info.plist")
    assert_file_exists("${bundle_binary_dir}/reproplug.bundle/Contents/Info.plist" "Apple CFBundle Info.plist")
  endif()

  resolve_cuda_compiler(cuda_compiler)
  if(NOT "${cuda_compiler}" STREQUAL "")
    run_cuda_available_fixture("cuda-byproducts" "${cuda_compiler}" "")
  endif()

  resolve_clang_cuda_compiler(clang_cuda_compiler)
  if(NOT "${clang_cuda_compiler}" STREQUAL "")
    run_clang_cuda_available_fixture("clang-cuda-byproducts" "${clang_cuda_compiler}")
  endif()

  resolve_ispc_compiler(ispc_compiler)
  if(NOT "${ispc_compiler}" STREQUAL "")
    run_ispc_available_fixture("ispc-byproducts" "${ispc_compiler}")
  endif()
elseif(TEST_MODE STREQUAL "hcr_c_fixture")
  set(hcr_source_dir "${TEST_BINARY_ROOT}/hcr-src")
  set(hcr_binary_dir "${TEST_BINARY_ROOT}/hcr-build")
  write_hcr_project("${hcr_source_dir}" ReprobuildHcrFixture)
  run_configure("${hcr_source_dir}" "${hcr_binary_dir}" TRUE ""
    "-DCMAKE_REPROBUILD_HCR=OFF")

  file(READ "${hcr_binary_dir}/CMakeFiles/reprobuild/provider.meta" hcr_metadata)
  assert_contains("${hcr_metadata}" "m10_hcr_targets=generated" "HCR provider metadata")
  assert_contains("${hcr_metadata}" "hcr_targets=hcrapp" "HCR provider metadata")
  assert_not_contains("${hcr_metadata}" "hcr_targets=plain" "HCR provider metadata")
  assert_not_contains("${hcr_metadata}" "hcr_targets=globalhcr" "HCR provider metadata")
  file(READ "${hcr_binary_dir}/compile_commands.json" hcr_compile_commands)
  foreach(expected IN ITEMS
      "-g"
      "-fpatchable-function-entry=2,0"
      "-fno-inline"
      "-fno-optimize-sibling-calls"
      "${hcr_source_dir}/main.c"
      "${hcr_source_dir}/helper.c")
    assert_contains("${hcr_compile_commands}" "${expected}" "HCR compile commands")
  endforeach()
  file(READ "${hcr_binary_dir}/reprobuild.nim" hcr_provider)
  assert_contains("${hcr_provider}" "hcr-linkgraph-hcrapp" "HCR generated provider")
  assert_contains("${hcr_provider}" "CMakeFiles/reprobuild/hcr/" "HCR generated provider")

  run_hcr_metadata_reader("${hcr_binary_dir}" "validate" "" reader_output)
  assert_contains("${reader_output}" "target=hcrapp" "HCR metadata reader")
  assert_contains("${reader_output}" "profile=clang-gcc-debug-patchable-no-lto-v1" "HCR metadata reader")

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${hcr_binary_dir}" "hcrapp" "${runquota_socket}" hcr_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${hcr_output}" "hcr-linkgraph-hcrapp status=asSucceeded launched=true" "HCR build output")
  execute_process(COMMAND "${hcr_binary_dir}/hcrapp" RESULT_VARIABLE hcr_result)
  if(NOT hcr_result EQUAL 0)
    message(FATAL_ERROR "HCR executable failed with ${hcr_result}")
  endif()
  file(GLOB hcr_linkgraphs "${hcr_binary_dir}/CMakeFiles/reprobuild/hcr/*.linkgraph")
  list(LENGTH hcr_linkgraphs hcr_linkgraph_count)
  if(NOT hcr_linkgraph_count EQUAL 1)
    message(FATAL_ERROR "Expected one HCR linkgraph evidence file, found ${hcr_linkgraph_count}: ${hcr_linkgraphs}")
  endif()
  list(GET hcr_linkgraphs 0 hcr_linkgraph)
  file(READ "${hcr_linkgraph}" hcr_linkgraph_text)
  assert_contains("${hcr_linkgraph_text}" "schema_id=reprobuild.hcr.linkgraph-evidence.v1" "HCR linkgraph evidence")
  assert_contains("${hcr_linkgraph_text}" "symbols_begin" "HCR linkgraph evidence")

  set(global_hcr_binary_dir "${TEST_BINARY_ROOT}/hcr-global-build")
  run_configure("${hcr_source_dir}" "${global_hcr_binary_dir}" TRUE ""
    "-DCMAKE_REPROBUILD_HCR=ON")
  file(READ "${global_hcr_binary_dir}/CMakeFiles/reprobuild/provider.meta" global_hcr_metadata)
  assert_contains("${global_hcr_metadata}" "m10_hcr_targets=generated" "global HCR provider metadata")
  assert_contains("${global_hcr_metadata}" "hcrapp" "global HCR provider metadata")
  assert_contains("${global_hcr_metadata}" "globalhcr" "global HCR provider metadata")
  assert_not_contains("${global_hcr_metadata}" "hcr_targets=plain" "global HCR provider metadata")
elseif(TEST_MODE STREQUAL "hcr_affected_object_lookup")
  set(hcr_source_dir "${TEST_BINARY_ROOT}/hcr-affected-src")
  set(hcr_binary_dir "${TEST_BINARY_ROOT}/hcr-affected-build")
  write_hcr_project("${hcr_source_dir}" ReprobuildHcrAffected)
  run_configure("${hcr_source_dir}" "${hcr_binary_dir}" TRUE "")
  run_hcr_metadata_reader("${hcr_binary_dir}" "affected" "${hcr_source_dir}/helper.c" affected_before)
  assert_contains("${affected_before}" "affected=${hcr_source_dir}/helper.c" "HCR affected lookup")
  assert_contains("${affected_before}" "helper.c.o" "HCR affected lookup")
  assert_contains("${affected_before}" "link=link-hcrapp" "HCR affected lookup")
  assert_contains("${affected_before}" "linkgraph=CMakeFiles/reprobuild/hcr/" "HCR affected lookup")

  start_runquota("${TEST_BINARY_ROOT}" runquota_socket runquota_pid)
  run_build("${hcr_binary_dir}" "hcrapp" "${runquota_socket}" hcr_first_output)
  file(WRITE "${hcr_source_dir}/helper.c"
    "int hcr_helper(int value) { return value + 2; }\n"
    "int hcr_m10_changed_symbol(void) { return 10; }\n")
  run_build("${hcr_binary_dir}" "hcrapp" "${runquota_socket}" hcr_second_output)
  stop_runquota("${runquota_pid}")
  assert_contains("${hcr_second_output}" "helper.c.o status=asSucceeded launched=true" "HCR incremental output")
  assert_contains("${hcr_second_output}" "action: link-hcrapp status=asSucceeded launched=true" "HCR incremental output")
  assert_contains("${hcr_second_output}" "hcr-linkgraph-hcrapp status=asSucceeded launched=true" "HCR incremental output")
  assert_not_contains("${hcr_second_output}" "main.c.o status=asSucceeded launched=true" "HCR incremental output")
  run_hcr_metadata_reader("${hcr_binary_dir}" "affected" "${hcr_source_dir}/helper.c" affected_after)
  assert_contains("${affected_after}" "compile=compile-hcrapp" "HCR affected lookup after edit")
  file(GLOB hcr_linkgraphs "${hcr_binary_dir}/CMakeFiles/reprobuild/hcr/*.linkgraph")
  list(GET hcr_linkgraphs 0 hcr_linkgraph)
  file(READ "${hcr_linkgraph}" hcr_linkgraph_text)
  if(APPLE)
    set(hcr_changed_symbol "_hcr_m10_changed_symbol")
  else()
    set(hcr_changed_symbol "hcr_m10_changed_symbol")
  endif()
  assert_contains("${hcr_linkgraph_text}" "${hcr_changed_symbol}" "HCR linkgraph after edit")
elseif(TEST_MODE STREQUAL "hcr_rejects_incompatible_target")
  run_hcr_reject_case("compile-flto"
    "affected object lookup")
  run_hcr_reject_case("link-lto"
    "LTO/linker-plugin behavior")
  run_hcr_reject_case("no-debug"
    "disabled by compile flags")
  run_hcr_reject_case("ipo"
    "object-to-link metadata")
  run_hcr_reject_case("static-library"
    "STATIC_LIBRARY")
  run_hcr_reject_case("object-library"
    "OBJECT_LIBRARY")
  run_hcr_reject_case("asm-source"
    "uses language 'ASM'")
else()
  message(FATAL_ERROR "Unknown TEST_MODE: ${TEST_MODE}")
endif()
