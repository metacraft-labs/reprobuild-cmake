# Protects: the generator describes each CMake target twice, once in
# `reprobuild.nim` and once in the `trycompile.rbsz` envelope, and a build
# gives every action the same id whichever of the two it reads.
#
# The id is part of an action's cache key, and a `target(...)` that names
# exactly one action renames that action to the target's name. Before the
# fix, `reprobuild.nim` named a plain library or executable's link alone
# (`target("app", <link>)`), so a build that read it called the link `app`,
# while the envelope listed the target's compiles and its link, so a build
# that read the envelope called the same link `link-app`. The two routes
# then keyed one link under two ids.
#
# Defect record: reprobuild-pm
# issues/2026-11-21-the-cmake-generator-s-two-graph-descriptions-name-a-link-only-target-s-link-differently.md
# Spec: reprobuild-pm spec/Provider-Compile-Tiering.md, "2c — Tier 2a
# extended to the main CMake project": both descriptions declare the same
# members for every target.
#
# The test configures one project and builds `all` twice in the same build
# directory, through each route, and compares the action ids the two build
# reports list. The first build reads the envelope: `--tool-provisioning=path`
# with the `repro-cmake-trycompile-provider` installed beside `repro`. For
# the second the envelope is moved aside, which is what a `repro` without
# that provider, or with another tool provisioning, sees: it reads
# `reprobuild.nim`. Each report's `providerRoute` is checked against the one
# route that reads each file (`tier2a-trycompile-direct`, then
# `compiled-provider`), so the test fails instead of comparing one route
# with itself if the route selection changes.
#
# The project covers every target shape the generator writes: link-only
# static and shared libraries and an executable (the shape the defect was
# in), an executable with a post-build step (a target that already named
# several actions in both descriptions), and the targets that name exactly
# one action in both descriptions and so are renamed on both routes: a
# custom target and an object library with one source (its compile).
#
# No mocks: the forked CMake, the built `repro` and its trycompile provider,
# and the host C compiler. The regeneration edge is skipped
# (`--skip-cmake-regeneration`) because it would otherwise rewrite the
# envelope the second build hides; it is not under test.
cmake_minimum_required(VERSION 3.29)
foreach(required IN ITEMS TEST_CMAKE TEST_REPROBUILD_REPRO
                          TEST_REPROBUILD_SOURCE_ROOT TEST_C_COMPILER
                          TEST_BINARY_ROOT)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "${required} is required")
  endif()
endforeach()
file(REMOVE_RECURSE "${TEST_BINARY_ROOT}")
set(source "${TEST_BINARY_ROOT}/src")
set(binary "${TEST_BINARY_ROOT}/build")
file(MAKE_DIRECTORY "${source}")

file(WRITE "${source}/CMakeLists.txt" [[
cmake_minimum_required(VERSION 3.20)
project(GraphDescriptionsAgree C)
add_library(alpha STATIC alpha.c)
add_library(beta SHARED beta.c)
add_executable(app main.c)
target_link_libraries(app PRIVATE alpha beta)
add_executable(stamped stamped.c)
add_custom_command(TARGET stamped POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E touch stamped.done)
add_custom_target(note ALL COMMAND "${CMAKE_COMMAND}" -E echo note)
add_library(objs OBJECT objs.c)
]])
file(WRITE "${source}/alpha.c" "int alpha_value(void) { return 1; }\n")
file(WRITE "${source}/beta.c" "int beta_value(void) { return 2; }\n")
file(WRITE "${source}/main.c"
  "int alpha_value(void);\nint beta_value(void);\n"
  "int main(void) { return alpha_value() + beta_value() == 3 ? 0 : 1; }\n")
file(WRITE "${source}/stamped.c" "int main(void) { return 0; }\n")
file(WRITE "${source}/objs.c" "int objs_value(void) { return 3; }\n")

execute_process(
  COMMAND "${CMAKE_COMMAND}" -E env
    "REPROBUILD_REPRO=${TEST_REPROBUILD_REPRO}"
    "${TEST_CMAKE}" -S "${source}" -B "${binary}" -G Reprobuild
    "-DCMAKE_C_COMPILER=${TEST_C_COMPILER}"
    "-DCMAKE_MAKE_PROGRAM=${TEST_REPROBUILD_REPRO}"
    -DCMAKE_BUILD_TYPE=Release
  RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "configure failed:\n${out}\n${err}")
