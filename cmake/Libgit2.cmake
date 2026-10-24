# Builds the vendored libgit2 (subprojects/libgit2, pinned to a release tag; GPLv2 with linking
# exception) as a static library. Reads only: the network and every mutation go through the git
# CLI (plan §8), so HTTPS, SSH and auth backends are off. After bumping the submodule, re-run cmake.

if(NOT EXISTS "${PROJECT_SOURCE_DIR}/subprojects/libgit2/CMakeLists.txt")
  message(FATAL_ERROR "subprojects/libgit2 is missing; run: git submodule update --init --recursive")
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_CLI OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_FUZZERS OFF CACHE BOOL "" FORCE)
set(USE_HTTPS OFF CACHE STRING "" FORCE)
set(USE_SSH OFF CACHE STRING "" FORCE)
set(USE_AUTH_NTLM OFF CACHE STRING "" FORCE)
set(USE_AUTH_NEGOTIATE OFF CACHE STRING "" FORCE)
set(USE_SHA256 CommonCrypto CACHE STRING "" FORCE)
set(USE_BUNDLED_ZLIB ON CACHE BOOL "" FORCE)
set(REGEX_BACKEND builtin CACHE STRING "" FORCE)
set(USE_ICONV ON CACHE BOOL "" FORCE)
add_subdirectory("${PROJECT_SOURCE_DIR}/subprojects/libgit2" "${CMAKE_BINARY_DIR}/libgit2" EXCLUDE_FROM_ALL)
