# Protects: a compiler driver with the MSVC frontend (clang-cl) gets compile
# and link lines spelled in its own frontend's syntax. Its dependency flags
# are the ones CMake's platform module defines for it
# (CMAKE_DEPFILE_FLAGS_<LANG>, `-clang:-MD ...`), never the GNU `-MD -MT
# <obj> -MF <dep>`, which clang-cl reads as the /MD and /MT runtime switches
# plus stray input files. Linker options, which Windows-MSVC.cmake spells for
# the linker itself (CMAKE_<LANG>_LINK_MODE LINKER: `/machine:x64`, `/debug`,
# `/subsystem:console`, `-LIBPATH:`), the libraries and the import library's
# `/IMPLIB:` reach the linker after a single `/link` instead of being read by
# the driver as file names; a SHARED or MODULE library is linked with `/dll`,
# which CMake's own rule passes to the linker. Covers an executable, an
# ENABLE_EXPORTS executable, a SHARED and a MODULE library.
#
# Defect record: reprobuild-pm
# issues/2026-10-27-reprobuild-cmake-passes-msvc-linker-flags-to-clang-cl-as-file-names.md
# Spec: reprobuild-pm spec/CMake-Reprobuild-Generator.md, "Compiler drivers
# with the MSVC frontend".
#
# Runs the generator's real compile and link actions with a real clang-cl,
# lld-link and llvm-dlltool, cross-linking Windows images without an SDK or C
# runtime (/nodefaultlib, explicit entry points), so it needs no Windows host.
# No compiler, linker or librarian is mocked. The one stand-in: the compiler's
# identity is forced (CMAKE_C_COMPILER_FORCED) with the values CMake
# identifies clang-cl by (Clang, simulating MSVC, MSVC frontend), because
# CMake's compiler checks run try_compile through the Reprobuild generator,
# which needs a repro engine this argv test does not run (as
# compiler-target.cmake does). Identification is upstream CMake, not under
# test. clang-cl runs its default linker by name: `link`, or the
# distribution's CLANG_DEFAULT_LINKER (`ld` on Ubuntu). Both names on PATH
# run the real lld-link (a symbolic link for `link`, which lld recognises;
# a one-line exec script for `ld`, which lld would take for GNU ld).
cmake_minimum_required(VERSION 3.29)
foreach(required IN ITEMS TEST_CMAKE TEST_CLANG_CL TEST_BINARY_ROOT)
  if(NOT DEFINED ${required})
    message(FATAL_ERROR "${required} is required")
  endif()
endforeach()
file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
set(tool_path "${TEST_BINARY_ROOT}/tools")
file(MAKE_DIRECTORY "${tool_path}")
foreach(tool IN ITEMS lld-link llvm-dlltool llvm-lib llvm-rc make)
  find_program(tool_${tool} NAMES ${tool} REQUIRED)
  file(CREATE_LINK "${tool_${tool}}" "${tool_path}/${tool}" SYMBOLIC)
endforeach()
file(CREATE_LINK "${tool_lld-link}" "${tool_path}/link" SYMBOLIC)
file(WRITE "${tool_path}/ld" "#!/bin/sh\nexec '${tool_lld-link}' \"$@\"\n")
file(CHMOD "${tool_path}/ld" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE)
# clang selects its cl mode from the name it is run as.
set(clang_cl "${tool_path}/clang-cl")
file(CREATE_LINK "${TEST_CLANG_CL}" "${clang_cl}" SYMBOLIC)
set(tool_env "${CMAKE_COMMAND}" -E env --unset=REPROBUILD_REPRO "PATH=${tool_path}")

set(source "${TEST_BINARY_ROOT}/src")
file(MAKE_DIRECTORY "${source}")
file(WRITE "${source}/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 3.29)
project(MsvcFrontendDriver C)
add_library(lib SHARED lib.c)
add_library(plugin MODULE lib.c)
add_executable(app main.c)
target_link_libraries(app PRIVATE lib)
target_link_directories(app PRIVATE "${CMAKE_BINARY_DIR}")
add_executable(host host.c)
set_target_properties(host PROPERTIES ENABLE_EXPORTS ON)
]=])
file(WRITE "${source}/host.c" "int main(void) { return 0; }\n")
file(WRITE "${source}/lib.c" "__declspec(dllexport) int lib_value(void) { return 42; }\n")
file(WRITE "${source}/main.c" [=[
__declspec(dllimport) int lib_value(void);
int main(void) { return lib_value() == 42 ? 0 : 1; }
]=])

