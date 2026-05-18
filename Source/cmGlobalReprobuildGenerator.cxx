/* Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
   file LICENSE.rst or https://cmake.org/licensing for details.  */

#include "cmGlobalReprobuildGenerator.h"

#include <algorithm>
#include <cctype>
#include <set>
#include <sstream>
#include <utility>
#include <vector>

#include <cm/memory>
#include <cmext/algorithm>

#include "cmsys/FStream.hxx"

#include "cmDocumentationEntry.h"
#include "cmGlobalGeneratorFactory.h"
#include "cmGeneratorTarget.h"
#include "cmLocalGenerator.h"
#include "cmLocalReprobuildGenerator.h"
#include "cmMakefile.h"
#include "cmSourceFile.h"
#include "cmStateTypes.h"
#include "cmStringAlgorithms.h"
#include "cmSystemTools.h"
#include "cmValue.h"
#include "cmake.h"

namespace {
std::string ReprobuildEscape(std::string const& value)
{
  std::string out;
  out.reserve(value.size() + 8);
  out.push_back('"');
  for (char ch : value) {
    switch (ch) {
      case '\\':
        out += "\\\\";
        break;
      case '"':
        out += "\\\"";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        out.push_back(ch);
        break;
    }
  }
  out.push_back('"');
  return out;
}

std::string ReprobuildJsonEscape(std::string const& value)
{
  std::string out;
  out.reserve(value.size() + 8);
  out.push_back('"');
  for (unsigned char ch : value) {
    switch (ch) {
      case '\\':
        out += "\\\\";
        break;
      case '"':
        out += "\\\"";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (ch < 0x20) {
          out += "\\u00";
          static char const hex[] = "0123456789abcdef";
          out.push_back(hex[(ch >> 4) & 0xf]);
          out.push_back(hex[ch & 0xf]);
        } else {
          out.push_back(static_cast<char>(ch));
        }
        break;
    }
  }
  out.push_back('"');
  return out;
}

std::string ReprobuildSafeId(std::string value)
{
  for (char& ch : value) {
    unsigned char uch = static_cast<unsigned char>(ch);
    if (!std::isalnum(uch) && ch != '_' && ch != '-' && ch != '.') {
      ch = '_';
    }
  }
  if (value.empty()) {
    value = "action";
  }
  return value;
}

std::string ReprobuildNimIdent(std::string const& prefix,
                               std::size_t index,
                               std::string const& value)
{
  std::string out = cmStrCat(prefix, index);
  bool pendingSeparator = true;
  for (char ch : value) {
    unsigned char uch = static_cast<unsigned char>(ch);
    if (std::isalnum(uch)) {
      if (pendingSeparator && out.back() != '_') {
        out.push_back('_');
      }
      out.push_back(ch);
      pendingSeparator = false;
    } else {
      pendingSeparator = true;
    }
  }
  while (!out.empty() && out.back() == '_') {
    out.pop_back();
  }
  return out;
}

void ReprobuildWriteStringArray(cmsys::ofstream& out,
                                std::vector<std::string> const& values)
{
  out << "@[";
  char const* sep = "";
  for (std::string const& value : values) {
    out << sep << ReprobuildEscape(value);
    sep = ", ";
  }
  out << "]";
}

std::string ReprobuildRelativeTo(std::string const& root,
                                 std::string const& path)
{
  std::string normalizedRoot = cmSystemTools::CollapseFullPath(root);
  std::string normalizedPath = cmSystemTools::CollapseFullPath(path);
  std::string prefix = normalizedRoot;
  if (!cmHasSuffix(prefix, "/")) {
    prefix += "/";
  }
  if (normalizedPath == normalizedRoot) {
    return ".";
  }
  if (normalizedPath.rfind(prefix, 0) == 0) {
    return normalizedPath.substr(prefix.size());
  }
  return normalizedPath;
}

void ReprobuildAppendParsed(std::vector<std::string>& out,
                            std::string const& flags)
{
  if (flags.empty()) {
    return;
  }
  std::vector<std::string> parsed;
#ifdef _WIN32
  cmSystemTools::ParseWindowsCommandLine(flags.c_str(), parsed);
#else
  cmSystemTools::ParseUnixCommandLine(flags.c_str(), parsed);
#endif
  cm::append(out, parsed);
}

std::string ReprobuildCompilerVar(std::string const& lang)
{
  return cmStrCat("CMAKE_", lang, "_COMPILER");
}

std::string ReprobuildToolId(std::string const& lang)
{
  return lang == "CXX" ? "reprobuild-cmake-cxx" : "reprobuild-cmake-cc";
}

std::string ReprobuildShellSingleQuote(std::string const& value)
{
  std::string out = "'";
  for (char ch : value) {
    if (ch == '\'') {
      out += "'\\''";
    } else {
      out.push_back(ch);
    }
  }
  out += "'";
  return out;
}

bool ReprobuildWriteWrapper(std::string const& path,
                            std::string const& executable)
{
  cmsys::ofstream wrapper(path.c_str());
  if (!wrapper) {
    return false;
  }
  wrapper << "#!/bin/sh\n";
  wrapper << "exec " << ReprobuildShellSingleQuote(executable)
          << " \"$@\"\n";
  wrapper.close();
  return cmSystemTools::SetPermissions(path.c_str(), 0755).IsSuccess();
}

struct ReprobuildAction
{
  std::string Id;
  std::string Var;
  std::string ToolLang;
  std::vector<std::string> Args;
  std::vector<std::string> Inputs;
  std::vector<std::string> Outputs;
  std::vector<std::string> Deps;
  std::string CompileDirectory;
  std::string CompileCommand;
  std::string CompileFile;
};

struct ReprobuildTarget
{
  std::string Name;
  std::string Var;
  std::vector<ReprobuildAction> CompileActions;
  ReprobuildAction LinkAction;
};
}

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
    if (lang != "NONE" && lang != "C" && lang != "CXX") {
      mf->IssueMessage(
        MessageType::FATAL_ERROR,
        cmStrCat("The Reprobuild generator M2 slice supports only the C and "
                 "CXX languages; language '",
                 lang, "' is not supported."));
      cmSystemTools::SetFatalErrorOccurred();
      return;
    }
  }

  this->cmGlobalUnixMakefileGenerator3::EnableLanguage(languages, mf,
                                                       optional);
}

