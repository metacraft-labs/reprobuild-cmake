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

#include "cmComputeLinkInformation.h"
#include "cmCustomCommand.h"
#include "cmCustomCommandGenerator.h"
#include "cmDocumentationEntry.h"
#include "cmFileSetMetadata.h"
#include "cmGlobalGeneratorFactory.h"
#include "cmGeneratorExpression.h"
#include "cmGeneratorFileSet.h"
#include "cmGeneratorTarget.h"
#include "cmLinkLineComputer.h"
#include "cmLocalGenerator.h"
#include "cmLocalReprobuildGenerator.h"
#include "cmList.h"
#include "cmMakefile.h"
#include "cmPolicies.h"
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
  if (lang == "CXX") {
    return "reprobuild-cmake-cxx";
  }
  if (lang == "Fortran") {
    return "reprobuild-cmake-fortran";
  }
  return "reprobuild-cmake-cc";
}

std::string ReprobuildArchiveToolId()
{
  return "reprobuild-cmake-ar-ranlib";
}

std::string ReprobuildSymlinkToolId()
{
  return "reprobuild-cmake-symlink";
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
  wrapper << "if [ \"${1:-}\" = \"--version\" ]; then echo 1.0; exit 0; fi\n";
  if (!workingDirectory.empty()) {
    wrapper << "cd " << ReprobuildShellSingleQuote(workingDirectory) << "\n";
  }
  for (std::string const& command : commands) {
    wrapper << command << "\n";
  }
  wrapper.close();
  return cmSystemTools::SetPermissions(path.c_str(), 0755).IsSuccess();
}

bool ReprobuildWriteArchiveWrapper(std::string const& path)
{
  cmsys::ofstream wrapper(path.c_str());
  if (!wrapper) {
    return false;
  }
  wrapper << "#!/bin/sh\n";
  wrapper << "set -e\n";
  wrapper << "if [ \"${1:-}\" = \"--version\" ]; then echo 1.0; exit 0; fi\n";
  wrapper << "ar_tool=\"$1\"\n";
  wrapper << "ranlib_tool=\"$2\"\n";
  wrapper << "shift 2\n";
  wrapper << "output=\"$2\"\n";
  wrapper << "rm -f \"$output\"\n";
  wrapper << "\"$ar_tool\" \"$@\"\n";
  wrapper << "if [ -n \"$ranlib_tool\" ]; then \"$ranlib_tool\" \"$output\"; fi\n";
  wrapper.close();
  return cmSystemTools::SetPermissions(path.c_str(), 0755).IsSuccess();
}

bool ReprobuildWriteSymlinkWrapper(std::string const& path,
                                   std::string const& cmakeCommand)
{
  cmsys::ofstream wrapper(path.c_str());
  if (!wrapper) {
    return false;
  }
  wrapper << "#!/bin/sh\n";
  wrapper << "set -e\n";
  wrapper << "if [ \"${1:-}\" = \"--version\" ]; then echo 1.0; exit 0; fi\n";
  wrapper << "exec " << ReprobuildShellSingleQuote(cmakeCommand)
          << " -E cmake_symlink_library \"$@\"\n";
  wrapper.close();
  return cmSystemTools::SetPermissions(path.c_str(), 0755).IsSuccess();
}