set(binary "${TEST_BINARY_ROOT}/build")
execute_process(COMMAND ${tool_env} "${TEST_CMAKE}" -S "${source}" -B "${binary}" -G Reprobuild
  "-DCMAKE_MAKE_PROGRAM=${tool_path}/make"
  "-DCMAKE_C_COMPILER=${clang_cl}"
  -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=AMD64
  -DCMAKE_C_COMPILER_FORCED=TRUE
  -DCMAKE_C_COMPILER_ID=Clang
  -DCMAKE_C_COMPILER_VERSION=18.1
  -DCMAKE_C_SIMULATE_ID=MSVC
  -DCMAKE_C_SIMULATE_VERSION=19.40
  -DCMAKE_C_COMPILER_FRONTEND_VARIANT=MSVC
  -DCMAKE_C_COMPILER_ARCHITECTURE_ID=x64
  "-DCMAKE_AR=${tool_path}/llvm-lib"
  "-DCMAKE_DLLTOOL=${tool_path}/llvm-dlltool"
  "-DCMAKE_RC_COMPILER=${tool_path}/llvm-rc"
  -DCMAKE_BUILD_TYPE=Debug
  -DCMAKE_C_STANDARD_LIBRARIES=
  # Spelled for the linker, as Windows-MSVC.cmake spells its own defaults.
  "-DCMAKE_EXE_LINKER_FLAGS=/machine:x64 /nodefaultlib /entry:main"
  "-DCMAKE_SHARED_LINKER_FLAGS=/machine:x64 /nodefaultlib /noentry"
  "-DCMAKE_MODULE_LINKER_FLAGS=/machine:x64 /nodefaultlib /noentry"
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "configure failed: ${out}\n${err}")
endif()

file(READ "${binary}/reprobuild.nim" provider)
string(REGEX MATCHALL "inlineExecCall\\(@\\[[^\n]*\\], cwd =" calls "${provider}")
set(compiles)
set(links)
set(index 0)
foreach(call IN LISTS calls)
  string(REGEX REPLACE "^inlineExecCall\\(@(\\[.*\\]), cwd =$" "\\1" argv_json "${call}")
  string(JSON length LENGTH "${argv_json}")
  math(EXPR last "${length} - 1")
  set(argv)
  foreach(i RANGE 0 ${last})
    string(JSON arg GET "${argv_json}" ${i})
    list(APPEND argv "${arg}")
  endforeach()
  set(args "${argv}")
  set(driver_args "${args}")
  list(FIND args "--" separator)
  if(separator GREATER -1)
    math(EXPR first "${separator} + 1")
    list(SUBLIST args ${first} -1 driver_args)
  endif()
  list(GET driver_args 0 exe)
  if(NOT exe STREQUAL clang_cl)
    continue()
  endif()
  math(EXPR index "${index} + 1")
  set_property(GLOBAL PROPERTY action_${index} "${argv}")
  if("-c" IN_LIST driver_args)
    foreach(gnu IN ITEMS -MD -MT -MF)
      if(gnu IN_LIST driver_args)
        message(FATAL_ERROR "A clang-cl compile carries the GNU dependency flag ${gnu}, which clang-cl does not read as one: ${args}")
      endif()
    endforeach()
    list(APPEND compiles ${index})
  else()
    list(FIND driver_args "/link" link_at)
    if(link_at EQUAL -1)
      message(FATAL_ERROR "A clang-cl link passes no linker options through /link: ${args}")
    endif()
    list(SUBLIST driver_args 0 ${link_at} before_link)
    list(SUBLIST driver_args ${link_at} -1 after_link)
    list(REMOVE_AT after_link 0)
    if("/link" IN_LIST after_link)
      message(FATAL_ERROR "A clang-cl link names /link twice; the linker would read the second as an option: ${args}")
    endif()
    foreach(option IN ITEMS /machine:x64 /nodefaultlib /debug)
      if(option IN_LIST before_link)
        message(FATAL_ERROR "The linker option ${option} reaches clang-cl, not the linker: ${args}")
      endif()
      if(NOT option IN_LIST after_link)
        message(FATAL_ERROR "The linker option ${option} is missing after /link: ${args}")
      endif()
    endforeach()
    foreach(arg IN LISTS before_link)
      if(arg MATCHES "^(/IMPLIB:|-LIBPATH:)")
        message(FATAL_ERROR "The linker option ${arg} reaches clang-cl, not the linker: ${args}")
      endif()
    endforeach()
    # The edges that create an import library run through the wrapper.
    if(separator GREATER -1 AND NOT after_link MATCHES "(^|;)/IMPLIB:")
      message(FATAL_ERROR "The import library's /IMPLIB: is missing after /link: ${args}")
    endif()
    if(args MATCHES "-o;app\\.exe" AND NOT after_link MATCHES "(^|;)-LIBPATH:")
      message(FATAL_ERROR "app's link directory is missing after /link: ${args}")
    endif()
    list(APPEND links ${index})
  endif()
