#!/usr/bin/env bash
#
# Bark2 dev installer: builds "Bark Dev.app" from source and copies it to ~/Applications.
# It has its own bundle id (se.lab37.bark.mac.dev), so it runs beside a shipped Bark
# and never touches it. Apple Silicon + macOS 26, full Xcode, no Apple Developer account.
#
#   ./install.sh

set -euo pipefail

cd "$(dirname "$0")"

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RST=$'\033[0m'
step() { printf "%s==>%s %s\n" "$GREEN$BOLD" "$RST" "$1"; }
warn() { printf "%s!  %s%s\n" "$YELLOW" "$1" "$RST"; }
die()  { printf "%sx  %s%s\n" "$RED" "$1" "$RST" >&2; exit 1; }

step "Checking prerequisites"

[ "$(uname -m)" = "arm64" ] || die "Bark requires Apple Silicon (arm64). This Mac is $(uname -m)."

os_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$os_major" -ge 26 ] 2>/dev/null || die "Bark requires macOS 26 or later. This Mac is $(sw_vers -productVersion)."

xcodebuild -version >/dev/null 2>&1 || die "Full Xcode is required (Command Line Tools alone can't build this).
   Install Xcode, then run:  sudo xcode-select -s /Applications/Xcode.app"

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    step "Installing xcodegen via Homebrew"
    brew install xcodegen
  else
    die "xcodegen is required and Homebrew was not found.
   Install Homebrew from https://brew.sh then run:  brew install xcodegen"
  fi
fi

# --- Signing identity --------------------------------------------------------
# The optional self-signed "Bark Dev" cert keeps mic/Accessibility grants across
# rebuilds; otherwise the build is signed ad-hoc.

SIGN_ID="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Bark Dev"'; then
  SIGN_ID="Bark Dev"
  step "Signing with the self-signed 'Bark Dev' identity (grants persist across rebuilds)"
else
  step "Signing ad-hoc (permissions reset if you rebuild)"
  printf "%s   Tip: run ./scripts/create-signing-cert.sh once to make rebuilds keep your grants.%s\n" "$DIM" "$RST"
fi

# --- Models ------------------------------------------------------------------
# Not published yet: link the local eval conversions into the app's model folder,
# but only when the 8-bit default models are missing and the eval models exist.

STORE="$HOME/Library/Application Support/Bark/Models"
EVAL="$HOME/Library/Application Support/Bark/eval/models"
ready() { for f in config.json weights.safetensors tokenizer.json; do [ -f "$STORE/$1/$f" ] || return 1; done; }
if ready kb-whisper-large-8bit && ready whisper-large-v3-8bit; then
  step "Models already in place"
elif [ -d "$EVAL/kb-whisper-large-mlx" ] && [ -d "$EVAL/whisper-large-v3-mlx" ]; then
  step "Linking local eval models"
  BarkKit/scripts/dev-models.sh
else
  warn "No models in $STORE and no eval models in $EVAL; the app will have nothing to transcribe with."
fi

# --- Build -------------------------------------------------------------------

step "Generating Xcode project"
xcodegen >/dev/null

# xcodebuild adds Sparkle's pin to this tracked file; undo only that, never the user's own edits.
resolved_clean=0
git diff --quiet -- BarkKit/Package.resolved 2>/dev/null && resolved_clean=1

step "Building Bark Dev (first build fetches Swift packages, a minute or two)"
xcodebuild -project Bark.xcodeproj -scheme Bark -configuration Debug \
  -derivedDataPath build \
  BARK_SIGN_IDENTITY="$SIGN_ID" \
  build >/tmp/bark-build.log 2>&1 \
  || { tail -25 /tmp/bark-build.log; die "Build failed. Full log: /tmp/bark-build.log"; }

[ "$resolved_clean" = 1 ] && { git checkout -- BarkKit/Package.resolved 2>/dev/null || true; }

APP="build/Build/Products/Debug/Bark Dev.app"
[ -d "$APP" ] || die "Build reported success but $APP is missing."

# --- Install -----------------------------------------------------------------

DEST="$HOME/Applications/Bark Dev.app"
step "Installing to ~/Applications"
mkdir -p "$HOME/Applications"
pkill -f "Bark Dev.app/Contents/MacOS/Bark Dev" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP" "$DEST"
# The installed copy drops get-task-allow (no debugger can attach) and keeps the hardened runtime.
codesign --force --deep --options runtime --entitlements App/BarkDev.entitlements --sign "$SIGN_ID" "$DEST" >/dev/null 2>&1 \
  || die "Re-signing $DEST failed."

cat <<MSG

${GREEN}${BOLD}Bark Dev is installed${RST} at $DEST. Open it from there; it does not replace a shipped Bark.

${BOLD}First run:${RST} grant Microphone and Accessibility when asked, then hold ${BOLD}Right Option${RST},
speak, release. The hotkey is changeable in Settings.

${DIM}Ad-hoc builds: macOS forgets the permissions each time you rebuild. If you plan to
iterate, run ./scripts/create-signing-cert.sh once, then ./install.sh.${RST}
MSG
