/* Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
   file LICENSE.rst or https://cmake.org/licensing for details.  */
#pragma once

#include "cmConfigure.h" // IWYU pragma: keep

#include "cmLocalUnixMakefileGenerator3.h"

class cmGlobalGenerator;
class cmMakefile;

class cmLocalReprobuildGenerator : public cmLocalUnixMakefileGenerator3
{
public:
  cmLocalReprobuildGenerator(cmGlobalGenerator* gg, cmMakefile* mf);
  ~cmLocalReprobuildGenerator() override;

  std::string GetLinkDependencyFile(cmGeneratorTarget* target,
                                    std::string const& config) const override;
};
