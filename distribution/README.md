# Bark — distribution

Release pipeline for signed, notarized builds with Sparkle auto-update.

## State (2026-07-17)

- Apple Developer Program: **LIVE**. LAB37 Media AB, Team ID `4D2U237VRC`.
- EdDSA keypair generated; public key lives in `project.yml` (`SUPublicEDKey`).
  Private key is in the login keychain of the release machine (Erik's M5 Pro).
- The whole release is scripted: `scripts/release.sh`.
- `appcast.xml` in this folder is the source of truth for the update feed. The
  script appends each release and mirrors it to the `gh-pages` branch, served at
  `https://delarc0.github.io/bark-mac/appcast.xml` (matches `SUFeedURL`).
- Release zips live on GitHub Releases; the appcast enclosure URLs point there.

## One-time machine setup

Both steps are interactive (Apple ID) and cannot be scripted:

1. **Developer ID certificate** — Xcode → Settings → Accounts → sign in
   `erik@lab37.io` → Manage Certificates → **+** → **Developer ID Application**.
2. **Notary credentials** — create an App Store Connect API key (Users and
   Access → Integrations, role Developer), then:
   ```bash
   xcrun notarytool store-credentials AC_NOTARY \
     --key /path/to/AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
   ```

Verify readiness any time:

```bash
./scripts/release.sh --check
```

## Cutting a release

```bash
./scripts/release.sh 0.2.0 --publish
```

That does, in order: preflight → bump `MARKETING_VERSION` +
`CURRENT_PROJECT_VERSION` in `project.yml` → archive Release → export with
Developer ID (`ExportOptions.plist`) → notarize (`AC_NOTARY`, waits) → staple →
verify (codesign strict, hardened-runtime flag, **audio-input entitlement**,
staple, Gatekeeper) → build + notarize a drag-to-Applications **DMG** →
`ditto` zip → Sparkle `sign_update` → append `<item>` to `appcast.xml` →
commit + push to main → GitHub Release with DMG + zip → push appcast to
`gh-pages`.

Two artifacts per release: the **DMG** is the human download (drag to
Applications sidesteps App Translocation, which breaks Sparkle updates for
apps run from ~/Downloads); the **zip** is what Sparkle pulls for updates
(the appcast enclosure points at it).

Without `--publish` it stops after local verification and pushes nothing
(dry run; reset with `git checkout -- project.yml distribution/appcast.xml`).

## Gotchas learned the hard way

- **notarytool takes a zip, not a .app.** The script zips, submits, then
  staples the .app and re-zips for distribution.
- **The mic dies silently** in a hardened-runtime build without the
  `com.apple.security.device.audio-input` entitlement. It's in
  `Bark/Bark.entitlements`; the verify step fails the release if it's missing.
- **Never pass `CODE_SIGN_IDENTITY` on the xcodebuild CLI** — it leaks into the
  SPM package targets, which then demand a development team. The archive stays
  ad-hoc; `-exportArchive` re-signs everything with the Developer ID cert per
  `ExportOptions.plist`.
- The Debug-only post-build deep re-sign in `project.yml` does not run for
  Release archives (guarded on `${CONFIGURATION}`), so it can't fight the
  export signing.

## Key management

- Public key is committed in `project.yml` (safe, public by design).
- Private key is in the login keychain of the release machine. Back it up with:
  ```bash
  build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x bark-sparkle-private.pem
  ```
  Store the exported PEM in 1Password. Re-import on a new machine with
  `generate_keys -f <file>`. Losing this key means shipped installs can never
  auto-update again (public key is baked into every released binary).
