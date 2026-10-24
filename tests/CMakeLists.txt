# C unit tests (label: c). No window or GPU.
add_executable(test_utf8 c/test_utf8.c)
target_link_libraries(test_utf8 PRIVATE pf_core)
add_test(NAME c.utf8 COMMAND test_utf8)

add_executable(test_async c/test_async.c)
target_link_libraries(test_async PRIVATE pf_core)
add_test(NAME c.async COMMAND test_async)

add_executable(test_process c/test_process.c)
target_link_libraries(test_process PRIVATE pf_core)
add_test(NAME c.process COMMAND test_process)

add_executable(test_text c/test_text.c)
target_link_libraries(test_text PRIVATE pf_core)
add_test(NAME c.text COMMAND test_text)

add_executable(test_text_undo c/test_text_undo.c)
target_link_libraries(test_text_undo PRIVATE pf_core)
add_test(NAME c.text_undo COMMAND test_text_undo)

add_executable(test_props c/test_props.c)
target_link_libraries(test_props PRIVATE pf_core)
add_test(NAME c.props COMMAND test_props)

add_executable(test_display c/test_display.c)
target_link_libraries(test_display PRIVATE pf_core)
add_test(NAME c.display COMMAND test_display)

add_executable(test_layout c/test_layout.c)
target_link_libraries(test_layout PRIVATE pf_core)
add_test(NAME c.layout COMMAND test_layout)

add_executable(test_frame c/test_frame.c)
target_link_libraries(test_frame PRIVATE pf_core)
add_test(NAME c.frame COMMAND test_frame)

add_executable(test_canvas c/test_canvas.c)
target_link_libraries(test_canvas PRIVATE pf_core)
add_test(NAME c.canvas COMMAND test_canvas)

add_executable(test_scheme c/test_scheme.c)
target_link_libraries(test_scheme PRIVATE pf_core_whole)
target_compile_definitions(test_scheme PRIVATE
  PF_TEST_BOOT_DIR="${CHEZ_BOOT_DIR}"
  PF_TEST_SCHEME_DIR="${PROJECT_SOURCE_DIR}/scheme")
add_test(NAME c.scheme COMMAND test_scheme)

foreach(_t IN ITEMS test_async test_process test_utf8 test_text test_text_undo test_props test_display test_layout test_frame
                   test_canvas test_scheme)
  target_compile_options(${_t} PRIVATE ${PROFANE_WARNINGS})
endforeach()
set_tests_properties(c.async c.process c.utf8 c.text c.text_undo c.props c.display c.layout c.frame c.canvas c.scheme
  PROPERTIES LABELS c)

# Scheme suites (label: scheme), run by the standalone Chez against the source tree. In a
# sanitizer build the instrumented pf_native dylib needs the ASan runtime preloaded into the
# (uninstrumented) scheme binary.
set(_asan_preload "")
if(PROFANE_SANITIZE)
  execute_process(COMMAND ${CMAKE_C_COMPILER} -print-file-name=libclang_rt.asan_osx_dynamic.dylib
    OUTPUT_VARIABLE _asan_rt OUTPUT_STRIP_TRAILING_WHITESPACE)
  set(_asan_preload "DYLD_INSERT_LIBRARIES=${_asan_rt}")
