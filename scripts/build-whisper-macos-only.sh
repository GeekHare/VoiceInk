#!/bin/bash
# Internal helper. Users should run build-local-macos.sh, which prepares tools.
# No sourcing/executing fragments of upstream's multi-platform build script.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# == 0 ]]; then
    exec bash "$ROOT/scripts/build-local-macos.sh" --whisper-only
fi
[[ $# == 5 ]] || { echo 'Internal usage: build-whisper-macos-only.sh SOURCE OUTPUT CMAKE ARCH JOBS' >&2; exit 1; }
SOURCE="$1"
OUTPUT="$2"
CMAKE="$3"
ARCH="$4"
JOBS="$5"
BUILD="$ROOT/.local-build/whisper-$ARCH"
FRAMEWORK="$BUILD/framework/whisper.framework"
VERSION="$FRAMEWORK/Versions/A"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CONFIG_KEY="$(printf '%s\n' "$SOURCE" "$SDK" "$ARCH" "$CMAKE" "$(xcrun --find clang)" | shasum -a 256 | awk '{print $1}')"
if [[ -d "$BUILD" && ( ! -f "$BUILD/voiceink-config-key" || "$(cat "$BUILD/voiceink-config-key")" != "$CONFIG_KEY" ) ]]; then
    rm -rf "$BUILD"
fi
mkdir -p "$BUILD"
printf '%s\n' "$CONFIG_KEY" > "$BUILD/voiceink-config-key"

"$CMAKE" -S "$SOURCE" -B "$BUILD" -G 'Unix Makefiles' \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.4 \
    "-DCMAKE_OSX_ARCHITECTURES=$ARCH" "-DCMAKE_OSX_SYSROOT=$SDK" \
    -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON
"$CMAKE" --build "$BUILD" --config Release --parallel "$JOBS"

# Match the pinned version's static library graph explicitly; missing libraries
# fail the build instead of silently producing an incomplete framework.
LIBRARIES=("$BUILD/src/libwhisper.a" "$BUILD/src/libwhisper.coreml.a"
    "$BUILD/ggml/src/libggml.a" "$BUILD/ggml/src/libggml-base.a"
    "$BUILD/ggml/src/libggml-cpu.a"
    "$BUILD/ggml/src/ggml-metal/libggml-metal.a"
    "$BUILD/ggml/src/ggml-blas/libggml-blas.a")
xcrun libtool -static -o "$BUILD/combined.a" "${LIBRARIES[@]}"
rm -rf "$BUILD/framework"
mkdir -p "$VERSION/Headers" "$VERSION/Modules" "$VERSION/Resources"
cp "$SOURCE/include/whisper.h" "$VERSION/Headers/"
cp "$SOURCE/LICENSE" "$VERSION/Resources/LICENSE-whisper.txt"
for header in ggml.h ggml-alloc.h ggml-backend.h ggml-metal.h ggml-cpu.h ggml-blas.h gguf.h; do
    cp "$SOURCE/ggml/include/$header" "$VERSION/Headers/"
done
cat > "$VERSION/Modules/module.modulemap" <<'MODULE'
framework module whisper {
    header "whisper.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "MetalKit"
    link framework "Foundation"
    link framework "CoreML"
    export *
}
MODULE
cat > "$VERSION/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>whisper</string>
<key>CFBundleIdentifier</key><string>org.ggml.whisper</string>
<key>CFBundleName</key><string>whisper</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.7.6</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>LSMinimumSystemVersion</key><string>14.4</string>
</dict></plist>
PLIST
ln -s A "$FRAMEWORK/Versions/Current"
for name in Headers Modules Resources whisper; do
    ln -s "Versions/Current/$name" "$FRAMEWORK/$name"
done
xcrun clang++ -dynamiclib -arch "$ARCH" -isysroot "$SDK" \
    -mmacosx-version-min=14.4 "-Wl,-force_load,$BUILD/combined.a" \
    -framework Foundation -framework Metal -framework MetalKit \
    -framework Accelerate -framework CoreML \
    -install_name '@rpath/whisper.framework/Versions/A/whisper' \
    -o "$VERSION/whisper"
# Stage the new framework before replacing a previous usable copy.
mkdir -p "$(dirname "$OUTPUT")"
STAGING="$(mktemp -d "$(dirname "$OUTPUT")/whisper-export.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$STAGING/whisper.xcframework"
rm -rf "$OUTPUT"
mv "$STAGING/whisper.xcframework" "$OUTPUT"
printf 'whisper XCFramework ready: %s\n' "$OUTPUT"
