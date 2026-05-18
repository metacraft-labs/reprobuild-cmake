/* Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
   file LICENSE.rst or https://cmake.org/licensing for details.  */

#include "cmGlobalReprobuildGenerator.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <map>
#include <set>
#include <sstream>
#include <utility>
#include <vector>

#include <cm/memory>
#include <cmext/algorithm>

#include "cmsys/FStream.hxx"

#include "cmCustomCommand.h"
#include "cmCustomCommandGenerator.h"
#include "cmDocumentationEntry.h"
#include "cmGlobalGeneratorFactory.h"
#include "cmGeneratorExpression.h"
#include "cmGeneratorTarget.h"
#include "cmLocalGenerator.h"
#include "cmLocalReprobuildGenerator.h"
#include "cmList.h"
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

std::string ReprobuildRspQuote(std::string const& value)
{
  if (value.empty()) {
    return "\"\"";
  }
  bool needsQuotes = false;
  for (char ch : value) {
    if (std::isspace(static_cast<unsigned char>(ch)) || ch == '"' ||
        ch == '\\') {
      needsQuotes = true;
      break;
    }
  }
  if (!needsQuotes) {
    return value;
  }
  std::string out = "\"";
  for (char ch : value) {
    if (ch == '"' || ch == '\\') {
      out.push_back('\\');
    }
    out.push_back(ch);
  }
  out.push_back('"');
  return out;
}

