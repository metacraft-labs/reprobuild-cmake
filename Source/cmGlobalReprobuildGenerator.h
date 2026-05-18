/* Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
   file LICENSE.rst or https://cmake.org/licensing for details.  */
#pragma once

#include "cmConfigure.h" // IWYU pragma: keep

#include <memory>
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

  void Generate() override;

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
  bool ValidateConfiguration();
  void WriteProviderMetadata();
};
