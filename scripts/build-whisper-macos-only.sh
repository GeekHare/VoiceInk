#!/usr/bin/env bash
# VoiceInk only ships a macOS app; whisper's upstream build-xcframework.sh also
# builds iOS / visionOS / tvOS slices, which requires those SDKs and breaks when
# they are missing or when CMake mis-resolves iphonesimulator.
#
# This script reuses whisper.cpp's variables, tool checks, and helper functions
# (sourced from fixed line ranges in build-xcframework.sh) and runs only the
# macOS CMake target + single-slice xcframework.
#
# If whisper.cpp changes those line ranges, update the sed ranges below.
# Start at line 4: IOS_/MACOS_*_MIN_OS_VERSION live before BUILD_SHARED_LIBS.

set -euo pipefail

WHISPER_CPP_DIR="${WHISPER_CPP_DIR:-$HOME/VoiceInk-Dependencies/whisper.cpp}"
cd "$WHISPER_CPP_DIR"

UPSTREAM="${WHISPER_CPP_DIR}/build-xcframework.sh"
if [[ ! -f "$UPSTREAM" ]]; then
	echo "Error: whisper.cpp not found at ${WHISPER_CPP_DIR}"
	exit 1
fi

# Variables, prerequisite checks, setup_framework_structure + combine_static_libraries.
# Use a temp file: bash 3.2 (macOS default) does not keep arrays from `source <(...)`.
FRAGMENT="$(mktemp)"
trap 'rm -f "$FRAGMENT"' EXIT
sed -n '4,64p;79,421p' "$UPSTREAM" >"$FRAGMENT"
# shellcheck disable=SC1090
source "$FRAGMENT"

rm -rf build-apple build-macos

echo "Building whisper for macOS only (VoiceInk dependency)..."
cmake -B build-macos -G Xcode \
	"${COMMON_CMAKE_ARGS[@]}" \
	-DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_MIN_OS_VERSION}" \
	-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
	-DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
	-DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
	-DWHISPER_COREML="ON" \
	-DWHISPER_COREML_ALLOW_FALLBACK="ON" \
	-S .
cmake --build build-macos --config Release -- -quiet

echo "Setting up framework structure..."
setup_framework_structure "build-macos" "${MACOS_MIN_OS_VERSION}" "macos"

echo "Creating dynamic library from static libraries..."
combine_static_libraries "build-macos" "Release" "macos" "false"

mkdir -p build-apple
echo "Creating whisper.xcframework (macOS slice only)..."
if [[ "${BUILD_STATIC_XCFRAMEWORK:-OFF}" == "ON" ]]; then
	xcodebuild -create-xcframework \
		-framework "$(pwd)/build-macos/framework/whisper.framework" \
		-output "$(pwd)/build-apple/whisper.xcframework"
else
	xcodebuild -create-xcframework \
		-framework "$(pwd)/build-macos/framework/whisper.framework" \
		-debug-symbols "$(pwd)/build-macos/dSYMs/whisper.dSYM" \
		-output "$(pwd)/build-apple/whisper.xcframework"
fi

echo "whisper.xcframework ready at $(pwd)/build-apple/whisper.xcframework"
