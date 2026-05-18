# reprobuild-cmake

This fork is the CMake-side integration branch for a future Reprobuild
generator.

The current branch is `reprobuild`. It starts from upstream CMake commit
`24d023247a7f67bf74f624b5a37b34183c570bf4`.

## Goal

The target user experience is a first-class CMake generator that can replace
Ninja as the local execution backend:

```sh
cmake -S . -B build-repro -G Reprobuild -DCMAKE_BUILD_TYPE=Debug
cmake --build build-repro --target all
```

The generator should emit a Reprobuild project/provider recipe from CMake's
configured target graph. Reprobuild then owns execution, cache checks,
dependency evidence, resource admission, and development-loop features.

Expected benefits:

- CMake builds launched through Reprobuild are admitted through RunQuota, so
  CPU, memory, IO, and pool pressure can be managed before the workstation hits
  swap storms or OOM failures.
- CMake targets become visible to Reprobuild's hot-code-reloading pipeline:
  source -> object -> link relationships, compiler flags, debug-info policy,
  and object artifacts can feed HCR patch generation.
- CMake can run inside Reprobuild development environments, using compilers,
  linkers, SDKs, and helper tools provided by Reprobuild/Nix profiles.

## Why a Fork

CMake generators are compiled into CMake as global generator factories. CMake's
"extra generators" are IDE sidecars, not loadable native build backends, and
they are not a replacement for the Ninja generator. A first-class
`-G Reprobuild` generator therefore needs either an upstream CMake change or a
fork while the design is still experimental.

## Source Areas

The first implementation should treat the Ninja generator as the compatibility
baseline and port behavior deliberately:

- `Source/cmGlobalNinjaGenerator.*`
- `Source/cmLocalNinjaGenerator.*`
- `Source/cmNinjaTargetGenerator.*`
- `Source/cmNinjaNormalTargetGenerator.*`
- `Source/cmNinjaUtilityTargetGenerator.*`
- `Source/cmNinjaTypes.h`
- `Source/cmake.cxx`
- `Source/cmGlobalGeneratorFactory.h`

The core Ninja generator is about 10.6k lines before adjacent docs and tests.
The Reprobuild generator should not copy the text-emission layer blindly; it
should preserve the CMake semantics while lowering into Reprobuild's normalized
action graph.

## Translation Model

At a high level:

- A CMake target becomes one or more Reprobuild public targets and action
  groups.
- A compile, scan, device-link, link, custom command, install, test, package,
  or utility edge becomes a Reprobuild action.
- Ninja explicit, implicit, and order-only dependencies become normalized
  Reprobuild graph edges with path-producing actions inferred where possible.
- Ninja depfiles, MSVC include output, CMake scanner reports, and dyndep files
  become recognized or converted Reprobuild dependency evidence.
- Ninja pools become Reprobuild scheduler pools and RunQuota named-pool
  requests.
- CMake target properties and generator variables become action metadata:
  config, language, target name, toolchain identity, resource estimate key,
  cacheability policy, and HCR eligibility.

The generated artifact should be treated as a provider output owned by the CMake
configure step, not as hand-authored Reprobuild DSL.

## Feature Inventory

The Reprobuild generator needs parity with these Ninja generator feature
groups:

- Single-config `Ninja`:
  emit one configured Reprobuild action graph.
- `Ninja Multi-Config`:
  emit a multi-config graph or config-qualified target aliases.
- `cmake --build` target dispatch:
  invoke `repro build` through CMake's build command wrapper.
- `all`, per-directory `all`, and target aliases:
  emit public Reprobuild target aliases and aggregates.
- install, test, package, help, rebuild-cache, and clean targets:
  emit named public targets with compatible behavior.
- CMake language compile rules:
  emit per-source or per-module actions using CMake-expanded command templates.
- defines, includes, flags, file-set properties, source properties, and PCH:
  lower into action argv, response files, inputs, and tool metadata.
- GCC/Clang depfiles and MSVC `/showIncludes`:
  lower into recognized dependency reports.
- custom commands and custom targets:
  emit process actions with outputs, byproducts, depfiles, working directory,
  pools, terminal policy, comments, and restat behavior.
