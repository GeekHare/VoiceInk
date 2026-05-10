#!/usr/bin/env bash
# One-shot local build for VoiceInk on macOS: prerequisites check, CMake if needed,
# prefer full Xcode over Command Line Tools only, then `make local`
# (outputs ~/Downloads/VoiceInk.app).
#
# Usage from repo root:
#   ./scripts/build-local-macos.sh
# Or from anywhere:
#   bash /path/to/VoiceInk/scripts/build-local-macos.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() {
	echo "Error: $*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "$1 not found. Install Xcode from the App Store and Command Line Tools (xcode-select --install)."
}

echo "==> VoiceInk local build ($(uname -m) macOS)"

# Prefer full Xcode so xcodebuild / SDKs match VoiceInk + whisper.cpp.
pick_developer_dir() {
	local d
	for d in /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer; do
		if [[ -d "$d" ]]; then
			export DEVELOPER_DIR="$d"
			return 0
		fi
	done
	# Any Xcode*.app (bash 3.2–safe glob)
	local saved
	saved=$(shopt -p nullglob)
	shopt -s nullglob
	for d in /Applications/Xcode*.app/Contents/Developer; do
		if [[ -d "$d" ]]; then
			export DEVELOPER_DIR="$d"
			eval "$saved"
			return 0
		fi
	done
	eval "$saved"
	return 1
}

if pick_developer_dir; then
	echo "==> Using DEVELOPER_DIR=$DEVELOPER_DIR"
else
	echo "==> No Xcode.app found under /Applications; using current xcode-select path"
fi

need_cmd git
need_cmd swift

if ! xcodebuild -version >/dev/null 2>&1; then
	die "Full Xcode is required (not Command Line Tools alone). Install Xcode from the App Store, open it once to finish setup, then run:\n  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

echo "==> $(xcodebuild -version | head -1)"

ensure_cmake() {
	if command -v cmake >/dev/null 2>&1; then
		return 0
	fi
	if command -v brew >/dev/null 2>&1; then
		local prefix
		prefix="$(brew --prefix cmake 2>/dev/null || true)"
		if [[ -n "$prefix" && -x "$prefix/bin/cmake" ]]; then
			export PATH="$prefix/bin:$PATH"
		fi
	fi
	if command -v cmake >/dev/null 2>&1; then
		return 0
	fi
	echo "==> CMake not found; installing with pip (user install, no sudo)..."
	python3 -m pip install --user --upgrade cmake
	local userbase
	userbase="$(python3 -m site --user-base 2>/dev/null || true)"
	if [[ -n "$userbase" ]]; then
		export PATH="$userbase/bin:$PATH"
	fi
	command -v cmake >/dev/null 2>&1
}

ensure_cmake || die "Could not install CMake. Fix Homebrew permissions or install manually: brew install cmake"

echo "==> $(command -v cmake) — $(cmake --version | head -1)"

echo "==> Running make local (whisper + VoiceInk → ~/Downloads/VoiceInk.app)..."
make -C "$ROOT" local

echo ""
echo "Done. Install the app by dragging ~/Downloads/VoiceInk.app to Applications."
