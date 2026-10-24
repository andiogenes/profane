# Code Scheme reaches through foreign-procedure. It must not depend on Chez, so that it can also
# be built as a dylib for Scheme tests run by the standalone `scheme` binary.
set(PF_NATIVE_SOURCES
  async/pf_async.c
  display/pf_canvas.c
  display/pf_face.c
  display/pf_frame.c
  display/pf_strip.c
  display/pf_window.c
  embed/pf_buffer_ffi.c
  embed/pf_canvas_ffi.c
  embed/pf_display_ffi.c
  embed/pf_handles.c
  embed/pf_input.c
  embed/pf_window_ffi.c
  layout/pf_layout.c
  render/pf_display.c
  text/pf_props.c
  text/pf_text.c
  text/pf_utf8.c)

add_library(pf_core STATIC
  embed/pf_scheme.c
  embed/pf_repl.c
  ${PF_NATIVE_SOURCES})

target_include_directories(pf_core PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/async"
  "${CMAKE_CURRENT_SOURCE_DIR}/display"
  "${CMAKE_CURRENT_SOURCE_DIR}/embed"
  "${CMAKE_CURRENT_SOURCE_DIR}/layout"
  "${CMAKE_CURRENT_SOURCE_DIR}/render"
  "${CMAKE_CURRENT_SOURCE_DIR}/text")
target_compile_options(pf_core PRIVATE ${PROFANE_WARNINGS})
# Public headers stay Chez-free; only pf_scheme.c includes scheme.h.
target_link_libraries(pf_core PUBLIC chez::kernel)

# Executables that embed Chez link this so every native entry point is present (the linker
# would otherwise drop objects nothing in C references) and resolvable by Scheme via dlsym.
add_library(pf_core_whole INTERFACE)
target_link_libraries(pf_core_whole INTERFACE "$<LINK_LIBRARY:WHOLE_ARCHIVE,pf_core>")

add_library(pf_native SHARED ${PF_NATIVE_SOURCES})
target_include_directories(pf_native PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/async"
  "${CMAKE_CURRENT_SOURCE_DIR}/display"
  "${CMAKE_CURRENT_SOURCE_DIR}/embed"
  "${CMAKE_CURRENT_SOURCE_DIR}/layout"
  "${CMAKE_CURRENT_SOURCE_DIR}/render"
  "${CMAKE_CURRENT_SOURCE_DIR}/text")
target_compile_options(pf_native PRIVATE ${PROFANE_WARNINGS})
