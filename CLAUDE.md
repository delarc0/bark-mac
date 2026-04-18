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

forces `cpuAndGPU` for both. **Required on M1** — ANE hangs indefinitely on large-v3-turbo on M1 hardware (confirmed 2026-04-18). On M5 Pro the ANE path is expected to work; verify on first run after upgrade.

Env vars don't propagate reliably through `open`, so for the env flag, launch the binary directly.

## Conventions

- **No code comments** unless genuinely non-obvious (a hidden invariant, a workaround for a specific bug). Don't narrate what the code does.
- Ad-hoc codesigning (`CODE_SIGN_IDENTITY: "-"`) until Apple Developer ID is approved (applied 2026-04-18, pending). Limitations until then: no SMAppService login items, permissions reset on each rebuild.
- UserDefaults for settings, not migrated from Python Bark's `bark_config.json`. Clean slate.

## Roadmap status (2026-04-18)

- [x] Phase 0 — menu bar skeleton
- [x] Phase 1 — AudioRecorder (AVAudioEngine, device picker)
- [x] Phase 2 — WhisperKit transcription (large-v3-turbo, eager load + 1s silent warmup on launch → instant first click)
- [ ] Phase 3 — CGEventTap hotkey + paste (NSPasteboard + synthesized ⌘V)
- [ ] Phase 4 — Overlay pill (NSWindow + SwiftUI) + settings UI
- [ ] Phase 5 — Onboarding, Sparkle auto-update, signing pipeline (needs Dev ID)

**Active pause:** further phases deferred until M5 Pro 48 GB upgrade arrives — Erik prefers to do perf-sensitive work on target hardware. On resume: validate ANE path (remove `BARK_CPU_ONLY` requirement), then start Phase 3.

## Phase 3 design decisions (pending)

- Hotkey: leaning right-Option (single key, non-conflicting)
- Mode: hold-to-record (release = stop), not toggle
- Paste: NSPasteboard + synthesized ⌘V with save/restore of prior clipboard (trade: brief clobber, works everywhere; the alternative `CGEventKeyboardSetUnicodeString` avoids clipboard but is slower and can race)

## Bench (M1 16 GB, cpuAndGPU fallback)

- Cold start (load + 1s silent warmup): ~38s
- Transcribe 3s of audio, post-warmup: ~8s
- M5 Pro with ANE decoder: expected ~10-15s cold start, ~1-2s transcribe

## Key files

- `project.yml` — xcodegen source
- `Bark/BarkApp.swift` — `@main` + AppDelegate
- `Bark/MenuBarController.swift` — NSStatusItem, menu, test items, eager load + warmup on init
- `Bark/Audio/AudioRecorder.swift` — mic capture + resample
- `Bark/Transcription/Transcriber.swift` — WhisperKit actor (load, warmup, transcribe)
- `Bark/Bark.entitlements` — (sandbox disabled during dev)

## When something breaks

- Transcription hangs silently on M1 → ANE is wedged. Kill Bark, relaunch with `BARK_CPU_ONLY=1`.
- "AudioObjectRemovePropertyListener: no object" spam → AirPods/BT device hot-swapped mid-stream. Benign but audio stream may need restart.
- Model download fails → check `~/Documents/huggingface/` permissions; HuggingFace CDN occasionally 403s.