endforeach()
list(LENGTH compiles compile_count)
list(LENGTH links link_count)
if(NOT compile_count EQUAL 4 OR NOT link_count EQUAL 4)
  message(FATAL_ERROR "Expected 4 clang-cl compiles and 4 links, saw ${compile_count} and ${link_count}: ${provider}")
endif()

function(run_action index)
  get_property(argv GLOBAL PROPERTY action_${index})
  execute_process(COMMAND ${tool_env} ${argv} WORKING_DIRECTORY "${binary}"
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  set(action_result "${result}" PARENT_SCOPE)
  set(action_output "${out}\n${err}" PARENT_SCOPE)
endfunction()

foreach(index IN LISTS compiles)
  run_action(${index})
  if(NOT action_result EQUAL 0)
    message(FATAL_ERROR "clang-cl compile failed:\n${action_output}")
  endif()
  # clang-cl ignores an option it does not know with only a warning, so a
  # misspelled flag shows here and nowhere else.
  if(action_output MATCHES "unknown argument|input unused")
    message(FATAL_ERROR "clang-cl did not understand its compile line:\n${action_output}")
  endif()
endforeach()
# Each compile wrote the depfile the edge declares, naming its own object as
# the target: both placeholders were substituted.
foreach(object IN ITEMS lib.dir/lib.c plugin.dir/lib.c app.dir/main.c host.dir/host.c)
  set(depfile "${binary}/CMakeFiles/${object}.obj.d")
  if(NOT EXISTS "${depfile}")
    message(FATAL_ERROR "No compiler depfile ${depfile}: the dependency report is missing.")
  endif()
  file(STRINGS "${depfile}" first_line LIMIT_COUNT 1)
  if(NOT first_line MATCHES "^CMakeFiles/${object}\\.obj:")
    message(FATAL_ERROR "${depfile} does not name its object as the target: ${first_line}")
  endif()
endforeach()

# Links in dependency order: a link fails until the import library it needs
# exists, so retry the failures once each other link has run.
set(pending ${links})
set(last_output)
while(pending)
  set(progress FALSE)
  set(next)
  foreach(index IN LISTS pending)
    run_action(${index})
    if(action_result EQUAL 0)
      set(progress TRUE)
    else()
      list(APPEND next ${index})
      set(last_output "${action_output}")
    endif()
  endforeach()
  if(NOT progress)
    message(FATAL_ERROR "clang-cl link failed:\n${last_output}")
  endif()
  set(pending ${next})
endwhile()

# IMAGE_FILE_DLL (0x2000) in the COFF header's Characteristics: the image is
# a DLL only if the linker was told /dll.
function(pe_is_dll path out_var)
  file(READ "${path}" lfanew_hex OFFSET 60 LIMIT 4 HEX)
  string(SUBSTRING "${lfanew_hex}" 0 2 b0)
  string(SUBSTRING "${lfanew_hex}" 2 2 b1)
  math(EXPR characteristics_at "0x${b1}${b0} + 22")
  file(READ "${path}" characteristics_hex OFFSET ${characteristics_at} LIMIT 2 HEX)
  string(SUBSTRING "${characteristics_hex}" 2 2 high)
  math(EXPR is_dll "(0x${high} >> 5) & 1")
  set(${out_var} ${is_dll} PARENT_SCOPE)
endfunction()
foreach(image IN ITEMS lib.dll plugin.dll)
  if(NOT EXISTS "${binary}/${image}")
    message(FATAL_ERROR "${image} was not linked.")
  endif()
  pe_is_dll("${binary}/${image}" is_dll)
  if(NOT is_dll)
    message(FATAL_ERROR "${image} is not a DLL: the linker was not told /dll.")
  endif()
endforeach()
foreach(image IN ITEMS app.exe host.exe)
  pe_is_dll("${binary}/${image}" is_dll)
  if(is_dll)
    message(FATAL_ERROR "${image} is marked as a DLL.")
  endif()
endforeach()
foreach(import IN ITEMS lib.lib host.lib)
  if(NOT EXISTS "${binary}/${import}")
    message(FATAL_ERROR "The import library ${import} is missing.")
  endif()
endforeach()
