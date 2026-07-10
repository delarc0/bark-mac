# Bark-Mac — Claude Code context

Native macOS dictation tool. Swift/AppKit + WhisperKit. Mac-only fork of the cross-platform Python [`bark/`](../bark/) (which stays alive for Windows). Private repo: `github.com/delarc0/bark-mac`.

## Ownership / identity

- Author: Erik `<erik@lab37.io>`
- Bundle ID: `se.lab37.bark.mac`
- Target: macOS 14+, Apple Silicon only

## Stack

- Swift 5.9, SwiftUI + AppKit, `LSUIElement=YES` menu bar app
- WhisperKit 0.18 via SPM (model default: `openai_whisper-large-v3_turbo`)
- AVAudioEngine for mic capture, downsamples 48k → 16k mono Float32
- XcodeGen (`project.yml` is source of truth; `Bark.xcodeproj` is gitignored)

## Build / run

```bash
brew install xcodegen
xcodegen
xcodebuild -project Bark.xcodeproj -scheme Bark -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Bark.app
```

First launch triggers WhisperKit model download (~1.5 GB for large-v3-turbo) and prompts for mic permission. Subsequent launches are fast; model cached at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`.

## Compute path (important)

`Transcriber` defaults to **GPU encoder + ANE decoder** — the optimal Apple Silicon path. Env override:

```bash
BARK_CPU_ONLY=1 ./build/Build/Products/Debug/Bark.app/Contents/MacOS/Bark
```

forces `cpuAndGPU` for both. **Required on M1** — ANE hangs indefinitely on large-v3-turbo on M1 hardware (confirmed 2026-04-18). **M5 Pro: ANE path works, no override needed** (validated 2026-04-18).

Env vars don't propagate reliably through `open`, so for the env flag, launch the binary directly.

## Conventions

- **No code comments** unless genuinely non-obvious (a hidden invariant, a workaround for a specific bug). Don't narrate what the code does.
- Ad-hoc codesigning (`CODE_SIGN_IDENTITY: "-"`) until Apple Developer ID is approved (applied 2026-04-18, pending). Limitations until then: no SMAppService login items, permissions reset on each rebuild.
- UserDefaults for settings, not migrated from Python Bark's `bark_config.json`. Clean slate.

## Roadmap status (2026-04-18)

- [x] Phase 0 — menu bar skeleton
- [x] Phase 1 — AudioRecorder (AVAudioEngine, device picker)
- [x] Phase 2 — WhisperKit transcription (large-v3-turbo, eager load + 1s silent warmup on launch → instant first click)
- [x] Phase 3 — CGEventTap hotkey (right-Option hold) + paste (NSPasteboard + synthesized ⌘V with clipboard save/restore) — validated end-to-end 2026-04-18
- [x] Phase 4 — Overlay pill (NSPanel + SwiftUI) + Settings window (hotkey picker, model, language, audio device) — shipped 2026-04-18
- [x] Phase 5a — Onboarding flow + Sparkle SDK wired (infra only; can't ship updates until Dev ID lands) — shipped 2026-04-18
- [ ] Phase 5b — Dev ID signing + notarization + live appcast (blocked on Apple Developer ID approval)

**Resumed 2026-04-18** on M5 Pro 48 GB. ANE path validated — `BARK_CPU_ONLY` no longer required as default. Phase 3 landed same day; next up: Phase 4.

## Phase 3 shipped

- Hotkey: default right-Option, held-to-record. `HotkeyMonitor` uses a `.listenOnly` `cgSessionEventTap` on `flagsChanged` and isolates right-Option from left via device-specific `NX_DEVICERALTKEYMASK` (0x40) — the generic `.maskAlternate` bit fires for both Option keys and would misfire on mixed holds. The target keyCode + flag mask are read from `AppSettings` (Phase 4) so the hotkey is now user-configurable.
- Tap filter: holds shorter than 200 ms are discarded as accidental taps.
- Paste: `PasteService` snapshots the pasteboard, writes the transcription, posts a ⌘V via `.cgAnnotatedSessionEventTap`, then restores the previous clipboard after 150 ms (enough margin on Electron apps).
- Accessibility: `DictationCoordinator` gates start on `AXIsProcessTrustedWithOptions`. When the user grants AX after launch, `MenuBarController` polls `hasAccessibilityPermission()` for 2 min and arms the tap live — no relaunch needed. Ad-hoc rebuilds still invalidate the grant until Dev ID lands.

## Phase 5a shipped (onboarding + Sparkle wiring)

- **Onboarding** — 4-step SwiftUI flow in `OnboardingView` hosted by `OnboardingWindowController`. Steps: welcome → mic permission (`AVCaptureDevice.requestAccess(for: .audio)`) → accessibility (opens System Settings + polls for grant, auto-advances) → hotkey intro (shows current `settings.hotkeyDisplayName`). Gated by `settings.onboardingCompleted`; MenuBarController presents it on first launch. "Show Onboarding…" item re-opens it any time.
- **Sparkle 2.9.1** — `UpdaterController.shared` wraps `SPUStandardUpdaterController(startingUpdater: true)`. Instantiated eagerly in MenuBarController so scheduled checks start at launch. Menu item "Check for Updates…" targets the wrapper.
- **EdDSA keypair** — generated via `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`; private key lives in Erik's login keychain. Public key `xLy1zhCVvHlYyI1wHQyPWk67NxoP/u7vvPfMFe8joEY=` is in `project.yml`.
- **Info.plist** — switched from `GENERATE_INFOPLIST_FILE` to an xcodegen `info:` block so we can set custom keys (`SUFeedURL`, `SUPublicEDKey`, `SUEnableInstallerLauncherService`). `Bark/Info.plist` is now generated on disk by xcodegen and gitignored.
- **Feed URL** — `https://delarc0.github.io/bark-mac/appcast.xml`. Not yet hosted. `distribution/appcast.xml` is an empty template, `distribution/README.md` has the full release recipe for when Dev ID lands.
- **Dormant until Dev ID** — Sparkle can fetch the appcast and show UI, but won't apply updates that aren't both EdDSA-signed AND Dev-ID-codesigned. That's fine for now; the plumbing is tested and ready.

