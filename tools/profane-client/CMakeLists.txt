add_executable(profane-client profane_client.c)
target_compile_options(profane-client PRIVATE ${PROFANE_WARNINGS})
target_include_directories(profane-client PRIVATE "${PROJECT_SOURCE_DIR}/core/embed")
# Only the socket-path helper; the client must not link Chez.
target_sources(profane-client PRIVATE "${PROJECT_SOURCE_DIR}/core/embed/pf_repl.c")
