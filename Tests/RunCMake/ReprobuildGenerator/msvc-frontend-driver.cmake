# Protects: an MSVC-frontend toolchain (clang-cl) gets compile, link, archive
# and module-scan lines that carry what CMake's own rules for it carry
# (Modules/Platform/Windows-MSVC.cmake, Windows-Clang.cmake,
# Compiler/Clang-CXX.cmake), and every file a link writes is a declared
# output of its edge.
#
# - Compile: the dependency flags are CMAKE_DEPFILE_FLAGS_<LANG>
#   (`-clang:-MD ...`), never the GNU `-MD -MT <obj> -MF <dep>`, which
#   clang-cl reads as the /MD and /MT runtime switches plus stray inputs.
# - Link (CMAKE_<LANG>_LINK_MODE LINKER): the edge runs the linker CMake
#   resolved (CMAKE_LINKER), not the compiler driver, whose default linker is
#   a different program. The line has the rule's `/out:`, `/pdb:`, `/dll` for
#   a SHARED or MODULE library, `/version:`, the rule-only platform flags
#   (the machine flag under policy CMP0197 NEW), and `/IMPLIB:` where the
#   target has an import library. Under policy CMP0197 OLD the machine flag
#   comes from the flag variables instead, once. A link that writes a
#   program database declares it, at CMake's configured path or at the path
#   the project's own `/PDB:` names; a link that writes none (`/debug:none`)
#   declares none.
# - Archive: `<CMAKE_AR> /nologo ... /out:<lib> <objects>`, not `ar rcs`,
#   which llvm-lib and lib.exe read as an input file named `rcs`.
# - A link or archive line too long for the command line is passed in its
#   response file: the process gets `@<rsp>`, and the response file quotes
#   an argument the way its reader does (the Windows command-line rules for
#   the MSVC tools; GCC's, where `'` is a quote, for a GNU driver).
# - C++ module scan: the output and dependency options are behind `-clang:`.
#
# Covers an executable, an ENABLE_EXPORTS executable, a SHARED, a MODULE and
# a STATIC library, and one long link through a GNU-frontend clang.
#
# Defect records: reprobuild-pm
# issues/2026-10-27-reprobuild-cmake-passes-msvc-linker-flags-to-clang-cl-as-file-names.md
# issues/2026-11-18-reprobuild-cmake-msvc-frontend-lines-omit-parts-of-cmakes-rules.md
# Spec: reprobuild-pm spec/CMake-Reprobuild-Generator.md, "Compiler drivers
# with the MSVC frontend".
#
# Runs the generator's real compile, archive and link actions with a real
# clang-cl, lld-link, llvm-lib and llvm-dlltool, cross-linking Windows images
# without an SDK or C runtime (/nodefaultlib, explicit entry points), so it
# needs no Windows host. No compiler, linker or librarian is mocked. Two
# stand-ins:
# - The compiler's identity is forced (CMAKE_<LANG>_COMPILER_FORCED) with the
#   values CMake identifies clang-cl by (Clang, simulating MSVC, MSVC
#   frontend), because CMake's compiler checks run try_compile through the
#   Reprobuild generator, which needs a repro engine this argv test does not
#   run (as compiler-target.cmake does). Identification is upstream CMake,
#   not under test.
# - The module scan line is compared with CMake's rule and not run. CMake
#   scans with clang-cl only from version 19.1, which the forced identity
#   claims; an older clang-cl rejects the rule's `-x c++`, so running it
#   needs clang-cl 19.1 or newer.
# The MSVC-style linker is on no PATH directory and is named only by
# CMAKE_LINKER, and PATH holds no `link`: a clang-cl link that ran the
# compiler driver would not reach it. (`ld` on PATH is GNU ld, for the
# GNU-frontend link.)
cmake_minimum_required(VERSION 3.29)
foreach(required IN ITEMS TEST_CMAKE TEST_CLANG_CL TEST_BINARY_ROOT)
  if(NOT DEFINED ${required})
    message(FATAL_ERROR "${required} is required")
  endif()
