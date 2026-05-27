/* Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
   file LICENSE.rst or https://cmake.org/licensing for details.  */

#include "cmGlobalReprobuildGenerator.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <map>
#include <set>
#include <sstream>
#include <tuple>
#include <utility>
#include <vector>

#include <cm/memory>
#include <cmext/algorithm>

#include "cmsys/FStream.hxx"

#include "cmComputeLinkInformation.h"
#include "cmCryptoHash.h"
#include "cmCustomCommand.h"
#include "cmCustomCommandGenerator.h"
#include "cmDocumentationEntry.h"
#include "cmFileSetMetadata.h"
#include "cmGlobalGeneratorFactory.h"
#include "cmGeneratorExpression.h"
#include "cmGeneratorFileSet.h"
#include "cmGeneratorFileSets.h"
#include "cmGeneratorTarget.h"
#include "cmLinkLineDeviceComputer.h"
#include "cmLinkLineComputer.h"
#include "cmLocalGenerator.h"
#include "cmLocalReprobuildGenerator.h"
#include "cmList.h"
#include "cmMakefile.h"
#include "cmPolicies.h"
#include "cmSourceFile.h"
#include "cmState.h"
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

std::string ReprobuildSafeId(std::string value);

// Canonicalise CMake TryCompile ephemeral tokens out of any string that
// downstream code is going to hash. CMake mints a fresh `cmTC_<hex>` target
// name for each try_compile() invocation; without canonicalisation, two
// projects asking the same CMake check (e.g. CheckIncludeFile sys/types.h)
// produce action ids and commandStats ids that differ only in that hex
// suffix, defeating the action cache.
//
// We rewrite every `cmTC_<hex>` token to a fixed `cmTC_tryCompile` token.
// The hex suffix is exactly 24 lowercase hex chars in practice (libcmake's
// `cmSystemTools::RandomSeed`-derived id, see cmCoreTryCompile.cxx) but we
// accept any non-empty run of [0-9a-fA-F] for forward-compatibility. We
// stop at the first non-hex character so adjacent non-hex text (e.g. a
// `.dir/` or `.exe` suffix) is preserved verbatim.
//
// Per Provider-Compile-Tiering.md §"Cache Scope" Phase 1 fingerprint
// canonicalisation requirements.
std::string ReprobuildCanonicaliseTryCompileTokens(std::string const& input)
{
  std::string out;
  out.reserve(input.size());
  std::size_t i = 0;
  while (i < input.size()) {
    // Look for the literal "cmTC_" sentinel and verify a non-empty hex
    // suffix follows. The sentinel itself is preserved; the hex run is
    // replaced with the canonical "tryCompile".
    if (i + 5 <= input.size() && input.compare(i, 5, "cmTC_") == 0) {
      std::size_t hexStart = i + 5;
      std::size_t j = hexStart;
      while (j < input.size()) {
        char c = input[j];
        bool isHex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
          (c >= 'A' && c <= 'F');
        if (!isHex) {
          break;
        }
        ++j;
      }
      // Real cmTC ids are >= 8 hex chars in modern CMake; insist on >= 4 to
      // avoid spurious matches against e.g. "cmTC_abc.cmake" where the tail
      // is an alphabetic identifier.
      if (j - hexStart >= 4) {
        out.append("cmTC_tryCompile");
        i = j;
        continue;
      }
    }
    out.push_back(input[i]);
    ++i;
  }
  return out;
}

// Returns the user-level reprobuild store root that hosts cross-project
// content-addressed assets (action cache, CAS, and our TryCompile source
// mirror). Mirrors the engine's resolveActionCacheRoot precedence
// (Cache-Scope.milestones §"Cache-root split"):
//   1. ${REPROBUILD_STORE_ROOT}
//   2. ${REPRO_STORE_ROOT} (compat alias)
//   3. Platform default
//      - Windows: %LOCALAPPDATA%\repro
//      - macOS:   $HOME/Library/Caches/repro
//      - Linux:   $XDG_CACHE_HOME/repro, else $HOME/.cache/repro
// Returns empty string if none can be resolved (e.g. no HOME) — callers
// must treat that as "no shared store available" and fall back to per-project
// paths rather than synthesising one.
std::string ReprobuildSharedStoreRoot()
{
  if (cm::optional<std::string> v =
        cmSystemTools::GetEnvVar("REPROBUILD_STORE_ROOT")) {
    if (!v->empty()) {
      return *v;
    }
  }
  if (cm::optional<std::string> v =
        cmSystemTools::GetEnvVar("REPRO_STORE_ROOT")) {
    if (!v->empty()) {
      return *v;
    }
  }
#ifdef _WIN32
  if (cm::optional<std::string> v =
        cmSystemTools::GetEnvVar("LOCALAPPDATA")) {
    if (!v->empty()) {
      return cmStrCat(*v, "\\repro");
    }
  }
  return std::string();
#elif defined(__APPLE__)
  if (cm::optional<std::string> v = cmSystemTools::GetEnvVar("HOME")) {
    if (!v->empty()) {
      return cmStrCat(*v, "/Library/Caches/repro");
    }
  }
  return std::string();
#else
  if (cm::optional<std::string> v =
        cmSystemTools::GetEnvVar("XDG_CACHE_HOME")) {
    if (!v->empty()) {
      return cmStrCat(*v, "/repro");
    }
  }
  if (cm::optional<std::string> v = cmSystemTools::GetEnvVar("HOME")) {
    if (!v->empty()) {
      return cmStrCat(*v, "/.cache/repro");
    }
  }
  return std::string();
#endif
}

// Stage a TryCompile test source through a content-addressed canonical
// location under the user-level reprobuild store so two projects asking the
// same CMake check probe (e.g. check_include_file(sys/types.h)) emit
// byte-identical compile-action input paths. The Reprobuild engine's strong
// fingerprint hashes input.path + content; per-project scratch paths defeat
// cross-project reuse even when the content is identical, so re-routing the
// path through a single content-addressed location is what makes a second
// project's identical probe actually hit the action cache.
//
// Failure modes (store root missing, source unreadable, copy fails) silently
// fall back to the original per-project path — the canonical-source step is
// a pure optimisation, never load-bearing.
//
// Per Cache-Scope.milestones §"Cross-project reuse: canonical source path"
// and Provider-Compile-Tiering.md §"Cache Scope".
std::string ReprobuildCanonicaliseTryCompileSourcePath(
  std::string const& originalPath)
{
  if (originalPath.empty() ||
      !cmSystemTools::FileExists(originalPath, true)) {
    return originalPath;
  }
  std::string const storeRoot = ReprobuildSharedStoreRoot();
  if (storeRoot.empty()) {
    return originalPath;
  }
  cmCryptoHash hash(cmCryptoHash::AlgoSHA256);
  std::string const digest = hash.HashFile(originalPath);
  if (digest.empty()) {
    return originalPath;
  }
  // 128 bits of digest is ample collision resistance for a user-local cache
  // and keeps the resulting path short — relevant on Windows where the
  // compiler still has to spell the path on its command line.
  std::string const shortDigest = digest.substr(0, 32);
  std::string const baseName =
    cmSystemTools::GetFilenameName(originalPath);
  std::string const canonicalDir =
    cmStrCat(storeRoot, "/cmake-trycompile-sources/", shortDigest);
  std::string const canonicalPath = cmStrCat(canonicalDir, "/", baseName);
  if (cmSystemTools::FileExists(canonicalPath, true)) {
    return canonicalPath;
  }
  if (!cmSystemTools::MakeDirectory(canonicalDir)) {
    return originalPath;
  }
  // CopyFileIfDifferent is idempotent and tolerant of two concurrent CMake
  // processes staging the same probe source at the same time — both writers
  // produce byte-identical destinations.
  if (!cmSystemTools::CopyFileIfDifferent(originalPath, canonicalPath)) {
    return originalPath;
  }
  return canonicalPath;
}

// Encodes the Tier 2a TryCompile metadata envelope written next to
// reprobuild.nim in each try_compile() scratch dir. The byte layout must
// stay in lockstep with the Nim decoder in
// ``libs/repro_cmake_trycompile/src/repro_cmake_trycompile.nim``.
//
// Format (little-endian, length-prefixed):
//   magic        "RBCT"
//   version      u16  (= 1)
//   payloadLen   u32
//   payload {
//     usedTools  : string-seq
//     pools      : u32 count + each (name: string, capacity: u32)
//     actions    : u32 count + each TryCompileAction
//     targetName : string
//     targetActionIds : string-seq
//   }
//
// TryCompileAction matches the Nim decoder's struct field-for-field.
namespace ReprobuildTryCompileEnvelope {

void AppendU16Le(std::string& out, std::uint16_t v)
{
  out.push_back(static_cast<char>(v & 0xff));
  out.push_back(static_cast<char>((v >> 8) & 0xff));
}

void AppendU32Le(std::string& out, std::uint32_t v)
{
  out.push_back(static_cast<char>(v & 0xff));
  out.push_back(static_cast<char>((v >> 8) & 0xff));
  out.push_back(static_cast<char>((v >> 16) & 0xff));
  out.push_back(static_cast<char>((v >> 24) & 0xff));
}

void AppendString(std::string& out, std::string const& s)
{
  AppendU32Le(out, static_cast<std::uint32_t>(s.size()));
  out.append(s);
}

void AppendStringSeq(std::string& out,
                     std::vector<std::string> const& items)
{
  AppendU32Le(out, static_cast<std::uint32_t>(items.size()));
  for (auto const& s : items) {
    AppendString(out, s);
  }
}

void AppendBool(std::string& out, bool v)
{
  out.push_back(static_cast<char>(v ? 1 : 0));
}

} // namespace ReprobuildTryCompileEnvelope

