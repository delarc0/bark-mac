#!/usr/bin/env bash
#
# Bark installer — builds from source and installs to /Applications.
# One command, no Apple Developer account needed. Apple Silicon + macOS 14+.
#
#   ./install.sh
#
# What it does: checks prerequisites, generates the Xcode project, builds a
# Debug app, code-signs it (self-signed "Bark Dev" cert if you made one,
# otherwise ad-hoc), installs to /Applications, and launches it.

set -euo pipefail

cd "$(dirname "$0")"

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RST=$'\033[0m'
step() { printf "%s==>%s %s\n" "$GREEN$BOLD" "$RST" "$1"; }
warn() { printf "%s!  %s%s\n" "$YELLOW" "$1" "$RST"; }
die()  { printf "%sx  %s%s\n" "$RED" "$1" "$RST" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------

step "Checking prerequisites"

[ "$(uname -m)" = "arm64" ] || die "Bark requires Apple Silicon (arm64). This Mac is $(uname -m)."

os_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$os_major" -ge 14 ] 2>/dev/null || die "Bark requires macOS 14 or later. This Mac is $(sw_vers -productVersion)."

if ! xcodebuild -version >/dev/null 2>&1; then
  die "Full Xcode is required (Command Line Tools alone can't build this).
   Install Xcode from the App Store, then run:  sudo xcode-select -s /Applications/Xcode.app"
fi

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
# Prefer the optional self-signed "Bark Dev" cert (keeps mic/Accessibility
# grants across rebuilds). Fall back to ad-hoc, which works with zero setup.

SIGN_ID="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Bark Dev"'; then
  SIGN_ID="Bark Dev"
  step "Signing with self-signed 'Bark Dev' identity (grants persist across rebuilds)"
else
  step "Signing ad-hoc (fine for use; permissions reset if you rebuild)"
  printf "%s   Tip: run ./scripts/create-signing-cert.sh once to make rebuilds keep your grants.%s\n" "$DIM" "$RST"
fi

# --- Build -------------------------------------------------------------------

step "Generating Xcode project"
xcodegen >/dev/null

step "Building Bark (first build fetches Swift packages — a minute or two)"
xcodebuild -project Bark.xcodeproj -scheme Bark -configuration Debug \
  -derivedDataPath build \
  BARK_SIGN_IDENTITY="$SIGN_ID" \
  build >/tmp/bark-build.log 2>&1 \
  || { tail -25 /tmp/bark-build.log; die "Build failed. Full log: /tmp/bark-build.log"; }

APP="build/Build/Products/Debug/Bark.app"
[ -d "$APP" ] || die "Build reported success but $APP is missing."

# --- Install -----------------------------------------------------------------

step "Installing to /Applications"
pkill -f "Bark.app/Contents/MacOS/Bark" 2>/dev/null || true
sleep 1
rm -rf /Applications/Bark.app
cp -R "$APP" /Applications/Bark.app
codesign --force --deep --sign "$SIGN_ID" /Applications/Bark.app >/dev/null 2>&1 || true

step "Launching Bark"
open /Applications/Bark.app

cat <<EOF

${GREEN}${BOLD}Bark is installed and running.${RST} Look for the paw icon in your menu bar.

${BOLD}First run:${RST}
  1. An onboarding window walks you through two permissions:
       • Microphone  — to hear you
       • Accessibility — to detect the hotkey and paste at your cursor
     Toggle Bark on in System Settings when prompted.
  2. The speech model (~1.5 GB) downloads on first use. One-time.
  3. Hold ${BOLD}Right Option${RST}, speak, release. Text appears at your cursor.
     Change the hotkey any time in the menu bar → Settings → Hotkey.

${DIM}Ad-hoc builds: macOS forgets the permissions each time you rebuild. If you
plan to iterate, run ./scripts/create-signing-cert.sh once, then ./install.sh.${RST}
EOF
