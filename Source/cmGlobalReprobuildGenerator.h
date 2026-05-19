/* Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
   file LICENSE.rst or https://cmake.org/licensing for details.  */
#pragma once

#include "cmConfigure.h" // IWYU pragma: keep

#include <memory>
#include <set>
#include <string>
#include <vector>

#include "cmBuildOptions.h"
#include "cmGlobalUnixMakefileGenerator3.h"

class cmGlobalGeneratorFactory;
class cmLocalGenerator;
class cmMakefile;
class cmake;
struct cmDocumentationEntry;

class cmGlobalReprobuildGenerator : public cmGlobalUnixMakefileGenerator3
{
public:
  cmGlobalReprobuildGenerator(cmake* cm);
  ~cmGlobalReprobuildGenerator() override;

  static std::unique_ptr<cmGlobalGeneratorFactory> NewFactory();

  std::string GetName() const override
  {
    return cmGlobalReprobuildGenerator::GetActualName();
  }
  static std::string GetActualName() { return "Reprobuild"; }

  static bool SupportsToolset() { return false; }
  static bool SupportsPlatform() { return false; }
  static cmDocumentationEntry GetDocumentation();

  std::unique_ptr<cmLocalGenerator> CreateLocalGenerator(
    cmMakefile* mf) override;

  void EnableLanguage(std::vector<std::string> const& languages, cmMakefile* mf,
                      bool optional) override;

  // Override the base UnixMakefileGenerator3 search (which looks for
  // gmake/make/smake). Reprobuild is the build tool that consumes this
  // generator's metadata, so we set CMAKE_MAKE_PROGRAM to the `repro` CLI.
  // This is also what makes the generator usable on Windows, where the
  // gmake/make/smake search yields nothing.
  bool FindMakeProgram(cmMakefile* mf) override;

  void Generate() override;
  bool IsMultiConfig() const override;

  bool InspectConfigTypeVariables() override;

  std::string GetDefaultBuildConfig() const override;

  std::set<std::string> const& GetDefaultConfigs() const override
  {
    return this->DefaultConfigs;
  }

  bool SupportsDefaultBuildType() const override { return true; }
  bool SupportsCrossConfigs() const override { return true; }
  bool SupportsDefaultConfigs() const override { return true; }

  bool CheckCxxModuleSupport(CxxModuleSupportQuery /*query*/) override
  {
    return true;
  }

  std::vector<GeneratedMakeCommand> GenerateBuildCommand(
    std::string const& makeProgram, std::string const& projectName,
    std::string const& projectDir, std::vector<std::string> const& targetNames,
    std::string const& config, int jobs, bool verbose,
    cmBuildOptions buildOptions = cmBuildOptions(),
    std::vector<std::string> const& makeOptions = std::vector<std::string>(),
    BuildTryCompile isInTryCompile = BuildTryCompile::No) override;

private:
  void WriteProviderMetadata();

  std::set<std::string> CrossConfigs;
  std::set<std::string> DefaultConfigs;
  std::string DefaultFileConfig;
};
