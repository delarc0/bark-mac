# AGENTS.md — installing Bark

Instructions for a coding agent (Claude Code, etc.) asked to install Bark on
this Mac. Follow them top to bottom. Bark is a native macOS dictation app: hold
a hotkey, speak, release, and the transcribed text is pasted at the cursor.
Everything runs on-device; no account, no network transcription.

## TL;DR

```bash
./install.sh
```

That builds from source, code-signs, installs to `/Applications`, and launches.
The two permission grants (Microphone, Accessibility) and the one-time ~1.5 GB
model download are completed by the human on first launch — you cannot script
them. Tell the user to expect those.

## Requirements (install.sh checks all of these and stops with a clear message)

- Apple Silicon Mac (arm64). Intel is not supported.
- macOS 14 (Sonoma) or later.
- Full **Xcode** (not just Command Line Tools). If missing: the user installs it
  from the App Store, then `sudo xcode-select -s /Applications/Xcode.app`. You
  cannot install Xcode for them.
- **xcodegen**. If Homebrew is present, install.sh runs `brew install xcodegen`
  automatically. If Homebrew is missing, tell the user to install it from
  https://brew.sh first.

## Step by step

1. **Run the installer.**
   ```bash
   ./install.sh
   ```
   First build fetches Swift packages (WhisperKit, Sparkle) and takes a minute
   or two. On failure the full log is at `/tmp/bark-build.log`.

2. **Hand off the permission grants to the user.** On first launch an onboarding
   window opens. The user must:
   - Allow **Microphone** access when prompted.
   - Toggle **Bark** on under System Settings → Privacy & Security →
     **Accessibility** (needed to detect the hotkey and paste). The app polls
     and picks up the grant live — no relaunch needed.

3. **First transcription downloads the model.** ~1.5 GB, one time, cached at
   `~/Documents/huggingface/`. Tell the user the first dictation will pause while
   it downloads; later ones are fast.

4. **Use it.** Hold **Right Option**, speak, release. Text appears at the cursor.
   The hotkey and everything else is in the menu bar (paw icon) → Settings.

## Signing — what happens and why

Bark has no Apple Developer ID yet, so it self-signs. install.sh picks the
identity automatically:

- **Ad-hoc (default, zero setup).** Works immediately. The catch: macOS ties
  permission grants to the exact signature, so *if the app is rebuilt*, the user
  re-grants Microphone and Accessibility. Fine for install-once-and-use.
- **Self-signed "Bark Dev" cert (optional).** If the user will rebuild often,
  run this once, first:
  ```bash
  ./scripts/create-signing-cert.sh   # asks for the login password once
  ./install.sh
  ```
  install.sh detects the cert and uses it, so grants survive rebuilds. This is
  **interactive** (a GUI password prompt macOS requires to trust a new signing
  cert) — you cannot fully automate it; ask the user to run it themselves.

Do not add `CODE_SIGN_IDENTITY=...` to the `xcodebuild` command line — it leaks
to the Swift-package targets and makes them demand a development team. The
identity is applied by the post-build re-sign step via `BARK_SIGN_IDENTITY`,
which install.sh sets. Just run install.sh.

## Manual build (only if install.sh cannot be used)

```bash
xcodegen
xcodebuild -project Bark.xcodeproj -scheme Bark -configuration Debug \
  -derivedDataPath build build
# ad-hoc; installs from build/Build/Products/Debug/Bark.app
```

## Verify it worked

```bash
pgrep -lf "Bark.app/Contents/MacOS/Bark"   # should print a PID
codesign --verify --deep --strict /Applications/Bark.app && echo "signature OK"
```

Then confirm with the user that dictation actually pastes text — that is the
real end-to-end check, and it depends on the two permission grants only they can
give.

## If something breaks

- **Build fails** → read `/tmp/bark-build.log`. Most first-build failures are a
  missing/oudated Xcode or a Swift Package fetch hiccup (re-run install.sh).
- **Hotkey does nothing** → Accessibility grant missing or, after a rebuild,
  stale. Re-grant in System Settings, or use the "Bark Dev" cert to stop that.
- **Transcription hangs / app pegs a CPU core** → the Neural Engine path
  wedges on some chips (confirmed M1 and M2 Max). Bark detects this at launch
  and switches itself to CPU+GPU automatically. If it's still stuck: quit Bark,
  toggle Settings → Model → "Use CPU + GPU only", relaunch. (See CLAUDE.md.)
- **Nothing pastes but text was heard** → Accessibility grant covers both the
  hotkey and the paste; check it's on.