endforeach()
file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
set(tool_path "${TEST_BINARY_ROOT}/tools")
file(MAKE_DIRECTORY "${tool_path}")
foreach(tool IN ITEMS lld-link llvm-dlltool llvm-lib llvm-rc make ld)
  find_program(tool_${tool} NAMES ${tool} REQUIRED)
endforeach()
foreach(tool IN ITEMS llvm-dlltool llvm-lib llvm-rc make ld)
  file(CREATE_LINK "${tool_${tool}}" "${tool_path}/${tool}" SYMBOLIC)
endforeach()
# lld selects its COFF driver from the name it is run as.
set(linker "${TEST_BINARY_ROOT}/resolved-linker/lld-link")
file(MAKE_DIRECTORY "${TEST_BINARY_ROOT}/resolved-linker")
file(CREATE_LINK "${tool_lld-link}" "${linker}" SYMBOLIC)
# clang selects its cl mode from the name it is run as.
set(clang_cl "${tool_path}/clang-cl")
file(CREATE_LINK "${TEST_CLANG_CL}" "${clang_cl}" SYMBOLIC)
set(tool_env "${CMAKE_COMMAND}" -E env --unset=REPROBUILD_REPRO "PATH=${tool_path}")

set(source "${TEST_BINARY_ROOT}/src")
set(long_dir "a_directory_with_a_deliberately_long_name_for_the_response_file")
file(MAKE_DIRECTORY "${source}/${long_dir}")
set(big_sources)
foreach(n RANGE 1 30)
  file(WRITE "${source}/${long_dir}/unit_${n}.c" "int unit_${n}(void) { return ${n}; }\n")
  list(APPEND big_sources "${long_dir}/unit_${n}.c")
