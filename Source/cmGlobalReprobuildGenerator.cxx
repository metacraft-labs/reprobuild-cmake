/* Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
   file LICENSE.rst or https://cmake.org/licensing for details.  */

#include "cmGlobalReprobuildGenerator.h"

#include <sstream>
#include <utility>

#include <cm/memory>

#include "cmsys/FStream.hxx"

#include "cmDocumentationEntry.h"
#include "cmGlobalGeneratorFactory.h"
#include "cmLocalGenerator.h"
#include "cmLocalReprobuildGenerator.h"
#include "cmMakefile.h"
#include "cmStringAlgorithms.h"
#include "cmSystemTools.h"
#include "cmValue.h"
#include "cmake.h"

cmGlobalReprobuildGenerator::cmGlobalReprobuildGenerator(cmake* cm)
  : cmGlobalUnixMakefileGenerator3(cm)
{
}

cmGlobalReprobuildGenerator::~cmGlobalReprobuildGenerator() = default;

std::unique_ptr<cmGlobalGeneratorFactory>
cmGlobalReprobuildGenerator::NewFactory()
{
  return std::unique_ptr<cmGlobalGeneratorFactory>(
    new cmGlobalGeneratorSimpleFactory<cmGlobalReprobuildGenerator>());
}

cmDocumentationEntry cmGlobalReprobuildGenerator::GetDocumentation()
{
  return { cmGlobalReprobuildGenerator::GetActualName(),
           "Generates Reprobuild provider metadata." };
}

std::unique_ptr<cmLocalGenerator>
cmGlobalReprobuildGenerator::CreateLocalGenerator(cmMakefile* mf)
{
  return std::unique_ptr<cmLocalGenerator>(
    cm::make_unique<cmLocalReprobuildGenerator>(this, mf));
}

void cmGlobalReprobuildGenerator::EnableLanguage(
  std::vector<std::string> const& languages, cmMakefile* mf, bool optional)
{
  for (std::string const& lang : languages) {
    if (lang != "NONE" && lang != "C") {
      mf->IssueMessage(
        MessageType::FATAL_ERROR,
        cmStrCat("The Reprobuild generator M1 skeleton supports only the C "
                 "language; language '",
                 lang, "' is not supported."));
      cmSystemTools::SetFatalErrorOccurred();
      return;
    }
  }

  this->cmGlobalUnixMakefileGenerator3::EnableLanguage(languages, mf,
                                                       optional);
}

bool cmGlobalReprobuildGenerator::ValidateM1Configuration()
{
  if (cmValue configs = this->GetCMakeInstance()->GetState()->GetCacheEntryValue(
        "CMAKE_CONFIGURATION_TYPES")) {
    if (!configs->empty()) {
      this->GetCMakeInstance()->IssueMessage(
        MessageType::FATAL_ERROR,
        "The Reprobuild generator M1 skeleton supports only single-config "
        "build trees; CMAKE_CONFIGURATION_TYPES is not supported.");
      return false;
    }
  }
  return true;
}

void cmGlobalReprobuildGenerator::Generate()
{
  if (!this->ValidateM1Configuration()) {
    return;
  }

  this->cmGlobalUnixMakefileGenerator3::Generate();
  if (cmSystemTools::GetErrorOccurredFlag()) {
    return;
  }

  this->WriteProviderMetadata();
}

void cmGlobalReprobuildGenerator::WriteProviderMetadata()
{
  std::string const providerDir =
    cmStrCat(this->GetCMakeInstance()->GetHomeOutputDirectory(),
             "/CMakeFiles/reprobuild");
  if (!cmSystemTools::MakeDirectory(providerDir)) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      cmStrCat("Could not create Reprobuild provider directory: ",
               providerDir));
    return;
  }

  std::string const metadataFile = cmStrCat(providerDir, "/provider.meta");
  cmsys::ofstream metadata(metadataFile.c_str());
  if (!metadata) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      cmStrCat("Could not write Reprobuild provider metadata: ",
               metadataFile));
    return;
  }

  metadata << "generator=Reprobuild\n";
  metadata << "provider_version=1\n";
  metadata << "m1_action_state=unsupported\n";
  metadata << "source_dir=" << this->GetCMakeInstance()->GetHomeDirectory()
           << "\n";
  metadata << "binary_dir="
           << this->GetCMakeInstance()->GetHomeOutputDirectory() << "\n";

  std::vector<std::string> languages;
  this->GetEnabledLanguages(languages);
  metadata << "enabled_languages=" << cmJoin(languages, ",") << "\n";

  std::string const launcherStateFile =
    cmStrCat(providerDir, "/launcher-state.txt");
  cmsys::ofstream launcherState(launcherStateFile.c_str());
  if (!launcherState) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      cmStrCat("Could not write Reprobuild launcher state: ",
               launcherStateFile));
    return;
  }
  launcherState << "unsupported_action=build\n";
}

std::vector<cmGlobalGenerator::GeneratedMakeCommand>
cmGlobalReprobuildGenerator::GenerateBuildCommand(
  std::string const& makeProgram, std::string const& projectName,
  std::string const& projectDir, std::vector<std::string> const& targetNames,
  std::string const& config, int jobs, bool verbose,
  cmBuildOptions buildOptions, std::vector<std::string> const& makeOptions,
  BuildTryCompile isInTryCompile)
{
  if (isInTryCompile == BuildTryCompile::Yes) {
    return this->cmGlobalUnixMakefileGenerator3::GenerateBuildCommand(
      makeProgram, projectName, projectDir, targetNames, config, jobs, verbose,
      buildOptions, makeOptions, isInTryCompile);
  }

  GeneratedMakeCommand makeCommand;
  makeCommand.Add(cmSystemTools::GetCMakeCommand());
  makeCommand.Add("--reprobuild-launch");
  makeCommand.Add(projectDir);
  makeCommand.Add("--action=build");
  makeCommand.Add(cmStrCat("--project=", projectName));
  if (!config.empty()) {
    makeCommand.Add(cmStrCat("--config=", config));
  }
  for (std::string const& targetName : targetNames) {
    if (!targetName.empty()) {
      makeCommand.Add(cmStrCat("--target=", targetName));
    }
  }
  return { std::move(makeCommand) };
}
