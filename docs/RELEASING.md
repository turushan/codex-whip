# Publishing a release

Builds need no private update key. Publishing updates requires the release Ed25519 key in the
maintainer's login Keychain, under account `com.turushan.codex-whip` and the Sparkle update-key item.
Its public key is committed in `scripts/sparkle.py`. Keep a secure backup of this Keychain key and
never commit or upload it. Apps signed before 1.10.3 were ad hoc signed and cannot recover a lost
update key through Apple's Developer ID key rotation.

Release DMGs are signed with a Developer ID Application certificate, notarized by Apple and
stapled. The **Signed release build** workflow (`.github/workflows/release.yml`) does this on
GitHub's macOS runners. Its secrets live in the `release` environment, which only `main` can use:
`MACOS_CERTIFICATE` (the base64 `.p12`), `MACOS_CERTIFICATE_PASSWORD`, and an App Store Connect
Team API key with the Developer role as `NOTARY_KEY` (the base64 `.p8`), `NOTARY_KEY_ID` and
`NOTARY_ISSUER`. Local builds stay ad hoc unless `scripts/build_app.py --identity` names a
certificate in the keychain.

Release downloads and update feeds are public. Verify final feed and asset URLs without GitHub
authentication, matching how installed apps access updates.

1. Update `VERSION` in `codex_whip.py`, then run the tests and build:

   ```sh
   python3 scripts/build_app.py
   ```

2. Commit and push the source. Verify the clean Apple silicon and Intel GitHub builds, then run
   the **Signed release build** workflow and download both notarized DMGs:

   ```sh
   gh workflow run release.yml
   gh run download <run-id> -n codex-whip-signed-macos-15 -n codex-whip-signed-macos-15-intel -D build/signed
   ```

   Test the built app, including pause/resume/quit and an isolated update check.
   A maintainer with the release Keychain key can run the signed local upgrade and tamper test:

   ```sh
   python3 scripts/test_updater.py
   python3 scripts/test_update_notice.py --app "dist/Codex Whip.app"
   ```

   This uses QA app copies, separate state and preferences, and a loopback-only update server.
   It tests real update preferences, automatic installation/relaunch, state preservation, and
   rejection of a modified archive without connecting to Codex.
   The notice test additionally uses Accessibility and Screen Recording access to verify the
   real menu, quiet discovery without an installer download, and the standard update dialog.

3. Prepare the update feed using the release Keychain key. Plain text notes are optional:

   ```sh
   python3 scripts/prepare_release.py build/signed/codex-whip-signed-macos-15/Codex-Whip-arm64.dmg --notes build/release-notes.txt
   ```

   The script verifies the signing key, signs the DMG and feed with Sparkle's pinned tools,
   checks the feed signature and archive version, writes `updates/appcast-arm64.xml`, and
   refreshes `dist/SHA256SUMS.txt`. It never exports the private key.
   It must fail if the release key is missing or does not match the embedded public key, or if
   the DMG carries no stapled notarization ticket. Stapling changes the DMG, so the Sparkle
   signature is always made after notarization.

4. Create the matching GitHub release with the DMG and `SHA256SUMS.txt`. Use a tag matching
   `VERSION`, such as `v1.6.0`, and target the tested source commit. Verify the asset
   download and checksum without GitHub authentication.

5. Commit and push the prepared architecture feeds under `updates/`. Installed apps read their
   feed and signed DMG from GitHub without authentication. Automatic distribution requires
   publicly accessible URLs. Each feed must point to an already available release asset.

6. Point the Homebrew cask in [turushan/homebrew-tap](https://github.com/turushan/homebrew-tap)
   at the new release. The script reads both checksums from the published `SHA256SUMS.txt`:

   ```sh
   python3 scripts/update_tap.py
   ```

   The cask is marked `auto_updates`, so Homebrew installs keep updating through Sparkle and
   the cask only decides what a new `brew install` downloads.

Run the same preparation command on an Intel-built `Codex-Whip-x86_64.dmg` when publishing
an Intel download. It writes a separate feed so each Mac receives a compatible app. Keep feeds
signed; do not edit generated XML after signing. Sparkle verifies signatures before extracting updates.

Source builders who want their own distribution must generate their own update key with
Sparkle's `bin/generate_keys`, change the public key, Keychain account, repository, and feed root
in `scripts/sparkle.py`, and host their own signed feeds. The official private key is never needed
for local builds or normal development.