bool cmGlobalReprobuildGenerator::ValidateConfiguration()
{
  if (cmValue configs = this->GetCMakeInstance()->GetState()->GetCacheEntryValue(
        "CMAKE_CONFIGURATION_TYPES")) {
    if (!configs->empty()) {
      this->GetCMakeInstance()->IssueMessage(
        MessageType::FATAL_ERROR,
        "The Reprobuild generator M2 slice supports only single-config "
        "build trees; CMAKE_CONFIGURATION_TYPES is not supported.");
      return false;
    }
  }
  return true;
}

void cmGlobalReprobuildGenerator::Generate()
{
  if (!this->ValidateConfiguration()) {
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
  std::string const binaryDir = this->GetCMakeInstance()->GetHomeOutputDirectory();
  std::string const providerDir =
    cmStrCat(binaryDir, "/CMakeFiles/reprobuild");
  if (!cmSystemTools::MakeDirectory(providerDir)) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      cmStrCat("Could not create Reprobuild provider directory: ",
               providerDir));
    return;
  }
  std::string const wrapperDir = cmStrCat(providerDir, "/bin");
  if (!cmSystemTools::MakeDirectory(wrapperDir)) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      cmStrCat("Could not create Reprobuild wrapper directory: ",
               wrapperDir));
    return;
  }

  std::vector<ReprobuildTarget> executableTargets;
  std::set<std::string> usedLanguages;
  std::string const config;
  std::size_t nextActionVar = 0;
  std::size_t nextTargetVar = 0;

  for (auto const& lg : this->LocalGenerators) {
    for (auto const& gtPtr : lg->GetGeneratorTargets()) {
      cmGeneratorTarget* gt = gtPtr.get();
      auto const type = gt->GetType();
      if (type == cmStateEnums::UTILITY || type == cmStateEnums::INTERFACE_LIBRARY ||
          type == cmStateEnums::GLOBAL_TARGET || type == cmStateEnums::UNKNOWN_LIBRARY) {
        continue;
      }
      if (type != cmStateEnums::EXECUTABLE) {
        this->GetCMakeInstance()->IssueMessage(
          MessageType::FATAL_ERROR,
          cmStrCat("The Reprobuild generator M2 slice supports only executable "
                   "targets; target '",
                   gt->GetName(), "' has unsupported type ",
                   cmState::GetTargetTypeName(type), "."));
        return;
      }

      ReprobuildTarget target;
      target.Name = gt->GetName();
      target.Var = ReprobuildNimIdent("target", nextTargetVar++, target.Name);

      std::vector<cmSourceFile const*> sources;
      gt->GetObjectSources(sources, config);
      if (sources.empty()) {
        this->GetCMakeInstance()->IssueMessage(
          MessageType::FATAL_ERROR,
          cmStrCat("The Reprobuild generator M2 slice requires executable "
                   "target '",
                   gt->GetName(), "' to have at least one C or CXX source."));
        return;
      }

      std::vector<std::string> objects;
      for (cmSourceFile const* source : sources) {
        std::string const lang = source->GetLanguage();
        if (lang != "C" && lang != "CXX") {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("The Reprobuild generator M2 slice supports only C and "
                     "CXX object sources; source '",
                     source->GetFullPath(), "' uses language '", lang, "'."));
          return;
        }
        usedLanguages.insert(lang);

        std::string const objFull =
          cmStrCat(gt->GetObjectDirectory(config), gt->GetObjectName(source));
        std::string const objRel = ReprobuildRelativeTo(binaryDir, objFull);
        objects.push_back(objRel);

        std::vector<std::string> args;
        std::string flags;
        lg->GetTargetCompileFlags(gt, config, lang, flags, "");
        ReprobuildAppendParsed(args, flags);

        std::vector<std::string> definitions;
        gt->GetCompileDefinitions(definitions, config, lang);
        for (std::string const& def : definitions) {
          args.push_back(cmStrCat("-D", def));
        }

        std::vector<std::string> includes;
        lg->GetIncludeDirectories(includes, gt, lang, config);
        for (std::string const& include : includes) {
          args.push_back(cmStrCat("-I", include));
        }

        args.push_back("-o");
        args.push_back(objRel);
        args.push_back("-c");
        args.push_back(source->GetFullPath());

        ReprobuildAction action;
        action.Id = ReprobuildSafeId(cmStrCat("compile-", gt->GetName(), "-",
                                              objRel));
        action.Var = ReprobuildNimIdent("action", nextActionVar++, action.Id);
        action.ToolLang = lang;
        action.Args = args;
        action.Inputs = { source->GetFullPath() };
        action.Outputs = { objRel };
        action.CompileDirectory = binaryDir;
        action.CompileFile = source->GetFullPath();
        action.CompileCommand =
          cmStrCat(lg->GetMakefile()->GetSafeDefinition(
                     ReprobuildCompilerVar(lang)),
                   " ", cmJoin(args, " "));
        target.CompileActions.push_back(std::move(action));
      }

      std::string linkLang = gt->GetLinkerLanguage(config);
      if (linkLang != "C" && linkLang != "CXX") {
        linkLang = sources.front()->GetLanguage();
      }
      usedLanguages.insert(linkLang);

      std::vector<std::string> linkArgs;
      std::string const exeFlags =
        lg->GetMakefile()->GetSafeDefinition("CMAKE_EXE_LINKER_FLAGS");
      ReprobuildAppendParsed(linkArgs, exeFlags);
      std::vector<std::string> linkOptions;
      gt->GetLinkOptions(linkOptions, config, linkLang);
      cm::append(linkArgs, linkOptions);
      if (cmValue linkFlags = gt->GetProperty("LINK_FLAGS")) {
        ReprobuildAppendParsed(linkArgs, *linkFlags);
      }
      cm::append(linkArgs, objects);
      std::string const output = ReprobuildRelativeTo(binaryDir,
                                                      gt->GetFullPath(config));
      linkArgs.push_back("-o");
      linkArgs.push_back(output);

      target.LinkAction.Id =
        ReprobuildSafeId(cmStrCat("link-", gt->GetName()));
      target.LinkAction.Var =
        ReprobuildNimIdent("action", nextActionVar++, target.LinkAction.Id);
      target.LinkAction.ToolLang = linkLang;
      target.LinkAction.Args = linkArgs;
      target.LinkAction.Inputs = objects;
      target.LinkAction.Outputs = { output };
      for (ReprobuildAction const& compile : target.CompileActions) {
        target.LinkAction.Deps.push_back(compile.Id);
      }
      executableTargets.push_back(std::move(target));
    }
  }

  if (executableTargets.empty()) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      "The Reprobuild generator M2 slice requires at least one executable "
      "target.");
    return;
  }

  for (std::string const& lang : usedLanguages) {
    std::string const compiler =
      this->LocalGenerators.front()->GetMakefile()->GetSafeDefinition(
        ReprobuildCompilerVar(lang));
    if (compiler.empty()) {
      this->GetCMakeInstance()->IssueMessage(
        MessageType::FATAL_ERROR,
        cmStrCat("Missing compiler path for language ", lang,
                 " while writing Reprobuild provider."));
      return;
    }
    if (!ReprobuildWriteWrapper(cmStrCat(wrapperDir, "/", ReprobuildToolId(lang)),
                                compiler)) {
      this->GetCMakeInstance()->IssueMessage(
        MessageType::FATAL_ERROR,
        cmStrCat("Could not write Reprobuild compiler wrapper for ", lang));
      return;
    }
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
  metadata << "provider_version=2\n";
  metadata << "m2_action_state=generated\n";
  metadata << "source_dir=" << this->GetCMakeInstance()->GetHomeDirectory()
           << "\n";
  metadata << "binary_dir=" << binaryDir << "\n";
  metadata << "provider_root=" << providerDir << "\n";
  metadata << "wrapper_path=" << wrapperDir << "\n";
  metadata << "default_target=all\n";

  std::vector<std::string> languages;
  this->GetEnabledLanguages(languages);
  metadata << "enabled_languages=" << cmJoin(languages, ",") << "\n";
  std::vector<std::string> targetNames;
  for (ReprobuildTarget const& target : executableTargets) {
    targetNames.push_back(target.Name);
  }
  metadata << "targets=all,default," << cmJoin(targetNames, ",") << "\n";

  std::string const providerFile = cmStrCat(binaryDir, "/reprobuild.nim");
  cmsys::ofstream provider(providerFile.c_str());
  if (!provider) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      cmStrCat("Could not write generated Reprobuild provider: ",
               providerFile));
    return;
  }
  provider << "import repro_project_dsl\n\n";
  provider << "package cmakeReprobuild:\n"
           << "  uses:\n";
  for (std::string const& lang : usedLanguages) {
    provider << "    " << ReprobuildEscape(cmStrCat(ReprobuildToolId(lang),
                                                    " >=1.0 <2.0"))
             << "\n";
  }
  provider << "\n  build:\n";
  auto writeAction = [&provider](ReprobuildAction const& action) {
    provider << "    let " << action.Var << " = buildAction("
             << ReprobuildEscape(action.Id)
             << ", publicCliCall("
             << ReprobuildEscape(ReprobuildToolId(action.ToolLang)) << ", "
             << ReprobuildEscape(ReprobuildToolId(action.ToolLang)) << ", \"\", "
             << ReprobuildEscape(cmStrCat(ReprobuildToolId(action.ToolLang),
                                          ".call"))
             << ", @[cliArgSeq(\"args\", ";
    ReprobuildWriteStringArray(provider, action.Args);
    provider << ", cpkPositional, 0)]), deps = ";
    ReprobuildWriteStringArray(provider, action.Deps);
    provider << ", inputs = ";
    ReprobuildWriteStringArray(provider, action.Inputs);
    provider << ", outputs = ";
    ReprobuildWriteStringArray(provider, action.Outputs);
    provider << ", commandStatsId = " << ReprobuildEscape(action.Id)
             << ", dependencyPolicy = declaredOnlyDependencyPolicy())\n";
  };
  for (ReprobuildTarget const& target : executableTargets) {
    for (ReprobuildAction const& action : target.CompileActions) {
      writeAction(action);
    }
    writeAction(target.LinkAction);
    provider << "    let " << target.Var
             << " = target(" << ReprobuildEscape(target.Name) << ", "
             << target.LinkAction.Var << ")\n";
  }
  provider << "    let allTarget = aggregate(\"all\", targets = @[";
  char const* targetSep = "";
  for (ReprobuildTarget const& target : executableTargets) {
    provider << targetSep << target.Var;
    targetSep = ", ";
  }
  provider << "])\n"
           << "    discard exportTarget(\"default\", allTarget)\n"
           << "    defaultTarget(allTarget)\n";

  std::string const compileCommandsFile =
    cmStrCat(binaryDir, "/compile_commands.json");
  cmsys::ofstream compileCommands(compileCommandsFile.c_str());
  if (!compileCommands) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      cmStrCat("Could not write compile_commands.json: ",
               compileCommandsFile));
    return;
  }
  compileCommands << "[\n";
  char const* sep = "";
  for (ReprobuildTarget const& target : executableTargets) {
    for (ReprobuildAction const& action : target.CompileActions) {
      compileCommands << sep << "  {\n"
                      << "    \"directory\": "
                      << ReprobuildJsonEscape(action.CompileDirectory)
                      << ",\n"
                      << "    \"command\": "
                      << ReprobuildJsonEscape(action.CompileCommand) << ",\n"
                      << "    \"file\": "
                      << ReprobuildJsonEscape(action.CompileFile) << "\n"
                      << "  }";
      sep = ",\n";
    }
  }
  compileCommands << "\n]\n";

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
  launcherState << "action_state=generated\n";
  launcherState << "provider=" << providerFile << "\n";
  launcherState << "targets=all,default," << cmJoin(targetNames, ",")
                << "\n";
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