bool ReprobuildWriteResponseFile(std::string const& path,
                                 std::vector<std::string> const& args)
{
  cmSystemTools::MakeDirectory(cmSystemTools::GetFilenamePath(path));
  cmsys::ofstream out(path.c_str());
  if (!out) {
    return false;
  }
  for (std::string const& arg : args) {
    out << ReprobuildRspQuote(arg) << "\n";
  }
  return true;
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

bool ReprobuildWriteLaunchedWrapper(std::string const& path,
                                    std::vector<std::string> const& launcher,
                                    std::string const& executable)
{
  cmsys::ofstream wrapper(path.c_str());
  if (!wrapper) {
    return false;
  }
  wrapper << "#!/bin/sh\n";
  wrapper << "exec";
  for (std::string const& arg : launcher) {
    wrapper << " " << ReprobuildShellSingleQuote(arg);
  }
  wrapper << " " << ReprobuildShellSingleQuote(executable) << " \"$@\"\n";
  wrapper.close();
  return cmSystemTools::SetPermissions(path.c_str(), 0755).IsSuccess();
}

bool ReprobuildWriteCommandScript(std::string const& path,
                                  std::string const& workingDirectory,
                                  std::vector<std::string> const& commands)
{
  cmsys::ofstream wrapper(path.c_str());
  if (!wrapper) {
    return false;
  }
  wrapper << "#!/bin/sh\n";
  wrapper << "set -e\n";
  if (!workingDirectory.empty()) {
    wrapper << "cd " << ReprobuildShellSingleQuote(workingDirectory) << "\n";
  }
  for (std::string const& command : commands) {
    wrapper << command << "\n";
  }
  wrapper.close();
  return cmSystemTools::SetPermissions(path.c_str(), 0755).IsSuccess();
}

bool ReprobuildCompilerUsesMakeDepfile(cmMakefile const* mf,
                                       std::string const& lang)
{
  std::string const id =
    mf->GetSafeDefinition(cmStrCat("CMAKE_", lang, "_COMPILER_ID"));
  return id == "GNU" || id == "Clang" || id == "AppleClang";
}

bool ReprobuildCompilerIsMsvc(cmMakefile const* mf, std::string const& lang)
{
  return mf->GetSafeDefinition(cmStrCat("CMAKE_", lang, "_COMPILER_ID")) ==
    "MSVC";
}

std::string ReprobuildPoolProperty(cmGeneratorTarget* gt,
                                   cmSourceFile const* source,
                                   std::string const& targetProperty,
                                   std::string const& sourceProperty)
{
  if (source != nullptr) {
    if (cmValue value = source->GetProperty(sourceProperty)) {
      return *value;
    }
  }
  if (cmValue value = gt->GetProperty(targetProperty)) {
    return *value;
  }
  return std::string();
}

void ReprobuildAppendCleanFile(std::set<std::string>& cleanFiles,
                               std::string const& binaryDir,
                               std::string const& path)
{
  if (path.empty()) {
    return;
  }
  cleanFiles.insert(cmSystemTools::CollapseFullPath(path, binaryDir));
}

void ReprobuildAppendOptionList(std::vector<std::string>& args,
                                std::string const& options)
{
  if (options.empty()) {
    return;
  }
  cmList list{ options };
  for (std::string const& option : list) {
    if (!option.empty()) {
      args.push_back(option);
    }
  }
}

std::vector<std::string> ReprobuildEvaluateCleanFiles(cmLocalGenerator* lg,
                                                      std::string const& config,
                                                      cmValue value)
{
  if (!value) {
    return {};
  }
  cmList files{ cmGeneratorExpression::Evaluate(*value, lg, config) };
  return std::vector<std::string>(files.begin(), files.end());
}

struct ReprobuildAction
{
  std::string Id;
  std::string Var;
  std::string ToolId;
  std::vector<std::string> Args;
  std::vector<std::string> Inputs;
  std::vector<std::string> Outputs;
  std::vector<std::string> Deps;
  std::string Depfile;
  std::string Pool;
  std::string ResponseFile;
  std::string CompileDirectory;
  std::string CompileCommand;
  std::string CompileFile;
  bool Cacheable = true;
};

struct ReprobuildTarget
{
  std::string Name;
  std::string Var;
  std::vector<ReprobuildAction> CompileActions;
  ReprobuildAction LinkAction;
  ReprobuildAction UtilityAction;
  bool IsUtility = false;
  bool IncludeInAll = true;
};

struct ReprobuildPool
{
  std::string Name;
  unsigned int Capacity = 1;
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
  std::vector<ReprobuildPool> pools;
  std::set<std::string> cleanFiles;
  std::set<std::string> usedLanguages;
  std::set<std::string> usedTools;
  std::string const config;
  std::size_t nextActionVar = 0;
  std::size_t nextTargetVar = 0;
  std::size_t nextRsp = 0;

  pools.push_back(ReprobuildPool{ "console", 1 });
  if (cmValue poolProp =
        this->GetCMakeInstance()->GetState()->GetGlobalProperty("JOB_POOLS")) {
    cmList entries{ *poolProp };
    for (std::string const& entry : entries) {
      std::string::size_type eq = entry.find('=');
      if (eq == std::string::npos || eq == 0 || eq + 1 >= entry.size()) {
        this->GetCMakeInstance()->IssueMessage(
          MessageType::FATAL_ERROR,
          cmStrCat("Invalid Reprobuild JOB_POOLS entry '", entry,
                   "'; expected name=capacity."));
        return;
      }
      char* end = nullptr;
      unsigned long capacity = std::strtoul(entry.c_str() + eq + 1, &end, 10);
      if (end == entry.c_str() + eq + 1 || *end != '\0' || capacity == 0) {
        this->GetCMakeInstance()->IssueMessage(
          MessageType::FATAL_ERROR,
          cmStrCat("Invalid Reprobuild JOB_POOLS capacity in '", entry,
                   "'."));
        return;
      }
      pools.push_back(ReprobuildPool{
        entry.substr(0, eq), static_cast<unsigned int>(capacity) });
    }
  }

  for (auto const& lg : this->LocalGenerators) {
    for (auto const& gtPtr : lg->GetGeneratorTargets()) {
      cmGeneratorTarget* gt = gtPtr.get();
      auto const type = gt->GetType();
      if (type == cmStateEnums::INTERFACE_LIBRARY ||
          type == cmStateEnums::GLOBAL_TARGET || type == cmStateEnums::UNKNOWN_LIBRARY) {
        continue;
      }
      if (type == cmStateEnums::UTILITY) {
        std::vector<cmCustomCommand> utilityCommands =
          gt->GetPreBuildCommands();
        cm::append(utilityCommands, gt->GetPostBuildCommands());
        std::vector<std::string> commandLines;
        bool usesTerminal = false;
        std::string jobPool;
        auto appendCustomCommand = [&](cmCustomCommand const& cc) {
          cmCustomCommandGenerator ccg(cc, config, lg.get());
          for (std::string const& byproduct : ccg.GetByproducts()) {
            ReprobuildAppendCleanFile(cleanFiles,
                                      lg->GetCurrentBinaryDirectory(),
                                      byproduct);
          }
          if (cc.GetUsesTerminal()) {
            usesTerminal = true;
          } else if (jobPool.empty() && !cc.GetJobPool().empty()) {
            jobPool = cc.GetJobPool();
          }
          for (unsigned int i = 0; i < ccg.GetNumberOfCommands(); ++i) {
            std::string commandLine;
            std::string const workingDirectory = ccg.GetWorkingDirectory();
            if (!workingDirectory.empty()) {
              commandLine += "cd ";
              commandLine += ReprobuildShellSingleQuote(workingDirectory);
              commandLine += " && ";
            }
            commandLine += ReprobuildShellSingleQuote(ccg.GetCommand(i));
            ccg.AppendArguments(i, commandLine);
            commandLines.push_back(commandLine);
          }
        };
        for (cmCustomCommand const& cc : utilityCommands) {
          appendCustomCommand(cc);
        }
        std::vector<cmSourceFile*> utilitySources;
        gt->GetSourceFiles(utilitySources, config);
        for (cmSourceFile const* source : utilitySources) {
          if (cmCustomCommand const* cc = source->GetCustomCommand()) {
            appendCustomCommand(*cc);
          }
        }
        if (commandLines.empty()) {
          continue;
        }

        ReprobuildTarget target;
        target.Name = gt->GetName();
        target.Var = ReprobuildNimIdent("target", nextTargetVar++, target.Name);
        target.IsUtility = true;
        target.IncludeInAll = !gt->GetPropertyAsBool("EXCLUDE_FROM_ALL");
        target.UtilityAction.Id =
          ReprobuildSafeId(cmStrCat("custom-", gt->GetName()));
        target.UtilityAction.Var = ReprobuildNimIdent(
          "action", nextActionVar++, target.UtilityAction.Id);
        target.UtilityAction.ToolId =
          ReprobuildSafeId(cmStrCat("reprobuild-cmake-",
                                    target.UtilityAction.Var));
        target.UtilityAction.Pool = usesTerminal ? "console" : jobPool;
        target.UtilityAction.Inputs = {};
        target.UtilityAction.Outputs = {};
        target.UtilityAction.Cacheable = false;
        std::string const wrapperPath =
          cmStrCat(wrapperDir, "/", target.UtilityAction.ToolId);
        if (!ReprobuildWriteCommandScript(wrapperPath, "", commandLines)) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Could not write Reprobuild custom target wrapper: ",
                     wrapperPath));
          return;
        }
        usedTools.insert(target.UtilityAction.ToolId);
        executableTargets.push_back(std::move(target));
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

      std::map<std::string, std::string> pchActionIds;
      for (cmSourceFile const* source : sources) {
        if (!source->IsPchSource()) {
          continue;
        }
        std::string const objFull =
          cmStrCat(gt->GetObjectDirectory(config), gt->GetObjectName(source));
        std::string const objRel = ReprobuildRelativeTo(binaryDir, objFull);
        pchActionIds[source->GetFullPath()] =
          ReprobuildSafeId(cmStrCat("compile-", gt->GetName(), "-", objRel));
      }

      std::vector<std::string> linkObjects;
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

        cmMakefile const* mf = lg->GetMakefile();
        if (ReprobuildCompilerIsMsvc(mf, lang)) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            "The Reprobuild generator M3 slice does not support MSVC "
            "/showIncludes dependency reports yet; refusing to build without "
            "recognized dependency evidence.");
          return;
        }
        if (!ReprobuildCompilerUsesMakeDepfile(mf, lang)) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("The Reprobuild generator M3 slice supports depfiles "
                     "only for GCC-compatible C/CXX compilers; compiler id '",
                     mf->GetSafeDefinition(
                       cmStrCat("CMAKE_", lang, "_COMPILER_ID")),
                     "' is not supported."));
          return;
        }

        std::string const objFull =
          cmStrCat(gt->GetObjectDirectory(config), gt->GetObjectName(source));
        std::string const objRel = ReprobuildRelativeTo(binaryDir, objFull);
        std::string const depRel = cmStrCat(objRel, ".d");
        if (!source->IsPchSource() || mf->IsOn("CMAKE_LINK_PCH")) {
          linkObjects.push_back(objRel);
        }
        ReprobuildAppendCleanFile(cleanFiles, binaryDir, objRel);
        ReprobuildAppendCleanFile(cleanFiles, binaryDir, depRel);

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

        std::map<std::string, std::string> pchSources;
        std::vector<std::string> pchArchs = gt->GetPchArchs(config, lang);
        for (std::string const& arch : pchArchs) {
          std::string const pchSource = gt->GetPchSource(config, lang, arch);
          if (!pchSource.empty()) {
            pchSources[pchSource] = arch;
          }
        }
        bool const sourceUsesPch =
          !pchSources.empty() &&
          !source->GetProperty("SKIP_PRECOMPILE_HEADERS");
        if (sourceUsesPch) {
          std::string pchOptions;
          auto const pchIt = pchSources.find(source->GetFullPath());
          if (pchIt != pchSources.end()) {
            pchOptions =
              gt->GetPchCreateCompileOptions(config, lang, pchIt->second);
          } else {
            pchOptions = gt->GetPchUseCompileOptions(config, lang);
          }
          ReprobuildAppendOptionList(args, pchOptions);
        }

        args.push_back("-MD");
        args.push_back("-MT");
        args.push_back(objRel);
        args.push_back("-MF");
        args.push_back(depRel);
        args.push_back("-o");
        args.push_back(objRel);
        args.push_back("-c");
        args.push_back(source->GetFullPath());

        ReprobuildAction action;
        action.Id = ReprobuildSafeId(cmStrCat("compile-", gt->GetName(), "-",
                                              objRel));
        action.Var = ReprobuildNimIdent("action", nextActionVar++, action.Id);
        action.ToolId = ReprobuildToolId(lang);
        std::string const launcher = lg->GetRuleLauncher(
          gt, "RULE_LAUNCH_COMPILE", config);
        if (!launcher.empty()) {
          std::vector<std::string> launcherArgs;
          if (launcher.find(';') != std::string::npos) {
            cmList launcherList{ launcher };
            launcherArgs.assign(launcherList.begin(), launcherList.end());
          } else {
            ReprobuildAppendParsed(launcherArgs, launcher);
          }
          if (!launcherArgs.empty()) {
            action.ToolId = ReprobuildSafeId(cmStrCat("reprobuild-cmake-",
                                                      action.Var));
            std::string const wrapperPath =
              cmStrCat(wrapperDir, "/", action.ToolId);
            if (!ReprobuildWriteLaunchedWrapper(
                  wrapperPath, launcherArgs,
                  mf->GetSafeDefinition(ReprobuildCompilerVar(lang)))) {
              this->GetCMakeInstance()->IssueMessage(
                MessageType::FATAL_ERROR,
                cmStrCat("Could not write Reprobuild compiler launcher wrapper: ",
                         wrapperPath));
              return;
            }
          }
        }
        usedTools.insert(action.ToolId);
        action.Args = args;
        action.Inputs = { source->GetFullPath() };
        action.Outputs = { objRel };
        action.Depfile = depRel;
        if (sourceUsesPch) {
          for (std::string const& arch : pchArchs) {
            std::string const pchHeader = gt->GetPchHeader(config, lang, arch);
            if (!pchHeader.empty()) {
              action.Inputs.push_back(pchHeader);
            }
            std::string const pchSource = gt->GetPchSource(config, lang, arch);
            if (!source->IsPchSource() && !pchSource.empty()) {
              std::string const pchFile = gt->GetPchFile(config, lang, arch);
              if (!pchFile.empty()) {
                action.Inputs.push_back(pchFile);
              }
              auto const pchAction = pchActionIds.find(pchSource);
              if (pchAction != pchActionIds.end()) {
                action.Deps.push_back(pchAction->second);
              }
            }
          }
        }
        if (source->IsPchSource()) {
          action.Pool = ReprobuildPoolProperty(
            gt, source, "JOB_POOL_PRECOMPILE_HEADER", "JOB_POOL_COMPILE");
        } else {
          action.Pool = ReprobuildPoolProperty(gt, source, "JOB_POOL_COMPILE",
                                               "JOB_POOL_COMPILE");
        }
        action.CompileDirectory = binaryDir;
        action.CompileFile = source->GetFullPath();
        action.CompileCommand =
          cmStrCat(mf->GetSafeDefinition(ReprobuildCompilerVar(lang)),
                   " ", cmJoin(args, " "));
        std::string const argsText = cmJoin(args, " ");
        if (argsText.size() > 2048) {
          action.ResponseFile = cmStrCat("CMakeFiles/reprobuild/rsp/",
                                         action.Var, "-", nextRsp++, ".rsp");
          std::string const rspFull = cmStrCat(binaryDir, "/", action.ResponseFile);
          if (!ReprobuildWriteResponseFile(rspFull, args)) {
            this->GetCMakeInstance()->IssueMessage(
              MessageType::FATAL_ERROR,
              cmStrCat("Could not write Reprobuild response file: ", rspFull));
            return;
          }
          action.Args = { cmStrCat("@", action.ResponseFile) };
          action.Inputs.push_back(action.ResponseFile);
          ReprobuildAppendCleanFile(cleanFiles, binaryDir, action.ResponseFile);
        }
        target.CompileActions.push_back(std::move(action));
      }

      std::string linkLang = gt->GetLinkerLanguage(config);
      if (linkLang != "C" && linkLang != "CXX") {
        linkLang = sources.front()->GetLanguage();
      }
      usedLanguages.insert(linkLang);
      usedTools.insert(ReprobuildToolId(linkLang));

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
      cm::append(linkArgs, linkObjects);
      std::string const output = ReprobuildRelativeTo(binaryDir,
                                                      gt->GetFullPath(config));
      linkArgs.push_back("-o");
      linkArgs.push_back(output);
      ReprobuildAppendCleanFile(cleanFiles, binaryDir, output);

      target.LinkAction.Id =
        ReprobuildSafeId(cmStrCat("link-", gt->GetName()));
      target.LinkAction.Var =
        ReprobuildNimIdent("action", nextActionVar++, target.LinkAction.Id);
      target.LinkAction.ToolId = ReprobuildToolId(linkLang);
      target.LinkAction.Args = linkArgs;
      target.LinkAction.Inputs = linkObjects;
      target.LinkAction.Outputs = { output };
      target.LinkAction.Pool = ReprobuildPoolProperty(gt, nullptr,
                                                      "JOB_POOL_LINK", "");
      for (ReprobuildAction const& compile : target.CompileActions) {
        target.LinkAction.Deps.push_back(compile.Id);
      }
      std::string const linkArgsText = cmJoin(linkArgs, " ");
      if (linkArgsText.size() > 2048) {
        target.LinkAction.ResponseFile =
          cmStrCat("CMakeFiles/reprobuild/rsp/", target.LinkAction.Var, "-",
                   nextRsp++, ".rsp");
        std::string const rspFull =
          cmStrCat(binaryDir, "/", target.LinkAction.ResponseFile);
        if (!ReprobuildWriteResponseFile(rspFull, linkArgs)) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Could not write Reprobuild response file: ", rspFull));
          return;
        }
        target.LinkAction.Args = { cmStrCat("@", target.LinkAction.ResponseFile) };
        target.LinkAction.Inputs.push_back(target.LinkAction.ResponseFile);
        ReprobuildAppendCleanFile(cleanFiles, binaryDir,
                                  target.LinkAction.ResponseFile);
      }

      for (std::string const& cleanFile : ReprobuildEvaluateCleanFiles(
             lg.get(), config, gt->GetProperty("ADDITIONAL_CLEAN_FILES"))) {
        ReprobuildAppendCleanFile(cleanFiles,
                                  lg->GetCurrentBinaryDirectory(), cleanFile);
      }
      std::vector<cmSourceFile const*> customCommands;
      gt->GetCustomCommands(customCommands, config);
      for (cmSourceFile const* sf : customCommands) {
        cmCustomCommandGenerator ccg(*sf->GetCustomCommand(), config,
                                     lg.get());
        for (std::string const& customOutput : ccg.GetOutputs()) {
          ReprobuildAppendCleanFile(cleanFiles,
                                    lg->GetCurrentBinaryDirectory(),
                                    customOutput);
        }
        for (std::string const& byproduct : ccg.GetByproducts()) {
          ReprobuildAppendCleanFile(cleanFiles,
                                    lg->GetCurrentBinaryDirectory(),
                                    byproduct);
        }
      }
      std::vector<cmCustomCommand> buildEventCommands =
        gt->GetPreBuildCommands();
      cm::append(buildEventCommands, gt->GetPreLinkCommands());
      cm::append(buildEventCommands, gt->GetPostBuildCommands());
      for (cmCustomCommand const& cc : buildEventCommands) {
        cmCustomCommandGenerator ccg(cc, config, lg.get());
        for (std::string const& byproduct : ccg.GetByproducts()) {
          ReprobuildAppendCleanFile(cleanFiles,
                                    lg->GetCurrentBinaryDirectory(),
                                    byproduct);
        }
      }
      executableTargets.push_back(std::move(target));
    }

    for (std::string const& cleanFile : ReprobuildEvaluateCleanFiles(
           lg.get(), config,
           lg->GetMakefile()->GetProperty("ADDITIONAL_CLEAN_FILES"))) {
      ReprobuildAppendCleanFile(cleanFiles, lg->GetCurrentBinaryDirectory(),
                                cleanFile);
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

  std::string const cleanManifestFile = cmStrCat(providerDir, "/clean.manifest");
  cmsys::ofstream cleanManifest(cleanManifestFile.c_str());
  if (!cleanManifest) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      cmStrCat("Could not write Reprobuild clean manifest: ",
               cleanManifestFile));
    return;
  }
  for (std::string const& path : cleanFiles) {
    cleanManifest << path << "\n";
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
  metadata << "provider_version=3\n";
  metadata << "m2_action_state=generated\n";
  metadata << "m3_action_state=generated\n";
  metadata << "source_dir=" << this->GetCMakeInstance()->GetHomeDirectory()
           << "\n";
  metadata << "binary_dir=" << binaryDir << "\n";
  metadata << "provider_root=" << providerDir << "\n";
  metadata << "wrapper_path=" << wrapperDir << "\n";
  metadata << "clean_manifest=" << cleanManifestFile << "\n";
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
  for (std::string const& tool : usedTools) {
    provider << "    " << ReprobuildEscape(cmStrCat(tool, " >=1.0 <2.0"))
             << "\n";
  }
  provider << "\n  build:\n";
  for (ReprobuildPool const& pool : pools) {
    provider << "    discard buildPool(" << ReprobuildEscape(pool.Name)
             << ", " << pool.Capacity << "'u32)\n";
  }
  auto writeAction = [&provider](ReprobuildAction const& action) {
    provider << "    let " << action.Var << " = buildAction("
             << ReprobuildEscape(action.Id)
             << ", publicCliCall("
             << ReprobuildEscape(action.ToolId) << ", "
             << ReprobuildEscape(action.ToolId) << ", \"\", "
             << ReprobuildEscape(cmStrCat(action.ToolId, ".call"))
             << ", @[cliArgSeq(\"args\", ";
    ReprobuildWriteStringArray(provider, action.Args);
    provider << ", cpkPositional, 0)]), deps = ";
    ReprobuildWriteStringArray(provider, action.Deps);
    provider << ", inputs = ";
    ReprobuildWriteStringArray(provider, action.Inputs);
    provider << ", outputs = ";
    ReprobuildWriteStringArray(provider, action.Outputs);
    provider << ", pool = " << ReprobuildEscape(action.Pool)
             << ", poolUnits = 1'u32";
    if (!action.Depfile.empty()) {
      provider << ", depfile = " << ReprobuildEscape(action.Depfile)
               << ", dependencyPolicy = makeDepfilePolicy("
               << ReprobuildEscape(action.Depfile) << ")";
    } else {
      provider << ", dependencyPolicy = declaredOnlyDependencyPolicy()";
    }
    provider << ", cacheable = " << (action.Cacheable ? "true" : "false");
    provider << ", commandStatsId = " << ReprobuildEscape(action.Id)
             << ")\n";
  };
  for (ReprobuildTarget const& target : executableTargets) {
    if (target.IsUtility) {
      writeAction(target.UtilityAction);
      provider << "    let " << target.Var
               << " = target(" << ReprobuildEscape(target.Name) << ", "
               << target.UtilityAction.Var << ")\n";
    } else {
      for (ReprobuildAction const& action : target.CompileActions) {
        writeAction(action);
      }
      writeAction(target.LinkAction);
      provider << "    let " << target.Var
               << " = target(" << ReprobuildEscape(target.Name) << ", "
               << target.LinkAction.Var << ")\n";
    }
  }
  provider << "    let allTarget = aggregate(\"all\", targets = @[";
  char const* targetSep = "";
  for (ReprobuildTarget const& target : executableTargets) {
    if (!target.IncludeInAll) {
      continue;
    }
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
    if (target.IsUtility) {
      continue;
    }
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
  bool cleanTarget = buildOptions.Clean;
  for (std::string const& targetName : targetNames) {
    if (targetName == "clean") {
      cleanTarget = true;
      break;
    }
  }
  makeCommand.Add(cmSystemTools::GetCMakeCommand());
  makeCommand.Add("--reprobuild-launch");
  makeCommand.Add(projectDir);
  makeCommand.Add(cleanTarget ? "--action=clean" : "--action=build");
  makeCommand.Add(cmStrCat("--project=", projectName));
  if (!config.empty()) {
    makeCommand.Add(cmStrCat("--config=", config));
  }
  for (std::string const& targetName : targetNames) {
    if (!targetName.empty() && targetName != "clean") {
      makeCommand.Add(cmStrCat("--target=", targetName));
    }
  }
  return { std::move(makeCommand) };
}