- Fortran module dyndep:
  emit pre-execution scan/collation actions that publish module edges.
- C++20 module scanning and BMI output:
  emit scanner actions, dynamic dependencies, and BMI artifact outputs.
- Swift output maps and split Swift builds:
  emit module-level actions with output maps and `.swiftdeps` evidence.
- CUDA separable compilation and device link:
  emit device-link, fatbinary, and registration-stub actions.
- static, shared, module, executable, and object-library outputs:
  emit link/archive actions, aggregates, import libraries, and byproducts.
- macOS bundles, frameworks, content copy, and install names:
  emit bundle-layout and copy actions plus platform link metadata.
- Windows manifests, import libs, PDBs, and generated DEF files:
  emit link pre-steps, declared byproducts, and platform output metadata.
- AIX exports, text stubs, symlink rules, and soname chains:
  emit link helper actions and byproduct-aware output policies.
- response files:
  emit Reprobuild-owned preflight files or action-local execution inputs.
- CMake job pools and `USES_TERMINAL`:
  map to scheduler pools, console/exclusive pools, and RunQuota named pools.
- `CMAKE_NINJA_OUTPUT_PATH_PREFIX` and `cmake_ninja_workdir`:
  record logical build-root and path-prefix metadata in the provider.
- regeneration and glob verification:
  emit a generator action that reruns CMake and refreshes the provider graph.
- `compile_commands.json`:
  emit the same JSON or derive it from Reprobuild action metadata.
- CMake instrumentation targets:
  preserve CTest instrumentation behavior through Reprobuild utility actions.

## HCR Direction

The first HCR integration should be opt-in. A likely shape is:

- A CMake cache variable such as `CMAKE_REPROBUILD_HCR=ON`.
- A target property for HCR eligibility and per-target overrides.
- Compiler flag injection for a supported profile: debug info, patchable
  function entries, no incompatible LTO, and bounded inlining policy.
- Preservation of source -> object -> link metadata for Reprobuild's HCR
  coordinator.
- A post-link metadata edge that extracts linkgraph facts needed for patch
  generation.

The Reprobuild generator should not claim universal HCR. It should expose enough
metadata for Reprobuild to validate support profile by support profile.

## Development Environment Direction

No CMake fork work is required for the shallow integration: run CMake inside a
Reprobuild development environment and let today's CMake toolchain variables
point at Reprobuild/Nix-provided tools.

Deeper integration should add:

- Generated CMake toolchain files from Reprobuild profiles.
- Stable tool identity and SDK identity in generated Reprobuild actions.
- Resource defaults by action family, such as compile, link, scan, install, and
  custom command.
- A way for `cmake --build` and `repro build` to agree on build directory,
  selected target, selected config, and provider refresh policy.

## Implementation Order

1. Add generator factory plumbing and a minimal `-G Reprobuild` skeleton.
2. Emit a Reprobuild provider/action graph for a single-config C/C++ executable.
3. Add compile depfiles, response files, target aliases, `all`, and
   `compile_commands.json`.
4. Add static/shared/module libraries, object libraries, normal link outputs,
   byproducts, and clean behavior.
5. Add custom commands, custom targets, install/test/package utility targets,
   regeneration, and glob verification.
6. Add RunQuota resource metadata and full pool parity.
7. Add Fortran and C++ module dynamic dependencies.
8. Add CUDA, Swift, ISPC, platform bundle/framework/import-library behavior, and
   Ninja Multi-Config parity.
9. Add opt-in HCR metadata and development-environment/toolchain integration.

## Open Questions

- Should the generated provider be a Reprobuild source file, a compiled provider
  helper, or a binary graph artifact consumed by Reprobuild directly?
- Should `cmake --build` call `repro build`, or should it call a small
  `cmake-reprobuild-build` compatibility launcher?
- Which dynamic-dependency format should replace Ninja `.dd` for Fortran and
  C++ modules long term?
- What target property and cache-variable names should expose HCR support
  without making unsupported targets look reloadable?
- How much of `clean` should be CMake-compatible deletion and how much should be
  Reprobuild cache/store cleanup?
