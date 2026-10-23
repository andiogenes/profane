# C unit tests (label: c). No window or GPU.
add_executable(test_utf8 c/test_utf8.c)
target_link_libraries(test_utf8 PRIVATE pf_core)
add_test(NAME c.utf8 COMMAND test_utf8)

add_executable(test_text c/test_text.c)
target_link_libraries(test_text PRIVATE pf_core)
add_test(NAME c.text COMMAND test_text)

add_executable(test_text_undo c/test_text_undo.c)
target_link_libraries(test_text_undo PRIVATE pf_core)
add_test(NAME c.text_undo COMMAND test_text_undo)

add_executable(test_scheme c/test_scheme.c)
target_link_libraries(test_scheme PRIVATE pf_core_whole)
target_compile_definitions(test_scheme PRIVATE
  PF_TEST_BOOT_DIR="${CHEZ_BOOT_DIR}"
  PF_TEST_SCHEME_DIR="${PROJECT_SOURCE_DIR}/scheme")
add_test(NAME c.scheme COMMAND test_scheme)

foreach(_t IN ITEMS test_utf8 test_text test_text_undo test_scheme)
  target_compile_options(${_t} PRIVATE ${PROFANE_WARNINGS})
endforeach()
set_tests_properties(c.utf8 c.text c.text_undo c.scheme PROPERTIES LABELS c)

# Scheme suites (label: scheme), run by the standalone Chez against the source tree.
file(GLOB _scheme_suites CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/scheme/*-test.ss")
foreach(_suite IN LISTS _scheme_suites)
  get_filename_component(_name "${_suite}" NAME_WE)
  add_test(NAME scheme.${_name}
    COMMAND "${CHEZ_EXECUTABLE}" -b "${CHEZ_BOOT_DIR}/petite.boot" -b "${CHEZ_BOOT_DIR}/scheme.boot"
      --libdirs "${PROJECT_SOURCE_DIR}/scheme:${CMAKE_CURRENT_SOURCE_DIR}/scheme/lib"
      --script "${_suite}")
  set_tests_properties(scheme.${_name} PROPERTIES LABELS scheme
    ENVIRONMENT "PROFANE_NATIVE_LIB=$<TARGET_FILE:pf_native>")
endforeach()

# App integration (label: macos): signed bundle, hardened runtime + JIT, socket REPL.
add_test(NAME macos.signing
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/macos/signing.sh" "$<TARGET_BUNDLE_DIR:profane>")
add_test(NAME macos.repl
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/macos/repl.sh" "$<TARGET_BUNDLE_DIR:profane>"
    "$<TARGET_FILE:profane-client>")
add_test(NAME macos.snapshot
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/macos/snapshot.sh" "$<TARGET_BUNDLE_DIR:profane>")
set_tests_properties(macos.signing macos.repl macos.snapshot PROPERTIES LABELS macos TIMEOUT 60)
