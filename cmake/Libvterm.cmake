# Builds the vendored libvterm (subprojects/libvterm, pinned to a release tag; MIT) as a static
# library `vterm`. Its two character-set tables are generated from .tbl files with perl (as its
# Makefile does) into the build tree. After bumping the submodule, re-run cmake.

set(LIBVTERM_DIR "${PROJECT_SOURCE_DIR}/subprojects/libvterm")
if(NOT EXISTS "${LIBVTERM_DIR}/include/vterm.h")
  message(FATAL_ERROR "subprojects/libvterm is missing; run: git submodule update --init --recursive")
endif()

find_program(PERL_EXECUTABLE perl REQUIRED)
set(LIBVTERM_GEN "${CMAKE_BINARY_DIR}/libvterm-gen")
set(_inc_files)
foreach(_table DECdrawing uk)
  set(_inc "${LIBVTERM_GEN}/encoding/${_table}.inc")
  add_custom_command(
    OUTPUT "${_inc}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${LIBVTERM_GEN}/encoding"
    COMMAND ${PERL_EXECUTABLE} -CSD "${LIBVTERM_DIR}/tbl2inc_c.pl" "${LIBVTERM_DIR}/src/encoding/${_table}.tbl" > "${_inc}"
    DEPENDS "${LIBVTERM_DIR}/src/encoding/${_table}.tbl" "${LIBVTERM_DIR}/tbl2inc_c.pl"
    VERBATIM)
  list(APPEND _inc_files "${_inc}")
endforeach()

file(GLOB _vterm_sources CONFIGURE_DEPENDS "${LIBVTERM_DIR}/src/*.c")
add_library(vterm STATIC ${_vterm_sources} ${_inc_files})
target_include_directories(vterm
  PUBLIC "${LIBVTERM_DIR}/include"
  PRIVATE "${LIBVTERM_DIR}/src" "${LIBVTERM_GEN}")
# Third-party code: no project warnings, and it is C99 with GNU-free extensions only.
set_target_properties(vterm PROPERTIES C_STANDARD 99 C_EXTENSIONS OFF POSITION_INDEPENDENT_CODE ON)
target_compile_options(vterm PRIVATE -w)
