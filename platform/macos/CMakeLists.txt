set(PROFANE_RESOURCES)

# Shaders are compiled at build time into Resources/default.metallib (-newDefaultLibrary).
set(_shader_air "${CMAKE_CURRENT_BINARY_DIR}/Shaders.air")
set(_metallib "${CMAKE_CURRENT_BINARY_DIR}/default.metallib")
add_custom_command(
  OUTPUT "${_metallib}"
  COMMAND xcrun -sdk macosx metal -c "${CMAKE_CURRENT_SOURCE_DIR}/Shaders.metal"
    -I "${CMAKE_CURRENT_SOURCE_DIR}"
    -mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET} -o "${_shader_air}"
  COMMAND xcrun -sdk macosx metallib "${_shader_air}" -o "${_metallib}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/Shaders.metal" "${CMAKE_CURRENT_SOURCE_DIR}/PFShaderTypes.h"
  VERBATIM)
set_source_files_properties("${_metallib}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
list(APPEND PROFANE_RESOURCES "${_metallib}")

# Chez boot files -> Resources/boot.
set_source_files_properties(${CHEZ_BOOT_FILES} PROPERTIES
  GENERATED TRUE MACOSX_PACKAGE_LOCATION Resources/boot)
list(APPEND PROFANE_RESOURCES ${CHEZ_BOOT_FILES})

# Scheme sources -> Resources/scheme, preserving the library tree. Loaded from source at
# startup for now; precompiling to .so at build time is a later optimization.
set(_scheme_root "${PROJECT_SOURCE_DIR}/scheme")
file(GLOB_RECURSE _scheme_files CONFIGURE_DEPENDS "${_scheme_root}/*.ss" "${_scheme_root}/*.sls")
foreach(_file IN LISTS _scheme_files)
  file(RELATIVE_PATH _rel "${_scheme_root}" "${_file}")
  get_filename_component(_dir "${_rel}" DIRECTORY)
  if(_dir)
    set(_dir "/${_dir}")
  endif()
  set_source_files_properties("${_file}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/scheme${_dir}")
endforeach()
list(APPEND PROFANE_RESOURCES ${_scheme_files})

add_executable(profane MACOSX_BUNDLE
  main.m
  PFAppDelegate.m
  PFFont.m
  PFGlyphAtlas.m
  PFMetalRenderer.m
  PFReplServer.m
  PFScheme.m
  PFShaper.m
  ProfaneView.m
  ${PROFANE_RESOURCES})

set_target_properties(profane PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${PROFANE_BUNDLE_ID}"
  MACOSX_BUNDLE_BUNDLE_NAME profane
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}")
target_compile_options(profane PRIVATE -fobjc-arc ${PROFANE_WARNINGS})
target_link_libraries(profane PRIVATE
  pf_core_whole
  "-framework AppKit"
  "-framework CoreText"
  "-framework ImageIO"
  "-framework Metal"
  "-framework QuartzCore"
  "-framework UniformTypeIdentifiers")

# Sign the finished bundle with the hardened runtime and allow-jit. Runs after any binary or
# resource change, since resource copies alone do not relink the executable.
if(PROFANE_CODESIGN_IDENTITY STREQUAL "-")
  set(_timestamp --timestamp=none)
else()
  set(_timestamp --timestamp)
endif()
set(_sign_stamp "${CMAKE_CURRENT_BINARY_DIR}/profane-signed.stamp")
add_custom_command(
  OUTPUT "${_sign_stamp}"
  COMMAND codesign --force --sign "${PROFANE_CODESIGN_IDENTITY}" --options runtime
    --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/Profane.entitlements" ${_timestamp}
    "$<TARGET_BUNDLE_DIR:profane>"
  COMMAND "${CMAKE_COMMAND}" -E touch "${_sign_stamp}"
  DEPENDS profane "${CMAKE_CURRENT_SOURCE_DIR}/Profane.entitlements" ${PROFANE_RESOURCES}
  VERBATIM)
add_custom_target(profane_signed ALL DEPENDS "${_sign_stamp}")