## Phase 4 shipped

- **Overlay pill** — `OverlayController` owns a transparent `NSPanel` (borderless, non-activating, `.statusBar` level, joins all spaces incl. full-screen). `OverlayView` is SwiftUI: idle (hidden), recording (breathing red dot + "Listening…"), transcribing (spinner + "Transcribing…"). Positioned bottom-center of the main screen, fades in/out.
- **Settings window** — `SettingsWindowController` / `SettingsView` (SwiftUI `TabView`): General, Hotkey, Audio, Model. Launched from status menu (⌘,).
- **Hotkey picker** — `HotkeyRecorder` installs a local `NSEvent` monitor while capturing. Posts `HotkeyRecorder.listeningChanged` so `MenuBarController` pauses the global tap during capture (prevents the capture keystroke from triggering dictation on the old mapping). Persists keyCode + device-specific flag mask (NX_DEVICEL/R for each modifier) + a display name to `AppSettings`.
- **AppSettings** — UserDefaults-backed `ObservableObject` singleton. Persists hotkey (keyCode + mask + display name), model variant, language, input device UID. Posts `AppSettings.didChange` on any mutation; `MenuBarController` listens and restarts the hotkey tap so new mappings take effect immediately.
- **Input device persistence** — selection is now stored by device UID (stable across reboots/reconnects), not the ephemeral `AudioDeviceID`. `AudioDeviceCatalog.inputID(matching:)` resolves on each start.
- **Model / language** — selectable in Settings → Model. Takes effect on next launch (Transcriber is init'd once at MenuBarController construction).
- **Launch-at-login** — deferred to Phase 5. Needs `SMAppService`, which needs Dev ID.

## Bench

**M1 16 GB, cpuAndGPU fallback:**
- Cold start (load + 1s silent warmup): ~38s
- Transcribe 3s of audio, post-warmup: ~8s

**M5 Pro 48 GB, ANE decoder (measured 2026-04-18):**
- Eager load: 5.76s
- Warmup (1s silent): 1.27s
- Transcribe ~3s of audio: 2.17s

## Key files

- `project.yml` — xcodegen source
- `Bark/BarkApp.swift` — `@main` + AppDelegate
- `Bark/MenuBarController.swift` — NSStatusItem, menu, test items, eager load + warmup on init, red-dot recording indicator
- `Bark/Audio/AudioRecorder.swift` — mic capture + resample
- `Bark/Transcription/Transcriber.swift` — WhisperKit actor (load, warmup, transcribe)
- `Bark/Hotkey/HotkeyMonitor.swift` — CGEventTap on flagsChanged, reads keyCode + flag mask from AppSettings, `restart()` picks up changes live
- `Bark/DictationCoordinator.swift` — hotkey → record → transcribe → paste glue; publishes `State` (idle/recording/transcribing); holds the 200 ms tap filter
- `Bark/Paste/PasteService.swift` — clipboard snapshot + synthesized ⌘V + 150 ms restore
- `Bark/Overlay/OverlayController.swift` — floating NSPanel host + show/hide
- `Bark/Overlay/OverlayView.swift` — SwiftUI pill (breathing dot / spinner)
- `Bark/Settings/AppSettings.swift` — UserDefaults-backed `ObservableObject`, posts `didChange`
- `Bark/Settings/SettingsWindow.swift` — shared `NSWindowController` holding the SwiftUI view
- `Bark/Settings/SettingsView.swift` — `TabView` (General/Hotkey/Audio/Model)
- `Bark/Settings/HotkeyRecorder.swift` — capture widget; posts `HotkeyRecorder.listeningChanged` to pause global tap during capture
- `Bark/Onboarding/OnboardingView.swift` — 4-step SwiftUI flow (welcome/mic/ax/hotkey/done)
- `Bark/Onboarding/OnboardingWindow.swift` — `OnboardingWindowController.shared`, sets `onboardingCompleted` on finish
- `Bark/Updates/UpdaterController.swift` — `SPUStandardUpdaterController` wrapper; menu target for "Check for Updates…"
- `distribution/appcast.xml` + `distribution/README.md` — release pipeline scaffolding (dormant until Dev ID)
- `Bark/Bark.entitlements` — (sandbox disabled during dev)
- `Bark/Info.plist` — generated by xcodegen (gitignored); holds `SUFeedURL`, `SUPublicEDKey`, all `NS*`/`LS*`/`CF*` keys

## When something breaks

- Transcription hangs silently on M1 → ANE is wedged. Kill Bark, relaunch with `BARK_CPU_ONLY=1`.
- "AudioObjectRemovePropertyListener: no object" spam → AirPods/BT device hot-swapped mid-stream. Benign but audio stream may need restart.
- Model download fails → check `~/Documents/huggingface/` permissions; HuggingFace CDN occasionally 403s.
