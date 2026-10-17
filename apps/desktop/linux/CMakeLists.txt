# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "skotiq")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.skotiq.desktop")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  # Newer clang (e.g. clang 22 on Arch/CachyOS) flags pre-existing deprecated
  # syntax in some third-party plugin headers (e.g. flutter_secure_storage_linux's
  # vendored json.hpp uses `operator"" _json`) as an error under -Werror. These
  # come from upstream plugins, not our code, and would otherwise break the build
  # on bleeding-edge toolchains. Demote just these diagnostics back to warnings.
  # Appended AFTER -Werror so the per-warning exemption wins.
  #
  # `-Wno-unknown-warning-option` MUST come first: older clang (e.g. clang 14 on
  # Debian Bookworm, the appliance's build/runtime target) does not know the
  # `deprecated-literal-operator` warning name, and without this guard `-Werror`
  # promotes the resulting "unknown warning option" into a hard build failure.
  # With it, the specific suppressions below are simply ignored on toolchains
  # that predate those warnings.
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    target_compile_options(${TARGET} PRIVATE
      -Wno-unknown-warning-option
      -Wno-error=deprecated-literal-operator
      -Wno-error=deprecated-declarations)
  endif()
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets produced by package build hooks (package:sqlite3's
# hermetic libsqlite3.so is the one this release depends on).
#
# The existence check MUST happen at install time. It used to be a configure
# time `if(EXISTS ...)`, and the hooks do not run until the Flutter build,
# after CMake has configured — so on a clean tree the directory did not exist
# yet, the install rule was never created, and the asset was silently dropped
# from the bundle. That is invisible on any machine whose build/ directory
# still holds native_assets/ from an earlier build, which is exactly why every
# local build passed and every clean CI build shipped a bundle without SQLite.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux")
install(CODE "
  file(GLOB _ns_assets \"${NATIVE_ASSETS_DIR}/*\")
  if(_ns_assets)
    file(COPY \${_ns_assets} DESTINATION \"${INSTALL_BUNDLE_LIB_DIR}\")
  else()
    message(WARNING \"No native assets found in ${NATIVE_ASSETS_DIR}; the bundle will have no hermetic libsqlite3.\")
  endif()
" COMPONENT Runtime)

# Copy Rust native library if it exists
# This allows the library to be found at runtime.
# CMAKE_CURRENT_SOURCE_DIR is apps/desktop/linux, so the repo root is THREE
# levels up (linux -> desktop -> apps -> root). The previous "../../native"
# resolved to apps/native and silently never bundled the bridge .so, so the
# Linux release shipped without its native library and couldn't start.
set(RUST_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../native/skotiq_native/target/release")
set(RUST_LIB_NAME "libskotiq_bridge.so")
if(EXISTS "${RUST_LIB_DIR}/${RUST_LIB_NAME}")
  install(FILES "${RUST_LIB_DIR}/${RUST_LIB_NAME}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
  message(STATUS "Installing Rust library: ${RUST_LIB_NAME}")
else()
  message(WARNING "Rust library not found at ${RUST_LIB_DIR}/${RUST_LIB_NAME}. Build it first with: cd native/skotiq_native && cargo build --release")
endif()

# Install application icons
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/icons"
  DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
