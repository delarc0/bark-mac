# Bark for Mac

Native macOS dictation tool. Hold a key, speak, release — text appears at your cursor.

**Status:** early development (v0.1 — menu bar skeleton only)

## Stack

- Swift 5.9 / SwiftUI + AppKit
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) (MLX-based Whisper)
- AVAudioEngine for audio capture
- CGEventTap for push-to-talk
- NSStatusItem menu bar app (LSUIElement)

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon

## Build

```bash
brew install xcodegen
xcodegen
open Bark.xcodeproj
```

Or from CLI:

```bash
xcodegen
xcodebuild -project Bark.xcodeproj -scheme Bark -configuration Debug build
open build/Debug/Bark.app
```

## Roadmap

- [x] Phase 0 — menu bar skeleton
- [ ] Phase 1 — AVAudioEngine recorder + device picker + AirPods hot-swap
- [ ] Phase 2 — WhisperKit transcription
- [ ] Phase 3 — Keyboard hook + paste
- [ ] Phase 4 — Overlay pill + settings UI
- [ ] Phase 5 — Onboarding, Sparkle, signing pipeline
