cmake_minimum_required(VERSION 3.28)

# Must precede project() to take effect.
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Target architectures")

project(profane VERSION 0.0.1 LANGUAGES C OBJC)

if(NOT APPLE OR NOT CMAKE_SYSTEM_PROCESSOR MATCHES "arm64")
  message(FATAL_ERROR "profane targets macOS on Apple Silicon only")
endif()

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(PROFANE_CODESIGN_IDENTITY "-" CACHE STRING "codesign identity (\"-\" = ad-hoc)")
set(PROFANE_BUNDLE_ID "org.profane.editor" CACHE STRING "CFBundleIdentifier")

option(PROFANE_SANITIZE "Build with AddressSanitizer + UBSan" OFF)
if(PROFANE_SANITIZE)
  # UB reports are fatal, so sanitizer test runs fail on them instead of just printing.
  add_compile_options(-fsanitize=address,undefined -fno-sanitize-recover=undefined
                      -fno-omit-frame-pointer)
  add_link_options(-fsanitize=address,undefined)
endif()

set(PROFANE_WARNINGS -Wall -Wextra -Wpedantic -Wno-gnu-zero-variadic-macro-arguments)

include(cmake/Chez.cmake)
include(cmake/Libvterm.cmake)

enable_testing()

add_subdirectory(core)
add_subdirectory(platform/macos)
add_subdirectory(tools/profane-client)
add_subdirectory(tests)
