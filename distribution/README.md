# Bark — distribution

This folder holds the release pipeline scaffolding for Sparkle auto-update.

## State (2026-04-18)

- EdDSA keypair generated; public key lives in `project.yml` under `INFOPLIST_KEY_SUPublicEDKey`. Private key is in the macOS login keychain of the signing machine.
- `appcast.xml` is a placeholder. Not yet hosted.
- Apple Developer ID is **pending**. Until it's approved, we cannot ship real updates — Sparkle refuses to apply updates that aren't both EdDSA-signed and codesigned by a trusted identity.

## When Dev ID is approved

Release recipe (run from `apps/bark-mac`):

```bash
# 1. Bump version
sed -i '' 's/MARKETING_VERSION: "0.1.0"/MARKETING_VERSION: "0.2.0"/' project.yml
xcodegen

# 2. Archive + export with Developer ID
xcodebuild -project Bark.xcodeproj -scheme Bark -configuration Release \
  -archivePath build/Bark.xcarchive archive
xcodebuild -exportArchive -archivePath build/Bark.xcarchive \
  -exportPath build/export -exportOptionsPlist distribution/ExportOptions.plist

# 3. Notarize + staple
xcrun notarytool submit build/export/Bark.app --keychain-profile "AC_NOTARY" --wait
xcrun stapler staple build/export/Bark.app

# 4. Zip + sign for Sparkle
ditto -c -k --sequesterRsrc --keepParent build/export/Bark.app build/Bark-0.2.0.zip
build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update build/Bark-0.2.0.zip

# 5. Update appcast.xml with the new <item>, push to GH Pages, upload zip to GH Release
```

## Hosting

Target: GitHub Pages from a `bark-mac-updates` branch or a separate repo, served at `delarc0.github.io/bark-mac/appcast.xml` (matches `SUFeedURL` in `project.yml`). Release zips live on GitHub Releases so they're cacheable without hammering Pages.

## Key management

- Public key is committed in `project.yml` (safe — it's public by design).
- Private key is in the login keychain on the release machine. Back it up with:
  ```bash
  build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x bark-sparkle-private.pem
  ```
  Store the exported PEM in 1Password. Re-import on a new machine with `-f <file>`.
