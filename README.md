# Bark for Mac

Push-to-talk dictation plus a meeting notetaker for macOS, transcribed on the Mac.
Hold a key anywhere, speak, release: the text lands at your cursor. Swedish and
English use separate Whisper models (KB-Whisper for Swedish), run by our own MLX engine.

## Requirements

- Apple Silicon Mac
- macOS 26
- Full Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```bash
git clone https://github.com/delarc0/bark-mac.git
cd bark-mac
./install.sh
```

`install.sh` builds the Debug app "Bark Dev" (bundle id `se.lab37.bark.mac.dev`) and
copies it to `~/Applications`. It runs beside a shipped Bark and never replaces it.
Grant Microphone and Accessibility on first run; the default hotkey is Right Option.

Library only: `cd BarkKit && swift build && swift test`.

## Models

Models are MLX Whisper weights in `~/Library/Application Support/Bark/Models/<id>/`
(`kb-whisper-large` and `whisper-large-v3`, 8-bit by default). They are not published yet;
`BarkKit/scripts/dev-models.sh` links local eval conversions into that folder.

## Privacy

- Dictation is transcribed on the Mac. Dictated text is never written to disk.
- Meetings are stored locally (`~/Library/Application Support/Bark/Meetings/`).
  Audio is kept for a retention period (default 30 days); transcripts are kept.
- The hq endpoint is empty by default, so nothing is sent anywhere unless you connect one.

## More

- `AGENTS.md`: install guide for coding agents.
- `tasks/bark2.md`: the PRD, decisions and measurements.
- `distribution/README.md`: release pipeline.

Licence: see `LICENSE.md`.