std::string ReprobuildSafeId(std::string value)
{
  // Canonicalise CMake TryCompile random tokens BEFORE the [^A-Za-z0-9_.-]
  // replacement. The canonicalisation walks the literal "cmTC_<hex>"
  // substrings; doing it before character normalisation keeps the match
  // logic free of post-replacement quirks. Non-TryCompile inputs are
  // unchanged because they do not contain the sentinel + hex suffix
  // pattern.
  value = ReprobuildCanonicaliseTryCompileTokens(value);
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

std::string ReprobuildCommandStatsId(std::string const& id)
{
  constexpr std::size_t maxCommandStatsIdBytes = 64;
  // The commandStats id is also user-visible bench stats output. Canonicalise
  // the TryCompile random suffix on the way in so two probes for the same
  // CMake check aggregate into one metric line. Since `id` typically comes
  // from ReprobuildSafeId() it is already canonicalised, but defend against
  // callers that compose ids out of band.
  std::string canonical = ReprobuildCanonicaliseTryCompileTokens(id);
  if (canonical.size() <= maxCommandStatsIdBytes) {
    return canonical;
  }
  cmCryptoHash hash(cmCryptoHash::AlgoSHA256);
  std::string const suffix = hash.HashString(canonical).substr(0, 16);
  return cmStrCat(canonical.substr(0, maxCommandStatsIdBytes - suffix.size() - 1),
                  "-", suffix);
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
  if (lang == "CUDA") {
    return "reprobuild-cmake-cuda";
  }
  if (lang == "CXX") {
    return "reprobuild-cmake-cxx";
  }
  if (lang == "Fortran") {
    return "reprobuild-cmake-fortran";
  }
  if (lang == "ISPC") {
    return "reprobuild-cmake-ispc";
  }
  if (lang == "Swift") {
    return "reprobuild-cmake-swift";
  }
  return "reprobuild-cmake-cc";
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

// Quote a tool path or argument for a `cmd.exe` batch file. Batch has no
// general escaping for a `"` *inside* a quoted string, but tool paths and
// the structured argv we emit here are filesystem paths / plain flags that
// never contain an embedded double quote (the POSIX wrapper bodies confirm
// this: they only ever single-quote whole paths/args). Should one ever
// appear, "" is the closest cmd.exe approximation.
std::string ReprobuildBatchQuote(std::string const& value)
{
  std::string out;
  out.reserve(value.size() + 2);
  out.push_back('"');
  for (char ch : value) {
    if (ch == '"') {
      out += "\"\"";
    } else {
      out.push_back(ch);
    }
  }
  out.push_back('"');
  return out;
}

// Emit the Windows `.cmd` shim beside an extensionless POSIX wrapper script.
//
// Windows cannot CreateProcess the `#!/bin/sh` body directly, and repro's
// PATH resolution deliberately skips extensionless files (they cannot be
// launched as Win32 apps), so a sibling `.cmd` -- discoverable via PATHEXT --
// is required.
//
// When `nativeBody` is non-empty it is a self-contained batch program that
// invokes the real tool directly (no `sh`, no delegation to the script body):
// every build action then costs one CreateProcess instead of
// cmd.exe -> MSYS sh.exe -> script -> tool. When it is empty (wrappers whose
// bodies are genuine multi-step POSIX shell) we fall back to running the
// sibling script through `sh`; `%~dpn0` is this .cmd's path minus its
// extension, i.e. the sibling wrapper script.
bool ReprobuildFinalizeWrapper(std::string const& path,
                               std::string const& nativeBody = std::string())
{
  if (!cmSystemTools::SetPermissions(path.c_str(), 0755).IsSuccess()) {
    return false;
  }
#ifdef _WIN32
  std::string const shimPath = cmStrCat(path, ".cmd");
  // cmd.exe batch files use CRLF line endings; open in binary mode so the
  // \r\n we write is preserved verbatim.
  cmsys::ofstream shim(shimPath.c_str(), std::ios::out | std::ios::binary);
  if (!shim) {
    return false;
  }
  shim << "@echo off\r\n";
  if (nativeBody.empty()) {
    shim << "sh \"%~dpn0\" %*\r\n";
  } else {
    shim << nativeBody;
    if (!cmHasSuffix(nativeBody, "\r\n")) {
      shim << "\r\n";
    }
  }
  shim.close();
#else
  static_cast<void>(nativeBody);
#endif
  return true;
}

// Native batch body for a passthrough wrapper: run the tool (optionally with
// a fixed launcher prefix) forwarding all arguments. Mirrors the POSIX body
// `exec [launcher...] '<tool>' "$@"`.
std::string ReprobuildNativePassthroughBody(
  std::vector<std::string> const& launcher, std::string const& executable)
{
  std::string body;
  for (std::string const& arg : launcher) {
    body += ReprobuildBatchQuote(arg);
    body.push_back(' ');
  }
  body += ReprobuildBatchQuote(executable);
  body += " %*\r\n";
  return body;
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
  return ReprobuildFinalizeWrapper(
    path, ReprobuildNativePassthroughBody({}, executable));
}

std::string ReprobuildParentPath(std::string const& path)
{
  std::string::size_type slash = path.find_last_of("/\\");
  if (slash == std::string::npos) {
    return std::string();
  }
  return path.substr(0, slash);
}

std::string ReprobuildBaseName(std::string const& path)
{
  std::string::size_type slash = path.find_last_of("/\\");
  if (slash == std::string::npos) {
    return path;
  }
  return path.substr(slash + 1);
}

std::string ReprobuildNixStorePath(std::string const& path)
{
  std::string const normalized = cmSystemTools::ToNormalizedPathOnDisk(path);
  std::string const prefix = "/nix/store/";
  if (normalized.rfind(prefix, 0) != 0) {
    return std::string();
  }
  std::string::size_type slash = normalized.find('/', prefix.size());
  if (slash == std::string::npos) {
    return normalized;
  }
  return normalized.substr(0, slash);
}

bool ReprobuildWriteToolProfile(std::string const& wrapperPath,
                                std::string const& executable,
                                std::string const& portabilityMode,
                                bool canRunExecutableDirectly)
{
  std::string const profilePath = wrapperPath + ".repro-tool-profile";
  cmsys::ofstream profile(profilePath.c_str());
  if (!profile) {
    return false;
  }
  std::string const executablePath =
    executable.empty() ? wrapperPath
                       : cmSystemTools::ToNormalizedPathOnDisk(executable);
  std::string const storePath = ReprobuildNixStorePath(executablePath);
  bool const portable = portabilityMode == "nix" && !storePath.empty();
  std::string const installMethod = portable ? "nix" : "path";
  std::string const binDir = ReprobuildParentPath(
    canRunExecutableDirectly ? executablePath : wrapperPath);
  std::string const declared =
    !storePath.empty() && executablePath.rfind(storePath + "/", 0) == 0
    ? executablePath.substr(storePath.size() + 1)
    : ReprobuildBaseName(executablePath);
  profile << "reprobuild-tool-profile-v1\n";
  profile << "installMethod=" << installMethod << "\n";
  profile << "packageId=" << (portable ? storePath : executablePath) << "\n";
  profile << "nixSelector=" << (portable ? cmStrCat("store:", storePath) : "")
          << "\n";
  profile << "declaredExecutablePath=" << declared << "\n";
  profile << "selectedStorePath=" << (portable ? storePath : "") << "\n";
  profile << "lockIdentity=" << (portable ? storePath : executablePath) << "\n";
  profile << "realizationBoundary=" << (portable ? storePath : "") << "\n";
  profile << "pathSearchList=" << binDir << "\n";
  profile << "resolvedExecutablePath="
          << (canRunExecutableDirectly ? executablePath : wrapperPath) << "\n";
  profile << "adapterStrength=" << (portable ? "strong" : "weak") << "\n";
  profile << "cachePortability=" << (portable ? "portable" : "local-only")
          << "\n";
  profile.close();
  return true;
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
  return ReprobuildFinalizeWrapper(
    path, ReprobuildNativePassthroughBody(launcher, executable));
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
  return ReprobuildFinalizeWrapper(path);
}

bool ReprobuildCompilerUsesMakeDepfile(cmMakefile const* mf,
                                       std::string const& lang)
{
  if (lang == "Fortran") {
    return true;
  }
  if (lang == "ISPC") {
    return mf->GetDefinition("CMAKE_ISPC_DEPENDS_USE_COMPILER").IsOn();
  }
  std::string const id =
    mf->GetSafeDefinition(cmStrCat("CMAKE_", lang, "_COMPILER_ID"));
  return id == "GNU" || id == "Clang" || id == "AppleClang" ||
    id == "NVIDIA";
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

std::string ReprobuildOutputPath(std::string const& binaryDir,
                                 std::string const& baseDir,
                                 std::string const& path);
std::string ReprobuildConfigFullPath(std::string const& binaryDir,
                                     std::string const& fullPath,
                                     std::string const& config,
                                     bool multiConfig);

std::string ReprobuildSwiftCompileModeName(cmSwiftCompileMode mode)
{
  switch (mode) {
    case cmSwiftCompileMode::Unknown:
      return "unknown";
    case cmSwiftCompileMode::Wholemodule:
      return "wholemodule";
    case cmSwiftCompileMode::Incremental:
      return "incremental";
    case cmSwiftCompileMode::Singlefile:
      return "singlefile";
  }
  return "unknown";
}

void ReprobuildAppendCommonCompileArgs(std::vector<std::string>& args,
                                       cmLocalGenerator* lg,
                                       cmGeneratorTarget* gt,
                                       std::string const& config,
                                       std::string const& lang)
{
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
}

void ReprobuildAppendSourcePropertyCompileArgs(std::vector<std::string>& args,
                                               cmLocalGenerator* lg,
                                               cmGeneratorTarget* gt,
                                               cmSourceFile const* source,
                                               std::string const& config,
                                               std::string const& lang)
{
  cmGeneratorExpressionInterpreter genexInterpreter(lg, config, gt, lang);

  std::string const compileFlagsProp("COMPILE_FLAGS");
  if (cmValue compileFlags = source->GetProperty(compileFlagsProp)) {
    ReprobuildAppendParsed(
      args, genexInterpreter.Evaluate(*compileFlags, compileFlagsProp));
  }

  std::string const compileOptionsProp("COMPILE_OPTIONS");
  if (cmValue compileOptions = source->GetProperty(compileOptionsProp)) {
    ReprobuildAppendOptionList(
      args, genexInterpreter.Evaluate(*compileOptions, compileOptionsProp));
  }

  if (auto const* fileSet =
        gt->GetGeneratorFileSets()->GetFileSetForSource(config, source)) {
    auto options = fileSet->BelongsTo(gt)
      ? fileSet->GetCompileOptions(config, lang)
      : fileSet->GetInterfaceCompileOptions(config, lang);
    for (BT<std::string> const& option : options) {
      ReprobuildAppendOptionList(args, option.Value);
    }
  }
}

std::string ReprobuildSwiftOutputMapPath(std::string const& binaryDir,
                                         cmGeneratorTarget* gt,
                                         std::string const& config,
                                         bool multiConfig)
{
  std::string const suffix = config.empty() ? std::string() : cmStrCat("/", config);
  return ReprobuildConfigFullPath(
    binaryDir,
    cmStrCat(gt->GetSupportDirectory(), suffix, "/output-file-map.json"),
    config, multiConfig);
}

std::string ReprobuildSwiftDepsPath(std::string const& binaryDir,
                                    cmGeneratorTarget* gt,
                                    cmSourceFile const* source,
                                    std::string const& objectRel)
{
  if (source) {
    if (cmValue value = source->GetProperty("Swift_DEPENDENCIES_FILE")) {
      return ReprobuildOutputPath(binaryDir, gt->Makefile->GetCurrentBinaryDirectory(), *value);
    }
  }
  return cmStrCat(objectRel, ".swiftdeps");
}

std::string ReprobuildSwiftDiagnosticsPath(std::string const& binaryDir,
                                           cmGeneratorTarget* gt,
                                           cmSourceFile const* source,
                                           std::string const& objectRel)
{
  if (source) {
    if (cmValue value = source->GetProperty("Swift_DIAGNOSTICS_FILE")) {
      return ReprobuildOutputPath(binaryDir, gt->Makefile->GetCurrentBinaryDirectory(), *value);
    }
  }
  return cmStrCat(objectRel, ".dia");
}

bool ReprobuildWriteSwiftOutputMap(
  std::string const& path, std::string const& binaryDir,
  cmGeneratorTarget* gt,
  std::vector<cmSourceFile const*> const& swiftSources,
  std::vector<std::string> const& objectRels, std::string const& config)
{
  cmSystemTools::MakeDirectory(cmSystemTools::GetFilenamePath(path));
  cmsys::ofstream out(path.c_str());
  if (!out) {
    return false;
  }
  std::string targetDepsPath;
  if (cmValue value = gt->GetProperty("Swift_DEPENDENCIES_FILE")) {
    targetDepsPath =
      ReprobuildOutputPath(binaryDir, gt->Makefile->GetCurrentBinaryDirectory(), *value);
  } else {
    std::string const suffix = config.empty() ? std::string() : cmStrCat("/", config);
    targetDepsPath = ReprobuildRelativeTo(
      binaryDir,
      cmStrCat(gt->GetSupportDirectory(), suffix, "/", gt->GetName(),
               ".swiftdeps"));
  }
  out << "{\n"
      << "  \"\": {\n"
      << "    \"swift-dependencies\": "
      << ReprobuildJsonEscape(targetDepsPath) << "\n"
      << "  }";
  for (std::size_t i = 0; i < swiftSources.size(); ++i) {
    std::string const& objectRel = objectRels[i];
    std::string const depRel = cmStrCat(objectRel, ".d");
    out << ",\n  " << ReprobuildJsonEscape(swiftSources[i]->GetFullPath())
        << ": {\n"
        << "    \"object\": " << ReprobuildJsonEscape(objectRel) << ",\n"
        << "    \"dependencies\": " << ReprobuildJsonEscape(depRel)
        << ",\n"
        << "    \"swift-dependencies\": "
        << ReprobuildJsonEscape(ReprobuildSwiftDepsPath(
             binaryDir, gt, swiftSources[i], objectRel))
        << ",\n"
        << "    \"diagnostics\": "
        << ReprobuildJsonEscape(ReprobuildSwiftDiagnosticsPath(
             binaryDir, gt, swiftSources[i], objectRel))
        << "\n"
        << "  }";
  }
  out << "\n}\n";
  return true;
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

// Try to extract a raw argv (vector<string>) for command `c` of `ccg`
// without going through shell quoting. Returns empty when the command
// cannot be safely inlined (multi-emulator setups where the engine would
// need to layer extra arguments are routed through the legacy
// shell-wrapper path instead).
//
// The returned argv is what would be passed to a direct CreateProcess /
// posix_spawn for that one command: argv[0] is the resolved executable
// (which already accounts for `cmake -E …` renames and CROSSCOMPILING
// adjustments inside `ccg.GetCommand`), and argv[1..] are the original
// raw arguments from the custom command's command line (no shell quoting,
// no `cd` prefix, no `&&` chaining).
std::vector<std::string> ReprobuildCustomCommandArgv(
  cmCustomCommandGenerator const& ccg, unsigned int c)
{
  std::vector<std::string> argv;
  std::string const exe = ccg.GetCommand(c);
  if (exe.empty()) {
    return argv;
  }
  cmCustomCommandLines const& lines = ccg.GetCC().GetCommandLines();
  if (c >= lines.size() || lines[c].empty()) {
    argv.push_back(exe);
    return argv;
  }
  argv.push_back(exe);
  for (std::size_t j = 1; j < lines[c].size(); ++j) {
    argv.push_back(lines[c][j]);
  }
  return argv;
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

  // When `Inline` is true, the action is emitted as
  // `inlineExecCall(@argv, cwd)` instead of `publicCliCall(<package>, …)`,
  // and no synthetic per-action package is added to `uses:` or written as a
  // wrapper script. The engine's `reprobuild.builtin.exec` lowering takes
  // over and launches `InlineArgv` directly. Used for CMake custom commands
  // and other build edges whose absolute argv is fully known at generate
  // time and that do not need a typed-tool identity.
  bool Inline = false;
  std::vector<std::string> InlineArgv;
  std::string InlineCwd;
};

struct ReprobuildHcrObject
{
  std::string Source;
  std::string Object;
  std::string CompileAction;
  std::string Language;
};

struct ReprobuildTarget
{
  std::string BaseName;
  std::string Name;
  std::string Var;
  std::string OutputConfig;
  std::string CommandConfig;
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
  std::vector<ReprobuildHcrObject> HcrObjects;
  std::string HcrProfile;
  std::string HcrLinkOutput;
  std::string HcrLinkGraph;
  std::string HcrLinkGraphAction;
  bool IsUtility = false;
  bool HasLinkAction = false;
  bool IncludeInAll = true;
  bool IsCrossConfig = false;
  bool HcrEnabled = false;
};

struct ReprobuildPool
{
  std::string Name;
  unsigned int Capacity = 1;
};

struct ReprobuildConfigPair
{
  std::string OutputConfig;
  std::string CommandConfig;
  bool IsCrossConfig = false;
};

std::string ReprobuildConfigSuffix(std::string const& outputConfig,
                                   std::string const& commandConfig,
                                   bool multiConfig)
{
  if (!multiConfig) {
    return "";
  }
  if (outputConfig == commandConfig) {
    return cmStrCat("-", outputConfig);
  }
  return cmStrCat("-", outputConfig, "-from-", commandConfig);
}

std::string ReprobuildTargetName(std::string const& baseName,
                                 std::string const& outputConfig,
                                 std::string const& commandConfig,
                                 bool multiConfig)
{
  if (!multiConfig) {
    return baseName;
  }
  if (outputConfig == commandConfig) {
    return cmStrCat(baseName, ":", outputConfig);
  }
  return cmStrCat(baseName, ":", outputConfig, ":", commandConfig);
}

std::string ReprobuildConfigPath(std::string const& rel,
                                 std::string const& config, bool multiConfig)
{
  if (!multiConfig || config.empty() || rel.empty() ||
      cmSystemTools::FileIsFullPath(rel)) {
    return rel;
  }
  if (rel == config || cmHasPrefix(rel, cmStrCat(config, "/"))) {
    return rel;
  }
  if (cmHasLiteralPrefix(rel, "CMakeFiles/reprobuild/")) {
    return rel;
  }
  std::string::size_type dirPos = rel.find(".dir/");
  if (cmHasLiteralPrefix(rel, "CMakeFiles/") && dirPos != std::string::npos) {
    dirPos += 5;
    if (cmHasPrefix(rel.substr(dirPos), cmStrCat(config, "/"))) {
      return rel;
    }
    return cmStrCat(rel.substr(0, dirPos), config, "/",
                    rel.substr(dirPos));
  }
  return cmStrCat(config, "/", rel);
}

std::string ReprobuildConfigFullPath(std::string const& binaryDir,
                                     std::string const& fullPath,
                                     std::string const& config,
                                     bool multiConfig)
{
  std::string rel = ReprobuildRelativeTo(binaryDir, fullPath);
  return ReprobuildConfigPath(rel, config, multiConfig);
}

bool ReprobuildListSubsetWithAll(std::set<std::string> const& all,
                                 std::set<std::string> const& defaults,
                                 std::vector<std::string> const& items,
                                 std::set<std::string>& result)
{
  result.clear();
  for (std::string const& item : items) {
    if (item == "all") {
      if (items.size() == 1) {
        result = defaults;
      } else {
        return false;
      }
    } else if (all.count(item)) {
      result.insert(item);
    } else {
      return false;
    }
  }
  return true;
}

bool ReprobuildStringHasFlag(std::vector<std::string> const& args,
                             std::string const& flag)
{
  return std::find(args.begin(), args.end(), flag) != args.end();
}

bool ReprobuildContainsLtoFlag(std::vector<std::string> const& args)
{
  for (std::string const& arg : args) {
    if (arg == "-flto" || cmHasLiteralPrefix(arg, "-flto=") ||
        arg == "-fuse-linker-plugin" || arg == "/GL") {
      return true;
    }
  }
  return false;
}

bool ReprobuildContainsNoDebugFlag(std::vector<std::string> const& args)
{
  for (std::string const& arg : args) {
    if (arg == "-g0" || arg == "/DEBUG:NONE") {
      return true;
    }
  }
  return false;
}

bool ReprobuildCompilerSupportsHcr(std::string const& compilerId)
{
  return compilerId == "GNU" || compilerId == "Clang" ||
    compilerId == "AppleClang";
}

bool ReprobuildTargetHcrEnabled(cmGeneratorTarget const* gt,
                                cmMakefile const* mf)
{
  if (cmValue prop = gt->GetProperty("REPROBUILD_HCR")) {
    return cmIsOn(*prop);
  }
  return mf->IsOn("CMAKE_REPROBUILD_HCR");
}

void ReprobuildAppendHcrCompilePolicy(std::vector<std::string>& args)
{
  if (!ReprobuildStringHasFlag(args, "-g")) {
    args.push_back("-g");
  }
  if (!ReprobuildStringHasFlag(args, "-fpatchable-function-entry=2,0")) {
    args.push_back("-fpatchable-function-entry=2,0");
  }
  if (!ReprobuildStringHasFlag(args, "-fno-inline")) {
    args.push_back("-fno-inline");
  }
  if (!ReprobuildStringHasFlag(args, "-fno-optimize-sibling-calls")) {
    args.push_back("-fno-optimize-sibling-calls");
  }
}

bool ReprobuildLooksLikeMakeProgram(std::string const& path)
{
  std::string const name =
    cmSystemTools::LowerCase(cmSystemTools::GetFilenameName(path));
  return name == "make" || name == "gmake" || name == "nmake" ||
    name == "nmake.exe" || name == "mingw32-make" ||
    name == "mingw32-make.exe" || name == "wmake" ||
    name == "wmake.exe" || name == "jom" || name == "jom.exe";
}

std::string ReprobuildCliFromEnv()
{
  if (cm::optional<std::string> reproEnv =
        cmSystemTools::GetEnvVar("REPROBUILD_REPRO")) {
    if (!reproEnv->empty() && cmSystemTools::FileExists(*reproEnv, true)) {
      return *reproEnv;
    }
  }
  return std::string();
}

std::string ReprobuildFindCliOnPath()
{
#ifdef _WIN32
  std::string makeProgram = cmSystemTools::FindProgram("repro.exe");
  if (makeProgram.empty()) {
    makeProgram = cmSystemTools::FindProgram("repro");
  }
  return makeProgram;
#else
  return cmSystemTools::FindProgram("repro");
#endif
}

std::string ReprobuildFindNativeMakeOnPath()
{
#ifdef _WIN32
  return std::string();
#else
  for (char const* candidate : { "gmake", "make", "smake" }) {
    std::string makeProgram = cmSystemTools::FindProgram(candidate);
    if (!makeProgram.empty()) {
      return makeProgram;
    }
  }
  return std::string();
#endif
}

bool ReprobuildCliSupportsProviderPriming(std::string const& repro)
{
  if (repro.empty()) {
    return false;
  }
  std::vector<std::string> command = { repro, "capabilities",
                                       "--format=json" };
  std::string output;
  int ret = 0;
  bool const ok = cmSystemTools::RunSingleCommand(
    command, &output, nullptr, &ret, nullptr, cmSystemTools::OUTPUT_NONE);
  return ok && ret == 0 &&
    output.find("\"provider-cache-priming\"") != std::string::npos;
}
}

cmGlobalReprobuildGenerator::cmGlobalReprobuildGenerator(cmake* cm)
  : cmGlobalUnixMakefileGenerator3(cm)
{
}

cmGlobalReprobuildGenerator::~cmGlobalReprobuildGenerator() = default;

bool cmGlobalReprobuildGenerator::FindMakeProgram(cmMakefile* mf)
{
  // The Reprobuild generator emits provider metadata that the `repro` CLI
  // (the "reprobuild" build tool) consumes. The parent class
  // cmGlobalUnixMakefileGenerator3 inherits FindMakeProgramFile =
  // "CMakeUnixFindMake.cmake", which searches for gmake/make/smake. That
  // search yields nothing on Windows and is semantically wrong for this
  // generator on every platform. Instead, resolve `repro` itself as the make
  // program. Order of resolution:
  //   1. CMAKE_MAKE_PROGRAM already set by the caller (e.g. -D on cmdline)
  //   2. $REPROBUILD_REPRO env var (set by the develop wrapper)
  //   3. `repro` (or `repro.exe` on Windows) on PATH
  std::string const current = mf->GetSafeDefinition("CMAKE_MAKE_PROGRAM");
  if (mf->GetDefinition("CMAKE_MAKE_PROGRAM").IsOff() ||
      ReprobuildLooksLikeMakeProgram(current)) {
    std::string makeProgram = ReprobuildCliFromEnv();
    if (makeProgram.empty()) {
      makeProgram = ReprobuildFindCliOnPath();
    }
    if (!makeProgram.empty()) {
      mf->AddCacheDefinition("CMAKE_MAKE_PROGRAM", makeProgram,
                             "Reprobuild CLI", cmStateEnums::FILEPATH);
    }
  }
  return this->cmGlobalGenerator::FindMakeProgram(mf);
}

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
  if (this->IsMultiConfig()) {
    mf->InitCMAKE_CONFIGURATION_TYPES("Debug;Release;RelWithDebInfo");
  }

  for (std::string const& lang : languages) {
    // Windows: `RC` is auto-enabled by Windows-MSVC.cmake / Windows-GNU.cmake
    // whenever C or CXX is enabled. The Reprobuild generator doesn't produce
    // metadata for resource files itself, but allowing RC through here lets
    // any project that calls `project(foo C)` succeed on Windows. Resource
    // files (.rc) won't reach the per-source whitelist below unless the
    // project explicitly adds them to a target; until that path needs
    // metadata support, leaving RC out of the source-language whitelist is
    // fine.
    if (lang != "NONE" && lang != "C" && lang != "CXX" &&
        lang != "Fortran" && lang != "CUDA" && lang != "ISPC" &&
        lang != "Swift" && lang != "ASM" && lang != "RC") {
      mf->IssueMessage(
        MessageType::FATAL_ERROR,
        cmStrCat("The Reprobuild generator supports only the C, CXX, "
                 "Fortran, CUDA, ISPC, Swift, ASM, and RC languages; language '",
                 lang, "' is not supported."));
      cmSystemTools::SetFatalErrorOccurred();
      return;
    }
    if (lang == "CUDA") {
      if (mf->GetSafeDefinition("CMAKE_REPROBUILD_CUDA_PROFILE") ==
          "ClangFatbinary") {
        std::string const compiler =
          mf->GetSafeDefinition("CMAKE_CUDA_COMPILER");
        if (compiler.empty() ||
            cmSystemTools::GetFilenameName(compiler).find("clang") ==
              std::string::npos) {
          mf->IssueMessage(MessageType::FATAL_ERROR,
                           "Reprobuild profile unavailable: Clang CUDA "
                           "fatbinary and registration-stub profile requires "
                           "an explicit Clang CUDA compiler.");
          cmSystemTools::SetFatalErrorOccurred();
          return;
        }
      }
      std::string compiler = mf->GetSafeDefinition("CMAKE_CUDA_COMPILER");
      if (compiler.empty()) {
        compiler = cmSystemTools::FindProgram("nvcc");
      }
      if (compiler.empty()) {
        mf->IssueMessage(MessageType::FATAL_ERROR,
                         "Reprobuild profile unavailable: CUDA compiler "
                         "and device-link toolchain were not found.");
        cmSystemTools::SetFatalErrorOccurred();
        return;
      }
    }
    if (lang == "ISPC") {
      std::string compiler = mf->GetSafeDefinition("CMAKE_ISPC_COMPILER");
      if (compiler.empty()) {
        compiler = cmSystemTools::FindProgram("ispc");
      }
      if (compiler.empty()) {
        mf->IssueMessage(MessageType::FATAL_ERROR,
                         "Reprobuild profile unavailable: ISPC compiler "
                         "was not found.");
        cmSystemTools::SetFatalErrorOccurred();
        return;
      }
    }
    if (lang == "Swift") {
      std::string compiler = mf->GetSafeDefinition("CMAKE_Swift_COMPILER");
      if (compiler.empty()) {
        compiler = cmSystemTools::FindProgram("swiftc");
      }
      if (compiler.empty()) {
        mf->IssueMessage(MessageType::FATAL_ERROR,
                         "Reprobuild profile unavailable: Swift compiler "
                         "was not found.");
        cmSystemTools::SetFatalErrorOccurred();
        return;
      }
    }
  }

  this->cmGlobalUnixMakefileGenerator3::EnableLanguage(languages, mf,
                                                       optional);
}

bool cmGlobalReprobuildGenerator::IsMultiConfig() const
{
  cmake* cm = this->GetCMakeInstance();
  cmState* state = cm ? cm->GetState() : nullptr;
  if (!state) {
    return false;
  }
  for (std::string const& var :
       { "CMAKE_CONFIGURATION_TYPES", "CMAKE_DEFAULT_BUILD_TYPE",
         "CMAKE_DEFAULT_CONFIGS", "CMAKE_CROSS_CONFIGS" }) {
    if (cmValue value = state->GetCacheEntryValue(var)) {
      if (!value->empty()) {
        return true;
      }
    }
  }
  return false;
}

bool cmGlobalReprobuildGenerator::InspectConfigTypeVariables()
{
  if (!this->IsMultiConfig()) {
    this->CrossConfigs.clear();
    this->DefaultConfigs.clear();
    this->DefaultFileConfig.clear();
    return true;
  }

  std::vector<std::string> configsList =
    this->Makefiles.front()->GetGeneratorConfigs(
      cmMakefile::IncludeEmptyConfig);
  std::set<std::string> configs(configsList.cbegin(), configsList.cend());
  configs.erase("");
  if (configs.empty()) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      "CMAKE_CONFIGURATION_TYPES must contain at least one configuration.");
    return false;
  }

  this->DefaultFileConfig =
    this->Makefiles.front()->GetSafeDefinition("CMAKE_DEFAULT_BUILD_TYPE");
  if (this->DefaultFileConfig.empty()) {
    for (std::string const& config : configsList) {
      if (!config.empty()) {
        this->DefaultFileConfig = config;
        break;
      }
    }
  }
  if (!configs.count(this->DefaultFileConfig)) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      cmStrCat("The configuration specified by CMAKE_DEFAULT_BUILD_TYPE (",
               this->DefaultFileConfig,
               ") is not present in CMAKE_CONFIGURATION_TYPES"));
    return false;
  }

  cmList crossConfigsList{
    this->Makefiles.front()->GetSafeDefinition("CMAKE_CROSS_CONFIGS")
  };
  std::set<std::string> crossConfigs;
  if (!ReprobuildListSubsetWithAll(configs, configs, crossConfigsList,
                                   crossConfigs)) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      "CMAKE_CROSS_CONFIGS is not a subset of CMAKE_CONFIGURATION_TYPES");
    return false;
  }
  this->CrossConfigs = crossConfigs;

  std::string defaultConfigsString =
    this->Makefiles.front()->GetSafeDefinition("CMAKE_DEFAULT_CONFIGS");
  if (defaultConfigsString.empty()) {
    defaultConfigsString = this->DefaultFileConfig;
  }
  if (!defaultConfigsString.empty() &&
      defaultConfigsString != this->DefaultFileConfig &&
      (this->DefaultFileConfig.empty() || this->CrossConfigs.empty())) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      "CMAKE_DEFAULT_CONFIGS cannot be used without CMAKE_DEFAULT_BUILD_TYPE "
      "or CMAKE_CROSS_CONFIGS");
    return false;
  }

  cmList defaultConfigsList(defaultConfigsString);
  std::set<std::string> allowedDefaults = this->CrossConfigs;
  allowedDefaults.insert(this->DefaultFileConfig);
  std::set<std::string> defaultConfigs;
  if (!ReprobuildListSubsetWithAll(allowedDefaults, this->CrossConfigs,
                                   defaultConfigsList, defaultConfigs)) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      "CMAKE_DEFAULT_CONFIGS is not a subset of CMAKE_CROSS_CONFIGS");
    return false;
  }
  this->DefaultConfigs = defaultConfigs;
  if (this->DefaultConfigs.empty()) {
    this->DefaultConfigs.insert(this->DefaultFileConfig);
  }

  return true;
}