endforeach()
# 4.1 sets policy CMP0197 to NEW: the machine flag is then in no flag
# variable, only in the text of CMake's link and archive rules.
file(WRITE "${source}/CMakeLists.txt" "
cmake_minimum_required(VERSION 4.1)
project(MsvcFrontendDriver C)
add_library(lib SHARED lib.c)
set_target_properties(lib PROPERTIES VERSION 3.4)
add_library(plugin MODULE lib.c)
set_target_properties(plugin PROPERTIES
  PDB_OUTPUT_DIRECTORY \"\${CMAKE_BINARY_DIR}/symbols\" PDB_NAME plugin-symbols)
add_library(st STATIC st.c)
add_executable(app main.c)
target_link_libraries(app PRIVATE lib st)
target_link_directories(app PRIVATE \"\${CMAKE_BINARY_DIR}\")
add_executable(host host.c)
set_target_properties(host PROPERTIES ENABLE_EXPORTS ON)
add_executable(quiet host.c)
target_link_options(quiet PRIVATE /debug:none)
add_executable(named host.c)
target_link_options(named PRIVATE /PDB:custom/named-by-the-project.pdb)
add_executable(dwarf host.c)
target_link_options(dwarf PRIVATE /debug:dwarf)
add_executable(big host.c \"${big_sources}\")
target_link_options(big PRIVATE [[/pdbaltpath:C:\\sym \"q\" dir\\]])
add_library(bigst STATIC \"${big_sources}\")
")
string(REPLACE ";" "\" \"" cmakelists_fixed "${big_sources}")
file(READ "${source}/CMakeLists.txt" cmakelists)
string(REPLACE "\"${big_sources}\"" "\"${cmakelists_fixed}\"" cmakelists "${cmakelists}")
string(REPLACE "\\\\" "\\" cmakelists "${cmakelists}")
file(WRITE "${source}/CMakeLists.txt" "${cmakelists}")
file(WRITE "${source}/host.c" "int main(void) { return 0; }\n")
file(WRITE "${source}/lib.c" "__declspec(dllexport) int lib_value(void) { return 42; }\n")
file(WRITE "${source}/st.c" "int st_value(void) { return 7; }\n")
file(WRITE "${source}/main.c" [=[
__declspec(dllimport) int lib_value(void);
int st_value(void);
int main(void) { return lib_value() + st_value() == 49 ? 0 : 1; }
]=])

set(forced_identity
  -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=AMD64
  "-DCMAKE_MAKE_PROGRAM=${tool_path}/make"
  "-DCMAKE_AR=${tool_path}/llvm-lib"
  "-DCMAKE_LINKER=${linker}"
  "-DCMAKE_DLLTOOL=${tool_path}/llvm-dlltool"
  "-DCMAKE_RC_COMPILER=${tool_path}/llvm-rc"
  -DCMAKE_BUILD_TYPE=Debug)
foreach(lang IN ITEMS C CXX)
  list(APPEND forced_identity
    "-DCMAKE_${lang}_COMPILER=${clang_cl}"
    -DCMAKE_${lang}_COMPILER_FORCED=TRUE
    -DCMAKE_${lang}_COMPILER_ID=Clang
    -DCMAKE_${lang}_SIMULATE_ID=MSVC
    -DCMAKE_${lang}_SIMULATE_VERSION=19.40
    -DCMAKE_${lang}_COMPILER_FRONTEND_VARIANT=MSVC
    -DCMAKE_${lang}_COMPILER_ARCHITECTURE_ID=x64
    -DMSVC_${lang}_ARCHITECTURE_ID=x64
    -DCMAKE_${lang}_STANDARD_LIBRARIES=)
endforeach()

set(binary "${TEST_BINARY_ROOT}/build")
execute_process(COMMAND ${tool_env} "${TEST_CMAKE}" -S "${source}" -B "${binary}" -G Reprobuild
  ${forced_identity}
  -DCMAKE_C_COMPILER_VERSION=18.1
  # Spelled for the linker, as Windows-MSVC.cmake spells its own defaults.
  "-DCMAKE_EXE_LINKER_FLAGS=/nodefaultlib /entry:main"
  "-DCMAKE_SHARED_LINKER_FLAGS=/nodefaultlib /noentry"
  "-DCMAKE_MODULE_LINKER_FLAGS=/nodefaultlib /noentry"
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "configure failed: ${out}\n${err}")
endif()

# Reads every inline action of the provider: its id, argv and declared
# outputs.
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
file(STRINGS "${binary}/reprobuild.nim" provider_lines REGEX "buildAction\\(\"[^\"]+\", inlineExecCall\\(")
set(compiles)
set(links)
set(archives)
set(declared_outputs)
foreach(line IN LISTS provider_lines)
  if(NOT line MATCHES "buildAction\\(\"([^\"]+)\", inlineExecCall\\(@(\\[.*\\])(, cwd = \"[^\"]*\")?\\), deps = .* outputs = @(\\[[^]]*\\]), pool = ")
    message(FATAL_ERROR "Unreadable action: ${line}")
  endif()
  set(id "${CMAKE_MATCH_1}")
  set(outputs_json "${CMAKE_MATCH_4}")
  json_array_to_list("${CMAKE_MATCH_2}" argv)
  json_array_to_list("${outputs_json}" outputs)
  set_property(GLOBAL PROPERTY argv_${id} "${argv}")
  set_property(GLOBAL PROPERTY outputs_${id} "${outputs}")
  list(APPEND declared_outputs ${outputs})
  if(id MATCHES "^compile-")
    list(APPEND compiles "${id}")
  elseif(id MATCHES "^link-(st|bigst)$")
    list(APPEND archives "${id}")
  elseif(id MATCHES "^link-")
    list(APPEND links "${id}")
  endif()
endforeach()
list(LENGTH compiles compile_count)
list(SORT links)
list(SORT archives)
if(NOT compile_count EQUAL 69 OR NOT archives STREQUAL "link-bigst;link-st" OR
   NOT links STREQUAL "link-app;link-big;link-dwarf;link-host;link-lib;link-named;link-plugin;link-quiet")
  message(FATAL_ERROR "Expected 69 compiles, 2 archives and 8 links; saw ${compile_count} compiles, '${archives}' and '${links}'")
endif()

foreach(id IN LISTS compiles)
  get_property(argv GLOBAL PROPERTY argv_${id})
  list(GET argv 0 exe)
  if(NOT exe STREQUAL clang_cl)
    message(FATAL_ERROR "${id} does not run clang-cl: ${argv}")
  endif()
  foreach(gnu IN ITEMS -MD -MT -MF)
    if(gnu IN_LIST argv)
      message(FATAL_ERROR "A clang-cl compile carries the GNU dependency flag ${gnu}, which clang-cl does not read as one: ${argv}")
    endif()
  endforeach()
endforeach()

# The archive: CMake's CMAKE_<LANG>_CREATE_STATIC_LIBRARY, not `ar rcs`.
get_property(argv GLOBAL PROPERTY argv_link-st)
list(GET argv 0 exe)
if(NOT exe STREQUAL "${tool_path}/llvm-lib")
  message(FATAL_ERROR "The archive does not run CMAKE_AR: ${argv}")
endif()
if("rcs" IN_LIST argv)
  message(FATAL_ERROR "The archive passes `rcs`, which llvm-lib and lib.exe read as an input file: ${argv}")
endif()
foreach(expected IN ITEMS /nologo -machine:x64 /out:st.lib CMakeFiles/st.dir/st.c.obj)
  if(NOT expected IN_LIST argv)
    message(FATAL_ERROR "The archive line lacks ${expected}, which CMake's rule passes: ${argv}")
  endif()
endforeach()

# A long archive line is passed in its response file too.
get_property(argv GLOBAL PROPERTY argv_link-bigst)
if(NOT argv STREQUAL "${tool_path}/llvm-lib;@CMakeFiles/reprobuild/rsp/link-bigst.rsp")
  message(FATAL_ERROR "bigst's archive line is not passed in its response file: ${argv}")
endif()

set(pdb_of_link-named custom/named-by-the-project.pdb)
set(pdb_of_link-dwarf dwarf.pdb)
set(pdb_of_link-app app.pdb)
set(pdb_of_link-big big.pdb)
set(pdb_of_link-host host.pdb)
set(pdb_of_link-lib lib.pdb)
set(pdb_of_link-plugin symbols/plugin-symbols.pdb)
set(pdb_of_link-quiet quiet.pdb)
set(version_of_link-lib 3.4)
foreach(id IN LISTS links)
  get_property(argv GLOBAL PROPERTY argv_${id})
  get_property(outputs GLOBAL PROPERTY outputs_${id})
  # The edges that create an import library run through a wrapper; the link
  # itself follows its `--`.
  set(line "${argv}")
  list(FIND argv "--" separator)
  if(separator GREATER -1)
    math(EXPR first "${separator} + 1")
    list(SUBLIST argv ${first} -1 line)
  endif()
  list(GET line 0 exe)
  if(NOT exe STREQUAL linker)
    message(FATAL_ERROR "${id} does not run the linker CMake resolved (${linker}): ${argv}")
  endif()
  if("/link" IN_LIST line OR "-o" IN_LIST line)
    message(FATAL_ERROR "${id} passes the linker a compiler driver's option: ${argv}")
  endif()
  if(id STREQUAL "link-big")
    # Too long for the command line: the process gets the response file.
    # The file is named after the action, not after an ordinal that moves
    # when a target is added.
    set(rsp "CMakeFiles/reprobuild/rsp/link-big.rsp")
    if(NOT line STREQUAL "${linker};@${rsp}")
      message(FATAL_ERROR "big's link line is not passed in its response file: ${argv}")
    endif()
    if(NOT EXISTS "${binary}/${rsp}")
      message(FATAL_ERROR "big's response file ${rsp} is missing.")
    endif()
    # Quoted by the Windows command-line rules: a backslash is literal
    # unless it precedes a double quote. GCC's rules would double each one.
    file(READ "${binary}/${rsp}" rsp_text)
    string(FIND "${rsp_text}" [[
"/pdbaltpath:C:\sym \"q\" dir\\"
]] quoted_at)
    if(quoted_at EQUAL -1)
      message(FATAL_ERROR "big's response file does not quote its option by the Windows rules:\n${rsp_text}")
    endif()
    string(REPLACE [[
"/pdbaltpath:C:\sym \"q\" dir\\"
]] "\n" rsp_text "${rsp_text}")
    string(REPLACE "\n" ";" line "${rsp_text}")
  endif()
  set(version 0.0)
  if(DEFINED version_of_${id})
    set(version "${version_of_${id}}")
  endif()
  string(REGEX REPLACE "^.*/" "" rule_pdb "${id}")
  string(REGEX REPLACE "^link-" "" rule_pdb "${rule_pdb}.pdb")
  if(id STREQUAL "link-plugin")
    set(rule_pdb "${pdb_of_${id}}")
  endif()
  foreach(expected IN ITEMS /nologo -machine:x64 /pdb:${rule_pdb} /version:${version} /nodefaultlib)
    if(NOT expected IN_LIST line)
      message(FATAL_ERROR "${id} lacks ${expected}, which CMake's link rule for this frontend passes: ${line}")
    endif()
  endforeach()
  if(id MATCHES "^link-(lib|plugin)$")
    if(NOT "/dll" IN_LIST line)
      message(FATAL_ERROR "${id} does not tell the linker /dll: ${line}")
    endif()
  elseif("/dll" IN_LIST line)
    message(FATAL_ERROR "${id} links an executable with /dll: ${line}")
  endif()
  if(separator GREATER -1 AND NOT line MATCHES "(^|;)/IMPLIB:")
    message(FATAL_ERROR "${id} names no import library with /IMPLIB:: ${line}")
  endif()
  if(id STREQUAL "link-app" AND NOT line MATCHES "(^|;)-LIBPATH:")
    message(FATAL_ERROR "app's link directory is missing: ${line}")
  endif()
  # The program database is declared exactly when the link writes one.
  if(id STREQUAL "link-quiet")
    if(outputs MATCHES "\\.pdb")
      message(FATAL_ERROR "quiet links with /debug:none and writes no program database, but declares one: ${outputs}")
    endif()
  elseif(NOT "${pdb_of_${id}}" IN_LIST outputs)
    message(FATAL_ERROR "${id} writes ${pdb_of_${id}} and does not declare it: ${outputs}")
  endif()
endforeach()

function(run_action id)
  get_property(argv GLOBAL PROPERTY argv_${id})
  execute_process(COMMAND ${tool_env} ${argv} WORKING_DIRECTORY "${binary}"
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  set(action_result "${result}" PARENT_SCOPE)
  set(action_output "${out}\n${err}" PARENT_SCOPE)
endfunction()

foreach(id IN LISTS compiles)
  run_action(${id})
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

# Runs an archive or link action. On success, every file it wrote must be
# one of its own declared outputs, and every declared output must exist.
function(run_and_check_outputs id)
  file(GLOB_RECURSE before RELATIVE "${binary}" "${binary}/*")
  run_action(${id})
  set(action_result "${action_result}" PARENT_SCOPE)
  set(action_output "${action_output}" PARENT_SCOPE)
  if(NOT action_result EQUAL 0)
    return()
  endif()
  file(GLOB_RECURSE after RELATIVE "${binary}" "${binary}/*")
  list(REMOVE_ITEM after ${before})
  # Known gap, recorded as reprobuild-pm
  # issues/2026-11-20-reprobuild-cmake-msvc-linker-writes-an-import-library-no-edge-declares.md:
  # a MODULE library has no import library in CMake's model, and lld-link
  # writes one for every DLL. Remove this line with that issue's fix.
  list(REMOVE_ITEM after plugin.lib)
  get_property(outputs GLOBAL PROPERTY outputs_${id})
  foreach(written IN LISTS after)
    if(NOT written IN_LIST outputs)
      message(FATAL_ERROR "${id} wrote ${written}, which it does not declare as an output (${outputs}).")
    endif()
  endforeach()
  foreach(output IN LISTS outputs)
    if(NOT EXISTS "${binary}/${output}")
      message(FATAL_ERROR "${id} declares ${output} and did not write it.")
    endif()
  endforeach()
endfunction()
foreach(id IN LISTS archives)
  run_and_check_outputs(${id})
  if(NOT action_result EQUAL 0)
    message(FATAL_ERROR "The archive action ${id} failed:\n${action_output}")
  endif()
endforeach()
# Links in dependency order: a link fails until the import library it needs
# exists, so retry the failures once each other link has run.
set(pending ${links})
set(last_output)
while(pending)
  set(progress FALSE)
  set(next)
  foreach(id IN LISTS pending)
    run_and_check_outputs(${id})
    if(action_result EQUAL 0)
      set(progress TRUE)
    else()
      list(APPEND next ${id})
      set(last_output "${action_output}")
    endif()
  endforeach()
  if(NOT progress)
    message(FATAL_ERROR "link failed:\n${last_output}")
  endif()
  set(pending ${next})
endwhile()

# Reads `count` little-endian bytes of the PE image at `offset` from its PE
# signature.
function(pe_field path offset count out_var)
  file(READ "${path}" lfanew_hex OFFSET 60 LIMIT 4 HEX)
  string(SUBSTRING "${lfanew_hex}" 0 2 b0)
  string(SUBSTRING "${lfanew_hex}" 2 2 b1)
  math(EXPR at "0x${b1}${b0} + ${offset}")
  file(READ "${path}" hex OFFSET ${at} LIMIT ${count} HEX)
  set(value 0)
  math(EXPR last "${count} - 1")
  foreach(i RANGE ${last} 0 -1)
    math(EXPR digit "${i} * 2")
    string(SUBSTRING "${hex}" ${digit} 2 byte)
    math(EXPR value "(${value} << 8) + 0x${byte}")
  endforeach()
  set(${out_var} ${value} PARENT_SCOPE)
endfunction()
# IMAGE_FILE_DLL (0x2000) in the COFF header's Characteristics: the image is
# a DLL only if the linker was told /dll.
foreach(image IN ITEMS lib.dll plugin.dll app.exe host.exe quiet.exe big.exe named.exe dwarf.exe)
  pe_field("${binary}/${image}" 22 2 characteristics)
  math(EXPR is_dll "(${characteristics} >> 13) & 1")
  if(image MATCHES "\\.dll$" AND NOT is_dll)
    message(FATAL_ERROR "${image} is not a DLL: the linker was not told /dll.")
  elseif(image MATCHES "\\.exe$" AND is_dll)
    message(FATAL_ERROR "${image} is marked as a DLL.")
  endif()
endforeach()
# The linker read the quoted response-file line as one option.
file(STRINGS "${binary}/big.exe" alt_pdb REGEX "sym \"q\" dir")
if(NOT alt_pdb)
  message(FATAL_ERROR "big.exe does not record the PDB path its response file names.")
endif()
# MajorImageVersion and MinorImageVersion of the optional header: /version:.
pe_field("${binary}/lib.dll" 68 2 major)
pe_field("${binary}/lib.dll" 70 2 minor)
if(NOT "${major}.${minor}" STREQUAL "3.4")
  message(FATAL_ERROR "lib.dll has image version ${major}.${minor}, not its target's VERSION 3.4.")
endif()

# The C++ module scan line (compared with CMake's rule, not run; see the
# header).
set(module_source "${TEST_BINARY_ROOT}/module-src")
file(MAKE_DIRECTORY "${module_source}")
file(WRITE "${module_source}/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 4.1)
project(MsvcFrontendModules CXX)
add_library(mod STATIC)
target_compile_features(mod PUBLIC cxx_std_20)
target_sources(mod PUBLIC FILE_SET CXX_MODULES FILES m.cppm)
]=])
file(WRITE "${module_source}/m.cppm" "export module m;\nexport int f() { return 1; }\n")
set(module_binary "${TEST_BINARY_ROOT}/module-build")
execute_process(COMMAND ${tool_env} "${TEST_CMAKE}" -S "${module_source}" -B "${module_binary}" -G Reprobuild
  ${forced_identity}
  -DCMAKE_CXX_COMPILER_VERSION=19.1
  "-DCMAKE_CXX_COMPILER_CLANG_SCAN_DEPS=${tool_path}/clang-scan-deps"
  -DCMAKE_CXX_COMPILE_FEATURES=cxx_std_20
  -DCMAKE_CXX20_COMPILE_FEATURES=cxx_std_20
  -DCMAKE_CXX_STANDARD_COMPUTED_DEFAULT=14
  -DCMAKE_CXX_STANDARD_DEFAULT=14
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "configuring the module project failed: ${out}\n${err}")
endif()
file(GLOB scan_wrappers "${module_binary}/CMakeFiles/reprobuild/bin/*scan_mod*")
list(LENGTH scan_wrappers scan_count)
if(NOT scan_count EQUAL 1)
  message(FATAL_ERROR "Expected one module scan action, saw: ${scan_wrappers}")
endif()
file(READ "${scan_wrappers}" scan)
set(ddi "CMakeFiles/mod.dir/m.cppm.obj.ddi")
foreach(expected IN ITEMS
    " -clang:-o '-clang:CMakeFiles/mod.dir/m.cppm.obj' "
    " -clang:-MT '-clang:${ddi}' "
    " -clang:-MD -clang:-MF '-clang:${ddi}.d' ")
  string(FIND "${scan}" "${expected}" at)
  if(at EQUAL -1)
    message(FATAL_ERROR "The module scan line lacks `${expected}`, as CMAKE_CXX_SCANDEP_SOURCE spells it for the MSVC frontend:\n${scan}")
  endif()
endforeach()
# Only what follows the source's `-c`: the flags before it may hold `-MD`
# as the runtime-library choice.
string(REGEX REPLACE "^.* -c " "" scan_options "${scan}")
if(scan_options MATCHES "(^| )-(MT|MD|MF|o) ")
  message(FATAL_ERROR "The module scan line passes a bare -${CMAKE_MATCH_2}, which clang-cl reads as a cl.exe option:\n${scan}")
endif()

# Policy CMP0197 OLD: the machine flag is in the linker flag variables, and
# the rule-only platform flags do not repeat it.
set(old_source "${TEST_BINARY_ROOT}/cmp0197-old-src")
file(MAKE_DIRECTORY "${old_source}")
file(WRITE "${old_source}/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 3.29)
project(MsvcFrontendOldMachineFlag C)
add_executable(old host.c)
]=])
file(COPY "${source}/host.c" DESTINATION "${old_source}")
set(old_binary "${TEST_BINARY_ROOT}/cmp0197-old-build")
execute_process(COMMAND ${tool_env} "${TEST_CMAKE}" -S "${old_source}" -B "${old_binary}" -G Reprobuild
  ${forced_identity} -DCMAKE_C_COMPILER_VERSION=18.1
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "configuring the CMP0197 OLD project failed: ${out}\n${err}")
endif()
file(STRINGS "${old_binary}/reprobuild.nim" old_link REGEX "buildAction\\(\"link-old\"")
string(REGEX MATCHALL "\"[/-][Mm][Aa][Cc][Hh][Ii][Nn][Ee]:[^\"]*\"" machine_flags "${old_link}")
if(NOT machine_flags STREQUAL "\"/machine:x64\"")
  message(FATAL_ERROR "Under CMP0197 OLD the link line should carry /machine:x64 once, from the flag variables; saw '${machine_flags}': ${old_link}")
endif()

# A GNU-frontend driver: a long link line is passed in a response file
# quoted by GCC's rules, where an apostrophe is a quote.
set(gnu_source "${TEST_BINARY_ROOT}/gnu-src")
set(gnu_lib_dir "${TEST_BINARY_ROOT}/o'brien")
file(MAKE_DIRECTORY "${gnu_source}/${long_dir}" "${gnu_lib_dir}")
file(WRITE "${gnu_source}/CMakeLists.txt" "
cmake_minimum_required(VERSION 3.29)
project(GnuLongLink C)
add_executable(big host.c \"${cmakelists_fixed}\")
target_link_directories(big PRIVATE [[${gnu_lib_dir}]])
")
file(COPY "${source}/host.c" DESTINATION "${gnu_source}")
file(COPY "${source}/${long_dir}" DESTINATION "${gnu_source}")
set(clang "${tool_path}/clang")
file(CREATE_LINK "${TEST_CLANG_CL}" "${clang}" SYMBOLIC)
set(gnu_binary "${TEST_BINARY_ROOT}/gnu-build")
execute_process(COMMAND ${tool_env} "${TEST_CMAKE}" -S "${gnu_source}" -B "${gnu_binary}" -G Reprobuild
  "-DCMAKE_MAKE_PROGRAM=${tool_path}/make"
  "-DCMAKE_C_COMPILER=${clang}"
  -DCMAKE_C_COMPILER_FORCED=TRUE
  -DCMAKE_C_COMPILER_ID=Clang
  -DCMAKE_C_COMPILER_VERSION=18.1
  -DCMAKE_C_COMPILER_FRONTEND_VARIANT=GNU
  "-DCMAKE_EXE_LINKER_FLAGS=-nostdlib -Wl,-e,main"
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "configuring the GNU project failed: ${out}\n${err}")
endif()
file(STRINGS "${gnu_binary}/reprobuild.nim" gnu_lines REGEX "buildAction\\(\"(compile-|link-big\")")
foreach(line IN LISTS gnu_lines)
  if(NOT line MATCHES "buildAction\\(\"([^\"]+)\", inlineExecCall\\(@(\\[.*\\])(, cwd = \"[^\"]*\")?\\), deps = ")
    message(FATAL_ERROR "Unreadable action: ${line}")
  endif()
  set(id "${CMAKE_MATCH_1}")
  json_array_to_list("${CMAKE_MATCH_2}" argv)
  if(id STREQUAL "link-big")
    if(NOT argv STREQUAL "${clang};@CMakeFiles/reprobuild/rsp/link-big.rsp")
      message(FATAL_ERROR "The GNU driver's long link line is not passed in its response file: ${argv}")
    endif()
    set(gnu_link "${argv}")
  else()
    execute_process(COMMAND ${tool_env} ${argv} WORKING_DIRECTORY "${gnu_binary}"
      RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
    if(NOT result EQUAL 0)
      message(FATAL_ERROR "GNU compile failed:\n${out}\n${err}")
    endif()
  endif()
endforeach()
execute_process(COMMAND ${tool_env} ${gnu_link} WORKING_DIRECTORY "${gnu_binary}"
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0 OR NOT EXISTS "${gnu_binary}/big")
  file(READ "${gnu_binary}/CMakeFiles/reprobuild/rsp/link-big.rsp" rsp_text)
  message(FATAL_ERROR "The GNU driver could not link through its response file:\n${out}\n${err}\n${rsp_text}")
endif()
