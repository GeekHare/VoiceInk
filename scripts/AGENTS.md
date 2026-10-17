# VoiceInk local macOS installer: maintenance notes

## User intent and entry point

The user wants one command from a clean Mac that guides them through installation:

```bash
./scripts/build-local-macos.sh --install
```

Keep this as the public entry point and the quick-start block at the very top of
README.md. `build-whisper-macos-only.sh` is an internal helper, not a competing
installer. Makefile shortcuts delegate to the main script. Detailed instructions
live in BUILDING.md. Keep these documents and `--help` consistent when changing
behavior.

Support Apple's system Bash 3.2. Do not require Python, Homebrew, ShellCheck or an
Apple Developer subscription for the normal build. Python is only used by the
optional development regression tests.

## Interactive behavior

- Detect the terminal before logging redirects stdout. Preserve that result in
  the logged child. A plain pipeline with tee avoids /dev/fd process-substitution
  failures encountered in the agent's sandbox. Preserve the build's actual exit
  status rather than tee's status, including Ctrl+C (130).
- On a manual prerequisite, explain what to do, offer App Store / Xcode shortcuts,
  and recheck after Enter in the same run. Do not treat Enter as proof that setup
  completed. `q`, Ctrl+C and closed stdin must let the user leave.
- `--check` must never install, run first-launch setup, or pause. Non-terminal runs
  and `--non-interactive` must never wait for input or a sudo password. Print an
  actionable error and an accurately quoted resume command instead.
- Do not request Apple passwords in chat, store them, or accept Apple's license
  on behalf of the user. Password requests belong to Apple's interface / sudo.

## Failures actually encountered on this Mac

1. **Command Line Tools are insufficient.** Initially xcode-select pointed to
   /Library/Developer/CommandLineTools. Swift and git existed, but xcodebuild could
   not build this app. Full Xcode 26+ is needed for enabled macOS 26 Speech APIs.
   Prefer installed Xcode locally via DEVELOPER_DIR; preserve an explicit user
   override and do not change global xcode-select as part of the installer.
2. **Xcode CLI installation needs user authentication.** `brew install mas`
   worked with existing Homebrew, but `mas get 497799835` required administrator
   credentials from a terminal. The user ultimately installed via App Store.
   On a Mac without brew/mas, explain/open App Store rather than installing an
   entire package-manager stack just to obtain Xcode.
3. **Installing Xcode is not the end of setup.** Xcode 27.1 appeared in Applications
   but first launch failed until the user opened it and accepted the agreement.
   `xcodebuild -runFirstLaunch` returned 77 for the pending license. Retry checks
   after user action; repeating sudo does not accept that license. Additional
   iOS/watchOS/tvOS/visionOS simulator downloads are unnecessary here.
4. **Conditional signing settings cannot be passed like ordinary CLI settings.**
   Passing `CODE_SIGN_IDENTITY[sdk=macosx*]=-` as an xcodebuild argument was parsed
   incorrectly: the resulting identity became `macosx*]=-`. Keep the conditional
   override inside LocalBuild.xcconfig and pass only CODE_SIGN_IDENTITY=- on CLI.
5. **A valid signature does not prove the app can launch.** The first installed
   build passed `codesign --verify --deep --strict`, then crashed immediately in
   dyld while loading whisper: ad-hoc app/framework signatures have no Team ID,
   which hardened runtime library validation rejected. Preserve
   `com.apple.security.cs.disable-library-validation = true` in the LOCAL
   entitlements. Do not weaken normal developer/distribution entitlements.
   Verify the entitlement extracted from the signed app before exporting it.
6. **codesign output format matters.** On this system,
   `codesign --display --entitlements -` produced a human-readable dictionary,
   causing PlistBuddy to fail with `Unexpected character [`. Pass `--xml` when
   extracting the signed entitlements for plist parsing.
7. **Do not install CMake via the system Python.** Use the pinned official Kitware
   universal archive and verify its pinned SHA-256 before extraction. All tools
   and caches belong under the ignored project-local .local-build directory.

## Native dependency and reproducibility

- whisper.cpp is v1.7.6, commit a8d002cfd879315632a579e73f0148d06959de36.
  This version contains the VAD and flash-attention API used by LibWhisper.swift.
  Do not replace it with a clone of the moving default branch or run git pull.
- The old helper extracted upstream shell functions by hardcoded line ranges.
  Upstream changes made this fragile. Maintain the small explicit macOS helper;
  do not execute fragments of upstream's multi-platform build script.
- Build only the current Mac's arm64 or x86_64 slice. Keep Metal, embedded Metal
  source, Accelerate and Core ML. No non-macOS SDKs are needed. The pinned version
  embeds Metal source and compiles it at runtime, so a separate Metal compiler
  download was not necessary for this build.
- Keep the framework's public headers, module map, versioned symlinks, library
  install name and linked static libraries in agreement. It must import in Swift
  and work after relocation into the final app bundle.
- Preserve the committed Swift Package.resolved revisions, even for branch-based
  package requirements. Preserve inherited ENABLE_NATIVE_SPEECH_ANALYZER and add
  LOCAL_BUILD rather than replacing all existing Swift compilation conditions.
- Invalidate native caches for helper/version/architecture/Xcode/SDK changes;
  reset generated CMake build data when source/compiler/SDK paths change. Do not
  discard compiled dependencies just because a UI message in the main script
  changed. Do not reset user-edited dependency checkouts silently.
- Stage and verify bundles before replacing an exported or installed app. Keep
  build logs on failure, and preserve the underlying error and exit code.

## Verification

The original end-to-end flow was verified on 2026-10-17 on Apple Silicon,
macOS 27.0.1, Xcode 27.1: Release VoiceInk 1.76 built, signed, installed in
~/Applications and remained running after launch. Real audio transcription was
not tested. Do not call every future edit validated on a freshly installed OS.

For script changes:

```bash
bash -n scripts/build-local-macos.sh scripts/build-whisper-macos-only.sh
python3 -m unittest discover -s scripts/tests -v
./scripts/build-local-macos.sh --check
./scripts/build-local-macos.sh --whisper-only --non-interactive
```

The tests isolate commands with fake tools and exercise actual pseudo-terminal
prompts, resumption after setup, quitting, exit statuses, paths with spaces and
non-interactive logging. They must not install anything or use the network.

When build/signing behavior changes, also run a real build. Export without
`--install` when checking installer-only edits so a running user's installed app
is not replaced unnecessarily. If validating launch, launch the appropriate
bundle and check the process after a short delay; inspect a fresh crash report
if it exits. An exit status of zero from `open` alone is not proof of a successful
launch. Do not quit the user's active app or grant macOS privacy permissions just
to automate that check.