std::string cmGlobalReprobuildGenerator::GetDefaultBuildConfig() const
{
  return this->IsMultiConfig() ? std::string() : "Debug";
}

void cmGlobalReprobuildGenerator::Generate()
{
  this->cmGlobalUnixMakefileGenerator3::Generate();
  if (cmSystemTools::GetErrorOccurredFlag()) {
    return;
  }

  this->WriteProviderMetadata();
}

void cmGlobalReprobuildGenerator::PrimeProviderMetadata()
{
  if (this->GetCMakeInstance()->GetIsInTryCompile()) {
    return;
  }

  if (this->LocalGenerators.empty()) {
    return;
  }

  std::string const binaryDir =
    this->GetCMakeInstance()->GetHomeOutputDirectory();
  std::string const providerDir =
    cmStrCat(binaryDir, "/CMakeFiles/reprobuild");
  std::string const wrapperDir = cmStrCat(providerDir, "/bin");
  std::string const providerFile = cmStrCat(binaryDir, "/reprobuild.nim");
  std::string const metadataFile = cmStrCat(providerDir, "/provider.meta");
  if (!cmSystemTools::FileExists(providerFile, true) ||
      !cmSystemTools::FileExists(metadataFile, true)) {
    return;
  }

  std::string repro = ReprobuildCliFromEnv();
  if (repro.empty()) {
    std::string const makeProgram =
      this->LocalGenerators.front()->GetMakefile()->GetSafeDefinition(
        "CMAKE_MAKE_PROGRAM");
    if (!makeProgram.empty() && !ReprobuildLooksLikeMakeProgram(makeProgram)) {
      repro = makeProgram;
    }
  }
  if (repro.empty()) {
    repro = ReprobuildFindCliOnPath();
  }
  if (repro.empty()) {
    return;
  }
  if (!ReprobuildCliSupportsProviderPriming(repro)) {
    return;
  }

  std::vector<std::string> env = cmSystemTools::GetEnvironmentVariables();
  auto setEnv = [&env](std::string const& key, std::string const& value) {
    std::string const prefix = key + "=";
    for (std::string& entry : env) {
      if (entry.rfind(prefix, 0) == 0) {
        entry = prefix + value;
        return;
      }
    }
    env.push_back(prefix + value);
  };

  std::string oldPath;
  if (cm::optional<std::string> envPath = cmSystemTools::GetEnvVar("PATH")) {
    oldPath = *envPath;
  }
#ifdef _WIN32
  setEnv("PATH", cmStrCat(wrapperDir, ";", oldPath));
#else
  setEnv("PATH", cmStrCat(wrapperDir, ":", oldPath));
#endif

  std::vector<std::string> command = {
    repro,
    "build",
    "--tool-provisioning=path",
    cmStrCat("--work-root=", providerDir),
    "--prepare-only",
    "--skip-cmake-regeneration",
    "--progress=none",
    "--report=none",
    "--log=quiet",
  };

  std::string output;
  std::string error;
  int ret = 0;
  bool const ok = cmSystemTools::RunSingleCommand(
    command, &output, &error, &ret, binaryDir.c_str(),
    cmSystemTools::OUTPUT_NONE, cmDuration::zero(), cmProcessOutput::Auto,
    env);
  if (!ok || ret != 0) {
    std::ostringstream message;
    message << "Reprobuild provider preparation failed while running: "
            << cmSystemTools::PrintSingleCommand(command);
    if (!output.empty()) {
      message << "\nstdout:\n" << output;
    }
    if (!error.empty()) {
      message << "\nstderr:\n" << error;
    }
    this->GetCMakeInstance()->IssueMessage(MessageType::FATAL_ERROR,
                                           message.str());
  }
}

// Serializes one ReprobuildAction into the trycompile.rbsz binary envelope
// using the field order that the Nim decoder in
// ``libs/repro_cmake_trycompile/src/repro_cmake_trycompile.nim`` expects.
// ``poolUnits`` is hard-coded to 1 to mirror ``writeAction`` in
// ``WriteProviderMetadata`` below.
static void ReprobuildAppendTryCompileAction(std::string& out,
                                             ReprobuildAction const& action)
{
  using namespace ReprobuildTryCompileEnvelope;
  AppendString(out, action.Id);
  AppendBool(out, action.Inline);
  AppendStringSeq(out, action.InlineArgv);
  AppendString(out, action.InlineCwd);
  AppendString(out, action.ToolId);
  AppendStringSeq(out, action.Args);
  AppendStringSeq(out, action.Deps);
  AppendStringSeq(out, action.Inputs);
  AppendStringSeq(out, action.Outputs);
  AppendString(out, action.Pool);
  AppendU32Le(out, 1u);
  AppendString(out, action.Depfile);
  AppendString(out, action.DynamicDepsFile);
  AppendBool(out, action.Cacheable);
  AppendString(out, ReprobuildCommandStatsId(action.Id));
}

// Describes one build target (or aggregate) in the v2/v3 metadata envelope.
struct ReprobuildTryCompileTargetDescriptor
{
  std::string Name;
  std::vector<std::string> ActionIds;
  std::vector<std::string> ChildTargets;
  bool IsAggregate = false;
};

// v3 only: describes a per-config or cross-config aggregate emitted by
// multi-config CMake builds. Mirrors ``CrossConfigTargetDef`` in
// ``libs/repro_cmake_trycompile/src/repro_cmake_trycompile.nim`` — byte
// layout must stay in lockstep with the Nim encoder.
struct ReprobuildTryCompileCrossConfigDescriptor
{
  std::string Name;
  std::string ConfigName;
  std::string BaseName;
  std::vector<std::string> ChildTargets;
};