endif()
foreach(description IN ITEMS reprobuild.nim trycompile.rbsz)
  if(NOT EXISTS "${binary}/${description}")
    message(FATAL_ERROR "the configure wrote no ${description}")
  endif()
endforeach()

# Builds `all` and returns the build report's provider route and the sorted
# ids of the actions it lists.
function(build_all label route_var ids_var)
  string(MAKE_C_IDENTIFIER "${label}" slug)
  set(report_path "${TEST_BINARY_ROOT}/${slug}-report.json")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env
      "REPROBUILD_WORK_ROOT=${binary}/CMakeFiles/reprobuild/work-root"
      "REPROBUILD_SOURCE_ROOT=${TEST_REPROBUILD_SOURCE_ROOT}"
      "${TEST_REPROBUILD_REPRO}" build "${binary}#all"
      --tool-provisioning=path
      "--work-root=${binary}/CMakeFiles/reprobuild"
      --skip-cmake-regeneration
      --progress=none
      "--write-report=${report_path}"
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "the ${label} build failed:\n${out}\n${err}")
  endif()
  if(NOT EXISTS "${report_path}")
    message(FATAL_ERROR "the ${label} build wrote no build report:\n${out}\n${err}")
  endif()
  file(READ "${report_path}" report)
  string(JSON route GET "${report}" providerRoute)
  string(JSON count LENGTH "${report}" actions)
  set(ids)
  if(count GREATER 0)
    math(EXPR last "${count} - 1")
    foreach(i RANGE 0 ${last})
      string(JSON id GET "${report}" actions ${i} id)
      list(APPEND ids "${id}")
    endforeach()
  endif()
  list(SORT ids)
  set(${route_var} "${route}" PARENT_SCOPE)
  set(${ids_var} "${ids}" PARENT_SCOPE)
endfunction()

build_all("envelope" envelope_route envelope_ids)
if(NOT envelope_route STREQUAL "tier2a-trycompile-direct")
  message(FATAL_ERROR
    "the first build did not read trycompile.rbsz: providerRoute is "
    "'${envelope_route}', not 'tier2a-trycompile-direct'")
endif()

file(RENAME "${binary}/trycompile.rbsz" "${binary}/trycompile.rbsz.hidden")
build_all("reprobuild.nim" provider_route provider_ids)
file(RENAME "${binary}/trycompile.rbsz.hidden" "${binary}/trycompile.rbsz")
if(NOT provider_route STREQUAL "compiled-provider")
  message(FATAL_ERROR
    "the second build did not read reprobuild.nim: providerRoute is "
    "'${provider_route}', not 'compiled-provider'")
endif()

# Each link-only target's link keeps its action id on both routes.
foreach(link IN ITEMS link-alpha link-beta link-app link-stamped)
  foreach(route IN ITEMS envelope provider)
    if(NOT link IN_LIST ${route}_ids)
      message(FATAL_ERROR
        "the ${route} route's build lists no '${link}' action.\n"
        "envelope route (${envelope_route}): ${envelope_ids}\n"
        "reprobuild.nim route (${provider_route}): ${provider_ids}")
    endif()
  endforeach()
endforeach()
# A target naming exactly one action renames it, on both routes alike.
foreach(renamed IN ITEMS note objs)
  foreach(route IN ITEMS envelope provider)
    if(NOT renamed IN_LIST ${route}_ids)
      message(FATAL_ERROR
        "the ${route} route's build lists no '${renamed}' action.\n"
        "envelope route (${envelope_route}): ${envelope_ids}\n"
        "reprobuild.nim route (${provider_route}): ${provider_ids}")
    endif()
  endforeach()
endforeach()
if(NOT envelope_ids STREQUAL provider_ids)
  message(FATAL_ERROR
    "the two graph descriptions give the actions different ids.\n"
    "envelope route (${envelope_route}): ${envelope_ids}\n"
    "reprobuild.nim route (${provider_route}): ${provider_ids}")
endif()
message(STATUS "both routes list: ${envelope_ids}")
