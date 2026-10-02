cmake_minimum_required(VERSION 3.22)
project(totp_ts_native_macos LANGUAGES Swift)

# Fase F: o host macOS nao compila mais NADA de C/Obj-C. O app e uma casca Swift
# fina (NtuiMacApp/NtuiHost/NtuiRuntime/NtuiMetalRenderer) sobre a dylib TS
# compilada — o Swift faz dlopen dela, le os acessores ntui_command_* /
# ntui_command_text_quads_* e desenha via Metal.
#
# O host antigo (ntui_macos_renderer.{c,h,m}) ficou congelado antes da migracao
# self-hosted e apontava para packages/compiler/src/runtime/macos/text, diretorio
# que nao existe mais — por isso o build quebrava com "font_manager.h not found".
# Os arquivos mortos foram movidos para ./legacy-c-host/ (nao sao mais
# compilados). As 4 fontes Swift sao copia do host canonico em
# examples/ts-native-ui-example/macos/src.

if(DEFINED ENV{NATIVE_TS_COMPILER_ROOT} AND NOT "$ENV{NATIVE_TS_COMPILER_ROOT}" STREQUAL "")
  set(NTUI_COMPILER_ROOT "$ENV{NATIVE_TS_COMPILER_ROOT}")
else()
  get_filename_component(NTUI_COMPILER_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../native-ts-compiler" ABSOLUTE)
endif()

set(NTUI_TS_NATIVE_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")
set(NTUI_TS_ENTRY "${NTUI_TS_NATIVE_ROOT}/ui-router.tsx")
set(NTUI_TS_RUNTIME "${CMAKE_CURRENT_BINARY_DIR}/generated/libntui_ts_app.dylib")
set(NTUI_ATLAS_BIN "${NTUI_COMPILER_ROOT}/packages/ts-native-ui-web/src/text/generated/font-atlas-sans-serif.a8.bin")

file(
  GLOB_RECURSE
  NTUI_TS_APP_SOURCES
  CONFIGURE_DEPENDS
  "${NTUI_TS_NATIVE_ROOT}/*.ts"
  "${NTUI_TS_NATIVE_ROOT}/*.tsx"
)
list(FILTER NTUI_TS_APP_SOURCES EXCLUDE REGEX "/(android|macos|scripts)/")

file(
  GLOB_RECURSE
  NTUI_TS_CSS_SOURCES
  CONFIGURE_DEPENDS
  "${NTUI_TS_NATIVE_ROOT}/app.css"
  "${NTUI_TS_NATIVE_ROOT}/styles/*.css"
)

file(
  GLOB_RECURSE
  NTUI_TS_WORKSPACE_SOURCES
  CONFIGURE_DEPENDS
  "${NTUI_COMPILER_ROOT}/packages/compiler/src/*.ts"
  "${NTUI_COMPILER_ROOT}/packages/ts-native-ui/src/*.ts"
  "${NTUI_COMPILER_ROOT}/packages/ts-native-ui-css/src/*.ts"
  "${NTUI_COMPILER_ROOT}/packages/ts-native-ui-display-list/src/*.ts"
  "${NTUI_COMPILER_ROOT}/packages/ts-native-ui-web/src/*.ts"
  "${NTUI_COMPILER_ROOT}/packages/ts-native-ui-web-macos/src/*.ts"
)

add_custom_command(
  OUTPUT "${NTUI_TS_RUNTIME}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "$<SHELL_PATH:${CMAKE_CURRENT_BINARY_DIR}/generated>"
  COMMAND
    bun run cli.ts compile
    "$<SHELL_PATH:${NTUI_TS_ENTRY}>"
    -o "$<SHELL_PATH:${NTUI_TS_RUNTIME}>"
    --artifact=shared
    --platform=darwin
  WORKING_DIRECTORY "${NTUI_COMPILER_ROOT}"
  DEPENDS
    "${NTUI_TS_ENTRY}"
    ${NTUI_TS_APP_SOURCES}
    ${NTUI_TS_CSS_SOURCES}
    ${NTUI_TS_WORKSPACE_SOURCES}
  VERBATIM
)

add_custom_target(ntui_ts_runtime DEPENDS "${NTUI_TS_RUNTIME}")

add_executable(
  TotpTsNativeMacApp
  MACOSX_BUNDLE
  src/NtuiMacApp.swift
  src/NtuiHost.swift
  src/NtuiRuntime.swift
  src/NtuiMetalRenderer.swift
)

add_dependencies(TotpTsNativeMacApp ntui_ts_runtime)

target_link_libraries(
  TotpTsNativeMacApp
  PRIVATE
  "-framework AppKit"
  "-framework CoreText"
  "-framework Metal"
  "-framework MetalKit"
  "-framework QuartzCore"
)

set_target_properties(
  TotpTsNativeMacApp
  PROPERTIES
    Swift_LANGUAGE_VERSION 5
    MACOSX_BUNDLE_GUI_IDENTIFIER "dev.meedwire.totp.tsnative.macos"
    MACOSX_BUNDLE_BUNDLE_NAME "TOTP Authenticator"
    MACOSX_BUNDLE_COPYRIGHT "Meedwire"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "dev.meedwire.totp.tsnative.macos"
    XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
)

add_custom_command(
  TARGET TotpTsNativeMacApp
  POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_BUNDLE_DIR:TotpTsNativeMacApp>/Contents/Frameworks"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "$<SHELL_PATH:${NTUI_TS_RUNTIME}>"
    "$<TARGET_BUNDLE_DIR:TotpTsNativeMacApp>/Contents/Frameworks/libntui_ts_app.dylib"
  COMMAND "${CMAKE_COMMAND}" -E copy_directory
    "$<SHELL_PATH:${CMAKE_CURRENT_LIST_DIR}/Resources/fonts>"
    "$<TARGET_BUNDLE_DIR:TotpTsNativeMacApp>/Contents/Resources/fonts"
  # Fase F: o atlas A8 assado vai como Resource do bundle; o NtuiHost carrega em runtime.
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "$<SHELL_PATH:${NTUI_ATLAS_BIN}>"
    "$<TARGET_BUNDLE_DIR:TotpTsNativeMacApp>/Contents/Resources/font-atlas-sans-serif.a8.bin"
  VERBATIM
)
