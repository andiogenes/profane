add_library(pf_core STATIC
  embed/pf_scheme.c
  embed/pf_repl.c
  text/pf_text.c
  text/pf_utf8.c)

target_include_directories(pf_core PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/embed"
  "${CMAKE_CURRENT_SOURCE_DIR}/text")
target_compile_options(pf_core PRIVATE ${PROFANE_WARNINGS})
# Public headers stay Chez-free; only pf_scheme.c includes scheme.h.
target_link_libraries(pf_core PUBLIC chez::kernel)