endif()
file(GLOB _scheme_suites CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/scheme/*-test.ss")
foreach(_suite IN LISTS _scheme_suites)
  get_filename_component(_name "${_suite}" NAME_WE)
  add_test(NAME scheme.${_name}
    COMMAND "${CHEZ_EXECUTABLE}" -b "${CHEZ_BOOT_DIR}/petite.boot" -b "${CHEZ_BOOT_DIR}/scheme.boot"
      --libdirs "${PROJECT_SOURCE_DIR}/scheme:${CMAKE_CURRENT_SOURCE_DIR}/scheme/lib"
      --script "${_suite}")
  set_tests_properties(scheme.${_name} PROPERTIES LABELS scheme
    ENVIRONMENT "PROFANE_NATIVE_LIB=$<TARGET_FILE:pf_native>;${_asan_preload}")
endforeach()

# Platform units needing Metal but no window (label: macos).
add_executable(test_atlas macos/test_atlas.m
  "${PROJECT_SOURCE_DIR}/platform/macos/PFFont.m"
  "${PROJECT_SOURCE_DIR}/platform/macos/PFGlyphAtlas.m")
target_include_directories(test_atlas PRIVATE "${PROJECT_SOURCE_DIR}/platform/macos" c)
target_compile_options(test_atlas PRIVATE -fobjc-arc ${PROFANE_WARNINGS})
target_link_libraries(test_atlas PRIVATE pf_core "-framework CoreGraphics" "-framework CoreText" "-framework Metal"
  "-framework Foundation")
add_test(NAME macos.atlas COMMAND test_atlas)
set_tests_properties(macos.atlas PROPERTIES LABELS macos)

add_executable(test_keys macos/test_keys.m "${PROJECT_SOURCE_DIR}/platform/macos/PFKeys.m")
target_include_directories(test_keys PRIVATE "${PROJECT_SOURCE_DIR}/platform/macos" c)
target_compile_options(test_keys PRIVATE -fobjc-arc ${PROFANE_WARNINGS})
target_link_libraries(test_keys PRIVATE "-framework AppKit" "-framework Carbon")
add_test(NAME macos.keys COMMAND test_keys)
set_tests_properties(macos.keys PROPERTIES LABELS macos)

# App integration (label: macos): signed bundle, hardened runtime + JIT, socket REPL.
add_test(NAME macos.signing
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/macos/signing.sh" "$<TARGET_BUNDLE_DIR:profane>")
add_test(NAME macos.repl
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/macos/repl.sh" "$<TARGET_BUNDLE_DIR:profane>"
    "$<TARGET_FILE:profane-client>")
add_test(NAME macos.macos
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/macos/macos.sh" "$<TARGET_BUNDLE_DIR:profane>"
    "$<TARGET_FILE:profane-client>")
add_test(NAME macos.snapshot
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/macos/snapshot.sh" "$<TARGET_BUNDLE_DIR:profane>")
set_tests_properties(macos.signing macos.repl macos.macos macos.snapshot PROPERTIES LABELS macos TIMEOUT 60)

# On-screen checks (label: screen), opt-in via PROFANE_SCREEN_TESTS=1: need Screen Recording.
add_executable(png_ink macos/png_ink.m)
target_compile_options(png_ink PRIVATE -fobjc-arc ${PROFANE_WARNINGS})
target_link_libraries(png_ink PRIVATE "-framework CoreGraphics" "-framework Foundation"
  "-framework ImageIO")
add_test(NAME screen.first-frames
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/macos/screen.sh" "$<TARGET_BUNDLE_DIR:profane>"
    "$<TARGET_FILE:profane-client>" "$<TARGET_FILE:png_ink>")
add_executable(post_keys macos/post_keys.m)
target_compile_options(post_keys PRIVATE -fobjc-arc ${PROFANE_WARNINGS})
target_link_libraries(post_keys PRIVATE "-framework ApplicationServices" "-framework Foundation")
add_test(NAME screen.input
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/macos/input.sh" "$<TARGET_BUNDLE_DIR:profane>"
    "$<TARGET_FILE:profane-client>" "$<TARGET_FILE:post_keys>")
add_test(NAME screen.latency
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/macos/latency.sh" "$<TARGET_BUNDLE_DIR:profane>"
    "$<TARGET_FILE:profane-client>" "$<TARGET_FILE:post_keys>")
set_tests_properties(screen.first-frames screen.input screen.latency PROPERTIES LABELS screen
  TIMEOUT 120 SKIP_RETURN_CODE 77)