bool ReprobuildCompilerUsesMakeDepfile(cmMakefile const* mf,
                                       std::string const& lang)
{
  if (lang == "Fortran") {
    return true;
  }
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

void ReprobuildAppendUnique(std::vector<std::string>& values,
                            std::string const& value)
{
  if (!value.empty() &&
      std::find(values.begin(), values.end(), value) == values.end()) {
    values.push_back(value);
  }
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

std::string ReprobuildOutputPath(std::string const& binaryDir,
                                 std::string const& baseDir,
                                 std::string const& path)
{
  return ReprobuildRelativeTo(binaryDir,
                              cmSystemTools::CollapseFullPath(path, baseDir));
}

std::string ReprobuildCustomDepfilePath(std::string const& binaryDir,
                                        cmLocalGenerator* lg,
                                        cmCustomCommandGenerator const& ccg)
{
  std::string depfile = ccg.GetDepfile();
  if (depfile.empty()) {
    return std::string();
  }
  std::string const base =
    ccg.GetWorkingDirectory().empty() ? lg->GetCurrentBinaryDirectory()
                                      : ccg.GetWorkingDirectory();
  return ReprobuildOutputPath(binaryDir, base, depfile);
}

std::vector<std::string> ReprobuildCustomCommandLines(
  cmCustomCommandGenerator const& ccg, bool echoComment,
  std::string const& defaultWorkingDirectory)
{
  std::vector<std::string> commandLines;
  if (echoComment) {
    if (cm::optional<std::string> comment = ccg.GetComment()) {
      commandLines.push_back(cmStrCat("echo ",
                                      ReprobuildShellSingleQuote(*comment)));
    }
  }
  for (unsigned int i = 0; i < ccg.GetNumberOfCommands(); ++i) {
    std::string workingDirectory = ccg.GetWorkingDirectory();
    if (workingDirectory.empty()) {
      workingDirectory = defaultWorkingDirectory;
    }
    std::string commandLine;
    if (!workingDirectory.empty()) {
      commandLine += "cd ";
      commandLine += ReprobuildShellSingleQuote(workingDirectory);
      commandLine += " && ";
    }
    commandLine += ReprobuildShellSingleQuote(ccg.GetCommand(i));
    ccg.AppendArguments(i, commandLine);
    commandLines.push_back(commandLine);
  }
  return commandLines;
}

bool ReprobuildWriteDyndepActionMap(
  std::string const& path,
  std::vector<std::pair<std::string, std::string>> const& entries)
{
  cmSystemTools::MakeDirectory(cmSystemTools::GetFilenamePath(path));
  cmsys::ofstream out(path.c_str());
  if (!out) {
    return false;
  }
  for (auto const& entry : entries) {
    out << entry.first << "\t" << entry.second << "\n";
  }
  return true;
}

bool ReprobuildWriteTargetDependInfo(
  std::string const& path, cmGeneratorTarget* gt, cmLocalGenerator* lg,
  std::string const& lang, std::string const& config,
  std::map<std::string, cmSourceFile const*> const& cxxModuleSources)
{
  cmSystemTools::MakeDirectory(cmSystemTools::GetFilenamePath(path));
  cmsys::ofstream out(path.c_str());
  if (!out) {
    return false;
  }
  cmMakefile const* mf = lg->GetMakefile();
  std::string moduleDir;
  if (lang == "Fortran") {
    moduleDir = gt->GetFortranModuleDirectory(mf->GetHomeOutputDirectory());
  } else {
    moduleDir = gt->ObjectDirectory;
  }
  if (moduleDir.empty()) {
    moduleDir = mf->GetCurrentBinaryDirectory();
  }
  out << "{\n"
      << "  \"language\": " << ReprobuildJsonEscape(lang) << ",\n"
      << "  \"compiler-id\": "
      << ReprobuildJsonEscape(
           mf->GetSafeDefinition(cmStrCat("CMAKE_", lang, "_COMPILER_ID")))
      << ",\n"
      << "  \"compiler-simulate-id\": "
      << ReprobuildJsonEscape(
           mf->GetSafeDefinition(cmStrCat("CMAKE_", lang, "_SIMULATE_ID")))
      << ",\n"
      << "  \"compiler-frontend-variant\": "
      << ReprobuildJsonEscape(mf->GetSafeDefinition(
           cmStrCat("CMAKE_", lang, "_COMPILER_FRONTEND_VARIANT")))
      << ",\n"
      << "  \"module-dir\": " << ReprobuildJsonEscape(moduleDir) << ",\n";
  if (lang == "Fortran") {
    out << "  \"submodule-sep\": "
        << ReprobuildJsonEscape(
             mf->GetSafeDefinition("CMAKE_Fortran_SUBMODULE_SEP"))
        << ",\n"
        << "  \"submodule-ext\": "
        << ReprobuildJsonEscape(
             mf->GetSafeDefinition("CMAKE_Fortran_SUBMODULE_EXT"))
        << ",\n";
  }
  out << "  \"dir-cur-bld\": "
      << ReprobuildJsonEscape(mf->GetCurrentBinaryDirectory()) << ",\n"
      << "  \"dir-cur-src\": "
      << ReprobuildJsonEscape(mf->GetCurrentSourceDirectory()) << ",\n"
      << "  \"dir-top-bld\": " << ReprobuildJsonEscape(mf->GetHomeOutputDirectory())
      << ",\n"
      << "  \"dir-top-src\": " << ReprobuildJsonEscape(mf->GetHomeDirectory())
      << ",\n"
      << "  \"include-dirs\": [";
  std::vector<std::string> includes;
  lg->GetIncludeDirectories(includes, gt, lang, config);
  char const* sep = "";
  for (std::string const& include : includes) {
    out << sep << ReprobuildJsonEscape(include);
    sep = ", ";
  }
  out << "],\n"
      << "  \"linked-target-dirs\": [],\n"
      << "  \"forward-modules-from-target-dirs\": [],\n";
  if (lang == "CXX") {
    out << "  \"bmi-installation\": null,\n"
        << "  \"exports\": [],\n"
        << "  \"sources\": {},\n"
        << "  \"cxx-modules\": {";
    sep = "";
    for (auto const& item : cxxModuleSources) {
      cmSourceFile const* source = item.second;
      cmGeneratorFileSet const* fs = gt->GetFileSetForSource(config, source);
      out << sep << "\n    " << ReprobuildJsonEscape(item.first) << ": {\n"
          << "      \"bmi-only\": false,\n"
          << "      \"compile-features\": [\"cxx_std_20\"],\n"
          << "      \"compile-options\": [],\n"
          << "      \"definitions\": [],\n"
          << "      \"destination\": null,\n"
          << "      \"include-directories\": [],\n"
          << "      \"name\": "
          << ReprobuildJsonEscape(fs ? fs->GetName() : "modules") << ",\n"
          << "      \"relative-directory\": \"\",\n"
          << "      \"source\": " << ReprobuildJsonEscape(source->GetFullPath())
          << ",\n"
          << "      \"type\": \"CXX_MODULES\",\n"
          << "      \"visibility\": \"PRIVATE\"\n"
          << "    }";
      sep = ",";
    }
    out << "\n  }\n";
  } else {
    out << "  \"cxx-modules\": {},\n"
        << "  \"sources\": {}\n";
  }
  out << "}\n";
  return true;
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
  std::string DynamicDepsFile;
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
  std::vector<ReprobuildAction> CustomActions;
  std::vector<ReprobuildAction> CompileActions;
  std::vector<ReprobuildAction> PreBuildActions;
  std::vector<ReprobuildAction> PreLinkActions;
  std::vector<ReprobuildAction> SymlinkActions;
  std::vector<ReprobuildAction> PostBuildActions;
  ReprobuildAction LinkAction;
  ReprobuildAction UtilityAction;
  std::vector<std::string> ObjectOutputs;
  std::vector<std::string> TargetDeps;
  bool IsUtility = false;
  bool HasLinkAction = false;
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
    if (lang != "NONE" && lang != "C" && lang != "CXX" &&
        lang != "Fortran") {
      mf->IssueMessage(
        MessageType::FATAL_ERROR,
        cmStrCat("The Reprobuild generator M6 slice supports only the C, "
                 "CXX, and Fortran languages; language '",
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
  if (!cmSystemTools::MakeDirectory(cmStrCat(providerDir, "/deps"))) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      cmStrCat("Could not create Reprobuild dependency directory: ",
               providerDir, "/deps"));
    return;
  }

  std::vector<ReprobuildTarget> buildTargets;
  std::vector<ReprobuildPool> pools;
  std::set<std::string> cleanFiles;
  std::set<std::string> usedLanguages;
  std::set<std::string> usedTools;
  bool sawImportLibraryOutput = false;
  bool sawLinkDepfile = false;
  bool sawSymlinkOutput = false;
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
        std::vector<std::string> utilityInputs;
        std::vector<std::string> utilityOutputs;
        std::string utilityDepfile;
        auto appendCustomCommand = [&](cmCustomCommand const& cc) {
          cmCustomCommandGenerator ccg(cc, config, lg.get());
          if (utilityDepfile.empty()) {
            utilityDepfile = ReprobuildCustomDepfilePath(binaryDir, lg.get(),
                                                         ccg);
          }
          for (std::string const& output : ccg.GetOutputs()) {
            utilityOutputs.push_back(ReprobuildOutputPath(
              binaryDir, lg->GetCurrentBinaryDirectory(), output));
            ReprobuildAppendCleanFile(cleanFiles,
                                      lg->GetCurrentBinaryDirectory(),
                                      output);
          }
          for (std::string const& byproduct : ccg.GetByproducts()) {
            utilityOutputs.push_back(ReprobuildOutputPath(
              binaryDir, lg->GetCurrentBinaryDirectory(), byproduct));
            ReprobuildAppendCleanFile(cleanFiles,
                                      lg->GetCurrentBinaryDirectory(),
                                      byproduct);
          }
          for (std::string const& dep : ccg.GetDepends()) {
            std::string realDep;
            if (lg->GetRealDependency(dep, config, realDep,
                                      cc.GetCMP0212Status())) {
              utilityInputs.push_back(ReprobuildOutputPath(
                binaryDir, lg->GetCurrentBinaryDirectory(), realDep));
            }
          }
          if (cc.GetUsesTerminal()) {
            usesTerminal = true;
          } else if (jobPool.empty() && !cc.GetJobPool().empty()) {
            jobPool = cc.GetJobPool();
          }
          cm::append(commandLines,
                     ReprobuildCustomCommandLines(
                       ccg, true, lg->GetCurrentBinaryDirectory()));
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
        for (auto const& utility : gt->GetUtilities()) {
          target.TargetDeps.push_back(utility.Value.first);
        }
        target.UtilityAction.Id =
          ReprobuildSafeId(cmStrCat("custom-", gt->GetName()));
        target.UtilityAction.Var = ReprobuildNimIdent(
          "action", nextActionVar++, target.UtilityAction.Id);
        target.UtilityAction.ToolId =
          ReprobuildSafeId(cmStrCat("reprobuild-cmake-",
                                    target.UtilityAction.Var));
        target.UtilityAction.Pool = usesTerminal ? "console" : jobPool;
        target.UtilityAction.Inputs = utilityInputs;
        target.UtilityAction.Outputs = utilityOutputs;
        target.UtilityAction.Depfile = utilityDepfile;
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
        buildTargets.push_back(std::move(target));
        continue;
      }
      if (type != cmStateEnums::EXECUTABLE &&
          type != cmStateEnums::STATIC_LIBRARY &&
          type != cmStateEnums::SHARED_LIBRARY &&
          type != cmStateEnums::MODULE_LIBRARY &&
          type != cmStateEnums::OBJECT_LIBRARY) {
        this->GetCMakeInstance()->IssueMessage(
          MessageType::FATAL_ERROR,
          cmStrCat("The Reprobuild generator M4 slice supports executable, "
                   "static library, shared library, module library, and "
                   "object library targets; target '",
                   gt->GetName(), "' has unsupported type ",
                   cmState::GetTargetTypeName(type), "."));
        return;
      }

      if (gt->IsImported()) {
        continue;
      }

      if (gt->IsAppBundleOnApple() || gt->IsFrameworkOnApple() ||
          gt->IsCFBundleOnApple() || gt->IsArchivedAIXSharedLibrary()) {
        this->GetCMakeInstance()->IssueMessage(
          MessageType::FATAL_ERROR,
          cmStrCat("The Reprobuild generator M4 slice does not support bundle, "
                   "framework, or archived AIX shared-library targets yet; "
                   "target '",
                   gt->GetName(), "' has unsupported type ",
                   cmState::GetTargetTypeName(type), "."));
        return;
      }

      ReprobuildTarget target;
      target.Name = gt->GetName();
      target.Var = ReprobuildNimIdent("target", nextTargetVar++, target.Name);
      target.IncludeInAll = !gt->GetPropertyAsBool("EXCLUDE_FROM_ALL");
      for (auto const& utility : gt->GetUtilities()) {
        target.TargetDeps.push_back(utility.Value.first);
      }

      std::vector<cmSourceFile const*> customCommandSources;
      gt->GetCustomCommands(customCommandSources, config);
      std::set<cmCustomCommand const*> emittedCustomCommands;
      unsigned int customIndex = 0;
      for (cmSourceFile const* customSource : customCommandSources) {
        cmCustomCommand const* cc = customSource->GetCustomCommand();
        if (cc == nullptr || !emittedCustomCommands.insert(cc).second) {
          continue;
        }
        cmCustomCommandGenerator ccg(*cc, config, lg.get());
        std::vector<std::string> commandLines =
          ReprobuildCustomCommandLines(
            ccg, true, lg->GetCurrentBinaryDirectory());
        if (commandLines.empty()) {
          continue;
        }

        ReprobuildAction custom;
        std::string const primaryOutput =
          ccg.GetOutputs().empty()
          ? cmStrCat("custom-", gt->GetName(), "-", customIndex)
          : ReprobuildOutputPath(binaryDir, lg->GetCurrentBinaryDirectory(),
                                 ccg.GetOutputs().front());
        custom.Id =
          ReprobuildSafeId(cmStrCat("custom-command-", gt->GetName(), "-",
                                    primaryOutput));
        custom.Var = ReprobuildNimIdent("action", nextActionVar++,
                                        custom.Id);
        custom.ToolId =
          ReprobuildSafeId(cmStrCat("reprobuild-cmake-", custom.Var));
        custom.Pool = cc->GetUsesTerminal() ? "console" : cc->GetJobPool();
        custom.Cacheable = true;
        for (std::string const& output : ccg.GetOutputs()) {
          custom.Outputs.push_back(ReprobuildOutputPath(
            binaryDir, lg->GetCurrentBinaryDirectory(), output));
          ReprobuildAppendCleanFile(cleanFiles,
                                    lg->GetCurrentBinaryDirectory(), output);
        }
        for (std::string const& byproduct : ccg.GetByproducts()) {
          custom.Outputs.push_back(ReprobuildOutputPath(
            binaryDir, lg->GetCurrentBinaryDirectory(), byproduct));
          ReprobuildAppendCleanFile(cleanFiles,
                                    lg->GetCurrentBinaryDirectory(),
                                    byproduct);
        }
        for (std::string const& dep : ccg.GetDepends()) {
          std::string realDep;
          if (lg->GetRealDependency(dep, config, realDep,
                                    cc->GetCMP0212Status())) {
            custom.Inputs.push_back(ReprobuildOutputPath(
              binaryDir, lg->GetCurrentBinaryDirectory(), realDep));
          }
        }
        custom.Depfile = ReprobuildCustomDepfilePath(binaryDir, lg.get(), ccg);
        if (!custom.Depfile.empty()) {
          ReprobuildAppendCleanFile(cleanFiles, binaryDir, custom.Depfile);
        }

        std::string const wrapperPath =
          cmStrCat(wrapperDir, "/", custom.ToolId);
        if (!ReprobuildWriteCommandScript(wrapperPath, "", commandLines)) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Could not write Reprobuild custom command wrapper: ",
                     wrapperPath));
          return;
        }
        usedTools.insert(custom.ToolId);
        target.CustomActions.push_back(std::move(custom));
        ++customIndex;
      }

      std::vector<cmSourceFile const*> sources;
      gt->GetObjectSources(sources, config);
      if (sources.empty()) {
        this->GetCMakeInstance()->IssueMessage(
          MessageType::FATAL_ERROR,
          cmStrCat("The Reprobuild generator M4 slice requires normal "
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

      std::map<std::string, std::vector<std::string>> dyndepDdis;
      std::map<std::string, std::vector<std::pair<std::string, std::string>>>
        dyndepActionMaps;
      std::map<std::string, std::vector<std::string>> dyndepScanActions;
      std::map<std::string, std::map<std::string, cmSourceFile const*>>
        dyndepCxxModuleSources;
      std::vector<std::string> linkObjects;
      for (cmSourceFile const* source : sources) {
        std::string const lang = source->GetLanguage();
        if (lang != "C" && lang != "CXX" && lang != "Fortran") {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("The Reprobuild generator M6 slice supports only C, "
                     "CXX, and Fortran object sources; source '",
                     source->GetFullPath(), "' uses language '", lang, "'."));
          return;
        }
        usedLanguages.insert(lang);

        cmMakefile const* mf = lg->GetMakefile();
        if (lang != "Fortran" && ReprobuildCompilerIsMsvc(mf, lang)) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            "The Reprobuild generator M3 slice does not support MSVC "
            "/showIncludes dependency reports yet; refusing to build without "
            "recognized dependency evidence.");
          return;
        }
        if (lang != "Fortran" && !ReprobuildCompilerUsesMakeDepfile(mf, lang)) {
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
        cmSystemTools::MakeDirectory(
          cmSystemTools::GetFilenamePath(cmStrCat(binaryDir, "/", objRel)));

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

        if (lang == "Fortran") {
          std::string const ppRel = cmStrCat(objRel, ".ddi.i");
          std::string const ddiRel = cmStrCat(objRel, ".ddi");
          std::string const scanDepRel = cmStrCat(ppRel, ".d");

          ReprobuildAction scan;
          scan.Id = ReprobuildSafeId(cmStrCat("scan-", gt->GetName(), "-",
                                              objRel));
          scan.Var = ReprobuildNimIdent("action", nextActionVar++, scan.Id);
          scan.ToolId = ReprobuildSafeId(cmStrCat("reprobuild-cmake-",
                                                  scan.Var));
          std::vector<std::string> scanLines;
          scanLines.push_back(cmStrCat(
            ReprobuildShellSingleQuote(
              mf->GetSafeDefinition(ReprobuildCompilerVar(lang))),
            " -cpp -E ", cmJoin(args, " "), " ",
            ReprobuildShellSingleQuote(source->GetFullPath()), " -o ",
            ReprobuildShellSingleQuote(ppRel)));
          std::string const tdiRel =
            cmStrCat("CMakeFiles/reprobuild/dyndep/", target.Var, "-",
                     lang, "DependInfo.json");
          scanLines.push_back(cmStrCat(
            ReprobuildShellSingleQuote(cmSystemTools::GetCMakeCommand()),
            " -E cmake_ninja_depends --tdi=",
            ReprobuildShellSingleQuote(tdiRel), " --lang=Fortran --src=",
            ReprobuildShellSingleQuote(ppRel), " --out=",
            ReprobuildShellSingleQuote(ppRel), " --dep=",
            ReprobuildShellSingleQuote(scanDepRel), " --obj=",
            ReprobuildShellSingleQuote(objRel), " --ddi=",
            ReprobuildShellSingleQuote(ddiRel), " --src-orig=",
            ReprobuildShellSingleQuote(source->GetFullPath())));
          std::string const scanWrapper =
            cmStrCat(wrapperDir, "/", scan.ToolId);
          if (!ReprobuildWriteCommandScript(scanWrapper, binaryDir,
                                            scanLines)) {
            this->GetCMakeInstance()->IssueMessage(
              MessageType::FATAL_ERROR,
              cmStrCat("Could not write Reprobuild Fortran scanner wrapper: ",
                       scanWrapper));
            return;
          }
          usedTools.insert(scan.ToolId);
          scan.Inputs = { source->GetFullPath(), tdiRel };
          scan.Outputs = { ppRel, ddiRel };
          scan.Depfile = scanDepRel;
          dyndepDdis[lang].push_back(ddiRel);
          dyndepScanActions[lang].push_back(scan.Id);
          dyndepActionMaps[lang].push_back({ objRel, ReprobuildSafeId(
                                                       cmStrCat("compile-",
                                                                gt->GetName(),
                                                                "-", objRel)) });
          target.CustomActions.push_back(std::move(scan));

          args.push_back("-o");
          args.push_back(objRel);
          args.push_back("-c");
          args.push_back(ppRel);
        } else {
          bool const needCxxDyndep =
            lang == "CXX" && gt->NeedDyndepForSource(lang, config, source);
          if (needCxxDyndep) {
            std::string const ddiRel = cmStrCat(objRel, ".ddi");
            std::string const scanDepRel = cmStrCat(ddiRel, ".d");
            ReprobuildAction scan;
            scan.Id = ReprobuildSafeId(cmStrCat("scan-", gt->GetName(), "-",
                                                objRel));
            scan.Var = ReprobuildNimIdent("action", nextActionVar++,
                                          scan.Id);
            scan.ToolId = ReprobuildSafeId(cmStrCat("reprobuild-cmake-",
                                                    scan.Var));
            std::string const scanner =
              mf->GetSafeDefinition("CMAKE_CXX_COMPILER_CLANG_SCAN_DEPS");
            if (scanner.empty()) {
              this->GetCMakeInstance()->IssueMessage(
                MessageType::FATAL_ERROR,
                "The Reprobuild generator M6 CXX module path requires "
                "CMAKE_CXX_COMPILER_CLANG_SCAN_DEPS.");
              return;
            }
            std::vector<std::string> scanLines;
            scanLines.push_back(cmStrCat(
              ReprobuildShellSingleQuote(scanner), " -format=p1689 -- ",
              ReprobuildShellSingleQuote(
                mf->GetSafeDefinition(ReprobuildCompilerVar(lang))),
              " ", cmJoin(args, " "), " -x c++ ",
              ReprobuildShellSingleQuote(source->GetFullPath()), " -c -o ",
              ReprobuildShellSingleQuote(objRel), " -MT ",
              ReprobuildShellSingleQuote(ddiRel), " -MD -MF ",
              ReprobuildShellSingleQuote(scanDepRel), " > ",
              ReprobuildShellSingleQuote(ddiRel)));
            std::string const scanWrapper =
              cmStrCat(wrapperDir, "/", scan.ToolId);
            if (!ReprobuildWriteCommandScript(scanWrapper, binaryDir,
                                              scanLines)) {
              this->GetCMakeInstance()->IssueMessage(
                MessageType::FATAL_ERROR,
                cmStrCat("Could not write Reprobuild CXX scanner wrapper: ",
                         scanWrapper));
              return;
            }
            usedTools.insert(scan.ToolId);
            scan.Inputs = { source->GetFullPath() };
            scan.Outputs = { ddiRel };
            scan.Depfile = scanDepRel;
            dyndepDdis[lang].push_back(ddiRel);
            dyndepScanActions[lang].push_back(scan.Id);
            dyndepActionMaps[lang].push_back({ objRel, ReprobuildSafeId(
                                                         cmStrCat("compile-",
                                                                  gt->GetName(),
                                                                  "-", objRel)) });
            if (cmGeneratorFileSet const* fs =
                  gt->GetFileSetForSource(config, source)) {
              if (fs->GetType() == cm::FileSetMetadata::CXX_MODULES) {
                dyndepCxxModuleSources[lang][objRel] = source;
              }
            }
            target.CustomActions.push_back(std::move(scan));
            std::string modmapFlag =
              mf->GetSafeDefinition("CMAKE_CXX_MODULE_MAP_FLAG");
            cmSystemTools::ReplaceString(modmapFlag, "<MODULE_MAP_FILE>",
                                         cmStrCat(objRel, ".modmap"));
            ReprobuildAppendParsed(args, modmapFlag);
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
        }

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
        if (lang == "Fortran") {
          action.Inputs = { cmStrCat(objRel, ".ddi.i") };
        } else {
          action.Inputs = { source->GetFullPath() };
        }
        action.Outputs = { objRel };
        if (lang != "Fortran") {
          action.Depfile = depRel;
        }
        if (lang == "Fortran" ||
            (lang == "CXX" && gt->NeedDyndepForSource(lang, config, source))) {
          action.DynamicDepsFile =
            cmStrCat("CMakeFiles/reprobuild/dyndep/", target.Var, "-", lang,
                     ".rbdyn");
          if (lang == "CXX") {
            action.Inputs.push_back(cmStrCat(objRel, ".modmap"));
          }
        }
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

      for (auto const& item : dyndepDdis) {
        std::string const& lang = item.first;
        std::vector<std::string> const& ddis = item.second;
        if (ddis.empty()) {
          continue;
        }
        std::string const stem =
          cmStrCat("CMakeFiles/reprobuild/dyndep/", target.Var, "-", lang);
        std::string const tdiRel = cmStrCat(stem, "DependInfo.json");
        std::string const mapRel = cmStrCat(stem, ".map");
        std::string const ddRel = cmStrCat(stem, ".dd");
        std::string const fragmentRel = cmStrCat(stem, ".rbdyn");
        if (!ReprobuildWriteTargetDependInfo(
              cmStrCat(binaryDir, "/", tdiRel), gt, lg.get(), lang, config,
              dyndepCxxModuleSources[lang]) ||
            !ReprobuildWriteDyndepActionMap(
              cmStrCat(binaryDir, "/", mapRel), dyndepActionMaps[lang])) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Could not write Reprobuild ", lang,
                     " dyndep metadata for target ", gt->GetName()));
          return;
        }

        ReprobuildAction dyndep;
        dyndep.Id = ReprobuildSafeId(cmStrCat("dyndep-", gt->GetName(), "-",
                                              lang));
        dyndep.Var =
          ReprobuildNimIdent("action", nextActionVar++, dyndep.Id);
        dyndep.ToolId =
          ReprobuildSafeId(cmStrCat("reprobuild-cmake-", dyndep.Var));
        dyndep.Deps = dyndepScanActions[lang];
        dyndep.Inputs = ddis;
        dyndep.Inputs.push_back(tdiRel);
        dyndep.Inputs.push_back(mapRel);
        dyndep.Outputs = { ddRel, fragmentRel,
                           cmStrCat(cmSystemTools::GetFilenamePath(ddRel),
                                    "/", lang, "Modules.json") };
        if (lang == "CXX") {
          for (auto const& mapEntry : dyndepActionMaps[lang]) {
            dyndep.Outputs.push_back(cmStrCat(mapEntry.first, ".modmap"));
          }
        }
        dyndep.Cacheable = false;

        std::vector<std::string> dyndepLines;
        std::string command = cmStrCat(
          ReprobuildShellSingleQuote(cmSystemTools::GetCMakeCommand()),
          " -E cmake_ninja_dyndep --tdi=", ReprobuildShellSingleQuote(tdiRel),
          " --lang=", lang);
        if (lang == "CXX") {
          std::string modmapFormat =
            lg->GetMakefile()->GetSafeDefinition("CMAKE_CXX_MODULE_MAP_FORMAT");
          if (modmapFormat.empty()) {
            this->GetCMakeInstance()->IssueMessage(
              MessageType::FATAL_ERROR,
              "The Reprobuild generator M6 CXX module path requires "
              "CMAKE_CXX_MODULE_MAP_FORMAT.");
            return;
          }
          command += cmStrCat(" --modmapfmt=", modmapFormat);
        }
        command += cmStrCat(" --dd=", ReprobuildShellSingleQuote(ddRel));
        for (std::string const& ddi : ddis) {
          command += " ";
          command += ReprobuildShellSingleQuote(ddi);
        }
        dyndepLines.push_back(command);
        std::string fragmentCommand =
          "candidate='/Users/zahary/metacraft/reprobuild/build/bin/"
          "repro-cmake-dyndep-fragment'; "
          "if [ -x \"$candidate\" ]; then conv=\"$candidate\"; else "
          "conv='repro-cmake-dyndep-fragment'; fi; "
          "\"$conv\" --out ";
        fragmentCommand += ReprobuildShellSingleQuote(fragmentRel);
        fragmentCommand += " --map ";
        fragmentCommand += ReprobuildShellSingleQuote(mapRel);
        for (std::string const& ddi : ddis) {
          fragmentCommand += " ";
          fragmentCommand += ReprobuildShellSingleQuote(ddi);
        }
        dyndepLines.push_back(fragmentCommand);
        std::string const dyndepWrapper =
          cmStrCat(wrapperDir, "/", dyndep.ToolId);
        if (!ReprobuildWriteCommandScript(dyndepWrapper, binaryDir,
                                          dyndepLines)) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Could not write Reprobuild dyndep wrapper: ",
                     dyndepWrapper));
          return;
        }
        usedTools.insert(dyndep.ToolId);
        for (ReprobuildAction& compile : target.CompileActions) {
          if (compile.DynamicDepsFile == fragmentRel) {
            ReprobuildAppendUnique(compile.Deps, dyndep.Id);
          }
        }
        target.CustomActions.push_back(std::move(dyndep));
      }

      auto objectOutputFor = [&](cmGeneratorTarget* objectTarget,
                                 cmSourceFile const* source) {
        return ReprobuildRelativeTo(
          binaryDir,
          cmStrCat(objectTarget->GetObjectDirectory(config),
                   objectTarget->GetObjectName(source)));
      };
      auto appendObjectLibraryOutputs = [&](cmGeneratorTarget* objectTarget,
                                            std::vector<std::string>& objects,
                                            std::vector<std::string>& deps) {
        std::vector<cmSourceFile const*> objectSources;
        objectTarget->GetObjectSources(objectSources, config);
        for (cmSourceFile const* objectSource : objectSources) {
          std::string const objRel = objectOutputFor(objectTarget, objectSource);
          ReprobuildAppendUnique(objects, objRel);
          ReprobuildAppendUnique(
            deps, ReprobuildSafeId(cmStrCat("compile-",
                                            objectTarget->GetName(), "-",
                                            objRel)));
        }
      };

      auto appendCustomEventActions =
        [&](std::vector<cmCustomCommand> const& commands,
            std::string const& stage, std::vector<ReprobuildAction>& actions) {
          unsigned int eventIndex = 0;
          for (cmCustomCommand const& cc : commands) {
            cmCustomCommandGenerator ccg(cc, config, lg.get());
            std::vector<std::string> commandLines;
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
            if (commandLines.empty()) {
              continue;
            }

            ReprobuildAction event;
            event.Id = ReprobuildSafeId(cmStrCat(stage, "-", gt->GetName(),
                                                 "-", eventIndex++));
            event.Var = ReprobuildNimIdent("action", nextActionVar++,
                                           event.Id);
            event.ToolId =
              ReprobuildSafeId(cmStrCat("reprobuild-cmake-", event.Var));
            event.Pool = cc.GetUsesTerminal() ? "console" : cc.GetJobPool();
            event.Inputs = ccg.GetDepends();
            event.Cacheable = false;
            for (std::string const& byproduct : ccg.GetByproducts()) {
              ReprobuildAppendCleanFile(cleanFiles,
                                        lg->GetCurrentBinaryDirectory(),
                                        byproduct);
              event.Outputs.push_back(ReprobuildRelativeTo(
                binaryDir,
                cmSystemTools::CollapseFullPath(
                  byproduct, lg->GetCurrentBinaryDirectory())));
            }
            std::string const wrapperPath =
              cmStrCat(wrapperDir, "/", event.ToolId);
            if (!ReprobuildWriteCommandScript(wrapperPath, "", commandLines)) {
              this->GetCMakeInstance()->IssueMessage(
                MessageType::FATAL_ERROR,
                cmStrCat("Could not write Reprobuild build-event wrapper: ",
                         wrapperPath));
              return false;
            }
            usedTools.insert(event.ToolId);
            actions.push_back(std::move(event));
          }
          return true;
        };

      if (!appendCustomEventActions(gt->GetPreBuildCommands(), "pre-build",
                                    target.PreBuildActions) ||
          !appendCustomEventActions(gt->GetPreLinkCommands(), "pre-link",
                                    target.PreLinkActions) ||
          !appendCustomEventActions(gt->GetPostBuildCommands(), "post-build",
                                    target.PostBuildActions)) {
        return;
      }
      for (ReprobuildAction& compile : target.CompileActions) {
        for (ReprobuildAction const& preBuild : target.PreBuildActions) {
          ReprobuildAppendUnique(compile.Deps, preBuild.Id);
        }
      }

      for (ReprobuildAction const& compile : target.CompileActions) {
        target.ObjectOutputs.insert(target.ObjectOutputs.end(),
                                    compile.Outputs.begin(),
                                    compile.Outputs.end());
      }

      if (type == cmStateEnums::OBJECT_LIBRARY) {
        buildTargets.push_back(std::move(target));
        continue;
      }

      std::string linkLang = gt->GetLinkerLanguage(config);
      if (linkLang != "C" && linkLang != "CXX") {
        linkLang = sources.front()->GetLanguage();
      }
      usedLanguages.insert(linkLang);

      target.LinkAction.Id =
        ReprobuildSafeId(cmStrCat("link-", gt->GetName()));
      target.LinkAction.Var =
        ReprobuildNimIdent("action", nextActionVar++, target.LinkAction.Id);
      target.LinkAction.Pool = ReprobuildPoolProperty(gt, nullptr,
                                                      "JOB_POOL_LINK", "");
      for (ReprobuildAction const& compile : target.CompileActions) {
        ReprobuildAppendUnique(target.LinkAction.Deps, compile.Id);
      }
      for (ReprobuildAction& preLink : target.PreLinkActions) {
        for (ReprobuildAction const& compile : target.CompileActions) {
          ReprobuildAppendUnique(preLink.Deps, compile.Id);
        }
      }

      std::vector<std::string> linkDependencyActions;
      auto appendLinkedTarget = [&](cmGeneratorTarget const* depTargetConst) {
        cmGeneratorTarget* depTarget =
          const_cast<cmGeneratorTarget*>(depTargetConst);
        if (!depTarget || depTarget->IsImported()) {
          return;
        }
        auto depType = depTarget->GetType();
        if (type == cmStateEnums::STATIC_LIBRARY &&
            depType != cmStateEnums::OBJECT_LIBRARY) {
          return;
        }
        if (depType == cmStateEnums::OBJECT_LIBRARY) {
          appendObjectLibraryOutputs(depTarget, linkObjects,
                                     linkDependencyActions);
          return;
        }
        if (depType == cmStateEnums::STATIC_LIBRARY ||
            depType == cmStateEnums::SHARED_LIBRARY ||
            depType == cmStateEnums::MODULE_LIBRARY ||
            depType == cmStateEnums::EXECUTABLE) {
          cmStateEnums::ArtifactType artifact =
            depTarget->HasImportLibrary(config)
            ? cmStateEnums::ImportLibraryArtifact
            : cmStateEnums::RuntimeBinaryArtifact;
          std::string const depPath = ReprobuildRelativeTo(
            binaryDir, depTarget->GetFullPath(config, artifact, true));
          ReprobuildAppendUnique(linkObjects, depPath);
          ReprobuildAppendUnique(linkDependencyActions,
                                ReprobuildSafeId(cmStrCat("link-",
                                                          depTarget->GetName())));
        }
      };

      std::vector<cmSourceFile const*> externalObjects;
      gt->GetExternalObjects(externalObjects, config);
      for (cmSourceFile const* externalObject : externalObjects) {
        std::string const& objLib = externalObject->GetObjectLibrary();
        if (!objLib.empty()) {
          appendLinkedTarget(lg->FindGeneratorTargetToUse(objLib));
        } else {
          ReprobuildAppendUnique(
            linkObjects, ReprobuildRelativeTo(binaryDir,
                                              externalObject->GetFullPath()));
        }
      }
      if (cmComputeLinkInformation* cli = gt->GetLinkInformation(config)) {
        for (cmComputeLinkInformation::Item const& item : cli->GetItems()) {
          if (item.Target) {
            appendLinkedTarget(item.Target);
          } else if (item.ObjectSource) {
            std::string const& objLib = item.ObjectSource->GetObjectLibrary();
            if (!objLib.empty()) {
              appendLinkedTarget(lg->FindGeneratorTargetToUse(objLib));
            } else {
              ReprobuildAppendUnique(
                linkObjects,
                ReprobuildRelativeTo(binaryDir,
                                      item.ObjectSource->GetFullPath()));
            }
          }
        }
      }
      for (std::string const& depAction : linkDependencyActions) {
        for (ReprobuildAction& preLink : target.PreLinkActions) {
          ReprobuildAppendUnique(preLink.Deps, depAction);
        }
        ReprobuildAppendUnique(target.LinkAction.Deps, depAction);
      }
      for (ReprobuildAction const& preLink : target.PreLinkActions) {
        ReprobuildAppendUnique(target.LinkAction.Deps, preLink.Id);
      }

      std::string const output = ReprobuildRelativeTo(
        binaryDir, gt->GetFullPath(config));
      std::string const realOutput = ReprobuildRelativeTo(
        binaryDir, gt->GetFullPath(config, cmStateEnums::RuntimeBinaryArtifact,
                                   true));
      ReprobuildAppendCleanFile(cleanFiles, binaryDir, output);
      ReprobuildAppendCleanFile(cleanFiles, binaryDir, realOutput);

      if (type == cmStateEnums::STATIC_LIBRARY) {
        usedTools.insert(ReprobuildArchiveToolId());
        std::string const arTool =
          lg->GetMakefile()->GetSafeDefinition("CMAKE_AR");
        std::string const ranlibTool =
          lg->GetMakefile()->GetSafeDefinition("CMAKE_RANLIB");
        if (arTool.empty()) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Missing CMAKE_AR while writing static library target ",
                     gt->GetName()));
          return;
        }
        target.LinkAction.ToolId = ReprobuildArchiveToolId();
        target.LinkAction.Args = { arTool, ranlibTool, "qc", output };
        cm::append(target.LinkAction.Args, linkObjects);
        target.LinkAction.Inputs = linkObjects;
        target.LinkAction.Outputs = { output };
      } else {
        usedTools.insert(ReprobuildToolId(linkLang));
        std::string flags;
        std::string linkFlags;
        std::string linkLibs;
        std::string frameworkPath;
        std::string linkPath;
        cmLinkLineComputer linkLineComputer(
          lg.get(), lg->GetStateSnapshot().GetDirectory());
        lg->GetTargetFlags(&linkLineComputer, config, linkLibs, flags,
                           linkFlags, frameworkPath, linkPath, gt);
        lg->AppendDependencyInfoLinkerFlags(linkFlags, gt, config, linkLang);
        if (cmComputeLinkInformation* cli = gt->GetLinkInformation(config)) {
          std::string const rpath = linkLineComputer.ComputeRPath(*cli);
          if (!rpath.empty()) {
            if (!linkFlags.empty()) {
              linkFlags += " ";
            }
            linkFlags += rpath;
          }
        }
        std::vector<std::string> linkArgs;
        ReprobuildAppendParsed(linkArgs, flags);
        ReprobuildAppendParsed(linkArgs, linkFlags);
        ReprobuildAppendParsed(linkArgs, frameworkPath);
        ReprobuildAppendParsed(linkArgs, linkPath);
        if (gt->HasSOName(config)) {
          cmGeneratorTarget::Names const names = gt->GetLibraryNames(config);
          std::string soname = names.SharedObject;
          if (gt->GetType() == cmStateEnums::SHARED_LIBRARY) {
            soname = cmStrCat(gt->GetInstallNameDirForBuildTree(config),
                              soname);
          }
          std::string const soFlag = lg->GetMakefile()->GetSONameFlag(linkLang);
          if (!soFlag.empty()) {
            if (std::isspace(static_cast<unsigned char>(soFlag.back())) ||
                !cmHasSuffix(soFlag, ",")) {
              std::string trimmed = soFlag;
              while (!trimmed.empty() &&
                     std::isspace(static_cast<unsigned char>(trimmed.back()))) {
                trimmed.pop_back();
              }
              linkArgs.push_back(trimmed);
              linkArgs.push_back(soname);
            } else {
              linkArgs.push_back(cmStrCat(soFlag, soname));
            }
          }
        }
        linkArgs.push_back("-o");
        linkArgs.push_back(realOutput);
        cm::append(linkArgs, linkObjects);
        ReprobuildAppendParsed(linkArgs, linkLibs);
        target.LinkAction.ToolId = ReprobuildToolId(linkLang);
        target.LinkAction.Args = linkArgs;
        target.LinkAction.Inputs = linkObjects;
        target.LinkAction.Outputs = { realOutput };
        if (gt->HasImportLibrary(config)) {
          std::string const importOutput = ReprobuildRelativeTo(
            binaryDir,
            gt->GetFullPath(config, cmStateEnums::ImportLibraryArtifact, true));
          if (!importOutput.empty()) {
            ReprobuildAppendCleanFile(cleanFiles, binaryDir, importOutput);
            ReprobuildAppendUnique(target.LinkAction.Outputs, importOutput);
            sawImportLibraryOutput = true;
          }
        }
        if (gt->HasLinkDependencyFile(config)) {
          target.LinkAction.Depfile = lg->GetLinkDependencyFile(gt, config);
          ReprobuildAppendCleanFile(cleanFiles, binaryDir,
                                    target.LinkAction.Depfile);
          sawLinkDepfile = true;
        }
      }
      target.HasLinkAction = true;

      if (type == cmStateEnums::SHARED_LIBRARY && output != realOutput) {
        cmGeneratorTarget::Names const names = gt->GetLibraryNames(config);
        std::string const soName = ReprobuildRelativeTo(
          binaryDir,
          cmStrCat(gt->GetDirectory(config), "/", names.SharedObject));
        ReprobuildAction symlinkAction;
        symlinkAction.Id =
          ReprobuildSafeId(cmStrCat("symlink-", gt->GetName()));
        symlinkAction.Var = ReprobuildNimIdent("action", nextActionVar++,
                                               symlinkAction.Id);
        symlinkAction.ToolId = ReprobuildSymlinkToolId();
        symlinkAction.Args = { realOutput, soName, output };
        symlinkAction.Inputs = { realOutput };
        symlinkAction.Outputs = { output };
        if (soName != output && soName != realOutput) {
          symlinkAction.Outputs.insert(symlinkAction.Outputs.begin(), soName);
          ReprobuildAppendCleanFile(cleanFiles, binaryDir, soName);
        }
        ReprobuildAppendCleanFile(cleanFiles, binaryDir, output);
        symlinkAction.Deps = { target.LinkAction.Id };
        usedTools.insert(ReprobuildSymlinkToolId());
        sawSymlinkOutput = true;
        target.SymlinkActions.push_back(std::move(symlinkAction));
      }

      std::string finalDep = target.LinkAction.Id;
      if (!target.SymlinkActions.empty()) {
        finalDep = target.SymlinkActions.back().Id;
      }
      for (ReprobuildAction& postBuild : target.PostBuildActions) {
        ReprobuildAppendUnique(postBuild.Deps, finalDep);
        finalDep = postBuild.Id;
      }
      std::string const linkArgsText = cmJoin(target.LinkAction.Args, " ");
      if (type != cmStateEnums::STATIC_LIBRARY && linkArgsText.size() > 2048) {
        std::vector<std::string> rspArgs = target.LinkAction.Args;
        target.LinkAction.ResponseFile =
          cmStrCat("CMakeFiles/reprobuild/rsp/", target.LinkAction.Var, "-",
                   nextRsp++, ".rsp");
        std::string const rspFull =
          cmStrCat(binaryDir, "/", target.LinkAction.ResponseFile);
        if (!ReprobuildWriteResponseFile(rspFull, rspArgs)) {
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
      buildTargets.push_back(std::move(target));
    }

    for (std::string const& cleanFile : ReprobuildEvaluateCleanFiles(
           lg.get(), config,
           lg->GetMakefile()->GetProperty("ADDITIONAL_CLEAN_FILES"))) {
      ReprobuildAppendCleanFile(cleanFiles, lg->GetCurrentBinaryDirectory(),
                                cleanFile);
    }
  }

  auto terminalActionIds = [](ReprobuildTarget const& target) {
    std::vector<std::string> ids;
    if (target.IsUtility) {
      ids.push_back(target.UtilityAction.Id);
      return ids;
    }
    if (!target.PostBuildActions.empty()) {
      ids.push_back(target.PostBuildActions.back().Id);
    } else if (!target.SymlinkActions.empty()) {
      ids.push_back(target.SymlinkActions.back().Id);
    } else if (target.HasLinkAction) {
      ids.push_back(target.LinkAction.Id);
    } else {
      for (ReprobuildAction const& action : target.CompileActions) {
        ids.push_back(action.Id);
      }
      if (ids.empty()) {
        for (ReprobuildAction const& action : target.CustomActions) {
          ids.push_back(action.Id);
        }
      }
    }
    return ids;
  };
  auto appendInitialDeps = [](ReprobuildTarget& target,
                              std::vector<std::string> const& deps) {
    if (deps.empty()) {
      return;
    }
    if (target.IsUtility) {
      for (std::string const& dep : deps) {
        ReprobuildAppendUnique(target.UtilityAction.Deps, dep);
      }
      return;
    }
    std::vector<ReprobuildAction*> initialActions;
    if (!target.CustomActions.empty()) {
      for (ReprobuildAction& action : target.CustomActions) {
        initialActions.push_back(&action);
      }
    } else if (!target.PreBuildActions.empty()) {
      for (ReprobuildAction& action : target.PreBuildActions) {
        initialActions.push_back(&action);
      }
    } else if (!target.CompileActions.empty()) {
      for (ReprobuildAction& action : target.CompileActions) {
        initialActions.push_back(&action);
      }
    } else if (target.HasLinkAction) {
      initialActions.push_back(&target.LinkAction);
    }
    for (ReprobuildAction* action : initialActions) {
      for (std::string const& dep : deps) {
        ReprobuildAppendUnique(action->Deps, dep);
      }
    }
  };

  std::map<std::string, std::vector<std::string>> targetTerminals;
  for (ReprobuildTarget const& target : buildTargets) {
    targetTerminals[target.Name] = terminalActionIds(target);
  }
  for (ReprobuildTarget& target : buildTargets) {
    std::vector<std::string> deps;
    for (std::string const& depName : target.TargetDeps) {
      auto const it = targetTerminals.find(depName);
      if (it != targetTerminals.end()) {
        cm::append(deps, it->second);
      }
    }
    appendInitialDeps(target, deps);
  }

  std::vector<std::string> allTargetDeps;
  for (ReprobuildTarget const& target : buildTargets) {
    if (target.IncludeInAll) {
      cm::append(allTargetDeps, terminalActionIds(target));
    }
  }

  auto addBuiltinTarget =
    [&](std::string const& name, std::vector<std::string> const& commands,
        std::vector<std::string> const& deps, bool usesTerminal) {
      ReprobuildTarget target;
      target.Name = name;
      target.Var = ReprobuildNimIdent("target", nextTargetVar++, name);
      target.IsUtility = true;
      target.IncludeInAll = false;
      target.UtilityAction.Id = ReprobuildSafeId(cmStrCat("builtin-", name));
      target.UtilityAction.Var = ReprobuildNimIdent(
        "action", nextActionVar++, target.UtilityAction.Id);
      target.UtilityAction.ToolId =
        ReprobuildSafeId(cmStrCat("reprobuild-cmake-",
                                  target.UtilityAction.Var));
      target.UtilityAction.Pool = usesTerminal ? "console" : "";
      target.UtilityAction.Deps = deps;
      target.UtilityAction.Cacheable = false;
      std::string const wrapperPath =
        cmStrCat(wrapperDir, "/", target.UtilityAction.ToolId);
      if (!ReprobuildWriteCommandScript(wrapperPath, binaryDir, commands)) {
        this->GetCMakeInstance()->IssueMessage(
          MessageType::FATAL_ERROR,
          cmStrCat("Could not write Reprobuild builtin target wrapper: ",
                   wrapperPath));
        return false;
      }
      usedTools.insert(target.UtilityAction.ToolId);
      buildTargets.push_back(std::move(target));
      return true;
    };

  std::string const cmakeCmd =
    ReprobuildShellSingleQuote(cmSystemTools::GetCMakeCommand());
  std::string const ctestCmd =
    ReprobuildShellSingleQuote(cmSystemTools::GetCTestCommand());
  std::string const cpackCmd =
    ReprobuildShellSingleQuote(cmSystemTools::GetCPackCommand());
  cmMakefile* rootMf = this->LocalGenerators.front()->GetMakefile();
  std::vector<std::string> helpTargets = { "all", "default", "clean" };
  auto addHelpTargetName = [&helpTargets](std::string const& name) {
    helpTargets.push_back(name);
  };
  bool const skipInstallRules = rootMf->IsOn("CMAKE_SKIP_INSTALL_RULES");
  if (!skipInstallRules && cmSystemTools::FileExists(
                             cmStrCat(binaryDir, "/cmake_install.cmake"))) {
    if (!addBuiltinTarget("install",
                          { cmStrCat(cmakeCmd, " -P cmake_install.cmake") },
                          allTargetDeps, true) ||
        !addBuiltinTarget("install/local",
                          { cmStrCat(cmakeCmd,
                                     " -DCMAKE_INSTALL_LOCAL_ONLY=1 -P "
                                     "cmake_install.cmake") },
                          {}, true) ||
        !addBuiltinTarget("install/strip",
                          { cmStrCat(cmakeCmd,
                                     " -DCMAKE_INSTALL_DO_STRIP=1 -P "
                                     "cmake_install.cmake") },
                          allTargetDeps, true) ||
        !addBuiltinTarget("preinstall",
                          { cmStrCat(cmakeCmd,
                                     " -E echo 'Built target preinstall'") },
                          allTargetDeps, false)) {
      return;
    }
    addHelpTargetName("install");
    addHelpTargetName("install/local");
    addHelpTargetName("install/strip");
    addHelpTargetName("preinstall");
  }
  if (rootMf->IsOn("CMAKE_TESTING_ENABLED")) {
    std::vector<std::string> testDeps = allTargetDeps;
    if (cmValue noall =
          rootMf->GetDefinition("CMAKE_SKIP_TEST_ALL_DEPENDENCY")) {
      if (noall.IsOn()) {
        testDeps.clear();
      }
    }
    cmList ctestArgs(rootMf->GetDefinition("CMAKE_CTEST_ARGUMENTS"));
    std::vector<std::string> testCommand = { ctestCmd };
    for (std::string const& arg : ctestArgs) {
      testCommand.push_back(ReprobuildShellSingleQuote(arg));
    }
    if (!addBuiltinTarget("test", { cmJoin(testCommand, " ") }, testDeps,
                          true)) {
      return;
    }
    addHelpTargetName("test");
  }
  if (cmSystemTools::FileExists(cmStrCat(binaryDir, "/CPackConfig.cmake"))) {
    std::vector<std::string> packageDeps;
    if (cmValue noPackageAll =
          rootMf->GetDefinition("CMAKE_SKIP_PACKAGE_ALL_DEPENDENCY")) {
      if (noPackageAll.IsOff()) {
        packageDeps = allTargetDeps;
      }
    } else {
      packageDeps = allTargetDeps;
    }
    if (!addBuiltinTarget(
          "package",
          { cmStrCat(cpackCmd, " --config ./CPackConfig.cmake") },
          packageDeps, false)) {
      return;
    }
    addHelpTargetName("package");
  }
  if (cmSystemTools::FileExists(cmStrCat(binaryDir,
                                         "/CPackSourceConfig.cmake"))) {
    if (!addBuiltinTarget(
          "package_source",
          { cmStrCat(cpackCmd, " --config ./CPackSourceConfig.cmake") },
          {}, false)) {
      return;
    }
    addHelpTargetName("package_source");
  }
  addHelpTargetName("help");
  addHelpTargetName("rebuild_cache");
  if (!addBuiltinTarget("help",
                        { cmStrCat("echo ",
                                   ReprobuildShellSingleQuote(cmStrCat(
                                     "The Reprobuild generator provides: ",
                                     cmJoin(helpTargets, " ")))) },
                        {}, false) ||
      !addBuiltinTarget("rebuild_cache",
                        { cmStrCat(cmakeCmd,
                                   " --regenerate-during-build -S ",
                                   ReprobuildShellSingleQuote(
                                     this->GetCMakeInstance()
                                       ->GetHomeDirectory()),
                                   " -B ",
                                   ReprobuildShellSingleQuote(binaryDir)) },
                        {}, true)) {
    return;
  }

  if (buildTargets.empty()) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      "The Reprobuild generator M4 slice requires at least one buildable "
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
  if (usedTools.count(ReprobuildArchiveToolId()) &&
      !ReprobuildWriteArchiveWrapper(
        cmStrCat(wrapperDir, "/", ReprobuildArchiveToolId()))) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      "Could not write Reprobuild archiver wrapper.");
    return;
  }
  if (usedTools.count(ReprobuildSymlinkToolId()) &&
      !ReprobuildWriteSymlinkWrapper(
        cmStrCat(wrapperDir, "/", ReprobuildSymlinkToolId()),
        cmSystemTools::GetCMakeCommand())) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      "Could not write Reprobuild symlink wrapper.");
    return;
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
  metadata << "m4_action_state=generated\n";
  metadata << "m4_import_library_outputs="
           << (sawImportLibraryOutput ? "generated"
                                      : "not_applicable_on_host")
           << "\n";
  metadata << "m4_debug_symbol_outputs=not_applicable_on_host\n";
  metadata << "m4_link_depfiles="
           << (sawLinkDepfile ? "generated" : "unsupported_by_toolchain")
           << "\n";
  metadata << "m4_symlink_outputs="
           << (sawSymlinkOutput ? "generated" : "not_required_by_targets")
           << "\n";
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
  for (ReprobuildTarget const& target : buildTargets) {
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
    if (!action.DynamicDepsFile.empty()) {
      provider << ", dynamicDepsFile = "
               << ReprobuildEscape(action.DynamicDepsFile);
    }
    provider << ", cacheable = " << (action.Cacheable ? "true" : "false");
    provider << ", commandStatsId = " << ReprobuildEscape(action.Id)
             << ")\n";
  };
  for (ReprobuildTarget const& target : buildTargets) {
    if (target.IsUtility) {
      writeAction(target.UtilityAction);
      provider << "    let " << target.Var
               << " = target(" << ReprobuildEscape(target.Name) << ", "
               << target.UtilityAction.Var << ")\n";
    } else {
      std::vector<std::string> actionVars;
      for (ReprobuildAction const& action : target.CustomActions) {
        writeAction(action);
        actionVars.push_back(action.Var);
      }
      for (ReprobuildAction const& action : target.PreBuildActions) {
        writeAction(action);
        actionVars.push_back(action.Var);
      }
      for (ReprobuildAction const& action : target.CompileActions) {
        writeAction(action);
        actionVars.push_back(action.Var);
      }
      for (ReprobuildAction const& action : target.PreLinkActions) {
        writeAction(action);
        actionVars.push_back(action.Var);
      }
      if (target.HasLinkAction) {
        writeAction(target.LinkAction);
        actionVars.push_back(target.LinkAction.Var);
      }
      for (ReprobuildAction const& action : target.SymlinkActions) {
        writeAction(action);
        actionVars.push_back(action.Var);
      }
      for (ReprobuildAction const& action : target.PostBuildActions) {
        writeAction(action);
        actionVars.push_back(action.Var);
      }
      if (target.HasLinkAction && target.PreBuildActions.empty() &&
          target.CustomActions.empty() &&
          target.PreLinkActions.empty() && target.SymlinkActions.empty() &&
          target.PostBuildActions.empty()) {
        provider << "    let " << target.Var
                 << " = target(" << ReprobuildEscape(target.Name) << ", "
                 << target.LinkAction.Var << ")\n";
      } else {
        provider << "    let " << target.Var
                 << " = target(" << ReprobuildEscape(target.Name) << ", @[";
        char const* actionSep = "";
        for (std::string const& actionVar : actionVars) {
          provider << actionSep << actionVar;
          actionSep = ", ";
        }
        provider << "])\n";
      }
    }
  }
  provider << "    let allTarget = aggregate(\"all\", targets = @[";
  char const* targetSep = "";
  for (ReprobuildTarget const& target : buildTargets) {
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
  for (ReprobuildTarget const& target : buildTargets) {
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
