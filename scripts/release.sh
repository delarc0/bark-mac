#!/bin/bash
# Bark release pipeline: archive -> Developer ID export -> notarize -> staple
# -> verify -> Sparkle-sign -> appcast -> GitHub Release + gh-pages.
#
# Usage:
#   ./scripts/release.sh --check                 preflight only (is this machine release-ready?)
#   ./scripts/release.sh 0.2.0                   build + notarize + stage locally, push NOTHING
#   ./scripts/release.sh 0.2.0 --publish         the real thing: commit, tag, GH Release, appcast
#   ./scripts/release.sh 0.2.0 --publish --notes "Fixed X"
#
# One-time machine setup (both interactive, Apple ID required):
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. xcrun notarytool store-credentials AC_NOTARY --key AuthKey_XXX.p8 --key-id XXX --issuer <uuid>
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="4D2U237VRC"
PROFILE="AC_NOTARY"
REPO="delarc0/bark-mac"
LOG=/tmp/bark-release.log

bold() { printf '  \033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
STAGED=0
fail() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  [ "$STAGED" = 1 ] && printf 'To reset staged changes: git checkout -- project.yml distribution/appcast.xml\n' >&2
  exit 1
}

preflight() {
  step "Preflight"
  [ -f project.yml ] || fail "project.yml not found (script must live in scripts/ under the repo root)"
  command -v xcodegen >/dev/null || { echo "  xcodegen: MISSING (brew install xcodegen)"; PREFLIGHT_OK=0; }
  if security find-identity -v -p codesigning | grep -q "Developer ID Application: .*(${TEAM_ID})"; then
    bold "cert: Developer ID Application (${TEAM_ID}) present"
  else
    echo "  cert: MISSING - Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
    PREFLIGHT_OK=0
  fi
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    bold "notary: keychain profile ${PROFILE} works"
  else
    echo "  notary: MISSING - xcrun notarytool store-credentials ${PROFILE} --key AuthKey.p8 --key-id <id> --issuer <uuid>"
    PREFLIGHT_OK=0
  fi
  if security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1; then
    bold "sparkle: EdDSA private key in login keychain"
  else
    echo "  sparkle: private key MISSING from keychain - re-import from 1Password backup (generate_keys -f <pem>)"
    PREFLIGHT_OK=0
  fi
  if gh auth status >/dev/null 2>&1; then
    bold "gh: authenticated"
  else
    echo "  gh: NOT authenticated (gh auth login)"
    PREFLIGHT_OK=0
  fi
  if [ -n "$(git status --porcelain)" ]; then
    echo "  git: working tree DIRTY - commit or stash first, releases must be reproducible"
    PREFLIGHT_OK=0
  else
    bold "git: clean tree at $(git rev-parse --short HEAD)"
  fi
  [ "$PREFLIGHT_OK" = 1 ] || fail "preflight failed - fix the items above"
  bold "preflight OK"
}

PREFLIGHT_OK=1
MODE_CHECK=0
PUBLISH=0
NOTES=""
VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE_CHECK=1 ;;
    --publish) PUBLISH=1 ;;
    --notes) NOTES="${2:?--notes needs a value}"; shift ;;
    -*) fail "unknown flag: $1" ;;
    *) VERSION="$1" ;;
  esac
  shift
done

if [ "$MODE_CHECK" = 1 ]; then
  preflight
  exit 0
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: release.sh X.Y.Z [--publish] [--notes \"...\"]"
preflight

step "Version ${VERSION}"
git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null && fail "tag v${VERSION} already exists"
git ls-remote --exit-code --tags origin "refs/tags/v${VERSION}" >/dev/null 2>&1 && fail "tag v${VERSION} already exists on origin"
grep -q "Bark-${VERSION}.zip" distribution/appcast.xml && fail "appcast already has ${VERSION}"
CUR_BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml)
[ -n "$CUR_BUILD" ] || fail "could not read CURRENT_PROJECT_VERSION from project.yml"
BUILD=$((CUR_BUILD + 1))
STAGED=1
sed -i '' \
  -e "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"${VERSION}\"/" \
  -e "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"${BUILD}\"/" \
  project.yml
xcodegen >/dev/null
bold "MARKETING_VERSION=${VERSION}  CURRENT_PROJECT_VERSION=${BUILD}"

step "Archive (Release)"
rm -rf build/Bark.xcarchive build/export
xcodebuild -project Bark.xcodeproj -scheme Bark -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath build -archivePath build/Bark.xcarchive \
  archive >"$LOG" 2>&1 || { tail -40 "$LOG"; fail "archive failed (full log: $LOG)"; }
bold "archived"

step "Export with Developer ID"
xcodebuild -exportArchive -archivePath build/Bark.xcarchive \
  -exportPath build/export -exportOptionsPlist distribution/ExportOptions.plist \
  >>"$LOG" 2>&1 || { tail -40 "$LOG"; fail "export failed (full log: $LOG)"; }
APP="build/export/Bark.app"
[ -d "$APP" ] || fail "export produced no app"
bold "exported and re-signed with Developer ID"

