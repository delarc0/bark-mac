# Bark: install guide for coding agents

Bark is a macOS app: push-to-talk dictation plus a meeting notetaker, transcribed on the Mac.
This file is for an agent asked to build and run it. Humans: see `README.md`.

## Requirements

- Apple Silicon, macOS 26, full Xcode (Command Line Tools alone cannot build it).
- `xcodegen` (`brew install xcodegen`); `install.sh` installs it with Homebrew if missing.

## Build and run

```bash
./install.sh
```

It generates the project, builds the Debug app "Bark Dev" (`se.lab37.bark.mac.dev`) and
copies it to `~/Applications/Bark Dev.app`. It never writes to `/Applications` and never
touches a shipped Bark. It does not launch the app: the user opens it and grants Microphone
and Accessibility (these prompts need the user; do not try to automate them).

Manual path:

```bash
xcodegen
xcodebuild -project Bark.xcodeproj -scheme Bark -configuration Debug -derivedDataPath build build
git checkout -- BarkKit/Package.resolved   # the app build adds Sparkle's pin; never commit it
```

Library only: `cd BarkKit && swift build && swift test`. Tests that need models or eval clips skip when absent.

## Models

`~/Library/Application Support/Bark/Models/<id>/{config.json,weights.safetensors,tokenizer.json}`,
ids `kb-whisper-large[-8bit]` and `whisper-large-v3[-8bit]`. Not published yet, so
`BarkKit/scripts/dev-models.sh` links the local eval conversions (it needs them under
`~/Library/Application Support/Bark/eval/models`). `install.sh` runs it only when models are missing.

## Rules for changes

- Read `CLAUDE.md` first, then `tasks/bark2.md`.
- Swift 6 strict concurrency; dependencies pinned `exact:`.
- Never run `scripts/release.sh`; releases are Erik's call.
- Dictated text never touches disk. Meeting data is local.
