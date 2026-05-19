set(M11_REAL_PROJECT_LOCKS_VERSION 1)
set(M11_REAL_PROJECT_DEFAULT_PROJECTS
  zlib
  nlohmann_json
  fmt)
set(M11_REAL_PROJECT_MEDIUM_PROJECTS
  libuv)
set(M11_REAL_PROJECT_NIGHTLY_PROJECTS
  libuv
  CMake)
set(M11_REAL_PROJECT_ALL_PROJECTS
  ${M11_REAL_PROJECT_DEFAULT_PROJECTS}
  ${M11_REAL_PROJECT_MEDIUM_PROJECTS}
  CMake)

set(M11_PROJECT_zlib_NAME "zlib")
set(M11_PROJECT_zlib_VERSION "1.3.1")
set(M11_PROJECT_zlib_PROFILE "small-local")
set(M11_PROJECT_zlib_URL
  "https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz")
set(M11_PROJECT_zlib_SHA256
  "17e88863f3600672ab49182f217281b6fc4d3c762bde361935e436a95214d05c")
set(M11_PROJECT_zlib_SOURCE_SUBDIR "zlib-1.3.1")
set(M11_PROJECT_zlib_BUILD_TARGET "all")
set(M11_PROJECT_zlib_INSTALL_TARGET "install")
set(M11_PROJECT_zlib_COMPILE_COMMAND_NEEDLE "adler32.c")
set(M11_PROJECT_zlib_INSTALL_OUTPUTS
  "include/zlib.h")
set(M11_PROJECT_zlib_BUILD_OUTPUTS
  "example")
set(M11_PROJECT_zlib_EXPECT_COMPILE_ACTIONS TRUE)

set(M11_PROJECT_nlohmann_json_NAME "nlohmann_json")
set(M11_PROJECT_nlohmann_json_VERSION "3.11.3")
set(M11_PROJECT_nlohmann_json_PROFILE "small-local-header-only")
set(M11_PROJECT_nlohmann_json_URL
  "https://github.com/nlohmann/json/archive/refs/tags/v3.11.3.tar.gz")
set(M11_PROJECT_nlohmann_json_SHA256
  "0d8ef5af7f9794e3263480193c491549b2ba6cc74bb018906202ada498a79406")
set(M11_PROJECT_nlohmann_json_SOURCE_SUBDIR "json-3.11.3")
set(M11_PROJECT_nlohmann_json_CONFIGURE_ARGS
  "-DJSON_BuildTests=OFF"
  "-DJSON_Install=ON")
set(M11_PROJECT_nlohmann_json_BUILD_TARGET "all")
set(M11_PROJECT_nlohmann_json_INSTALL_TARGET "install")
set(M11_PROJECT_nlohmann_json_INSTALL_OUTPUTS
  "include/nlohmann/json.hpp"
  "share/cmake/nlohmann_json/nlohmann_jsonConfig.cmake")
set(M11_PROJECT_nlohmann_json_EXPECT_COMPILE_ACTIONS FALSE)

set(M11_PROJECT_fmt_NAME "fmt")
set(M11_PROJECT_fmt_VERSION "10.2.1")
set(M11_PROJECT_fmt_PROFILE "small-local-compiled")
set(M11_PROJECT_fmt_URL
  "https://github.com/fmtlib/fmt/archive/refs/tags/10.2.1.tar.gz")
set(M11_PROJECT_fmt_SHA256
  "1250e4cc58bf06ee631567523f48848dc4596133e163f02615c97f78bab6c811")
set(M11_PROJECT_fmt_SOURCE_SUBDIR "fmt-10.2.1")
set(M11_PROJECT_fmt_CONFIGURE_ARGS
  "-DFMT_TEST=OFF"
  "-DFMT_DOC=OFF"
  "-DFMT_INSTALL=ON"
  "-DFMT_DEBUG_POSTFIX=")
set(M11_PROJECT_fmt_BUILD_TARGET "all")
set(M11_PROJECT_fmt_INSTALL_TARGET "install")
set(M11_PROJECT_fmt_COMPILE_COMMAND_NEEDLE "format.cc")
set(M11_PROJECT_fmt_INSTALL_OUTPUTS
  "include/fmt/core.h"
  "lib/cmake/fmt/fmt-config.cmake")
set(M11_PROJECT_fmt_EXPECT_COMPILE_ACTIONS TRUE)

set(M11_PROJECT_libuv_NAME "libuv")
set(M11_PROJECT_libuv_VERSION "1.48.0")
set(M11_PROJECT_libuv_PROFILE "medium-explicit-runquota-stress")
set(M11_PROJECT_libuv_URL
  "https://github.com/libuv/libuv/archive/refs/tags/v1.48.0.tar.gz")
set(M11_PROJECT_libuv_SHA256
  "8c253adb0f800926a6cbd1c6576abae0bc8eb86a4f891049b72f9e5b7dc58f33")
set(M11_PROJECT_libuv_SOURCE_SUBDIR "libuv-1.48.0")
set(M11_PROJECT_libuv_CONFIGURE_ARGS
  "-DBUILD_TESTING=OFF"
  "-DLIBUV_BUILD_SHARED=OFF"
  "-DLIBUV_BUILD_TESTS=OFF")
set(M11_PROJECT_libuv_BUILD_TARGET "all")
set(M11_PROJECT_libuv_INSTALL_TARGET "install")
set(M11_PROJECT_libuv_COMPILE_COMMAND_NEEDLE "src/unix")
set(M11_PROJECT_libuv_INSTALL_OUTPUTS
  "include/uv.h")
set(M11_PROJECT_libuv_EXPECT_COMPILE_ACTIONS TRUE)

set(M11_PROJECT_CMake_NAME "CMake")
set(M11_PROJECT_CMake_VERSION "3.30.5")
set(M11_PROJECT_CMake_PROFILE "large-nightly")
set(M11_PROJECT_CMake_URL
  "https://cmake.org/files/v3.30/cmake-3.30.5.tar.gz")
set(M11_PROJECT_CMake_SHA256
  "9f55e1a40508f2f29b7e065fa08c29f82c402fa0402da839fffe64a25755a86d")
set(M11_PROJECT_CMake_SOURCE_SUBDIR "cmake-3.30.5")
set(M11_PROJECT_CMake_CONFIGURE_ARGS
  "-DBUILD_TESTING=OFF"
  "-DCMake_BUILD_DEVELOPER_REFERENCE=OFF"
  "-DCMake_BUILD_MANUAL=OFF"
  "-DCMake_BUILD_QtDialog=OFF"
  "-DCMAKE_USE_OPENSSL=OFF")
set(M11_PROJECT_CMake_BUILD_TARGET "cmake")
set(M11_PROJECT_CMake_INSTALL_TARGET "install")
set(M11_PROJECT_CMake_COMPILE_COMMAND_NEEDLE "cmake.cxx")
set(M11_PROJECT_CMake_INSTALL_OUTPUTS
  "bin/cmake")
set(M11_PROJECT_CMake_EXPECT_COMPILE_ACTIONS TRUE)
