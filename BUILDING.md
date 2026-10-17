# Building VoiceInk on macOS

Run one command from the repository root, as your normal user:

```bash
./scripts/build-local-macos.sh --install
```

This builds a Release application for the current Mac (Apple Silicon or Intel),
with ad-hoc signing. No Apple Developer subscription or signing certificate is
needed. The verified application is exported to
`.local-build/output/VoiceInk.app` and, with `--install`, copied to
`~/Applications/VoiceInk.app`. Launch it with:

```bash
open ~/Applications/VoiceInk.app
```

Without `--install`, the script only exports the application inside the project.
It can also be run from any working directory:

```bash
bash /path/to/voiceink/scripts/build-local-macos.sh --install
```

## First run on a clean Mac

A **full Xcode 26 or newer** is required. The source enables the native Speech
APIs from the macOS 26 SDK. Command Line Tools alone are insufficient, even if
`git` and `swift` already work. Xcode may require a newer macOS version than the
application's deployment target (macOS 14.4).

In an interactive Terminal, if Xcode is missing, the script tries to install it
using `mas`, the Mac App Store CLI. If Homebrew already exists, the script can
install `mas` with `brew install mas`. It does not install Homebrew itself.

CLI installation requires an Apple Account signed in to App Store and may ask
for your macOS administrator password in Terminal. On a clean Mac, or when Apple
requires authentication, manual installation may be necessary:

1. Install [Xcode from the App Store](https://apps.apple.com/app/xcode/id497799835).
2. Open Xcode, accept the license and complete its first-launch setup. Only the
   macOS components are needed; other platforms and their simulators are optional.
3. Return to Terminal and press **Enter**. The script checks again and continues
   in the same run. If you already exited it, rerun the same command. The script
   detects Xcode without changing the computer's global `xcode-select` setting.

If Xcode is installed but first-launch tasks remain, the script first tries
`xcodebuild -runFirstLaunch` without sudo. If administrative privileges are needed,
it can request them for that step only. A pending license must be accepted by you
in Xcode; the script does not accept it on your behalf. Never run the entire
build script with `sudo`.

### Interactive guidance

The installer detects a normal Terminal, shows a numbered sequence of stages,
and pauses when a manual step is required. At that prompt:

- **Enter** checks Xcode again and continues when it is ready.
- **a** opens the Xcode page in App Store.
- **x** opens Xcode for license acceptance and component setup.
- **q** or **Ctrl+C** stops the installer. Its error summary includes the exact
  command to resume later, preserving your arguments and quoting paths with spaces.

Once installed, it offers to open VoiceInk. Inside the app, select a transcription
model and grant the macOS permissions required by the features you use.

`--non-interactive` disables these prompts and skips App Store CLI installation
that could require user authentication. First-launch setup can only use existing
administrator authorization (`sudo -n`); it will not request a password. If manual
action is required, the script prints the steps and exits with a nonzero status.
It behaves this way automatically when input/output are not a terminal. `--check`
always checks without installing, setting up Xcode, or waiting for input.

For a custom Xcode location, set:

```bash
DEVELOPER_DIR="/Volumes/Development/Xcode.app/Contents/Developer" \
  ./scripts/build-local-macos.sh --install
```

Internet access is needed on the first build for CMake, whisper.cpp, Swift
packages and their binary artifacts. Allow sufficient free space for Xcode and
its installation, plus several GB for build tools, dependencies and build output.

## What the script prepares

All build data stays in the ignored `.local-build/` directory:

- **CMake 3.31.8**, downloaded from Kitware's official GitHub release. The universal
  archive is checked against a pinned SHA-256 before extraction. Homebrew and
  Python are not needed for CMake.
- **whisper.cpp v1.7.6**, verified at commit
  `a8d002cfd879315632a579e73f0148d06959de36`. The macOS framework includes Metal,
  Accelerate and Core ML. It builds only the current architecture, and does not
  execute or extract line ranges from upstream's multi-platform shell script.
- **Swift packages**, resolved using the committed `Package.resolved` revisions,
  including dependencies whose project requirements track branches.
- **VoiceInk**, using `LocalBuild.xcconfig`, local entitlements and `LOCAL_BUILD`.
  The final bundle is checked with `codesign --verify --deep --strict` before
  export or installation. Local entitlements disable the hardened runtime's
  Team ID check for loaded libraries, allowing the ad-hoc app to load its embedded
  frameworks without a developer certificate. The script verifies this entitlement
  in the signed app too; normal developer builds keep their original entitlements.

Repeated runs reuse build products. The whisper cache is invalidated when the
native build helper, pinned revision, CMake version, architecture, Xcode or SDK
change. Failed builds keep logs under `.local-build/logs/`; the script prints
the log path and failing stage.
An existing exported or installed app is replaced only after a new bundle builds
and passes signature verification.

The helper `scripts/build-whisper-macos-only.sh` is internal; normally you only
need `build-local-macos.sh`. For Xcode development, run the script once with
`--whisper-only`, then open `VoiceInk.xcodeproj`. Its default framework reference
points to the project-local XCFramework.

## Options and Makefile shortcuts

```bash
./scripts/build-local-macos.sh --help
./scripts/build-local-macos.sh --check              # no installation or build
./scripts/build-local-macos.sh --install --non-interactive # never wait for input
./scripts/build-local-macos.sh --no-install-xcode   # skip automatic Xcode install
./scripts/build-local-macos.sh --debug              # Debug instead of Release
./scripts/build-local-macos.sh --output "$HOME/Downloads/VoiceInk.app"
./scripts/build-local-macos.sh --whisper-only
```

`make`, `make local`, `make build` and `make all` all run the same Release build.
`make dev` builds Debug and launches the result. `make run` launches the last
exported app. `make check` checks Xcode; `make whisper` / `make setup` prepare only
the native dependency. `make clean` removes this checkout's `.local-build/`,
including tools, dependencies and logs; it does not remove the installed app.

## Local build limitations

Local builds disable automatic updates and iCloud dictionary sync. Update this
checkout and rerun the script to install a newer build. The app will still need
normal macOS permissions for microphone, Accessibility and any features you use;
these cannot be granted by the build script. Transcription models are downloaded
from inside the app when you select them.

## Troubleshooting

- **Xcode missing or CLI installation fails:** follow the App Store steps above.
  `xcode-select --install` installs only Command Line Tools and will not fix this.
- **License / first-launch / missing SDK error:** open Xcode and finish setup,
  then rerun. `--check` checks prerequisites without making changes.
- **Download error:** check network access to GitHub and the package artifact
  servers, then rerun. CMake downloads use retries and SHA-256 verification.
- **Unexpected whisper revision or modified tracked files:** move
  `.local-build/dependencies/whisper.cpp` aside, then rerun. The script deliberately
  does not reset or pull an existing checkout.
- **After moving the project or changing Xcode:** the native build directory is
  reset automatically when the source, compiler or SDK path changes. If an
  interrupted build still fails, remove `.local-build/whisper-arm64` (or
  `whisper-x86_64`) and `.local-build/dependencies/whisper.build-key`, then rerun.
- **Other build errors:** inspect the log printed at the end. `make clean` is a
  full reset of project-local build data; save logs first if you need them.

## Notes for future agents

Implementation constraints, observed failures and verification commands are kept
in [scripts/AGENTS.md](scripts/AGENTS.md). Bootstrap regression checks (including
pseudo-terminal interaction) can be run without network access or installation:

```bash
python3 -m unittest discover -s scripts/tests -v
```