step "Notarize + staple"
NZIP="build/Bark-${VERSION}-notarize.zip"
rm -f "$NZIP"
ditto -c -k --keepParent "$APP" "$NZIP"
SUBMIT=$(xcrun notarytool submit "$NZIP" --keychain-profile "$PROFILE" 2>&1) || { echo "$SUBMIT"; fail "notarytool submit failed"; }
SUB_ID=$(echo "$SUBMIT" | awk '/^  id:/ {print $2; exit}')
[ -n "$SUB_ID" ] || { echo "$SUBMIT"; fail "no submission id in notarytool output"; }
bold "submitted ${SUB_ID}, waiting (a team's first submission can take up to an hour)"
# wait dies on transient network loss; the submission keeps processing server-side
for attempt in $(seq 1 40); do
  xcrun notarytool wait "$SUB_ID" --keychain-profile "$PROFILE" && break
  echo "  wait dropped (attempt ${attempt}, likely a network blip), retrying in 30s"
  sleep 30
done
STATUS=$(xcrun notarytool info "$SUB_ID" --keychain-profile "$PROFILE" 2>&1 | awk '/status:/ {print $2; exit}')
if [ "$STATUS" != "Accepted" ]; then
  xcrun notarytool log "$SUB_ID" --keychain-profile "$PROFILE" || true
  fail "notarization status: ${STATUS:-unknown}"
fi
xcrun stapler staple "$APP" >/dev/null
rm -f "$NZIP"
bold "notarized and stapled"

step "Verify"
codesign --verify --deep --strict "$APP" || fail "codesign verify failed"
codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime" || fail "hardened runtime flag missing"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "audio-input" || fail "audio-input entitlement missing (mic would be dead in this build)"
xcrun stapler validate "$APP" >/dev/null || fail "staple didn't validate"
spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "Notarized Developer ID" || fail "Gatekeeper assessment failed"
bold "signed, notarized, stapled, mic entitlement intact"

step "Sparkle-sign"
ZIP="build/Bark-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIGN_UPDATE=$(find build/SourcePackages/artifacts -type f -name sign_update 2>/dev/null | head -1)
[ -n "$SIGN_UPDATE" ] || fail "sign_update not found under build/SourcePackages (did the archive resolve packages?)"
ED_LINE=$("$SIGN_UPDATE" "$ZIP")
bold "$ED_LINE"

step "Appcast"
PUBDATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
URL="https://github.com/${REPO}/releases/download/v${VERSION}/Bark-${VERSION}.zip"
ITEM_FILE=$(mktemp)
cat > "$ITEM_FILE" <<EOF

        <item>
            <title>Version ${VERSION}</title>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <pubDate>${PUBDATE}</pubDate>
            <enclosure
                url="${URL}"
                ${ED_LINE}
                type="application/octet-stream" />
        </item>
EOF
sed -i '' "/<language>en<\/language>/r ${ITEM_FILE}" distribution/appcast.xml
rm -f "$ITEM_FILE"
xmllint --noout distribution/appcast.xml || fail "appcast.xml is not valid XML after insertion"
bold "distribution/appcast.xml updated"

if [ "$PUBLISH" != 1 ]; then
  step "Staged only - nothing pushed"
  cat <<EOF
  Built and verified locally:
    ${ZIP}
    distribution/appcast.xml + project.yml carry the v${VERSION} staging (uncommitted)

  To publish for real, reset the staging and re-run with --publish:
    git checkout -- project.yml distribution/appcast.xml
    ./scripts/release.sh ${VERSION} --publish
EOF
  exit 0
fi

step "Publish: commit release to main"
git add project.yml distribution/appcast.xml
git commit -m "Release ${VERSION}"
trap 'printf "\033[1;31mPUBLISH INCOMPLETE:\033[0m the release commit exists (check origin/main, the GH release, and gh-pages to see how far it got). Finish the remaining steps manually per distribution/README.md.\n" >&2' ERR
git push origin main
bold "pushed release commit"

step "Publish: GitHub Release"
[ -n "$NOTES" ] || NOTES="Bark ${VERSION} - signed and notarized (Developer ID). Existing installs update via the menu bar."
gh release create "v${VERSION}" "$ZIP" --repo "$REPO" --title "Bark ${VERSION}" --notes "$NOTES"
bold "release v${VERSION} live"

step "Publish: appcast to gh-pages"
WT="build/ghpages-wt"
rm -rf "$WT"
git worktree prune
# Detached checkout of the remote tip: immune to a stale local gh-pages branch
# and to the branch being checked out in some other worktree.
if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
  git fetch origin gh-pages || fail "could not fetch origin/gh-pages"
  git worktree add --detach "$WT" FETCH_HEAD
else
  git worktree list | grep -q " \[gh-pages\]" && fail "local gh-pages branch is checked out in another worktree (git worktree list)"
  git worktree add --orphan -b gh-pages "$WT"
fi
cp distribution/appcast.xml "$WT/appcast.xml"
touch "$WT/.nojekyll"
git -C "$WT" add appcast.xml .nojekyll
git -C "$WT" commit -m "appcast: Bark ${VERSION}" >/dev/null
git -C "$WT" push origin HEAD:refs/heads/gh-pages
git worktree remove --force "$WT"
gh api "repos/${REPO}/pages" >/dev/null 2>&1 || \
  gh api "repos/${REPO}/pages" -X POST -f "source[branch]=gh-pages" -f "source[path]=/" >/dev/null
bold "appcast live (Pages deploy takes ~1 min)"

step "Done"
cat <<EOF
  Bark ${VERSION} (build ${BUILD}) released.
    Release: https://github.com/${REPO}/releases/tag/v${VERSION}
    Appcast: https://delarc0.github.io/bark-mac/appcast.xml
    Direct:  ${URL}

  Existing installs: menu bar > Check for Updates.
  Sanity check: curl -sI ${URL} | head -1
EOF