// Writes ``trycompile.rbsz`` (legacy name retained — also used for main
// CMake-generated projects under Tier 2c) next to ``reprobuild.nim``. The
// engine routes any work-dir containing this marker to the pre-built
// ``repro-cmake-trycompile-provider`` binary, skipping the per-project
// provider compile entirely. Returns true on success; on failure the
// generator continues with just ``reprobuild.nim`` (the slow path) —
// emission is a pure optimisation, not load-bearing for correctness.
//
// v1 envelopes (TryCompile single-target form) are still written for
// stereotyped try_compile() probes. v2 envelopes carry the main project's
// multi-target shape — including aggregates and the default target — so
// the direct provider can synthesise the full build graph without
// compiling per-project reprobuild.nim. v3 extends v2 with cross-config
// descriptors so multi-config CMake builds (CMAKE_CROSS_CONFIGS,
// CMAKE_DEFAULT_CONFIGS) can also route through the direct provider.
//
// v2 readers MUST reject v3 (the cross-config target shape would
// otherwise be invisible and the slow path would silently disappear);
// the Nim decoder enforces that.
static bool ReprobuildWriteTryCompileMetadata(
  std::string const& path,
  std::vector<std::string> const& usedTools,
  std::vector<ReprobuildPool> const& pools,
  std::vector<ReprobuildAction const*> const& actions,
  std::vector<ReprobuildTryCompileTargetDescriptor> const& targets,
  std::string const& defaultTargetName,
  std::vector<std::string> const& crossConfigs,
  std::vector<ReprobuildTryCompileCrossConfigDescriptor> const&
    crossConfigTargets,
  std::vector<std::string> const& defaultConfigs)
{
  using namespace ReprobuildTryCompileEnvelope;
  std::string payload;
  AppendStringSeq(payload, usedTools);
  AppendU32Le(payload, static_cast<std::uint32_t>(pools.size()));
  for (auto const& pool : pools) {
    AppendString(payload, pool.Name);
    AppendU32Le(payload, pool.Capacity);
  }
  AppendU32Le(payload, static_cast<std::uint32_t>(actions.size()));
  for (auto const* action : actions) {
    ReprobuildAppendTryCompileAction(payload, *action);
  }
  AppendU32Le(payload, static_cast<std::uint32_t>(targets.size()));
  for (auto const& target : targets) {
    AppendString(payload, target.Name);
    AppendStringSeq(payload, target.ActionIds);
    AppendStringSeq(payload, target.ChildTargets);
    AppendBool(payload, target.IsAggregate);
  }
  AppendString(payload, defaultTargetName);
  // v3 trailer: cross-config descriptors. Mirrors the
  // ``encodeTryCompileMetadata`` Nim encoder field-for-field.
  AppendStringSeq(payload, crossConfigs);
  AppendU32Le(payload,
              static_cast<std::uint32_t>(crossConfigTargets.size()));
  for (auto const& crossTarget : crossConfigTargets) {
    AppendString(payload, crossTarget.Name);
    AppendString(payload, crossTarget.ConfigName);
    AppendString(payload, crossTarget.BaseName);
    AppendStringSeq(payload, crossTarget.ChildTargets);
  }
  AppendStringSeq(payload, defaultConfigs);

  std::string envelope = "RBCT";
  AppendU16Le(envelope, 3);
  AppendU32Le(envelope, static_cast<std::uint32_t>(payload.size()));
  envelope.append(payload);

  if (!cmSystemTools::MakeDirectory(cmSystemTools::GetFilenamePath(path))) {
    return false;
  }
  cmsys::ofstream out(path.c_str(), std::ios::binary);
  if (!out) {
    return false;
  }
  out.write(envelope.data(),
            static_cast<std::streamsize>(envelope.size()));
  return out.good();
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
  std::map<std::string, std::set<std::string>> cleanFilesByConfig;
  std::set<std::string> usedLanguages;
  std::set<std::string> usedTools;
  std::string const toolPortabilityMode =
    this->LocalGenerators.empty()
    ? std::string()
    : this->LocalGenerators.front()->GetMakefile()->GetSafeDefinition(
        "REPROBUILD_CMAKE_TOOL_PORTABILITY");
  bool sawImportLibraryOutput = false;
  bool sawLinkDepfile = false;
  bool sawSymlinkOutput = false;
  bool sawCudaDeviceLink = false;
  bool sawCudaClangFatbinary = false;
  bool sawISPCMultiOutput = false;
  bool sawSwiftOutputMap = false;
  bool sawSwiftSplit = false;
  bool sawAppleBundle = false;
  bool const multiConfig = this->IsMultiConfig();
  cmLocalGenerator* rootLg = this->LocalGenerators.front().get();
  cmMakefile* rootMf = this->LocalGenerators.front()->GetMakefile();
  if (!this->GetCMakeInstance()->GetState()->GetCacheEntryValue(
        "CMAKE_REPROBUILD_HCR")) {
    rootMf->AddCacheDefinition(
      "CMAKE_REPROBUILD_HCR", "OFF",
      "Enable Reprobuild hot-code-reload metadata and support profile flags.",
      cmStateEnums::BOOL);
  }
  std::vector<std::string> configs;
  if (multiConfig) {
    configs = rootMf->GetGeneratorConfigs(cmMakefile::ExcludeEmptyConfig);
  } else {
    configs.push_back(rootMf->GetSafeDefinition("CMAKE_BUILD_TYPE"));
  }
  std::set<std::string> nativeCommandConfigTargets;
  if (multiConfig && !this->CrossConfigs.empty()) {
    auto recordCommandConfigUtilities =
      [&](cmLocalGenerator* lg, cmCustomCommand const& cc) {
        for (std::string const& config : configs) {
          cmCustomCommandGenerator ccg(cc, config, lg);
          for (auto const& utility : ccg.GetUtilities()) {
            if (!utility.Value.second) {
              continue;
            }
            cmGeneratorTarget* utilityTarget =
              lg->FindGeneratorTargetToUse(utility.Value.first);
            if (utilityTarget &&
                utilityTarget->GetType() == cmStateEnums::EXECUTABLE &&
                !utilityTarget->IsImported()) {
              nativeCommandConfigTargets.insert(utilityTarget->GetName());
            }
          }
        }
      };
    for (auto const& lg : this->LocalGenerators) {
      for (auto const& gtPtr : lg->GetGeneratorTargets()) {
        cmGeneratorTarget* gt = gtPtr.get();
        std::vector<cmCustomCommand> commands = gt->GetPreBuildCommands();
        cm::append(commands, gt->GetPreLinkCommands());
        cm::append(commands, gt->GetPostBuildCommands());
        for (cmCustomCommand const& cc : commands) {
          recordCommandConfigUtilities(lg.get(), cc);
        }
        std::vector<cmSourceFile const*> customCommandSources;
        gt->GetCustomCommands(customCommandSources, configs.front());
        for (cmSourceFile const* customSource : customCommandSources) {
          if (cmCustomCommand const* cc = customSource->GetCustomCommand()) {
            recordCommandConfigUtilities(lg.get(), *cc);
          }
        }
        if (gt->GetType() == cmStateEnums::UTILITY) {
          std::vector<cmSourceFile*> utilitySources;
          gt->GetSourceFiles(utilitySources, configs.front());
          for (cmSourceFile const* source : utilitySources) {
            if (cmCustomCommand const* cc = source->GetCustomCommand()) {
              recordCommandConfigUtilities(lg.get(), *cc);
            }
          }
        }
      }
    }
  }
  std::vector<ReprobuildConfigPair> configPairs;
  if (multiConfig && !this->CrossConfigs.empty()) {
    std::set<std::string> allConfigs(configs.begin(), configs.end());
    std::set<std::pair<std::string, std::string>> seenPairs;
    for (std::string const& commandConfig : configs) {
      for (std::string const& outputConfig : this->CrossConfigs) {
        if (outputConfig == commandConfig || !allConfigs.count(outputConfig)) {
          continue;
        }
        if (seenPairs.insert({ outputConfig, commandConfig }).second) {
          configPairs.push_back(ReprobuildConfigPair{
            outputConfig, commandConfig, true });
        }
      }
    }
    for (std::string const& config : configs) {
      configPairs.push_back(ReprobuildConfigPair{ config, config, false });
    }
  } else {
    for (std::string const& config : configs) {
      configPairs.push_back(ReprobuildConfigPair{ config, config, false });
    }
  }
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

  for (ReprobuildConfigPair const& configPair : configPairs) {
    std::string const& config = configPair.OutputConfig;
    std::string const& commandConfig = configPair.CommandConfig;
    std::string const configSuffix =
      ReprobuildConfigSuffix(config, commandConfig, multiConfig);
    bool const declareOutputs = !configPair.IsCrossConfig;
    std::set<std::string>& cleanFiles = cleanFilesByConfig[config];
    for (auto const& lg : this->LocalGenerators) {
      auto retargetCommandConfigExecutables =
        [&](cmCustomCommandGenerator const& ccg,
            std::vector<std::string>& commandLines) {
          if (!multiConfig) {
            return;
          }
          for (auto const& utility : ccg.GetUtilities()) {
            cmGeneratorTarget* utilityTarget =
              lg->FindGeneratorTargetToUse(utility.Value.first);
            if (!utilityTarget ||
                utilityTarget->GetType() != cmStateEnums::EXECUTABLE ||
                utilityTarget->IsImported()) {
              continue;
            }
            std::string const depConfig =
              utility.Value.second ? commandConfig : config;
            std::string const oldPath = utilityTarget->GetFullPath(depConfig);
            std::string const newPath = cmStrCat(
              binaryDir, "/",
              ReprobuildConfigFullPath(binaryDir, oldPath, depConfig, true));
            if (oldPath == newPath) {
              continue;
            }
            for (std::string& commandLine : commandLines) {
              cmSystemTools::ReplaceString(
                commandLine, ReprobuildShellSingleQuote(oldPath),
                ReprobuildShellSingleQuote(newPath));
              cmSystemTools::ReplaceString(commandLine, oldPath, newPath);
            }
          }
        };
      for (auto const& gtPtr : lg->GetGeneratorTargets()) {
      cmGeneratorTarget* gt = gtPtr.get();
      auto const type = gt->GetType();
      if (type == cmStateEnums::INTERFACE_LIBRARY ||
          type == cmStateEnums::GLOBAL_TARGET || type == cmStateEnums::UNKNOWN_LIBRARY) {
        continue;
      }
      bool const isNativeCommandConfigTarget =
        nativeCommandConfigTargets.count(gt->GetName()) > 0;
      if (multiConfig && !this->CrossConfigs.empty()) {
        if (configPair.IsCrossConfig && isNativeCommandConfigTarget) {
          continue;
        }
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
          cmCustomCommandGenerator ccg(cc, commandConfig, lg.get(), false,
                                       config);
          if (utilityDepfile.empty()) {
            utilityDepfile = ReprobuildCustomDepfilePath(binaryDir, lg.get(),
                                                         ccg);
          }
          for (std::string const& output : ccg.GetOutputs()) {
            utilityOutputs.push_back(ReprobuildConfigPath(
              ReprobuildOutputPath(binaryDir, lg->GetCurrentBinaryDirectory(),
                                   output),
              config, multiConfig));
            ReprobuildAppendCleanFile(cleanFiles,
                                      binaryDir,
                                      ReprobuildConfigPath(
                                        ReprobuildOutputPath(
                                          binaryDir,
                                          lg->GetCurrentBinaryDirectory(),
                                          output),
                                        config, multiConfig));
          }
          for (std::string const& byproduct : ccg.GetByproducts()) {
            utilityOutputs.push_back(ReprobuildConfigPath(
              ReprobuildOutputPath(binaryDir, lg->GetCurrentBinaryDirectory(),
                                   byproduct),
              config, multiConfig));
            ReprobuildAppendCleanFile(cleanFiles,
                                      binaryDir,
                                      ReprobuildConfigPath(
                                        ReprobuildOutputPath(
                                          binaryDir,
                                          lg->GetCurrentBinaryDirectory(),
                                          byproduct),
                                        config, multiConfig));
          }
        for (std::string const& dep : ccg.GetDepends()) {
          std::string realDep;
          if (lg->GetRealDependency(dep, ccg.GetOutputConfig(), realDep,
                                    cc.GetCMP0212Status())) {
              utilityInputs.push_back(ReprobuildConfigPath(
                ReprobuildOutputPath(binaryDir, lg->GetCurrentBinaryDirectory(),
                                     realDep),
                configPair.IsCrossConfig ? commandConfig
                                         : ccg.GetOutputConfig(),
                multiConfig));
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
          retargetCommandConfigExecutables(ccg, commandLines);
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
        target.BaseName = gt->GetName();
        target.Name = ReprobuildTargetName(gt->GetName(), config,
                                           commandConfig, multiConfig);
        target.OutputConfig = config;
        target.CommandConfig = commandConfig;
        target.IsCrossConfig = configPair.IsCrossConfig;
        target.Var = ReprobuildNimIdent("target", nextTargetVar++, target.Name);
        target.IsUtility = true;
        target.IncludeInAll = !configPair.IsCrossConfig &&
          !gt->GetPropertyAsBool("EXCLUDE_FROM_ALL");
        if (!configPair.IsCrossConfig) {
          for (auto const& utility : gt->GetUtilities()) {
            target.TargetDeps.push_back(utility.Value.first);
          }
        }
        target.UtilityAction.Id =
          ReprobuildSafeId(cmStrCat("custom-", gt->GetName(), configSuffix));
        target.UtilityAction.Var = ReprobuildNimIdent(
          "action", nextActionVar++, target.UtilityAction.Id);
        target.UtilityAction.ToolId =
          ReprobuildSafeId(cmStrCat("reprobuild-cmake-",
                                    target.UtilityAction.Var));
        target.UtilityAction.Pool = usesTerminal ? "console" : jobPool;
        target.UtilityAction.Inputs = utilityInputs;
        if (declareOutputs) {
          target.UtilityAction.Outputs = utilityOutputs;
          target.UtilityAction.Depfile = utilityDepfile;
        }
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

      if (!lg->GetMakefile()->IsOn("APPLE") &&
          (gt->GetPropertyAsBool("MACOSX_BUNDLE") ||
           gt->GetPropertyAsBool("FRAMEWORK") ||
           gt->GetPropertyAsBool("BUNDLE"))) {
        this->GetCMakeInstance()->IssueMessage(
          MessageType::FATAL_ERROR,
          cmStrCat("Reprobuild profile unavailable: Apple bundle, framework, "
                   "or CFBundle target '",
                   gt->GetName(), "' requires an Apple platform."));
        return;
      }

      if (gt->IsAppBundleOnApple() || gt->IsFrameworkOnApple() ||
          gt->IsCFBundleOnApple() || gt->IsArchivedAIXSharedLibrary()) {
        if (gt->IsArchivedAIXSharedLibrary()) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Reprobuild profile unavailable: archived AIX shared "
                     "libraries are not supported by the current target "
                     "profile; target '",
                     gt->GetName(), "' has type ",
                     cmState::GetTargetTypeName(type), "."));
          return;
        }
      }

      ReprobuildTarget target;
      target.BaseName = gt->GetName();
      target.Name = ReprobuildTargetName(gt->GetName(), config, commandConfig,
                                         multiConfig);
      target.OutputConfig = config;
      target.CommandConfig = commandConfig;
      target.IsCrossConfig = configPair.IsCrossConfig;
      target.Var = ReprobuildNimIdent("target", nextTargetVar++, target.Name);
      target.IncludeInAll = !configPair.IsCrossConfig &&
        !gt->GetPropertyAsBool("EXCLUDE_FROM_ALL");
      target.HcrEnabled = ReprobuildTargetHcrEnabled(gt, lg->GetMakefile());
      if (target.HcrEnabled) {
        target.HcrProfile = "clang-gcc-debug-patchable-no-lto-v1";
        if (type == cmStateEnums::STATIC_LIBRARY ||
            type == cmStateEnums::OBJECT_LIBRARY) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Reprobuild HCR profile unavailable for target '",
                     gt->GetName(),
                     "': HCR requires an executable, shared library, or "
                     "module library link target, not ",
                     cmState::GetTargetTypeName(type), "."));
          return;
        }
        if (gt->GetPropertyAsBool("INTERPROCEDURAL_OPTIMIZATION")) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Reprobuild HCR profile unavailable for target '",
                     gt->GetName(),
                     "': interprocedural optimization/LTO is incompatible "
                     "with HCR object-to-link metadata."));
          return;
        }
      }
      if (!configPair.IsCrossConfig) {
        for (auto const& utility : gt->GetUtilities()) {
          target.TargetDeps.push_back(utility.Value.first);
        }
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
        cmCustomCommandGenerator ccg(*cc, commandConfig, lg.get(), false,
                                     config);
        std::vector<std::string> commandLines =
          ReprobuildCustomCommandLines(
            ccg, true, lg->GetCurrentBinaryDirectory());
        retargetCommandConfigExecutables(ccg, commandLines);
        if (commandLines.empty()) {
          continue;
        }

        ReprobuildAction custom;
        std::string const primaryOutput =
          ccg.GetOutputs().empty()
          ? cmStrCat("custom-", gt->GetName(), "-", customIndex)
          : ReprobuildConfigPath(
              ReprobuildOutputPath(binaryDir, lg->GetCurrentBinaryDirectory(),
                                   ccg.GetOutputs().front()),
              config, multiConfig);
        custom.Id =
          ReprobuildSafeId(cmStrCat("custom-command-", gt->GetName(), "-",
                                    primaryOutput, configSuffix));
        custom.Var = ReprobuildNimIdent("action", nextActionVar++,
                                        custom.Id);
        custom.ToolId =
          ReprobuildSafeId(cmStrCat("reprobuild-cmake-", custom.Var));
        custom.Pool = cc->GetUsesTerminal() ? "console" : cc->GetJobPool();
        custom.Cacheable = declareOutputs;
        for (std::string const& output : ccg.GetOutputs()) {
          if (declareOutputs) {
            custom.Outputs.push_back(ReprobuildConfigPath(
              ReprobuildOutputPath(binaryDir, lg->GetCurrentBinaryDirectory(),
                                   output),
              config, multiConfig));
          }
          ReprobuildAppendCleanFile(cleanFiles,
                                    binaryDir,
                                    ReprobuildConfigPath(
                                      ReprobuildOutputPath(
                                        binaryDir,
                                        lg->GetCurrentBinaryDirectory(),
                                        output),
                                      config, multiConfig));
        }
        for (std::string const& byproduct : ccg.GetByproducts()) {
          if (declareOutputs) {
            custom.Outputs.push_back(ReprobuildConfigPath(
              ReprobuildOutputPath(binaryDir, lg->GetCurrentBinaryDirectory(),
                                   byproduct),
              config, multiConfig));
          }
          ReprobuildAppendCleanFile(cleanFiles,
                                    binaryDir,
                                    ReprobuildConfigPath(
                                      ReprobuildOutputPath(
                                        binaryDir,
                                        lg->GetCurrentBinaryDirectory(),
                                        byproduct),
                                      config, multiConfig));
        }
        for (std::string const& dep : ccg.GetDepends()) {
          std::string realDep;
          if (lg->GetRealDependency(dep, ccg.GetOutputConfig(), realDep,
                                    cc->GetCMP0212Status())) {
            custom.Inputs.push_back(ReprobuildConfigPath(
              ReprobuildOutputPath(binaryDir, lg->GetCurrentBinaryDirectory(),
                                   realDep),
              configPair.IsCrossConfig ? commandConfig : ccg.GetOutputConfig(),
              multiConfig));
          }
        }
        for (auto const& utility : ccg.GetUtilities()) {
          cmGeneratorTarget* utilityTarget =
            lg->FindGeneratorTargetToUse(utility.Value.first);
          if (utilityTarget &&
              utilityTarget->GetType() == cmStateEnums::EXECUTABLE &&
              !utilityTarget->IsImported()) {
            std::string const depConfig =
              utility.Value.second ? commandConfig : config;
            ReprobuildAppendUnique(
              custom.Deps,
              ReprobuildSafeId(cmStrCat(
                "link-", utilityTarget->GetName(),
                ReprobuildConfigSuffix(depConfig, depConfig, multiConfig))));
          }
        }
        if (declareOutputs) {
          custom.Depfile = ReprobuildCustomDepfilePath(binaryDir, lg.get(), ccg);
        }
        if (!custom.Depfile.empty()) {
          ReprobuildAppendCleanFile(cleanFiles, binaryDir, custom.Depfile);
        }

        // Inline-exec fast path: a single-command custom command with no
        // declared comment-echo and no working-directory rewrite can be
        // emitted as `inlineExecCall(argv, cwd)` instead of a synthetic
        // package + shell wrapper. The lowered binary graph then holds
        // the literal argv per edge and the engine launches the tool
        // directly. Multi-command and comment-echo custom commands fall
        // back to the legacy wrapper-script path below for now (the
        // engine only knows how to inline a single argv per builtin
        // exec action; chaining multiple shell statements still needs
        // the wrapper).
        bool inlined = false;
        if (ccg.GetNumberOfCommands() == 1 && !ccg.GetComment().has_value()) {
          std::vector<std::string> inlineArgv =
            ReprobuildCustomCommandArgv(ccg, 0);
          if (!inlineArgv.empty()) {
            custom.Inline = true;
            custom.InlineArgv = std::move(inlineArgv);
            custom.InlineCwd = ccg.GetWorkingDirectory();
            inlined = true;
          }
        }
        if (!inlined) {
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
        }
        target.CustomActions.push_back(std::move(custom));
        ++customIndex;
      }

      if (gt->IsBundleOnApple()) {
        sawAppleBundle = true;
        std::vector<cmSourceFile const*> macContentSources;
        std::vector<cmSourceFile const*> headerSources;
        gt->GetHeaderSources(headerSources, config);
        cm::append(macContentSources, headerSources);
        std::vector<cmSourceFile const*> extraSources;
        gt->GetExtraSources(extraSources, config);
        cm::append(macContentSources, extraSources);
        unsigned int macContentIndex = 0;
        for (cmSourceFile const* macSource : macContentSources) {
          cmGeneratorTarget::SourceFileFlags flags =
            gt->GetTargetSourceFileFlags(macSource);
          if (flags.Type == cmGeneratorTarget::SourceFileTypeNormal ||
              flags.MacFolder == nullptr || *flags.MacFolder == '\0') {
            continue;
          }
          std::string const macDir = cmStrCat(
            gt->GetMacContentDirectory(
              config, cmStateEnums::RuntimeBinaryArtifact),
            "/", flags.MacFolder);
          std::string const outputFull =
            cmStrCat(macDir, "/",
                     cmSystemTools::GetFilenameName(macSource->GetFullPath()));
          std::string const outputRel =
            ReprobuildConfigFullPath(binaryDir, outputFull, config,
                                     multiConfig);
          ReprobuildAction content;
          content.Id =
            ReprobuildSafeId(cmStrCat("bundle-content-", gt->GetName(), "-",
                                      macContentIndex++, configSuffix));
          content.Var =
            ReprobuildNimIdent("action", nextActionVar++, content.Id);
          content.ToolId =
            ReprobuildSafeId(cmStrCat("reprobuild-cmake-", content.Var));
          content.Inputs = { macSource->GetFullPath() };
          content.Cacheable = declareOutputs;
          if (declareOutputs) {
            content.Outputs = { outputRel };
          }
          std::vector<std::string> lines;
          lines.push_back(cmStrCat(
            ReprobuildShellSingleQuote(cmSystemTools::GetCMakeCommand()),
            " -E make_directory ", ReprobuildShellSingleQuote(macDir)));
          lines.push_back(cmStrCat(
            ReprobuildShellSingleQuote(cmSystemTools::GetCMakeCommand()),
            cmSystemTools::FileIsDirectory(macSource->GetFullPath())
              ? " -E copy_directory "
              : " -E copy ",
            ReprobuildShellSingleQuote(macSource->GetFullPath()), " ",
            ReprobuildShellSingleQuote(outputFull)));
          std::string const wrapperPath =
            cmStrCat(wrapperDir, "/", content.ToolId);
          if (!ReprobuildWriteCommandScript(wrapperPath, binaryDir, lines)) {
            this->GetCMakeInstance()->IssueMessage(
              MessageType::FATAL_ERROR,
              cmStrCat("Could not write Reprobuild bundle content wrapper: ",
                       wrapperPath));
            return;
          }
          usedTools.insert(content.ToolId);
          ReprobuildAppendCleanFile(cleanFiles, binaryDir, outputRel);
          target.CustomActions.push_back(std::move(content));
        }
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
      bool targetHasCudaSources = false;
      for (cmSourceFile const* source : sources) {
        if (source->GetLanguage() == "CUDA") {
          targetHasCudaSources = true;
        }
        if (!source->IsPchSource()) {
          continue;
        }
        std::string const objFull =
          cmStrCat(gt->GetObjectDirectory(config), gt->GetObjectName(source));
        std::string const objRel =
          ReprobuildConfigFullPath(binaryDir, objFull, config, multiConfig);
        pchActionIds[source->GetFullPath()] =
          ReprobuildSafeId(cmStrCat("compile-", gt->GetName(), "-", objRel,
                                    configSuffix));
      }

      std::map<std::string, std::vector<std::string>> dyndepDdis;
      std::map<std::string, std::vector<std::pair<std::string, std::string>>>
        dyndepActionMaps;
      std::map<std::string, std::vector<std::string>> dyndepScanActions;
      std::map<std::string, std::map<std::string, cmSourceFile const*>>
        dyndepCxxModuleSources;
      std::vector<std::string> linkObjects;
      std::vector<cmSourceFile const*> swiftSources;
      std::vector<std::string> swiftObjectRels;
      for (cmSourceFile const* source : sources) {
        if (source->GetLanguage() != "Swift") {
          continue;
        }
        std::string const objFull =
          cmStrCat(gt->GetObjectDirectory(config), gt->GetObjectName(source));
        std::string const objRel =
          ReprobuildConfigFullPath(binaryDir, objFull, config, multiConfig);
        swiftSources.push_back(source);
        swiftObjectRels.push_back(objRel);
        linkObjects.push_back(objRel);
        ReprobuildAppendCleanFile(cleanFiles, binaryDir, objRel);
        ReprobuildAppendCleanFile(cleanFiles, binaryDir, cmStrCat(objRel, ".d"));
        ReprobuildAppendCleanFile(
          cleanFiles, binaryDir,
          ReprobuildSwiftDepsPath(binaryDir, gt, source, objRel));
        ReprobuildAppendCleanFile(
          cleanFiles, binaryDir,
          ReprobuildSwiftDiagnosticsPath(binaryDir, gt, source, objRel));
        cmSystemTools::MakeDirectory(
          cmSystemTools::GetFilenamePath(cmStrCat(binaryDir, "/", objRel)));
      }
      if (!swiftSources.empty()) {
        cmMakefile const* mf = lg->GetMakefile();
        usedLanguages.insert("Swift");
        std::vector<std::string> swiftArgs;
        ReprobuildAppendCommonCompileArgs(swiftArgs, lg.get(), gt, config,
                                          "Swift");
        if (gt->GetType() != cmStateEnums::EXECUTABLE) {
          swiftArgs.push_back("-parse-as-library");
        }
        swiftArgs.push_back("-module-name");
        swiftArgs.push_back(gt->GetSwiftModuleName());
        cm::optional<cmSwiftCompileMode> swiftMode =
          lg->GetSwiftCompileMode(gt, config);
        bool const splitSwift = swiftMode.has_value();
        if (swiftMode) {
          std::string const mode = ReprobuildSwiftCompileModeName(*swiftMode);
          if (mode == "wholemodule") {
            swiftArgs.push_back("-whole-module-optimization");
          } else if (mode == "incremental") {
            swiftArgs.push_back("-incremental");
          } else if (mode == "singlefile") {
            swiftArgs.push_back("-driver-use-frontend-path");
            swiftArgs.push_back(mf->GetSafeDefinition("CMAKE_Swift_COMPILER"));
          }
        }
        std::string const ofmRel =
          ReprobuildSwiftOutputMapPath(binaryDir, gt, config, multiConfig);
        std::string const ofmFull = cmStrCat(binaryDir, "/", ofmRel);
        if (!ReprobuildWriteSwiftOutputMap(ofmFull, binaryDir, gt,
                                           swiftSources, swiftObjectRels,
                                           config)) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Could not write Reprobuild Swift output map: ",
                     ofmFull));
          return;
        }
        sawSwiftOutputMap = true;
        ReprobuildAppendCleanFile(cleanFiles, binaryDir, ofmRel);
        swiftArgs.push_back("-output-file-map");
        swiftArgs.push_back(ofmRel);
        swiftArgs.push_back("-emit-dependencies");
        swiftArgs.push_back("-serialize-diagnostics");
        swiftArgs.push_back("-c");
        for (cmSourceFile const* swiftSource : swiftSources) {
          swiftArgs.push_back(swiftSource->GetFullPath());
        }

        bool const emitModuleSeparately =
          splitSwift &&
          gt->GetProperty("Swift_SEPARATE_MODULE_EMISSION").IsOn();
        std::string const swiftModuleRel =
          ReprobuildConfigFullPath(binaryDir, gt->GetSwiftModulePath(config),
                                   config, multiConfig);
        if (!swiftModuleRel.empty()) {
          ReprobuildAppendCleanFile(cleanFiles, binaryDir, swiftModuleRel);
        }
        std::string emitModuleActionId;
        if (emitModuleSeparately && !swiftModuleRel.empty()) {
          sawSwiftSplit = true;
          ReprobuildAction emitModule;
          emitModule.Id =
            ReprobuildSafeId(cmStrCat("emit-module-", gt->GetName(),
                                      configSuffix));
          emitModule.Var =
            ReprobuildNimIdent("action", nextActionVar++, emitModule.Id);
          emitModule.ToolId = ReprobuildToolId("Swift");
          usedTools.insert(emitModule.ToolId);
          emitModule.Args = swiftArgs;
          emitModule.Args.insert(emitModule.Args.begin(), "-emit-module");
          emitModule.Args.push_back("-emit-module-path");
          emitModule.Args.push_back(swiftModuleRel);
          for (cmSourceFile const* swiftSource : swiftSources) {
            emitModule.Inputs.push_back(swiftSource->GetFullPath());
          }
          emitModule.Inputs.push_back(ofmRel);
          if (declareOutputs) {
            emitModule.Outputs = { swiftModuleRel };
          } else {
            emitModule.Cacheable = false;
          }
          emitModule.CompileDirectory = binaryDir;
          emitModule.CompileFile = swiftSources.front()->GetFullPath();
          emitModule.CompileCommand =
            cmStrCat(mf->GetSafeDefinition(ReprobuildCompilerVar("Swift")),
                     " ", cmJoin(emitModule.Args, " "));
          emitModuleActionId = emitModule.Id;
          target.CustomActions.push_back(std::move(emitModule));
        } else if (!swiftModuleRel.empty()) {
          swiftArgs.push_back("-emit-module");
          swiftArgs.push_back("-emit-module-path");
          swiftArgs.push_back(swiftModuleRel);
        }

        ReprobuildAction swiftCompile;
        swiftCompile.Id =
          ReprobuildSafeId(cmStrCat("compile-", gt->GetName(), "-Swift",
                                    configSuffix));
        swiftCompile.Var =
          ReprobuildNimIdent("action", nextActionVar++, swiftCompile.Id);
        swiftCompile.ToolId = ReprobuildToolId("Swift");
        usedTools.insert(swiftCompile.ToolId);
        swiftCompile.Args = swiftArgs;
        for (cmSourceFile const* swiftSource : swiftSources) {
          swiftCompile.Inputs.push_back(swiftSource->GetFullPath());
        }
        swiftCompile.Inputs.push_back(ofmRel);
        if (!emitModuleActionId.empty()) {
          swiftCompile.Deps.push_back(emitModuleActionId);
        }
        if (declareOutputs) {
          swiftCompile.Outputs = swiftObjectRels;
          for (std::size_t i = 0; i < swiftSources.size(); ++i) {
            swiftCompile.Outputs.push_back(cmStrCat(swiftObjectRels[i], ".d"));
            swiftCompile.Outputs.push_back(ReprobuildSwiftDepsPath(
              binaryDir, gt, swiftSources[i], swiftObjectRels[i]));
            swiftCompile.Outputs.push_back(ReprobuildSwiftDiagnosticsPath(
              binaryDir, gt, swiftSources[i], swiftObjectRels[i]));
          }
          if (!emitModuleSeparately && !swiftModuleRel.empty()) {
            swiftCompile.Outputs.push_back(swiftModuleRel);
          }
        } else {
          swiftCompile.Cacheable = false;
        }
        swiftCompile.Pool =
          ReprobuildPoolProperty(gt, nullptr, "JOB_POOL_COMPILE", "");
        swiftCompile.CompileDirectory = binaryDir;
        swiftCompile.CompileFile = swiftSources.front()->GetFullPath();
        swiftCompile.CompileCommand =
          cmStrCat(mf->GetSafeDefinition(ReprobuildCompilerVar("Swift")), " ",
                   cmJoin(swiftCompile.Args, " "));
        target.CompileActions.push_back(std::move(swiftCompile));
      }
      for (cmSourceFile const* source : sources) {
        std::string const lang = source->GetLanguage();
        if (lang == "Swift") {
          continue;
        }
        if (target.HcrEnabled && lang != "C" && lang != "CXX") {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Reprobuild HCR profile unavailable for target '",
                     gt->GetName(), "': source '", source->GetFullPath(),
                     "' uses language '", lang,
                     "'; the current HCR support profile accepts only C "
                     "and CXX object sources."));
          return;
        }
        if (lang != "C" && lang != "CXX" && lang != "Fortran" &&
            lang != "CUDA" && lang != "ISPC") {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("The Reprobuild generator supports only C, CXX, "
                     "Fortran, CUDA, ISPC, and Swift object sources; source '",
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
        std::string const objRel =
          ReprobuildConfigFullPath(binaryDir, objFull, config, multiConfig);
        std::string const depRel = cmStrCat(objRel, ".d");
        if (!source->IsPchSource() || mf->IsOn("CMAKE_LINK_PCH")) {
          linkObjects.push_back(objRel);
        }
        ReprobuildAppendCleanFile(cleanFiles, binaryDir, objRel);
        ReprobuildAppendCleanFile(cleanFiles, binaryDir, depRel);
        std::vector<std::string> languageByproducts;
        if (lang == "ISPC") {
          std::string ispcSource =
            cmSystemTools::GetFilenameWithoutLastExtension(
              gt->GetObjectName(source));
          ispcSource =
            cmSystemTools::GetFilenameWithoutLastExtension(ispcSource);
          std::string headerDir = gt->GetObjectDirectory(config);
          if (cmValue prop = gt->GetProperty("ISPC_HEADER_DIRECTORY")) {
            headerDir = cmStrCat(lg->GetCurrentBinaryDirectory(), "/", *prop);
          }
          std::string const headerSuffix =
            gt->GetSafeProperty("ISPC_HEADER_SUFFIX");
          std::string const headerRel = ReprobuildConfigFullPath(
            binaryDir, cmStrCat(headerDir, "/", ispcSource, headerSuffix),
            config, multiConfig);
          languageByproducts.push_back(headerRel);
          ReprobuildAppendCleanFile(cleanFiles, binaryDir, headerRel);
          std::vector<std::string> suffixes =
            detail::ComputeISPCObjectSuffixes(gt);
          std::vector<std::string> extraObjects =
            detail::ComputeISPCExtraObjects(gt->GetObjectName(source),
                                            gt->GetObjectDirectory(config),
                                            suffixes);
          for (std::string const& extraObject : extraObjects) {
            std::string const extraRel =
              ReprobuildConfigFullPath(binaryDir, extraObject, config,
                                       multiConfig);
            languageByproducts.push_back(extraRel);
            ReprobuildAppendUnique(linkObjects, extraRel);
            ReprobuildAppendCleanFile(cleanFiles, binaryDir, extraRel);
            sawISPCMultiOutput = true;
          }
        }
        cmSystemTools::MakeDirectory(
          cmSystemTools::GetFilenamePath(cmStrCat(binaryDir, "/", objRel)));
        std::string sourcePath = source->GetFullPath();
        std::string sourceArg = sourcePath;
        std::string const binaryPrefix = cmStrCat(binaryDir, "/");
        if (multiConfig && sourcePath.rfind(binaryPrefix, 0) == 0) {
          sourcePath =
            ReprobuildConfigFullPath(binaryDir, sourcePath, config, true);
          sourceArg = cmStrCat(binaryDir, "/", sourcePath);
        }
        // TryCompile test sources live under each project's per-invocation
        // <binary_dir>/CMakeFiles/CMakeScratch/TryCompile-<random>/ scratch
        // dir, so projects with byte-identical probe content compile-hash
        // to distinct strong-fingerprint inputs and never share the action
        // cache. Stage the source through a content-addressed path under
        // the user-level reprobuild store so two projects asking the same
        // CMake check actually hit. The path move is symmetric — both
        // action.Inputs and the compiler-argv entry sourceArg adopt the
        // canonical path so weak and strong fingerprints both line up.
        if (this->GetCMakeInstance()->GetIsInTryCompile()) {
          std::string const canonicalPath =
            ReprobuildCanonicaliseTryCompileSourcePath(sourceArg);
          if (canonicalPath != sourceArg) {
            sourcePath = canonicalPath;
            sourceArg = canonicalPath;
          }
        }

        std::vector<std::string> args;
        std::string explicitLanguageFlags;
        gt->AddExplicitLanguageFlags(explicitLanguageFlags, *source);
        ReprobuildAppendParsed(args, explicitLanguageFlags);

        std::string flags;
        lg->GetTargetCompileFlags(gt, config, lang, flags, "");
        ReprobuildAppendParsed(args, flags);
        ReprobuildAppendSourcePropertyCompileArgs(args, lg.get(), gt, source,
                                                  config, lang);

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

        if (target.HcrEnabled) {
          std::string const compilerId =
            mf->GetSafeDefinition(cmStrCat("CMAKE_", lang, "_COMPILER_ID"));
          if (!ReprobuildCompilerSupportsHcr(compilerId)) {
            this->GetCMakeInstance()->IssueMessage(
              MessageType::FATAL_ERROR,
              cmStrCat("Reprobuild HCR profile unavailable for target '",
                       gt->GetName(), "': compiler id '", compilerId,
                       "' does not support the current debug-info and "
                       "patchable-function-entry HCR profile."));
            return;
          }
          if (ReprobuildContainsNoDebugFlag(args)) {
            this->GetCMakeInstance()->IssueMessage(
              MessageType::FATAL_ERROR,
              cmStrCat("Reprobuild HCR profile unavailable for target '",
                       gt->GetName(),
                       "': debug information was explicitly disabled by "
                       "compile flags."));
            return;
          }
          if (ReprobuildContainsLtoFlag(args)) {
            this->GetCMakeInstance()->IssueMessage(
              MessageType::FATAL_ERROR,
              cmStrCat("Reprobuild HCR profile unavailable for target '",
                       gt->GetName(),
                       "': LTO flags are incompatible with HCR affected "
                       "object lookup."));
            return;
          }
          ReprobuildAppendHcrCompilePolicy(args);
        }

        if (lang == "Fortran") {
          std::string const ppRel = cmStrCat(objRel, ".ddi.i");
          std::string const ddiRel = cmStrCat(objRel, ".ddi");
          std::string const scanDepRel = cmStrCat(ppRel, ".d");

          ReprobuildAction scan;
          scan.Id = ReprobuildSafeId(cmStrCat("scan-", gt->GetName(), "-",
                                              objRel, configSuffix));
          scan.Var = ReprobuildNimIdent("action", nextActionVar++, scan.Id);
          scan.ToolId = ReprobuildSafeId(cmStrCat("reprobuild-cmake-",
                                                  scan.Var));
          std::vector<std::string> scanLines;
          scanLines.push_back(cmStrCat(
            ReprobuildShellSingleQuote(
              mf->GetSafeDefinition(ReprobuildCompilerVar(lang))),
            " -cpp -E ", cmJoin(args, " "), " ",
              ReprobuildShellSingleQuote(sourceArg), " -o ",
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
            ReprobuildShellSingleQuote(sourceArg)));
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
          scan.Inputs = { sourcePath, tdiRel };
          if (declareOutputs) {
            scan.Outputs = { ppRel, ddiRel };
            scan.Depfile = scanDepRel;
          } else {
            scan.Cacheable = false;
          }
          dyndepDdis[lang].push_back(ddiRel);
          dyndepScanActions[lang].push_back(scan.Id);
          dyndepActionMaps[lang].push_back({ objRel, ReprobuildSafeId(
                                                       cmStrCat("compile-",
                                                                gt->GetName(),
                                                                "-", objRel,
                                                                configSuffix)) });
          target.CustomActions.push_back(std::move(scan));

          args.push_back("-o");
          args.push_back(objRel);
          args.push_back("-c");
          args.push_back(ppRel);
        } else if (lang == "ISPC") {
          args.push_back("-M");
          args.push_back("-MT");
          args.push_back(objRel);
          args.push_back("-MF");
          args.push_back(depRel);
          args.push_back("-o");
          args.push_back(objRel);
          args.push_back("--emit-obj");
          args.push_back(sourceArg);
          if (!languageByproducts.empty()) {
            args.push_back("-h");
            args.push_back(languageByproducts.front());
          }
        } else {
          if (lang == "CUDA" &&
              gt->GetPropertyAsBool("CUDA_SEPARABLE_COMPILATION")) {
            ReprobuildAppendParsed(
              args, mf->GetSafeDefinition("_CMAKE_CUDA_RDC_FLAG"));
          }
          bool const needCxxDyndep =
            lang == "CXX" && gt->NeedDyndepForSource(lang, config, source);
          if (needCxxDyndep) {
            std::string const ddiRel = cmStrCat(objRel, ".ddi");
            std::string const scanDepRel = cmStrCat(ddiRel, ".d");
            ReprobuildAction scan;
            scan.Id = ReprobuildSafeId(cmStrCat("scan-", gt->GetName(), "-",
                                                objRel, configSuffix));
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
              ReprobuildShellSingleQuote(sourceArg), " -c -o ",
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
            scan.Inputs = { sourcePath };
            if (declareOutputs) {
              scan.Outputs = { ddiRel };
              scan.Depfile = scanDepRel;
            } else {
              scan.Cacheable = false;
            }
            dyndepDdis[lang].push_back(ddiRel);
            dyndepScanActions[lang].push_back(scan.Id);
            dyndepActionMaps[lang].push_back({ objRel, ReprobuildSafeId(
                                                         cmStrCat("compile-",
                                                                  gt->GetName(),
                                                                  "-", objRel,
                                                                  configSuffix)) });
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
          args.push_back(sourceArg);
        }

        ReprobuildAction action;
        action.Id = ReprobuildSafeId(cmStrCat("compile-", gt->GetName(), "-",
                                              objRel, configSuffix));
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
        // Tier 2a + 2c: lift every C/CXX compile action to inline-exec.
        // The compiler binary is fully resolved by CMake's language
        // detection (CMAKE_<LANG>_COMPILER), so the action is
        // self-contained and does not need a typed tool profile. This
        // makes the action runnable by the direct provider without going
        // through resolveAndWriteIdentity, AND lets the slow-path
        // engine skip per-action tool-profile lookups for compiles.
        // Fortran is excluded because its scan/dyndep machinery still
        // assumes tool-profile lookup.
        if (lang != "Fortran") {
          std::string const compilerPath =
            mf->GetSafeDefinition(ReprobuildCompilerVar(lang));
          if (!compilerPath.empty()) {
            action.Inline = true;
            action.InlineArgv.clear();
            // If a per-target RULE_LAUNCH_COMPILE launcher was configured,
            // prepend its argv. The wrapper script the slow path writes
            // (ReprobuildWriteLaunchedWrapper) effectively runs
            // ``<launcher_argv> <compiler> "$@"`` — inline-exec mirrors
            // that with the launcher argv directly in the action's argv.
            if (!launcher.empty()) {
              std::vector<std::string> launcherInline;
              if (launcher.find(';') != std::string::npos) {
                cmList launcherList{ launcher };
                launcherInline.assign(launcherList.begin(),
                                      launcherList.end());
              } else {
                ReprobuildAppendParsed(launcherInline, launcher);
              }
              for (std::string const& part : launcherInline) {
                action.InlineArgv.push_back(part);
              }
            }
            action.InlineArgv.push_back(compilerPath);
            for (std::string const& arg : args) {
              action.InlineArgv.push_back(arg);
            }
            action.InlineCwd = binaryDir;
          }
        }
        if (lang == "Fortran") {
          action.Inputs = { cmStrCat(objRel, ".ddi.i") };
        } else {
          action.Inputs = { sourcePath };
        }
        if (declareOutputs) {
          action.Outputs = { objRel };
          cm::append(action.Outputs, languageByproducts);
        } else {
          action.Cacheable = false;
          for (ReprobuildAction const& custom : target.CustomActions) {
            ReprobuildAppendUnique(action.Deps, custom.Id);
          }
        }
        if (declareOutputs && lang != "Fortran") {
          action.Depfile = depRel;
        }
        if (declareOutputs &&
            (lang == "Fortran" ||
             (lang == "CXX" && gt->NeedDyndepForSource(lang, config, source)))) {
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
        action.CompileFile = sourceArg;
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
        }
        if (target.HcrEnabled && (lang == "C" || lang == "CXX")) {
          target.HcrObjects.push_back(ReprobuildHcrObject{
            sourcePath, objRel, action.Id, lang });
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
                                              lang, configSuffix));
        dyndep.Var =
          ReprobuildNimIdent("action", nextActionVar++, dyndep.Id);
        dyndep.ToolId =
          ReprobuildSafeId(cmStrCat("reprobuild-cmake-", dyndep.Var));
        dyndep.Deps = dyndepScanActions[lang];
        dyndep.Inputs = ddis;
        dyndep.Inputs.push_back(tdiRel);
        dyndep.Inputs.push_back(mapRel);
        if (declareOutputs) {
          dyndep.Outputs = { ddRel, fragmentRel,
                             cmStrCat(cmSystemTools::GetFilenamePath(ddRel),
                                      "/", lang, "Modules.json") };
          if (lang == "CXX") {
            for (auto const& mapEntry : dyndepActionMaps[lang]) {
              dyndep.Outputs.push_back(cmStrCat(mapEntry.first, ".modmap"));
            }
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
        return ReprobuildConfigFullPath(
          binaryDir,
          cmStrCat(objectTarget->GetObjectDirectory(config),
                   objectTarget->GetObjectName(source)),
          config, multiConfig);
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
                                            objRel, configSuffix)));
        }
      };

      auto appendCustomEventActions =
        [&](std::vector<cmCustomCommand> const& commands,
            std::string const& stage, std::vector<ReprobuildAction>& actions) {
          unsigned int eventIndex = 0;
          for (cmCustomCommand const& cc : commands) {
            cmCustomCommandGenerator ccg(cc, commandConfig, lg.get(), false,
                                         config);
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
            retargetCommandConfigExecutables(ccg, commandLines);

            ReprobuildAction event;
            event.Id = ReprobuildSafeId(cmStrCat(stage, "-", gt->GetName(),
                                                 "-", eventIndex++,
                                                 configSuffix));
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
              if (declareOutputs) {
                event.Outputs.push_back(ReprobuildRelativeTo(
                  binaryDir,
                  cmSystemTools::CollapseFullPath(
                    byproduct, lg->GetCurrentBinaryDirectory())));
              }
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

      std::vector<std::string> cudaDeviceLinkActionIds;
      if (targetHasCudaSources &&
          (gt->GetPropertyAsBool("CUDA_SEPARABLE_COMPILATION") ||
           gt->GetPropertyAsBool("CUDA_RESOLVE_DEVICE_SYMBOLS")) &&
          type != cmStateEnums::OBJECT_LIBRARY) {
        cmMakefile const* mf = lg->GetMakefile();
        if (mf->GetSafeDefinition("CMAKE_REPROBUILD_CUDA_PROFILE") ==
              "ClangFatbinary" &&
            mf->GetSafeDefinition("CMAKE_CUDA_COMPILER_ID") != "Clang" &&
            mf->GetSafeDefinition("CMAKE_CUDA_COMPILER_ID") != "AppleClang") {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            "Reprobuild profile unavailable: Clang CUDA fatbinary and "
            "registration-stub profile requires a Clang CUDA compiler.");
          return;
        }
        std::string const deviceObjRel = ReprobuildConfigFullPath(
          binaryDir,
          cmStrCat(gt->GetObjectDirectory(config),
                   "cmake_device_link", mf->GetSafeDefinition(
                                          "CMAKE_CUDA_OUTPUT_EXTENSION")),
          config, multiConfig);
        ReprobuildAction deviceLink;
        deviceLink.Id =
          ReprobuildSafeId(cmStrCat("device-link-", gt->GetName(),
                                    configSuffix));
        deviceLink.Var =
          ReprobuildNimIdent("action", nextActionVar++, deviceLink.Id);
        deviceLink.ToolId = ReprobuildToolId("CUDA");
        usedTools.insert(deviceLink.ToolId);
        std::string const cudaCompilerId =
          mf->GetSafeDefinition("CMAKE_CUDA_COMPILER_ID");
        if (cudaCompilerId == "Clang" || cudaCompilerId == "AppleClang") {
          std::string architecturesStr =
            gt->GetSafeProperty("CUDA_ARCHITECTURES");
          if (cmIsOff(architecturesStr)) {
            this->GetCMakeInstance()->IssueMessage(
              MessageType::FATAL_ERROR,
              "CUDA_SEPARABLE_COMPILATION on Clang requires "
              "CUDA_ARCHITECTURES to be set.");
            return;
          }
          cmList architectures{ architecturesStr };
          if (architectures.empty()) {
            this->GetCMakeInstance()->IssueMessage(
              MessageType::FATAL_ERROR,
              "Reprobuild profile unavailable: Clang CUDA fatbinary and "
              "registration-stub flow requires CUDA_ARCHITECTURES.");
            return;
          }
          std::string const cudaDeviceLinker =
            mf->GetSafeDefinition("CMAKE_CUDA_DEVICE_LINKER");
          std::string const cudaFatbinary =
            mf->GetSafeDefinition("CMAKE_CUDA_FATBINARY");
          if (cudaDeviceLinker.empty() || cudaFatbinary.empty()) {
            this->GetCMakeInstance()->IssueMessage(
              MessageType::FATAL_ERROR,
              "Reprobuild profile unavailable: Clang CUDA fatbinary and "
              "registration-stub tools were not found.");
            return;
          }
          std::string const dlinkToolId =
            ReprobuildSafeId("reprobuild-cmake-cuda-device-linker");
          std::string const fatbinaryToolId =
            ReprobuildSafeId("reprobuild-cmake-cuda-fatbinary");
          if (!ReprobuildWriteWrapper(cmStrCat(wrapperDir, "/", dlinkToolId),
                                      cudaDeviceLinker) ||
              !ReprobuildWriteWrapper(
                cmStrCat(wrapperDir, "/", fatbinaryToolId), cudaFatbinary)) {
            this->GetCMakeInstance()->IssueMessage(
              MessageType::FATAL_ERROR,
              "Could not write Reprobuild Clang CUDA tool wrappers.");
            return;
          }
          usedTools.insert(dlinkToolId);
          usedTools.insert(fatbinaryToolId);

          std::string const registerRel = ReprobuildConfigFullPath(
            binaryDir,
            cmStrCat(gt->GetObjectDirectory(config),
                     "cmake_cuda_register.h"),
            config, multiConfig);
          std::string const fatbinRel = ReprobuildConfigFullPath(
            binaryDir,
            cmStrCat(gt->GetObjectDirectory(config), "cmake_cuda_fatbin.h"),
            config, multiConfig);
          std::vector<std::string> cubinRels;
          std::vector<std::string> cubinActionIds;
          for (std::string const& architectureKind : architectures) {
            std::string const architecture =
              architectureKind.substr(0, architectureKind.find('-'));
            std::string const cubinRel = ReprobuildConfigFullPath(
              binaryDir,
              cmStrCat(gt->GetObjectDirectory(config), "sm_", architecture,
                       ".cubin"),
              config, multiConfig);
            ReprobuildAction cubinLink;
            cubinLink.Id = ReprobuildSafeId(
              cmStrCat("cuda-device-link-", gt->GetName(), "-sm-",
                       architecture, configSuffix));
            cubinLink.Var =
              ReprobuildNimIdent("action", nextActionVar++, cubinLink.Id);
            cubinLink.ToolId = dlinkToolId;
            cubinLink.Args = { cmStrCat("-arch=sm_", architecture) };
            if (cubinRels.empty()) {
              cubinLink.Args.push_back(
                cmStrCat("--register-link-binaries=", registerRel));
            }
            cubinLink.Args.push_back("-o");
            cubinLink.Args.push_back(cubinRel);
            cm::append(cubinLink.Args, linkObjects);
            cubinLink.Inputs = linkObjects;
            for (ReprobuildAction const& compile : target.CompileActions) {
              ReprobuildAppendUnique(cubinLink.Deps, compile.Id);
            }
            if (declareOutputs) {
              cubinLink.Outputs = { cubinRel };
              if (cubinRels.empty()) {
                cubinLink.Outputs.push_back(registerRel);
              }
            } else {
              cubinLink.Cacheable = false;
            }
            ReprobuildAppendCleanFile(cleanFiles, binaryDir, cubinRel);
            if (cubinRels.empty()) {
              ReprobuildAppendCleanFile(cleanFiles, binaryDir, registerRel);
            }
            cubinRels.push_back(cubinRel);
            cubinActionIds.push_back(cubinLink.Id);
            target.CustomActions.push_back(std::move(cubinLink));
          }

          ReprobuildAction fatbinary;
          fatbinary.Id =
            ReprobuildSafeId(cmStrCat("cuda-fatbinary-", gt->GetName(),
                                      configSuffix));
          fatbinary.Var =
            ReprobuildNimIdent("action", nextActionVar++, fatbinary.Id);
          fatbinary.ToolId = fatbinaryToolId;
          fatbinary.Args = { "-64", "-cmdline=--compile-only",
                             "-compress-all", "-link",
                             cmStrCat("--embedded-fatbin=", fatbinRel) };
          for (std::size_t i = 0; i < cubinRels.size(); ++i) {
            std::string const architecture =
              architectures[i].substr(0, architectures[i].find('-'));
            fatbinary.Args.push_back(
              cmStrCat("-im=profile=sm_", architecture, ",file=",
                       cubinRels[i]));
            fatbinary.Inputs.push_back(cubinRels[i]);
            fatbinary.Deps.push_back(cubinActionIds[i]);
          }
          if (declareOutputs) {
            fatbinary.Outputs = { fatbinRel };
          } else {
            fatbinary.Cacheable = false;
          }
          ReprobuildAppendCleanFile(cleanFiles, binaryDir, fatbinRel);
          std::string const fatbinaryActionId = fatbinary.Id;
          target.CustomActions.push_back(std::move(fatbinary));

          ReprobuildAction stubCompile;
          stubCompile.Id =
            ReprobuildSafeId(cmStrCat("cuda-registration-stub-",
                                      gt->GetName(), configSuffix));
          stubCompile.Var =
            ReprobuildNimIdent("action", nextActionVar++, stubCompile.Id);
          stubCompile.ToolId = ReprobuildToolId("CUDA");
          usedTools.insert(stubCompile.ToolId);
          ReprobuildAppendCommonCompileArgs(stubCompile.Args, lg.get(), gt,
                                            config, "CUDA");
          cmLinkLineDeviceComputer deviceLinkComputer(
            lg.get(), lg->GetStateSnapshot().GetDirectory());
          std::string linkLibs;
          std::string linkFlags;
          std::string frameworkPath;
          std::string linkPath;
          lg->GetDeviceLinkFlags(deviceLinkComputer, config, linkLibs,
                                 linkFlags, frameworkPath, linkPath, gt);
          ReprobuildAppendParsed(stubCompile.Args, linkFlags);
          stubCompile.Args.push_back(
            "-D__CUDA_INCLUDE_COMPILER_INTERNAL_HEADERS__");
          stubCompile.Args.push_back("-D__NV_EXTRA_INITIALIZATION=\"\"");
          stubCompile.Args.push_back("-D__NV_EXTRA_FINALIZATION=\"\"");
          stubCompile.Args.push_back(cmStrCat(
            "-DREGISTERLINKBINARYFILE=\\\"", registerRel, "\\\""));
          stubCompile.Args.push_back(
            cmStrCat("-DFATBINFILE=\\\"", fatbinRel, "\\\""));
          ReprobuildAppendParsed(
            stubCompile.Args,
            mf->GetSafeDefinition("_CMAKE_COMPILE_AS_CUDA_FLAG"));
          std::string const linkStub =
            cmStrCat(mf->GetSafeDefinition(
                       "CMAKE_CUDA_COMPILER_TOOLKIT_LIBRARY_ROOT"),
                     "/bin/crt/link.stub");
          stubCompile.Args.push_back("-c");
          stubCompile.Args.push_back(linkStub);
          stubCompile.Args.push_back("-o");
          stubCompile.Args.push_back(deviceObjRel);
          stubCompile.Inputs = { fatbinRel, registerRel, linkStub };
          stubCompile.Deps = { fatbinaryActionId };
          if (declareOutputs) {
            stubCompile.Outputs = { deviceObjRel };
          } else {
            stubCompile.Cacheable = false;
          }
          ReprobuildAppendCleanFile(cleanFiles, binaryDir, deviceObjRel);
          cudaDeviceLinkActionIds.push_back(stubCompile.Id);
          target.CustomActions.push_back(std::move(stubCompile));
          ReprobuildAppendUnique(linkObjects, deviceObjRel);
          sawCudaDeviceLink = true;
          sawCudaClangFatbinary = true;
          continue;
        } else {
          deviceLink.Args.push_back("-dlink");
        }
        deviceLink.Args.push_back("-o");
        deviceLink.Args.push_back(deviceObjRel);
        cm::append(deviceLink.Args, linkObjects);
        deviceLink.Inputs = linkObjects;
        for (ReprobuildAction const& compile : target.CompileActions) {
          ReprobuildAppendUnique(deviceLink.Deps, compile.Id);
        }
        if (declareOutputs) {
          deviceLink.Outputs = { deviceObjRel };
        } else {
          deviceLink.Cacheable = false;
        }
        ReprobuildAppendCleanFile(cleanFiles, binaryDir, deviceObjRel);
        cudaDeviceLinkActionIds.push_back(deviceLink.Id);
        target.CustomActions.push_back(std::move(deviceLink));
        ReprobuildAppendUnique(linkObjects, deviceObjRel);
        sawCudaDeviceLink = true;
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
        ReprobuildSafeId(cmStrCat("link-", gt->GetName(), configSuffix));
      target.LinkAction.Var =
        ReprobuildNimIdent("action", nextActionVar++, target.LinkAction.Id);
      target.LinkAction.Pool = ReprobuildPoolProperty(gt, nullptr,
                                                      "JOB_POOL_LINK", "");
      for (ReprobuildAction const& compile : target.CompileActions) {
        ReprobuildAppendUnique(target.LinkAction.Deps, compile.Id);
      }
      for (std::string const& deviceLinkAction : cudaDeviceLinkActionIds) {
        ReprobuildAppendUnique(target.LinkAction.Deps, deviceLinkAction);
      }
      for (ReprobuildAction& preLink : target.PreLinkActions) {
        for (ReprobuildAction const& compile : target.CompileActions) {
          ReprobuildAppendUnique(preLink.Deps, compile.Id);
        }
      }

      std::vector<std::string> linkDependencyActions;
      std::vector<std::string> linkLibraryInputs;
      auto appendLinkedTarget = [&](cmGeneratorTarget const* depTargetConst,
                                    bool includeObjectLibraryOutputs) {
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
          if (includeObjectLibraryOutputs) {
            appendObjectLibraryOutputs(depTarget, linkObjects,
                                       linkDependencyActions);
          }
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
          ReprobuildAppendUnique(
            linkLibraryInputs,
            ReprobuildConfigPath(depPath, config, multiConfig));
          ReprobuildAppendUnique(linkDependencyActions,
                                ReprobuildSafeId(cmStrCat("link-",
                                                          depTarget->GetName(),
                                                          configSuffix)));
        }
      };

      std::vector<cmSourceFile const*> externalObjects;
      gt->GetExternalObjects(externalObjects, config);
      for (cmSourceFile const* externalObject : externalObjects) {
        std::string const& objLib = externalObject->GetObjectLibrary();
        if (!objLib.empty()) {
          appendLinkedTarget(lg->FindGeneratorTargetToUse(objLib), true);
        } else {
          ReprobuildAppendUnique(
            linkObjects,
            ReprobuildConfigFullPath(binaryDir, externalObject->GetFullPath(),
                                     config, multiConfig));
        }
      }
      if (cmComputeLinkInformation* cli = gt->GetLinkInformation(config)) {
        for (cmComputeLinkInformation::Item const& item : cli->GetItems()) {
          if (item.Target) {
            appendLinkedTarget(item.Target, false);
          } else if (item.ObjectSource) {
            std::string const& objLib = item.ObjectSource->GetObjectLibrary();
            if (!objLib.empty()) {
              appendLinkedTarget(lg->FindGeneratorTargetToUse(objLib), true);
            } else {
              ReprobuildAppendUnique(
                linkObjects,
                ReprobuildConfigFullPath(binaryDir,
                                         item.ObjectSource->GetFullPath(),
                                         config, multiConfig));
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

      std::string const output = ReprobuildConfigFullPath(
        binaryDir, gt->GetFullPath(config), config, multiConfig);
      std::string const realOutput = ReprobuildConfigFullPath(
        binaryDir,
        gt->GetFullPath(config, cmStateEnums::RuntimeBinaryArtifact, true),
        config, multiConfig);
      ReprobuildAppendCleanFile(cleanFiles, binaryDir, output);
      ReprobuildAppendCleanFile(cleanFiles, binaryDir, realOutput);
      if (gt->IsBundleOnApple()) {
        std::string plistFull;
        if (gt->IsAppBundleOnApple()) {
          plistFull = cmStrCat(
            gt->GetDirectory(config), "/",
            gt->GetAppBundleDirectory(config,
                                      cmGeneratorTarget::ContentLevel),
            "/Info.plist");
        } else if (gt->IsFrameworkOnApple()) {
          plistFull = cmStrCat(
            gt->GetDirectory(config), "/",
            gt->GetFrameworkDirectory(config,
                                      cmGeneratorTarget::FullLevel),
            "/Resources/Info.plist");
        } else if (gt->IsCFBundleOnApple()) {
          plistFull = cmStrCat(
            gt->GetDirectory(config), "/",
            gt->GetCFBundleDirectory(config,
                                     cmGeneratorTarget::ContentLevel),
            "/Info.plist");
        }
        if (!plistFull.empty()) {
          ReprobuildAppendCleanFile(
            cleanFiles, binaryDir,
            ReprobuildConfigFullPath(binaryDir, plistFull, config,
                                     multiConfig));
        }
      }
      cmSystemTools::MakeDirectory(
        cmSystemTools::GetFilenamePath(cmStrCat(binaryDir, "/", realOutput)));

      if (type == cmStateEnums::STATIC_LIBRARY) {
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
        // Inline-exec: emit a single `ar rcs <output> <objects…>` invocation.
        // The flags collapse what the old multi-step shell wrapper did
        // (`rm -f output; ar qc output objects…; ranlib output`) into one
        // direct call: `r` replaces matching members (so re-runs don't
        // accumulate duplicates the way `qc` would), `c` suppresses the
        // "creating archive" warning, and `s` writes the symbol table —
        // i.e. ar performs its own ranlib step. CMAKE_RANLIB is not invoked
        // separately on the modern toolchains the bench exercises; if an
        // AIX-style toolchain ever needs a follow-up ranlib edge we can
        // add it as a second inline-exec depending on this one.
        std::vector<std::string> archiveArgv = { arTool, "rcs", output };
        cm::append(archiveArgv, linkObjects);
        target.LinkAction.Inline = true;
        target.LinkAction.InlineArgv = std::move(archiveArgv);
        target.LinkAction.Inputs = linkObjects;
        if (declareOutputs) {
          target.LinkAction.Outputs = { output };
        }
      } else {
        usedTools.insert(ReprobuildToolId(linkLang));
        std::string flags;
        std::string linkFlags;
        std::string linkLibs;
        std::string frameworkPath;
        std::string linkPath;
        // Reprobuild runs actions from the build root.  Use the root local
        // generator for link-line path conversion so CMake does not emit
        // library references relative to a target subdirectory.
        cmLinkLineComputer linkLineComputer(
          rootLg, rootLg->GetStateSnapshot().GetDirectory());
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
        if (linkLang == "Swift") {
          std::string swiftFlags;
          lg->GetTargetCompileFlags(gt, config, "Swift", swiftFlags, "");
          ReprobuildAppendParsed(linkArgs, swiftFlags);
          if (type == cmStateEnums::EXECUTABLE) {
            linkArgs.push_back("-emit-executable");
          } else if (type == cmStateEnums::SHARED_LIBRARY ||
                     type == cmStateEnums::MODULE_LIBRARY) {
            linkArgs.push_back("-emit-library");
          }
        }
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
        if (target.HcrEnabled && ReprobuildContainsLtoFlag(linkArgs)) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Reprobuild HCR profile unavailable for target '",
                     gt->GetName(),
                     "': link flags request LTO/linker-plugin behavior, "
                     "which is incompatible with HCR linkgraph evidence."));
          return;
        }
        target.LinkAction.ToolId = ReprobuildToolId(linkLang);
        target.LinkAction.Args = linkArgs;
        target.LinkAction.Inputs = linkObjects;
        for (std::string const& linkLibraryInput : linkLibraryInputs) {
          ReprobuildAppendUnique(target.LinkAction.Inputs, linkLibraryInput);
        }
        if (declareOutputs) {
          target.LinkAction.Outputs = { realOutput };
        }
        if (gt->HasImportLibrary(config)) {
          std::string const importOutput = ReprobuildRelativeTo(
            binaryDir,
            gt->GetFullPath(config, cmStateEnums::ImportLibraryArtifact, true));
          std::string const importOutputConfig =
            ReprobuildConfigPath(importOutput, config, multiConfig);
          if (!importOutput.empty()) {
            ReprobuildAppendCleanFile(cleanFiles, binaryDir,
                                      importOutputConfig);
            if (declareOutputs) {
              ReprobuildAppendUnique(target.LinkAction.Outputs,
                                     importOutputConfig);
            }
            sawImportLibraryOutput = true;
            // The link command is hand-built above and -- unlike CMake's
            // CMAKE_<LANG>_CREATE_SHARED_LIBRARY rule -- carries no import
            // library flag. A GNU-family linker would therefore produce the
            // DLL but never the import library (.dll.a) declared as an output
            // just above, so a consumer opening that output fails. Emit the
            // flag explicitly. (MSVC's linker writes the import library for a
            // /DLL automatically and needs no flag.)
            std::string const linkerId = lg->GetMakefile()->GetSafeDefinition(
              cmStrCat("CMAKE_", linkLang, "_COMPILER_ID"));
            std::string const linkerSimId =
              lg->GetMakefile()->GetSafeDefinition(
                cmStrCat("CMAKE_", linkLang, "_SIMULATE_ID"));
            bool const gnuStyleLinker =
              linkerId == "GNU" ||
              ((linkerId == "Clang" || linkerId == "AppleClang") &&
               linkerSimId != "MSVC");
            if (gnuStyleLinker) {
              target.LinkAction.Args.push_back(
                cmStrCat("-Wl,--out-implib,", importOutputConfig));
            }
          }
        }
        if (declareOutputs && gt->HasLinkDependencyFile(config)) {
          target.LinkAction.Depfile = lg->GetLinkDependencyFile(gt, config);
          ReprobuildAppendCleanFile(cleanFiles, binaryDir,
                                    target.LinkAction.Depfile);
          sawLinkDepfile = true;
        }
        // Tier 2a + 2c: lift the link action to inline-exec. The compiler
        // path is fully resolved (CMAKE_<LANG>_COMPILER) and the action is
        // self-contained. Build InlineArgv from target.LinkAction.Args
        // AFTER the HasImportLibrary block above has appended its
        // -Wl,--out-implib flag, so InlineArgv stays a faithful copy of
        // the final argv list.
        {
          cmMakefile const* linkMf = lg->GetMakefile();
          std::string const linkerPath =
            linkMf->GetSafeDefinition(ReprobuildCompilerVar(linkLang));
          if (!linkerPath.empty()) {
            target.LinkAction.Inline = true;
            target.LinkAction.InlineArgv.clear();
            target.LinkAction.InlineArgv.push_back(linkerPath);
            for (std::string const& arg : target.LinkAction.Args) {
              target.LinkAction.InlineArgv.push_back(arg);
            }
            target.LinkAction.InlineCwd = binaryDir;
          }
        }
      }
      if (!declareOutputs) {
        target.LinkAction.Cacheable = false;
      }
      target.HasLinkAction = true;

      if (type == cmStateEnums::SHARED_LIBRARY && output != realOutput) {
        cmGeneratorTarget::Names const names = gt->GetLibraryNames(config);
        std::string const soName = ReprobuildRelativeTo(
          binaryDir,
          cmStrCat(gt->GetDirectory(config), "/", names.SharedObject));
        ReprobuildAction symlinkAction;
        symlinkAction.Id =
          ReprobuildSafeId(cmStrCat("symlink-", gt->GetName(),
                                    configSuffix));
        symlinkAction.Var = ReprobuildNimIdent("action", nextActionVar++,
                                               symlinkAction.Id);
        // Inline-exec both symlink flavours: a framework's "Versions/Current"
        // shortcut uses `cmake -E create_symlink`, an ordinary shared-library
        // soname chain uses `cmake -E cmake_symlink_library`. Both are
        // single direct cmake.exe invocations — no shell, no wrapper script.
        std::string const cmakeCmd = cmSystemTools::GetCMakeCommand();
        symlinkAction.Inline = true;
        symlinkAction.InlineCwd = binaryDir;
        if (gt->IsFrameworkOnApple()) {
          std::string const frameworkLinkTarget = cmStrCat(
            "Versions/Current/", cmSystemTools::GetFilenameName(realOutput));
          symlinkAction.InlineArgv = {
            cmakeCmd, "-E", "create_symlink", frameworkLinkTarget, output
          };
        } else {
          symlinkAction.InlineArgv = {
            cmakeCmd, "-E", "cmake_symlink_library",
            realOutput, soName, output
          };
        }
        symlinkAction.Inputs = { realOutput };
        if (declareOutputs) {
          symlinkAction.Outputs = { output };
        } else {
          symlinkAction.Cacheable = false;
        }
        if (soName != output && soName != realOutput) {
          if (declareOutputs) {
            symlinkAction.Outputs.insert(symlinkAction.Outputs.begin(), soName);
          }
          ReprobuildAppendCleanFile(cleanFiles, binaryDir, soName);
        }
        ReprobuildAppendCleanFile(cleanFiles, binaryDir, output);
        symlinkAction.Deps = { target.LinkAction.Id };
        sawSymlinkOutput = true;
        target.SymlinkActions.push_back(std::move(symlinkAction));
      }

      if (target.HcrEnabled) {
        if (target.HcrObjects.empty()) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Reprobuild HCR profile unavailable for target '",
                     gt->GetName(),
                     "': no C or CXX object compile actions were available "
                     "for affected object lookup."));
          return;
        }
        ReprobuildAction linkGraph;
        linkGraph.Id =
          ReprobuildSafeId(cmStrCat("hcr-linkgraph-", gt->GetName(),
                                    configSuffix));
        linkGraph.Var =
          ReprobuildNimIdent("action", nextActionVar++, linkGraph.Id);
        linkGraph.ToolId =
          ReprobuildSafeId(cmStrCat("reprobuild-cmake-", linkGraph.Var));
        linkGraph.Inputs = { realOutput };
        linkGraph.Cacheable = false;
        std::string const linkGraphRel =
          cmStrCat("CMakeFiles/reprobuild/hcr/", linkGraph.Var,
                   ".linkgraph");
        if (declareOutputs) {
          linkGraph.Outputs = { linkGraphRel };
        }
        std::vector<std::string> lines;
        lines.push_back(cmStrCat("out=", ReprobuildShellSingleQuote(linkGraphRel),
                                 "; bin=", ReprobuildShellSingleQuote(realOutput),
                                 "; mkdir -p \"$(dirname \"$out\")\"; "
                                 "tmp=\"$out.tmp\"; "
                                 "{ printf '%s\\n' "
                                 "'schema_id=reprobuild.hcr.linkgraph-evidence.v1'; "
                                 "printf 'target=%s\\n' ",
                                 ReprobuildShellSingleQuote(target.Name),
                                 "; printf 'binary=%s\\n' \"$bin\"; "
                                 "if command -v file >/dev/null 2>&1; then "
                                 "printf '%s\\n' 'file_begin'; file \"$bin\"; "
                                 "printf '%s\\n' 'file_end'; fi; "
                                 "if command -v nm >/dev/null 2>&1; then "
                                 "printf '%s\\n' 'symbols_begin'; "
                                 "nm -an \"$bin\" 2>&1 | head -200; "
                                 "printf '%s\\n' 'symbols_end'; fi; "
                                 "if command -v otool >/dev/null 2>&1; then "
                                 "printf '%s\\n' 'load_commands_begin'; "
                                 "otool -l \"$bin\" 2>&1 | head -400; "
                                 "printf '%s\\n' 'load_commands_end'; "
                                 "elif command -v readelf >/dev/null 2>&1; then "
                                 "printf '%s\\n' 'elf_symbols_begin'; "
                                 "readelf -Ws \"$bin\" 2>&1 | head -400; "
                                 "printf '%s\\n' 'elf_symbols_end'; fi; "
                                 "} > \"$tmp\"; test -s \"$tmp\"; "
                                 "mv \"$tmp\" \"$out\""));
        std::string const wrapperPath =
          cmStrCat(wrapperDir, "/", linkGraph.ToolId);
        if (!ReprobuildWriteCommandScript(wrapperPath, binaryDir, lines)) {
          this->GetCMakeInstance()->IssueMessage(
            MessageType::FATAL_ERROR,
            cmStrCat("Could not write Reprobuild HCR linkgraph wrapper: ",
                     wrapperPath));
          return;
        }
        usedTools.insert(linkGraph.ToolId);
        target.HcrLinkOutput = realOutput;
        target.HcrLinkGraph = linkGraphRel;
        target.HcrLinkGraphAction = linkGraph.Id;
        ReprobuildAppendCleanFile(cleanFiles, binaryDir, linkGraphRel);
        target.PostBuildActions.insert(target.PostBuildActions.begin(),
                                       std::move(linkGraph));
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
      }

      for (std::string const& cleanFile : ReprobuildEvaluateCleanFiles(
             lg.get(), config, gt->GetProperty("ADDITIONAL_CLEAN_FILES"))) {
        ReprobuildAppendCleanFile(cleanFiles,
                                  lg->GetCurrentBinaryDirectory(), cleanFile);
      }
      std::vector<cmSourceFile const*> customCommands;
      gt->GetCustomCommands(customCommands, config);
      for (cmSourceFile const* sf : customCommands) {
        cmCustomCommandGenerator ccg(*sf->GetCustomCommand(), commandConfig,
                                     lg.get(), false, config);
        for (std::string const& customOutput : ccg.GetOutputs()) {
          ReprobuildAppendCleanFile(cleanFiles,
                                    binaryDir,
                                    ReprobuildConfigPath(
                                      ReprobuildOutputPath(
                                        binaryDir,
                                        lg->GetCurrentBinaryDirectory(),
                                        customOutput),
                                      config, multiConfig));
        }
        for (std::string const& byproduct : ccg.GetByproducts()) {
          ReprobuildAppendCleanFile(cleanFiles,
                                    binaryDir,
                                    ReprobuildConfigPath(
                                      ReprobuildOutputPath(
                                        binaryDir,
                                        lg->GetCurrentBinaryDirectory(),
                                        byproduct),
                                      config, multiConfig));
        }
      }
      std::vector<cmCustomCommand> buildEventCommands =
        gt->GetPreBuildCommands();
      cm::append(buildEventCommands, gt->GetPreLinkCommands());
      cm::append(buildEventCommands, gt->GetPostBuildCommands());
      for (cmCustomCommand const& cc : buildEventCommands) {
        cmCustomCommandGenerator ccg(cc, commandConfig, lg.get(), false,
                                     config);
        for (std::string const& byproduct : ccg.GetByproducts()) {
          ReprobuildAppendCleanFile(cleanFiles,
                                    binaryDir,
                                    ReprobuildConfigPath(
                                      ReprobuildOutputPath(
                                        binaryDir,
                                        lg->GetCurrentBinaryDirectory(),
                                        byproduct),
                                      config, multiConfig));
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
      std::string const depTargetName =
        ReprobuildTargetName(depName, target.OutputConfig,
                             target.CommandConfig, multiConfig);
      auto const it = targetTerminals.find(depTargetName);
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

  // All builtin targets (install, install/local, install/strip, preinstall,
  // test, package, help, rebuild_cache) emit a single direct command, so they
  // collapse to `inlineExecCall(@argv, cwd=binaryDir)` — no per-target
  // synthetic package, no shell wrapper, no entry in `uses:`. The engine's
  // `reprobuild.builtin.exec` lowering launches the argv directly.
  auto addBuiltinTarget =
    [&](std::string const& name, std::vector<std::string> const& argv,
        std::vector<std::string> const& deps, bool usesTerminal) {
      ReprobuildTarget target;
      target.Name = name;
      target.Var = ReprobuildNimIdent("target", nextTargetVar++, name);
      target.IsUtility = true;
      target.IncludeInAll = false;
      target.UtilityAction.Id = ReprobuildSafeId(cmStrCat("builtin-", name));
      target.UtilityAction.Var = ReprobuildNimIdent(
        "action", nextActionVar++, target.UtilityAction.Id);
      target.UtilityAction.Pool = usesTerminal ? "console" : "";
      target.UtilityAction.Deps = deps;
      target.UtilityAction.Cacheable = false;
      target.UtilityAction.Inline = true;
      target.UtilityAction.InlineArgv = argv;
      target.UtilityAction.InlineCwd = binaryDir;
      buildTargets.push_back(std::move(target));
      return true;
    };

  std::string const cmakeCmd = cmSystemTools::GetCMakeCommand();
  std::string const ctestCmd = cmSystemTools::GetCTestCommand();
  std::string const cpackCmd = cmSystemTools::GetCPackCommand();
  std::vector<std::string> helpTargets = { "all", "default", "clean" };
  auto addHelpTargetName = [&helpTargets](std::string const& name) {
    helpTargets.push_back(name);
  };
  bool const skipInstallRules = rootMf->IsOn("CMAKE_SKIP_INSTALL_RULES");
  if (!skipInstallRules && cmSystemTools::FileExists(
                             cmStrCat(binaryDir, "/cmake_install.cmake"))) {
    if (!addBuiltinTarget("install",
                          { cmakeCmd, "-P", "cmake_install.cmake" },
                          allTargetDeps, true) ||
        !addBuiltinTarget("install/local",
                          { cmakeCmd, "-DCMAKE_INSTALL_LOCAL_ONLY=1",
                            "-P", "cmake_install.cmake" },
                          {}, true) ||
        !addBuiltinTarget("install/strip",
                          { cmakeCmd, "-DCMAKE_INSTALL_DO_STRIP=1",
                            "-P", "cmake_install.cmake" },
                          allTargetDeps, true) ||
        !addBuiltinTarget("preinstall",
                          { cmakeCmd, "-E", "echo",
                            "Built target preinstall" },
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
    std::vector<std::string> testArgv = { ctestCmd };
    for (std::string const& arg : ctestArgs) {
      testArgv.push_back(arg);
    }
    if (!addBuiltinTarget("test", testArgv, testDeps, true)) {
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
          { cpackCmd, "--config", "./CPackConfig.cmake" },
          packageDeps, false)) {
      return;
    }
    addHelpTargetName("package");
  }
  if (cmSystemTools::FileExists(cmStrCat(binaryDir,
                                         "/CPackSourceConfig.cmake"))) {
    if (!addBuiltinTarget(
          "package_source",
          { cpackCmd, "--config", "./CPackSourceConfig.cmake" },
          {}, false)) {
      return;
    }
    addHelpTargetName("package_source");
  }
  addHelpTargetName("help");
  addHelpTargetName("rebuild_cache");
  // `help`: use `cmake -E echo` instead of a shell `echo` so the action runs
  // directly without a cmd.exe / sh.exe interpreter — cmake.exe is always
  // available since the user just invoked it.
  if (!addBuiltinTarget("help",
                        { cmakeCmd, "-E", "echo",
                          cmStrCat(
                            "The Reprobuild generator provides: ",
                            cmJoin(helpTargets, " ")) },
                        {}, false) ||
      !addBuiltinTarget("rebuild_cache",
                        { cmakeCmd, "--regenerate-during-build", "-S",
                          this->GetCMakeInstance()->GetHomeDirectory(),
                          "-B", binaryDir },
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
    // Only the sidecar (`<toolId>.repro-tool-profile`) is written. The
    // engine's PATH-only resolver looks for the sidecar directly on PATH
    // (libs/repro_tool_profiles/src/repro_tool_profiles.nim:
    // findToolProfileSidecarOnPath), so no on-disk wrapper executable is
    // needed as a PATH marker. The sidecar carries the real compiler
    // path; the build action's argv[0] is the compiler, launched
    // directly.
    std::string const wrapperPath =
      cmStrCat(wrapperDir, "/", ReprobuildToolId(lang));
    if (!ReprobuildWriteToolProfile(wrapperPath, compiler, toolPortabilityMode,
                                    true)) {
      this->GetCMakeInstance()->IssueMessage(
        MessageType::FATAL_ERROR,
        cmStrCat("Could not write Reprobuild compiler tool profile for ",
                 lang));
      return;
    }
  }
  // Archive (ar+ranlib) and symlink helpers were previously published as
  // synthetic packages (`reprobuild-cmake-ar-ranlib`,
  // `reprobuild-cmake-symlink`) backed by multi-step shell wrappers. Both
  // are now emitted as `inlineExecCall` actions in the per-target loop
  // above — the static-library link is one direct `ar rcs <output>
  // <objects…>` invocation, and the soname chain / framework shortcut is
  // one direct `cmake -E (cmake_symlink_library|create_symlink) …` call.
  // No wrappers, no synthetic packages, no entries in `uses:`.

  std::set<std::string> allCleanFiles;
  for (auto const& entry : cleanFilesByConfig) {
    allCleanFiles.insert(entry.second.begin(), entry.second.end());
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
  for (std::string const& path : allCleanFiles) {
    cleanManifest << path << "\n";
  }
  std::map<std::string, std::string> cleanManifestByConfig;
  if (multiConfig) {
    for (auto const& entry : cleanFilesByConfig) {
      std::string const configCleanManifestFile =
        cmStrCat(providerDir, "/clean-", entry.first, ".manifest");
      cmsys::ofstream configCleanManifest(configCleanManifestFile.c_str());
      if (!configCleanManifest) {
        this->GetCMakeInstance()->IssueMessage(
          MessageType::FATAL_ERROR,
          cmStrCat("Could not write Reprobuild clean manifest: ",
                   configCleanManifestFile));
        return;
      }
      for (std::string const& path : entry.second) {
        configCleanManifest << path << "\n";
      }
      cleanManifestByConfig[entry.first] = configCleanManifestFile;
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
  metadata << "m8_cuda_device_link="
           << (sawCudaDeviceLink ? "generated" : "not_required_by_targets")
           << "\n";
  metadata << "m8_cuda_clang_fatbinary="
           << (sawCudaClangFatbinary ? "generated" : "not_required_by_targets")
           << "\n";
  metadata << "m8_ispc_multiple_outputs="
           << (sawISPCMultiOutput ? "generated" : "not_required_by_targets")
           << "\n";
  metadata << "m8_swift_output_maps="
           << (sawSwiftOutputMap ? "generated" : "not_required_by_targets")
           << "\n";
  metadata << "m8_swift_split="
           << (sawSwiftSplit ? "generated" : "not_required_by_targets")
           << "\n";
  metadata << "m8_apple_bundles="
           << (sawAppleBundle ? "generated" : "not_applicable_on_host")
           << "\n";
  metadata << "source_dir=" << this->GetCMakeInstance()->GetHomeDirectory()
           << "\n";
  metadata << "binary_dir=" << binaryDir << "\n";
  metadata << "provider_root=" << providerDir << "\n";
  metadata << "wrapper_path=" << wrapperDir << "\n";
  metadata << "clean_manifest=" << cleanManifestFile << "\n";
  metadata << "cmake_regeneration=enabled\n";
  metadata << "cmake_regeneration_suppressed="
           << (this->GlobalSettingIsOn("CMAKE_SUPPRESS_REGENERATION") ? "true"
                                                                       : "false")
           << "\n";
  metadata << "cmake_command=" << cmSystemTools::GetCMakeCommand() << "\n";
  metadata << "cmake_regeneration_check_file=CMakeFiles/Makefile.cmake\n";
  metadata << "cmake_regeneration_glob_verify="
           << cmStrCat(binaryDir, "/CMakeFiles/VerifyGlobs.cmake") << "\n";
  metadata << "cmake_regeneration_provider_file="
           << cmStrCat(binaryDir, "/reprobuild.nim") << "\n";
  metadata << "cmake_regeneration_provider_state="
           << cmStrCat(providerDir, "/provider.last") << "\n";
  if (multiConfig) {
    metadata << "configurations=" << cmJoin(configs, ",") << "\n";
    metadata << "default_build_type=" << this->DefaultFileConfig << "\n";
    std::vector<std::string> defaultConfigs(this->DefaultConfigs.begin(),
                                            this->DefaultConfigs.end());
    metadata << "default_configs=" << cmJoin(defaultConfigs, ",") << "\n";
    std::vector<std::string> crossConfigs(this->CrossConfigs.begin(),
                                          this->CrossConfigs.end());
    metadata << "cross_configs=" << cmJoin(crossConfigs, ",") << "\n";
    for (auto const& entry : cleanManifestByConfig) {
      metadata << "clean_manifest_" << entry.first << "=" << entry.second
               << "\n";
    }
  }
  metadata << "default_target=all\n";

  std::vector<std::string> languages;
  this->GetEnabledLanguages(languages);
  metadata << "enabled_languages=" << cmJoin(languages, ",") << "\n";
  std::vector<std::string> targetNames;
  std::vector<std::string> hcrTargetNames;
  for (ReprobuildTarget const& target : buildTargets) {
    targetNames.push_back(target.Name);
    if (target.HcrEnabled) {
      hcrTargetNames.push_back(target.Name);
    }
  }
  metadata << "targets=all,default," << cmJoin(targetNames, ",") << "\n";
  metadata << "m10_hcr_targets="
           << (hcrTargetNames.empty() ? "not_enabled" : "generated")
           << "\n";
  metadata << "hcr_targets=" << cmJoin(hcrTargetNames, ",") << "\n";
  std::string const hcrMetadataFile = cmStrCat(providerDir, "/hcr.metadata.json");
  metadata << "hcr_metadata=" << hcrMetadataFile << "\n";

  cmsys::ofstream hcrMetadata(hcrMetadataFile.c_str());
  if (!hcrMetadata) {
    this->GetCMakeInstance()->IssueMessage(
      MessageType::FATAL_ERROR,
      cmStrCat("Could not write Reprobuild HCR metadata: ",
               hcrMetadataFile));
    return;
  }
  hcrMetadata << "{\n"
              << "  \"schemaId\": \"reprobuild.cmake.hcr.metadata.v1\",\n"
              << "  \"binaryDir\": " << ReprobuildJsonEscape(binaryDir)
              << ",\n"
              << "  \"sourceDir\": "
              << ReprobuildJsonEscape(this->GetCMakeInstance()->GetHomeDirectory())
              << ",\n"
              << "  \"targets\": [";
  char const* hcrTargetSep = "";
  for (ReprobuildTarget const& target : buildTargets) {
    if (!target.HcrEnabled) {
      continue;
    }
    hcrMetadata << hcrTargetSep << "\n    {\n"
                << "      \"name\": " << ReprobuildJsonEscape(target.Name)
                << ",\n"
                << "      \"profile\": "
                << ReprobuildJsonEscape(target.HcrProfile) << ",\n"
                << "      \"linkAction\": "
                << ReprobuildJsonEscape(target.LinkAction.Id) << ",\n"
                << "      \"linkOutput\": "
                << ReprobuildJsonEscape(target.HcrLinkOutput) << ",\n"
                << "      \"linkGraphAction\": "
                << ReprobuildJsonEscape(target.HcrLinkGraphAction) << ",\n"
                << "      \"linkGraph\": "
                << ReprobuildJsonEscape(target.HcrLinkGraph) << ",\n"
                << "      \"objects\": [";
    char const* hcrObjectSep = "";
    for (ReprobuildHcrObject const& object : target.HcrObjects) {
      hcrMetadata << hcrObjectSep << "\n        {\n"
                  << "          \"source\": "
                  << ReprobuildJsonEscape(object.Source) << ",\n"
                  << "          \"object\": "
                  << ReprobuildJsonEscape(object.Object) << ",\n"
                  << "          \"compileAction\": "
                  << ReprobuildJsonEscape(object.CompileAction) << ",\n"
                  << "          \"language\": "
                  << ReprobuildJsonEscape(object.Language) << "\n"
                  << "        }";
      hcrObjectSep = ",";
    }
    hcrMetadata << "\n      ]\n"
                << "    }";
    hcrTargetSep = ",";
  }
  hcrMetadata << "\n  ]\n"
              << "}\n";

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
             << ReprobuildEscape(action.Id) << ", ";
    if (action.Inline) {
      provider << "inlineExecCall(";
      ReprobuildWriteStringArray(provider, action.InlineArgv);
      if (!action.InlineCwd.empty()) {
        provider << ", cwd = " << ReprobuildEscape(action.InlineCwd);
      }
      provider << ")";
    } else {
      provider << "publicCliCall("
               << ReprobuildEscape(action.ToolId) << ", "
               << ReprobuildEscape(action.ToolId) << ", \"\", "
               << ReprobuildEscape(cmStrCat(action.ToolId, ".call"))
               << ", @[cliArgSeq(\"args\", ";
      ReprobuildWriteStringArray(provider, action.Args);
      provider << ", cpkPositional, 0)])";
    }
    provider << ", deps = ";
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
    provider << ", commandStatsId = "
             << ReprobuildEscape(ReprobuildCommandStatsId(action.Id))
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
  if (multiConfig) {
    using TargetConfigKey =
      std::tuple<std::string, std::string, std::string>;
    std::map<TargetConfigKey, std::string> targetVarsByConfig;
    std::map<std::string, std::vector<ReprobuildTarget const*>>
      nativeTargetsByBase;
    std::vector<ReprobuildTarget const*> nativeAllTargets;
    for (ReprobuildTarget const& target : buildTargets) {
      if (!target.BaseName.empty()) {
        targetVarsByConfig.emplace(
          TargetConfigKey{ target.BaseName, target.OutputConfig,
                           target.CommandConfig },
          target.Var);
        if (!target.IsCrossConfig) {
          nativeTargetsByBase[target.BaseName].push_back(&target);
        }
      }
      if (target.IncludeInAll && !target.IsCrossConfig) {
        nativeAllTargets.push_back(&target);
      }
    }
    auto commandConfigTargetVar =
      [&](std::string const& baseName, std::string const& outputConfig,
          std::string const& commandConfig) -> std::string {
      auto const it = targetVarsByConfig.find(
        TargetConfigKey{ baseName, outputConfig, commandConfig });
      if (it != targetVarsByConfig.end()) {
        return it->second;
      }
      return "";
    };

    for (std::string const& config : configs) {
      std::string const var =
        ReprobuildNimIdent("target", nextTargetVar++,
                           cmStrCat("all-", config));
      provider << "    let " << var << " = aggregate("
               << ReprobuildEscape(cmStrCat("all:", config))
               << ", targets = @[";
      char const* targetSep = "";
      for (ReprobuildTarget const& target : buildTargets) {
        if (!target.IncludeInAll || target.OutputConfig != config ||
            target.IsCrossConfig) {
          continue;
        }
        provider << targetSep << target.Var;
        targetSep = ", ";
      }
      provider << "])\n";
      provider << "    discard exportTarget("
               << ReprobuildEscape(cmStrCat("default:", config)) << ", "
               << var << ")\n";
    }

    for (auto const& entry : nativeTargetsByBase) {
      if (!this->CrossConfigs.empty()) {
        for (std::string const& commandConfig : configs) {
          std::string const var =
            ReprobuildNimIdent("target", nextTargetVar++,
                               cmStrCat(entry.first, "-all-", commandConfig));
          provider << "    let " << var << " = aggregate("
                   << ReprobuildEscape(
                        cmStrCat(entry.first, ":all:", commandConfig))
                   << ", targets = @[";
          char const* targetSep = "";
          for (std::string const& outputConfig : this->CrossConfigs) {
            std::string const targetVar =
              commandConfigTargetVar(entry.first, outputConfig,
                                     commandConfig);
            if (targetVar.empty()) {
              continue;
            }
            provider << targetSep << targetVar;
            targetSep = ", ";
          }
          provider << "])\n";
        }

        std::string const var =
          ReprobuildNimIdent("target", nextTargetVar++,
                             cmStrCat(entry.first, "-all"));
        provider << "    let " << var << " = aggregate("
                 << ReprobuildEscape(cmStrCat(entry.first, ":all"))
                 << ", targets = @[";
        char const* targetSep = "";
        for (std::string const& outputConfig : this->CrossConfigs) {
          std::string const targetVar =
            commandConfigTargetVar(entry.first, outputConfig,
                                   this->DefaultFileConfig);
          if (targetVar.empty()) {
            continue;
          }
          provider << targetSep << targetVar;
          targetSep = ", ";
        }
        provider << "])\n";
        continue;
      }

      for (std::string const& commandConfig : configs) {
        std::string const var =
          ReprobuildNimIdent("target", nextTargetVar++,
                             cmStrCat(entry.first, "-all-", commandConfig));
        provider << "    let " << var << " = aggregate("
                 << ReprobuildEscape(
                      cmStrCat(entry.first, ":all:", commandConfig))
                 << ", targets = @[";
        char const* targetSep = "";
        for (ReprobuildTarget const* target : entry.second) {
          provider << targetSep << target->Var;
          targetSep = ", ";
        }
        provider << "])\n";
      }

      std::string const var =
        ReprobuildNimIdent("target", nextTargetVar++,
                           cmStrCat(entry.first, "-all"));
      provider << "    let " << var << " = aggregate("
               << ReprobuildEscape(cmStrCat(entry.first, ":all"))
               << ", targets = @[";
      char const* targetSep = "";
      for (ReprobuildTarget const* target : entry.second) {
        provider << targetSep << target->Var;
        targetSep = ", ";
      }
      provider << "])\n";
    }
    for (auto const& entry : nativeTargetsByBase) {
      std::string const var =
        ReprobuildNimIdent("target", nextTargetVar++,
                           cmStrCat(entry.first, "-default"));
      provider << "    let " << var << " = aggregate("
               << ReprobuildEscape(entry.first) << ", targets = @[";
      char const* targetSep = "";
      for (std::string const& outputConfig : this->DefaultConfigs) {
        std::string const targetVar =
          commandConfigTargetVar(entry.first, outputConfig,
                                 this->DefaultFileConfig);
        if (targetVar.empty()) {
          continue;
        }
        provider << targetSep << targetVar;
        targetSep = ", ";
      }
      provider << "])\n";
    }

    provider << "    let allTarget = aggregate(\"all\", targets = @[";
    char const* targetSep = "";
    for (std::string const& config : this->DefaultConfigs) {
      for (ReprobuildTarget const* target : nativeAllTargets) {
        if (target->OutputConfig != config || target->BaseName.empty()) {
          continue;
        }
        std::string const targetVar =
          commandConfigTargetVar(target->BaseName, config,
                                 this->DefaultFileConfig);
        if (targetVar.empty()) {
          continue;
        }
        provider << targetSep << targetVar;
        targetSep = ", ";
      }
    }
    provider << "])\n"
             << "    discard exportTarget(\"default\", allTarget)\n"
             << "    defaultTarget(allTarget)\n";
  } else {
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
  }

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

  // Tier 2a + 2c: emit ``trycompile.rbsz`` next to ``reprobuild.nim`` for
  // every CMake-generated project. The engine routes any work-dir
  // containing this marker to the pre-built
  // ``repro-cmake-trycompile-provider`` binary, skipping the per-project
  // provider compile entirely.
  //
  // Multi-config builds (``CMAKE_CROSS_CONFIGS`` /
  // ``CMAKE_DEFAULT_CONFIGS``) emit a v3 envelope that carries the
  // per-config and cross-config aggregates the slow path used to emit
  // exclusively into ``reprobuild.nim``. Single-config still emits a v3
  // envelope but with empty cross-config trailers (so v2 readers also
  // reject it — the bump is observable per spec).
  //
  // ``reprobuild.nim`` is still written alongside ``trycompile.rbsz``
  // so older ``repro`` binaries fall back transparently.
  //
  // Per Provider-Compile-Tiering.md §"2a/2c".
  {
    std::vector<std::string> directUsedTools(usedTools.begin(),
                                              usedTools.end());
    std::vector<ReprobuildAction const*> directActions;
    auto pushAction = [&](ReprobuildAction const& action) {
      directActions.push_back(&action);
    };

    // Collect every action attached to each build target, in the same
    // declaration order ``writeAction`` uses when emitting reprobuild.nim.
    // Skipping the loop's action-list construction would let the direct
    // provider miss pre-build / pre-link / symlink / post-build steps that
    // CMake legitimately attaches to library targets.
    std::vector<ReprobuildTryCompileTargetDescriptor> directTargets;
    auto pushTarget = [&](ReprobuildTarget const& target) {
      ReprobuildTryCompileTargetDescriptor descriptor;
      descriptor.Name = target.Name;
      descriptor.IsAggregate = false;
      if (target.IsUtility) {
        pushAction(target.UtilityAction);
        descriptor.ActionIds.push_back(target.UtilityAction.Id);
      } else {
        for (ReprobuildAction const& action : target.CustomActions) {
          pushAction(action);
          descriptor.ActionIds.push_back(action.Id);
        }
        for (ReprobuildAction const& action : target.PreBuildActions) {
          pushAction(action);
          descriptor.ActionIds.push_back(action.Id);
        }
        for (ReprobuildAction const& action : target.CompileActions) {
          pushAction(action);
          descriptor.ActionIds.push_back(action.Id);
        }
        for (ReprobuildAction const& action : target.PreLinkActions) {
          pushAction(action);
          descriptor.ActionIds.push_back(action.Id);
        }
        if (target.HasLinkAction) {
          pushAction(target.LinkAction);
          descriptor.ActionIds.push_back(target.LinkAction.Id);
        }
        for (ReprobuildAction const& action : target.SymlinkActions) {
          pushAction(action);
          descriptor.ActionIds.push_back(action.Id);
        }
        for (ReprobuildAction const& action : target.PostBuildActions) {
          pushAction(action);
          descriptor.ActionIds.push_back(action.Id);
        }
      }
      directTargets.push_back(std::move(descriptor));
    };
    for (ReprobuildTarget const& target : buildTargets) {
      pushTarget(target);
    }

    // v3 cross-config descriptors. Empty in single-config builds — that
    // path's "all" aggregate still goes into ``directTargets`` below.
    std::vector<std::string> envelopeCrossConfigs;
    std::vector<ReprobuildTryCompileCrossConfigDescriptor>
      crossConfigDescriptors;
    std::vector<std::string> envelopeDefaultConfigs;
    std::string defaultTargetName = "all";

    if (multiConfig) {
      envelopeCrossConfigs = configs;
      envelopeDefaultConfigs = std::vector<std::string>(
        this->DefaultConfigs.begin(), this->DefaultConfigs.end());

      // Mirror the per-config "all:<Config>" aggregate the slow path
      // emits into ``reprobuild.nim``. Each entry references the
      // per-config build targets in ``directTargets``.
      for (std::string const& config : configs) {
        ReprobuildTryCompileCrossConfigDescriptor descriptor;
        descriptor.Name = cmStrCat("all:", config);
        descriptor.ConfigName = config;
        descriptor.BaseName.clear();
        for (ReprobuildTarget const& target : buildTargets) {
          if (!target.IncludeInAll || target.OutputConfig != config ||
              target.IsCrossConfig) {
            continue;
          }
          descriptor.ChildTargets.push_back(target.Name);
        }
        crossConfigDescriptors.push_back(std::move(descriptor));
      }

      // Per-base-name aggregates. Group config-qualified targets by
      // BaseName, then emit either CrossConfigs-fanout descriptors (one
      // per command-config plus the unsuffixed cross-config rollup) or
      // a per-config-config plus a default-config rollup, mirroring the
      // slow-path branches above.
      using TargetConfigKey =
        std::tuple<std::string, std::string, std::string>;
      std::map<TargetConfigKey, std::string> targetNamesByConfig;
      std::map<std::string, std::vector<ReprobuildTarget const*>>
        nativeTargetsByBase;
      for (ReprobuildTarget const& target : buildTargets) {
        if (!target.BaseName.empty()) {
          targetNamesByConfig.emplace(
            TargetConfigKey{ target.BaseName, target.OutputConfig,
                             target.CommandConfig },
            target.Name);
          if (!target.IsCrossConfig) {
            nativeTargetsByBase[target.BaseName].push_back(&target);
          }
        }
      }
      auto commandConfigTargetName =
        [&](std::string const& baseName, std::string const& outputConfig,
            std::string const& commandConfig) -> std::string {
        auto const it = targetNamesByConfig.find(
          TargetConfigKey{ baseName, outputConfig, commandConfig });
        if (it != targetNamesByConfig.end()) {
          return it->second;
        }
        return "";
      };

      for (auto const& entry : nativeTargetsByBase) {
        if (!this->CrossConfigs.empty()) {
          for (std::string const& commandConfig : configs) {
            ReprobuildTryCompileCrossConfigDescriptor descriptor;
            descriptor.Name =
              cmStrCat(entry.first, ":all:", commandConfig);
            descriptor.ConfigName = commandConfig;
            descriptor.BaseName = entry.first;
            for (std::string const& outputConfig : this->CrossConfigs) {
              std::string const targetName = commandConfigTargetName(
                entry.first, outputConfig, commandConfig);
              if (targetName.empty()) {
                continue;
              }
              descriptor.ChildTargets.push_back(targetName);
            }
            crossConfigDescriptors.push_back(std::move(descriptor));
          }

          ReprobuildTryCompileCrossConfigDescriptor allDescriptor;
          allDescriptor.Name = cmStrCat(entry.first, ":all");
          allDescriptor.ConfigName.clear();
          allDescriptor.BaseName = entry.first;
          for (std::string const& outputConfig : this->CrossConfigs) {
            std::string const targetName = commandConfigTargetName(
              entry.first, outputConfig, this->DefaultFileConfig);
            if (targetName.empty()) {
              continue;
            }
            allDescriptor.ChildTargets.push_back(targetName);
          }
          crossConfigDescriptors.push_back(std::move(allDescriptor));
          continue;
        }

        for (std::string const& commandConfig : configs) {
          ReprobuildTryCompileCrossConfigDescriptor descriptor;
          descriptor.Name = cmStrCat(entry.first, ":all:", commandConfig);
          descriptor.ConfigName = commandConfig;
          descriptor.BaseName = entry.first;
          for (ReprobuildTarget const* target : entry.second) {
            descriptor.ChildTargets.push_back(target->Name);
          }
          crossConfigDescriptors.push_back(std::move(descriptor));
        }

        ReprobuildTryCompileCrossConfigDescriptor allDescriptor;
        allDescriptor.Name = cmStrCat(entry.first, ":all");
        allDescriptor.ConfigName.clear();
        allDescriptor.BaseName = entry.first;
        for (ReprobuildTarget const* target : entry.second) {
          allDescriptor.ChildTargets.push_back(target->Name);
        }
        crossConfigDescriptors.push_back(std::move(allDescriptor));
      }

      // Per-base-name default-config rollup (the unsuffixed ``<base>``
      // target). The slow path emits this in a separate loop AFTER the
      // per-base-name aggregates regardless of CrossConfigs — mirror that
      // here so v3 envelopes carry the same set of aggregate names.
      for (auto const& entry : nativeTargetsByBase) {
        ReprobuildTryCompileCrossConfigDescriptor defaultDescriptor;
        defaultDescriptor.Name = entry.first;
        defaultDescriptor.ConfigName.clear();
        defaultDescriptor.BaseName = entry.first;
        for (std::string const& outputConfig : this->DefaultConfigs) {
          std::string const targetName = commandConfigTargetName(
            entry.first, outputConfig, this->DefaultFileConfig);
          if (targetName.empty()) {
            continue;
          }
          defaultDescriptor.ChildTargets.push_back(targetName);
        }
        crossConfigDescriptors.push_back(std::move(defaultDescriptor));
      }

      // Top-level cross-config ``all`` rollup mirroring the slow path's
      // ``allTarget = aggregate("all", targets = @[...])``. The slow
      // path enumerates ``(DefaultConfigs × nativeAllTargets)`` so the
      // ``all`` aggregate references the leaf per-config build targets
      // directly. We match that shape here.
      ReprobuildTryCompileCrossConfigDescriptor crossAllDescriptor;
      crossAllDescriptor.Name = "all";
      crossAllDescriptor.ConfigName.clear();
      crossAllDescriptor.BaseName.clear();
      for (std::string const& config : this->DefaultConfigs) {
        for (ReprobuildTarget const& target : buildTargets) {
          if (!target.IncludeInAll || target.IsCrossConfig ||
              target.OutputConfig != config || target.BaseName.empty()) {
            continue;
          }
          std::string const targetName = commandConfigTargetName(
            target.BaseName, config, this->DefaultFileConfig);
          if (targetName.empty()) {
            continue;
          }
          crossAllDescriptor.ChildTargets.push_back(targetName);
        }
      }
      crossConfigDescriptors.push_back(std::move(crossAllDescriptor));
    } else {
      // Single-config: the synthetic "all" aggregate matches the
      // ``aggregate("all", targets = @[...])`` block in reprobuild.nim.
      ReprobuildTryCompileTargetDescriptor allDescriptor;
      allDescriptor.Name = "all";
      allDescriptor.IsAggregate = true;
      for (ReprobuildTarget const& target : buildTargets) {
        if (!target.IncludeInAll) {
          continue;
        }
        allDescriptor.ChildTargets.push_back(target.Name);
      }
      directTargets.push_back(std::move(allDescriptor));
    }

    std::string const tryCompileMetadataFile =
      cmStrCat(binaryDir, "/trycompile.rbsz");
    if (!ReprobuildWriteTryCompileMetadata(
          tryCompileMetadataFile, directUsedTools, pools, directActions,
          directTargets, defaultTargetName, envelopeCrossConfigs,
          crossConfigDescriptors, envelopeDefaultConfigs)) {
      // Best-effort: log a non-fatal message and continue. The
      // reprobuild.nim slow-path remains available.
      this->GetCMakeInstance()->IssueMessage(
        MessageType::WARNING,
        cmStrCat("Could not write Reprobuild trycompile metadata "
                 "(falling back to per-project provider compile): ",
                 tryCompileMetadataFile));
    }
  }
}

std::vector<cmGlobalGenerator::GeneratedMakeCommand>
cmGlobalReprobuildGenerator::GenerateBuildCommand(
  std::string const& makeProgram, std::string const& projectName,
  std::string const& projectDir, std::vector<std::string> const& targetNames,
  std::string const& config, int jobs, bool verbose,
  cmBuildOptions buildOptions, std::vector<std::string> const& makeOptions,
  BuildTryCompile isInTryCompile)
{
  (void)jobs;
  (void)verbose;
  (void)makeOptions;

  bool cleanTarget = buildOptions.Clean;
  for (std::string const& targetName : targetNames) {
    if (targetName == "clean") {
      cleanTarget = true;
      break;
    }
  }
  if (isInTryCompile == BuildTryCompile::Yes) {
    std::string const nativeMake = ReprobuildFindNativeMakeOnPath();
    if (!nativeMake.empty()) {
      return this->cmGlobalUnixMakefileGenerator3::GenerateBuildCommand(
        nativeMake, projectName, projectDir, targetNames, config, jobs, verbose,
        buildOptions, makeOptions, isInTryCompile);
    }
  }
  if (cleanTarget) {
    GeneratedMakeCommand cleanCommand;
    cleanCommand.Add(cmSystemTools::GetCMakeCommand());
    cleanCommand.Add("--reprobuild-launch");
    cleanCommand.Add(projectDir);
    cleanCommand.Add("--action=clean");
    cleanCommand.Add(cmStrCat("--project=", projectName));
    if (!config.empty()) {
      cleanCommand.Add(cmStrCat("--config=", config));
    }
    return { std::move(cleanCommand) };
  }

  std::string const effectiveConfig =
    this->IsMultiConfig() ? config : std::string();
  auto selectedTarget = [&effectiveConfig](std::string const& targetName) {
    std::string normalizedTarget = targetName;
    if (cmHasSuffix(normalizedTarget, "/fast")) {
      normalizedTarget.resize(normalizedTarget.size() - 5);
    }
    if (effectiveConfig.empty()) {
      return normalizedTarget;
    }
    if (normalizedTarget.empty()) {
      return cmStrCat("all:", effectiveConfig);
    }
    if (normalizedTarget == "all" || normalizedTarget == "default") {
      return cmStrCat(normalizedTarget, ":", effectiveConfig);
    }
    std::string::size_type colon = normalizedTarget.find(':');
    if (colon == std::string::npos) {
      return cmStrCat(normalizedTarget, ":", effectiveConfig);
    }
    std::string const suffix = normalizedTarget.substr(colon + 1);
    if (suffix == "all") {
      return cmStrCat(normalizedTarget, ":", effectiveConfig);
    }
    if (suffix == effectiveConfig || suffix.find(':') != std::string::npos) {
      return normalizedTarget;
    }
    return cmStrCat(normalizedTarget, ":", effectiveConfig);
  };

  std::string repro = ReprobuildCliFromEnv();
  if (repro.empty() && !makeProgram.empty() &&
      !ReprobuildLooksLikeMakeProgram(makeProgram)) {
    repro = makeProgram;
  }
  if (repro.empty()) {
    repro = ReprobuildFindCliOnPath();
  }
  if (repro.empty()) {
    repro = "repro";
  }
  std::vector<std::string> targets;
  if (targetNames.empty()) {
    targets.emplace_back(selectedTarget(std::string()));
  } else {
    for (std::string const& targetName : targetNames) {
      if (!targetName.empty() && targetName != "clean") {
        targets.emplace_back(selectedTarget(targetName));
      }
    }
  }

  std::vector<GeneratedMakeCommand> commands;
  for (std::string const& target : targets) {
    GeneratedMakeCommand makeCommand;
    makeCommand.Add(repro);
    makeCommand.Add("build");
    if (!target.empty()) {
      makeCommand.Add(cmStrCat(projectDir, "#", target));
    }
    makeCommand.Add("--tool-provisioning=path");
    makeCommand.Add(cmStrCat("--work-root=", projectDir,
                             "/CMakeFiles/reprobuild"));
    if (isInTryCompile == BuildTryCompile::Yes) {
      makeCommand.Add("--progress=none");
      makeCommand.Add("--report=none");
      makeCommand.Add("--log=quiet");
    }
    commands.emplace_back(std::move(makeCommand));
  }
  return commands;
}
