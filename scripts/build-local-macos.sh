#!/bin/bash
# Public entry point; compatible with the Bash 3.2 shipped with macOS.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.local-build"
OUTPUT="$BUILD/output/VoiceInk.app"
CONFIGURATION=Release
INSTALL=0
CHECK=0
WHISPER_ONLY=0
AUTO_XCODE=1
INTERACTIVE="${VOICEINK_INTERACTIVE:-0}"
[[ ! -t 0 || ! -t 1 ]] || INTERACTIVE=1
ORIGINAL_ARGS=("$@")
RESUME_COMMAND="$(printf '%q ' /bin/bash "$ROOT/scripts/build-local-macos.sh" "$@")"
STEP_NUMBER=0
STAGE=arguments
STAGING=
WHISPER_REV=a8d002cfd879315632a579e73f0148d06959de36 # v1.7.6
CMAKE_VERSION=3.31.8
CMAKE_SHA256=d1449f969c54d5c00886d5b643340d493dfb3c81cb39ee29b35453395c11ebf7
ARCH="$(uname -m)"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

die() { printf '\nError: %s\n' "$*" >&2; exit 1; }
step() { STAGE="$*"; STEP_NUMBER=$((STEP_NUMBER + 1)); printf '\n==> [%s] %s\n' "$STEP_NUMBER" "$STAGE"; }
usage() {
    cat <<'HELP'
Usage: ./scripts/build-local-macos.sh [options]
  --install          Also copy to ~/Applications/VoiceInk.app (per-user install)
  --output PATH      Output .app path (default: .local-build/output/VoiceInk.app)
  --debug            Debug instead of Release
  --check            Check prerequisites without installing or building anything
  --non-interactive  Never pause for input or prompt for administrator credentials
  --no-install-xcode Report missing Xcode without attempting a CLI installation
  --whisper-only     Prepare only the pinned macOS whisper XCFramework
  --help             Show this help

Full Xcode 26+ is required. In an interactive Terminal, tries mas if Xcode is
missing (using existing Homebrew if needed). Apple login may require interaction.
Otherwise install Xcode from App Store and rerun. No Homebrew or Python is needed
for CMake or the app's dependencies. Do not run this entire script with sudo.
HELP
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) INSTALL=1 ;;
        --debug) CONFIGURATION=Debug ;;
        --check) CHECK=1 ;;
        --non-interactive) INTERACTIVE=0 ;;
        --no-install-xcode) AUTO_XCODE=0 ;;
        --whisper-only) WHISPER_ONLY=1 ;;
        --output)
            [[ $# -ge 2 && -n "$2" ]] || die '--output requires a path'
            OUTPUT="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
    shift
done
[[ "$(uname -s)" == Darwin ]] || die 'This script requires macOS.'
[[ "$EUID" -ne 0 ]] || die 'Run as your normal user, without sudo.'
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || die "Unsupported architecture: $ARCH"
case "$OUTPUT" in /*) ;; *) OUTPUT="$PWD/$OUTPUT" ;; esac
[[ "$OUTPUT" == *.app ]] || die 'Choose an output path ending in .app.'

if [[ "$CHECK" == 1 ]]; then
    INTERACTIVE=0
else
    mkdir -p "$BUILD/logs"
    if [[ "${VOICEINK_LOGGED:-0}" != 1 ]]; then
        LOG="$BUILD/logs/build-$(date +%Y%m%d-%H%M%S)-$$.log"
        # A pipeline works even where /dev/fd process substitution is unavailable.
        # Preserve terminal detection for the child, whose stdout goes through tee.
        set +e
        VOICEINK_LOGGED=1 VOICEINK_INTERACTIVE="$INTERACTIVE" VOICEINK_LOG_PATH="$LOG" \
            /bin/bash "$ROOT/scripts/build-local-macos.sh" ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"} 2>&1 | tee "$LOG"
        PIPE_STATUSES=("${PIPESTATUS[@]}")
        [[ "${PIPE_STATUSES[0]}" == 0 ]] || exit "${PIPE_STATUSES[0]}"
        exit "${PIPE_STATUSES[1]}"
    fi
    LOG="$VOICEINK_LOG_PATH"
    finish() {
        local status=$?
        [[ -z "$STAGING" ]] || rm -rf "$STAGING"
        if [[ "$status" != 0 ]]; then
            printf '\nBuild stopped during: %s (exit %s).\nLog: %s\n' "$STAGE" "$status" "$LOG" >&2
            case "$STAGE" in
                *CMake*|*packages*) printf 'Проверь доступ к GitHub и свободное место. После исправления повтори запуск.\n' >&2 ;;
                *whisper*) printf 'Подсказки по нативной сборке: %s/BUILDING.md (Troubleshooting).\n' "$ROOT" >&2 ;;
                *VoiceInk*) printf 'Подробности ошибки — выше и в логе. Готовое установленное приложение сохраняется до успешной проверки новой сборки.\n' >&2 ;;
            esac
            printf 'Продолжить повторным запуском (готовые зависимости сохраняются):\n  %s\n' "$RESUME_COMMAND" >&2
        fi
    }
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '\nVoiceInk — пошаговая сборка и установка для этого Mac (%s).\n' "$ARCH"
    printf 'Проверю Xcode → подготовлю инструменты → соберу зависимости и приложение → проверю подпись.\n'
    [[ "$INSTALL" != 1 ]] || printf 'Затем установлю приложение в ~/Applications/VoiceInk.app.\n'
    if [[ "$INTERACTIVE" == 1 ]]; then
        printf 'Если потребуется ручное действие, покажу инструкцию и дождусь Enter. Для выхода: q или Ctrl+C.\n'
    else
        printf 'Без интерактивного Terminal: при необходимости ручного действия выведу инструкцию и завершу работу.\n'
    fi
    printf 'Лог: %s\n' "$LOG"
fi

REQUESTED_DEVELOPER_DIR="${DEVELOPER_DIR:-}"
find_xcode() {
    local candidate selected
    if [[ -n "$REQUESTED_DEVELOPER_DIR" ]]; then
        export DEVELOPER_DIR="$REQUESTED_DEVELOPER_DIR"
        [[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] || die "Invalid DEVELOPER_DIR: $DEVELOPER_DIR"
        return 0
    fi
    selected="$(xcode-select -p 2>/dev/null || true)"
    for candidate in /Applications/Xcode.app/Contents/Developer "$selected" \
        /Applications/Xcode*.app/Contents/Developer "$HOME"/Applications/Xcode*.app/Contents/Developer; do
        if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
            export DEVELOPER_DIR="$candidate"
            return 0
        fi
    done
    return 1
}
xcode_instructions() {
    cat >&2 <<'HELP'

Нужен полный Xcode 26 или новее с macOS SDK.
Одних Command Line Tools (xcode-select --install) недостаточно.
1. Установи Xcode: https://apps.apple.com/app/xcode/id497799835
   Или в обычном Terminal, если установлен mas и выполнен вход в App Store:
       mas get 497799835
   Пароль администратора вводится только в запрос macOS / sudo.
2. Открой Xcode, прими лицензию и заверши установку обязательных компонентов.
   Платформы и симуляторы iOS / watchOS / tvOS / visionOS здесь не нужны.
3. Вернись сюда и нажми Enter для повторной проверки.
   Если скрипт уже закрыт, запусти ту же команду снова.
   Менять глобальный xcode-select не требуется. Для нестандартного пути:
       DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer" ./scripts/build-local-macos.sh --install
HELP
}
manual_xcode_step() {
    printf '\nНужно ручное действие: %s\n' "$1" >&2
    xcode_instructions
    [[ "$INTERACTIVE" == 1 ]] || return 1
    local answer
    while :; do
        printf '\n[Enter] проверить снова · [a] открыть App Store · [x] открыть Xcode · [q] выйти: '
        if ! IFS= read -r answer; then
            printf '\nВвод закрыт. После настройки повтори: %s\n' "$RESUME_COMMAND" >&2
            return 1
        fi
        case "$answer" in
            '') return 0 ;;
            a|A) open 'macappstore://apps.apple.com/app/id497799835' || printf 'Открой ссылку App Store из инструкции выше.\n' ;;
            x|X)
                if [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR/../.." ]]; then
                    open "$DEVELOPER_DIR/../.." || printf 'Открой Xcode вручную.\n'
                else
                    open -a Xcode || printf 'Сначала установи Xcode через App Store.\n'
                fi ;;
            q|Q) printf 'Остановлено. Позже продолжи той же командой.\n'; exit 130 ;;
            *) printf 'Нажми Enter после завершения настройки, a, x или q.\n' ;;
        esac
    done
}

step 'Checking Xcode'
XCODE_INSTALL_ATTEMPTED=0
XCODE_SETUP_ATTEMPTED=0
while :; do
    if ! find_xcode; then
        if [[ "$CHECK" == 0 && "$AUTO_XCODE" == 1 && "$XCODE_INSTALL_ATTEMPTED" == 0 && "$INTERACTIVE" == 1 ]]; then
            XCODE_INSTALL_ATTEMPTED=1
            for brew_bin in /opt/homebrew/bin /usr/local/bin; do
                [[ ! -x "$brew_bin/brew" ]] || export PATH="$brew_bin:$PATH"
            done
            if ! command -v mas >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
                step 'Installing the Mac App Store CLI using existing Homebrew'
                brew install mas || printf 'Could not install mas; use the App Store instructions below.\n'
            fi
            if command -v mas >/dev/null 2>&1; then
                step 'Installing Xcode from App Store (may require Apple login / administrator authorization)'
                printf 'Apple может запросить пароль macOS в Terminal и вход в App Store. Пароль вводи только в системный запрос.\n'
                mas get 497799835 || printf 'CLI installation did not complete; use the App Store instructions below.\n'
            fi
        fi
        if ! find_xcode; then
            manual_xcode_step 'Установи полный Xcode 26+ и заверши его начальную настройку.' || die 'Full Xcode is not installed. Install it and rerun.'
            continue
        fi
    fi
    printf 'Using DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"
    if ! XCODE_VERSION="$(xcodebuild -version)"; then
        manual_xcode_step 'Открой Xcode, прими лицензию и заверши начальную настройку.' || die 'Xcode is not ready. Open it and complete first-launch setup.'
        continue
    fi
    printf '%s\n' "$XCODE_VERSION"
    XCODE_MAJOR="$(printf '%s\n' "$XCODE_VERSION" | awk 'NR==1 {split($2,v,"."); print v[1]}')"
    if [[ ! "$XCODE_MAJOR" =~ ^[0-9]+$ || "$XCODE_MAJOR" -lt 26 ]]; then
        manual_xcode_step 'Обнови Xcode до версии 26 или новее: исходники используют macOS SDK 26+.' || die 'Xcode 26+ is required for native Speech APIs in this source tree.'
        continue
    fi
    if ! xcodebuild -checkFirstLaunchStatus; then
        [[ "$CHECK" == 0 ]] || die 'Finish Xcode first-launch setup before building.'
        if [[ "$XCODE_SETUP_ATTEMPTED" == 0 ]]; then
            XCODE_SETUP_ATTEMPTED=1
            step 'Finishing Xcode setup (macOS may request administrator authorization)'
            # First try without privilege elevation. Never accept Apple's license on
            # the user's behalf. If it is pending, Xcode must be opened manually.
            if xcodebuild -runFirstLaunch; then
                :
            else
                SETUP_STATUS=$?
                if [[ "$SETUP_STATUS" == 77 ]]; then
                    printf 'Сначала прими лицензию в окне Xcode; повторный запрос sudo это не исправит.\n'
                elif [[ "$INTERACTIVE" == 1 ]]; then
                    sudo env DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -runFirstLaunch || true
                else
                    sudo -n env DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -runFirstLaunch </dev/null || true
                fi
            fi
        fi
        if ! xcodebuild -checkFirstLaunchStatus; then
            manual_xcode_step 'Открой Xcode, прими соглашение и дождись установки обязательных компонентов macOS. Остальные платформы и симуляторы не нужны.' || die 'Open Xcode, accept its license, finish setup, then rerun.'
            continue
        fi
    fi
    if ! SDK="$(xcrun --sdk macosx --show-sdk-path)"; then
        manual_xcode_step 'В Xcode не готов macOS SDK. Заверши установку обязательных компонентов.' || die 'The macOS SDK is missing. Finish Xcode setup.'
        continue
    fi
    MISSING_TOOL=
    for tool in git clang clang++ swift libtool; do
        if ! xcrun --find "$tool" >/dev/null; then MISSING_TOOL="$tool"; break; fi
    done
    if [[ -n "$MISSING_TOOL" ]]; then
        manual_xcode_step "Xcode tool missing: $MISSING_TOOL. Finish Xcode setup." || die "Xcode tool missing: $MISSING_TOOL. Finish Xcode setup."
        continue
    fi
    break
done
if [[ "$CHECK" == 1 ]]; then
    printf '\nPrerequisites OK. CMake and pinned dependencies will be prepared during the build.\n'
    exit 0
fi

step 'Preparing CMake'
# Known version, independent of Homebrew permissions, Python, and PATH.
CMAKE_HOME="$BUILD/tools/cmake-$CMAKE_VERSION-macos-universal"
CMAKE="$CMAKE_HOME/CMake.app/Contents/bin/cmake"
if [[ ! -x "$CMAKE" ]]; then
    mkdir -p "$BUILD/tools"
    ARCHIVE="$BUILD/tools/cmake-$CMAKE_VERSION-macos-universal.tar.gz"
    curl --fail --location --retry 3 --connect-timeout 30 \
        "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-macos-universal.tar.gz" -o "$ARCHIVE.part"
    printf '%s  %s\n' "$CMAKE_SHA256" "$ARCHIVE.part" | shasum -a 256 -c -
    mv "$ARCHIVE.part" "$ARCHIVE"
    tar -xzf "$ARCHIVE" -C "$BUILD/tools"
fi
"$CMAKE" --version

step 'Preparing pinned whisper.cpp v1.7.6'
WHISPER="$BUILD/dependencies/whisper.cpp"
FRAMEWORK="$BUILD/dependencies/whisper.xcframework"
if [[ ! -d "$WHISPER/.git" ]]; then
    [[ ! -e "$WHISPER" ]] || die "Incomplete dependency directory: $WHISPER. Remove it and rerun."
    mkdir -p "$BUILD/dependencies"
    STAGING="$(mktemp -d "$BUILD/dependencies/whisper-clone.XXXXXX")"
    git clone --depth 1 --branch v1.7.6 https://github.com/ggml-org/whisper.cpp.git "$STAGING/source"
    mv "$STAGING/source" "$WHISPER"
    rmdir "$STAGING"
    STAGING=
fi
[[ "$(git -C "$WHISPER" rev-parse HEAD)" == "$WHISPER_REV" ]] || die "Unexpected whisper.cpp revision in $WHISPER; move that directory away and rerun."
[[ -z "$(git -C "$WHISPER" status --porcelain --untracked-files=no)" ]] || die "whisper.cpp has modified tracked files: $WHISPER"
CACHE_KEY="$( { printf '%s\n' "$WHISPER_REV" "$ARCH" "$XCODE_VERSION" "$SDK" "$CMAKE_VERSION"; shasum -a 256 "$ROOT/scripts/build-whisper-macos-only.sh"; } | shasum -a 256 | awk '{print $1}')"
if [[ ! -f "$FRAMEWORK/Info.plist" || ! -f "$BUILD/dependencies/whisper.build-key" || "$(cat "$BUILD/dependencies/whisper.build-key")" != "$CACHE_KEY" ]]; then
    step "Building whisper.cpp for macOS ($ARCH only)"
    bash "$ROOT/scripts/build-whisper-macos-only.sh" "$WHISPER" "$FRAMEWORK" "$CMAKE" "$ARCH" "$JOBS"
    printf '%s\n' "$CACHE_KEY" > "$BUILD/dependencies/whisper.build-key"
else
    printf 'Reusing verified whisper XCFramework.\n'
fi
if [[ "$WHISPER_ONLY" == 1 ]]; then
    printf '\nWhisper ready: %s\nLog: %s\n' "$FRAMEWORK" "$LOG"
    exit 0
fi

XCODE_ARGS=(-project "$ROOT/VoiceInk.xcodeproj" -scheme VoiceInk
    -configuration "$CONFIGURATION" -destination 'platform=macOS'
    -derivedDataPath "$BUILD/DerivedData" -clonedSourcePackagesDirPath "$BUILD/SourcePackages")
step 'Resolving Swift packages at the revisions in Package.resolved'
xcodebuild "${XCODE_ARGS[@]}" -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile
step "Building VoiceInk ($CONFIGURATION, $ARCH, local ad-hoc signing)"
xcodebuild "${XCODE_ARGS[@]}" -disableAutomaticPackageResolution \
    -xcconfig "$ROOT/LocalBuild.xcconfig" \
    "WHISPER_FRAMEWORK_PATH=$FRAMEWORK" "ARCHS=$ARCH" ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= \
    "CODE_SIGN_ENTITLEMENTS=$ROOT/VoiceInk/VoiceInk.local.entitlements" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD' build

step 'Verifying and exporting VoiceInk.app'
APP="$BUILD/DerivedData/Build/Products/$CONFIGURATION/VoiceInk.app"
[[ -x "$APP/Contents/MacOS/VoiceInk" ]] || die "Built application was not found at $APP"
codesign --verify --deep --strict "$APP"
# Signature integrity alone does not guarantee an ad-hoc app can load frameworks:
# hardened runtime otherwise rejects libraries because there is no Team ID.
codesign --display --entitlements - --xml "$APP" > "$BUILD/verified-entitlements.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$BUILD/verified-entitlements.plist")" == true ]] || die 'Local app is missing the entitlement needed to load embedded frameworks without an Apple Team ID.'
mkdir -p "$(dirname "$OUTPUT")"
[[ ! -e "$OUTPUT" || -d "$OUTPUT/Contents" ]] || die "Output exists and is not an app bundle: $OUTPUT"
[[ "$OUTPUT" != "$APP" ]] || die 'Output must differ from the internal DerivedData app.'
STAGING="$(mktemp -d "$(dirname "$OUTPUT")/voiceink-export.XXXXXX")"
ditto "$APP" "$STAGING/VoiceInk.app"
codesign --verify --deep --strict "$STAGING/VoiceInk.app"
rm -rf "$OUTPUT"
mv "$STAGING/VoiceInk.app" "$OUTPUT"
rmdir "$STAGING"
STAGING=
if [[ "$INSTALL" == 1 ]]; then
    step 'Installing in ~/Applications'
    INSTALL_PATH="$HOME/Applications/VoiceInk.app"
    if [[ "$OUTPUT" != "$INSTALL_PATH" ]]; then
        mkdir -p "$HOME/Applications"
        [[ ! -e "$INSTALL_PATH" || -d "$INSTALL_PATH/Contents" ]] || die "Install path exists and is not an app bundle: $INSTALL_PATH"
        STAGING="$(mktemp -d "$HOME/Applications/voiceink-install.XXXXXX")"
        ditto "$OUTPUT" "$STAGING/VoiceInk.app"
        codesign --verify --deep --strict "$STAGING/VoiceInk.app"
        rm -rf "$INSTALL_PATH"
        mv "$STAGING/VoiceInk.app" "$INSTALL_PATH"
        rmdir "$STAGING"
        STAGING=
    fi
    printf 'Installed: %s\n' "$INSTALL_PATH"
fi
LAUNCH_PATH="$OUTPUT"
[[ "$INSTALL" != 1 ]] || LAUNCH_PATH="$INSTALL_PATH"
printf '\nГотово!\nBuild complete: %s\nLog: %s\nLaunch: open "%s"\n' "$OUTPUT" "$LOG" "$LAUNCH_PATH"
printf 'При первом запуске выбери модель распознавания и предоставь запрошенные приложением разрешения macOS.\n'
if [[ "$INTERACTIVE" == 1 && "$INSTALL" == 1 ]]; then
    printf 'Открыть установленный VoiceInk? [Д/н]: '
    ANSWER=
    IFS= read -r ANSWER || true
    case "$ANSWER" in ''|y|Y|д|Д) open "$LAUNCH_PATH" || printf 'Открой приложение по пути выше.\n' ;; esac
fi
