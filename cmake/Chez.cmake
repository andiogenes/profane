# Builds the vendored Chez Scheme (subprojects/chez) out of tree and exposes:
#   chez::kernel      imported static library (libkernel.a + bundled zlib/lz4)
#   CHEZ_BOOT_DIR     directory holding petite.boot, scheme.boot and scheme.h
#   CHEZ_EXECUTABLE   the standalone `scheme` binary (used to run Scheme tests)
#
# Chez is built once per build tree; after bumping the submodule, delete build/chez.

include(ExternalProject)

set(CHEZ_MACHINE "tarm64osx" CACHE STRING "Chez Scheme machine type")
set(CHEZ_SOURCE_DIR "${PROJECT_SOURCE_DIR}/subprojects/chez")
set(CHEZ_BUILD_DIR "${CMAKE_BINARY_DIR}/chez")
set(CHEZ_WORK_DIR "${CHEZ_BUILD_DIR}/${CHEZ_MACHINE}")
set(CHEZ_BOOT_DIR "${CHEZ_WORK_DIR}/boot/${CHEZ_MACHINE}")
set(CHEZ_EXECUTABLE "${CHEZ_WORK_DIR}/bin/${CHEZ_MACHINE}/scheme")

if(NOT EXISTS "${CHEZ_SOURCE_DIR}/configure")
  message(FATAL_ERROR "subprojects/chez is missing; run: git submodule update --init --recursive")
endif()

find_program(MAKE_EXECUTABLE NAMES make gmake REQUIRED)

set(_chez_env ${CMAKE_COMMAND} -E env MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET})

ExternalProject_Add(chez
  SOURCE_DIR "${CHEZ_SOURCE_DIR}"
  BINARY_DIR "${CHEZ_BUILD_DIR}"
  CONFIGURE_COMMAND ${_chez_env} "${CHEZ_SOURCE_DIR}/configure"
    --threads -m=${CHEZ_MACHINE} --disable-x11 --disable-curses
  BUILD_COMMAND ${_chez_env} ${MAKE_EXECUTABLE}
  INSTALL_COMMAND ""
  BUILD_BYPRODUCTS
    "${CHEZ_BOOT_DIR}/libkernel.a"
    "${CHEZ_WORK_DIR}/zlib/libz.a"
    "${CHEZ_WORK_DIR}/lz4/lib/liblz4.a"
    "${CHEZ_BOOT_DIR}/petite.boot"
    "${CHEZ_BOOT_DIR}/scheme.boot"
    "${CHEZ_EXECUTABLE}"
  USES_TERMINAL_CONFIGURE ON
  USES_TERMINAL_BUILD ON
  STEP_TARGETS build)

# Imported targets require their include directory to exist at configure time.
file(MAKE_DIRECTORY "${CHEZ_BOOT_DIR}")

add_library(chez::kernel STATIC IMPORTED GLOBAL)
set_target_properties(chez::kernel PROPERTIES
  IMPORTED_LOCATION "${CHEZ_BOOT_DIR}/libkernel.a"
  INTERFACE_INCLUDE_DIRECTORIES "${CHEZ_BOOT_DIR}"
  INTERFACE_LINK_LIBRARIES "${CHEZ_WORK_DIR}/zlib/libz.a;${CHEZ_WORK_DIR}/lz4/lib/liblz4.a;iconv;m")
add_dependencies(chez::kernel chez)

set(CHEZ_BOOT_FILES "${CHEZ_BOOT_DIR}/petite.boot" "${CHEZ_BOOT_DIR}/scheme.boot")
