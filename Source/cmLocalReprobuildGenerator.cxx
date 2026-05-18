/* Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
   file LICENSE.rst or https://cmake.org/licensing for details.  */

#include "cmLocalReprobuildGenerator.h"

#include <cctype>

#include "cmGeneratorTarget.h"
#include "cmStringAlgorithms.h"
#include "cmSystemTools.h"

cmLocalReprobuildGenerator::cmLocalReprobuildGenerator(cmGlobalGenerator* gg,
                                                       cmMakefile* mf)
  : cmLocalUnixMakefileGenerator3(gg, mf)
{
}

cmLocalReprobuildGenerator::~cmLocalReprobuildGenerator() = default;

std::string cmLocalReprobuildGenerator::GetLinkDependencyFile(
  cmGeneratorTarget* target, std::string const& config) const
{
  std::string name = target ? target->GetName() : "target";
  for (char& ch : name) {
    unsigned char uch = static_cast<unsigned char>(ch);
    if (!std::isalnum(uch) && ch != '_' && ch != '-' && ch != '.') {
      ch = '_';
    }
  }
  if (!config.empty()) {
    name = cmStrCat(name, "-", config);
  }
  return cmStrCat("CMakeFiles/reprobuild/deps/", name, ".link.d");
}
