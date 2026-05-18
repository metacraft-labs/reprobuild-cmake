/* Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
   file LICENSE.rst or https://cmake.org/licensing for details.  */

#include "cmLocalReprobuildGenerator.h"

cmLocalReprobuildGenerator::cmLocalReprobuildGenerator(cmGlobalGenerator* gg,
                                                       cmMakefile* mf)
  : cmLocalUnixMakefileGenerator3(gg, mf)
{
}

cmLocalReprobuildGenerator::~cmLocalReprobuildGenerator() = default;
