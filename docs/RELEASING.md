# Releases And Updates

The first public channel is alpha. Downloads are GitHub prereleases. Sparkle reads
`appcast.xml` from the public repository's `main` branch and downloads the app ZIP
from the corresponding GitHub Release. The DMG is for manual installation.

## Two Different Signatures

- **Apple code signing** identifies the app and its nested code. Published alpha
  binaries keep the maintainer's Apple Development signature and public certificate
  chain. Signing certificates can expose their subject name and email. The private
  key stays in Keychain and is never copied into source, the app, or GitHub.
- **Sparkle Ed25519 signing** authenticates both the feed and archive. Its private
  key stays in Keychain under the account `reprise-updates`. The public key in
  `Resources/Info.plist` is intentionally public. Do not casually regenerate it.

The current alpha is not Developer ID signed or Apple-notarized. Code-signature
verification is not a Gatekeeper acceptance claim. For wider trusted distribution,
use Developer ID Application signing, notarize with `notarytool`, and staple the
ticket before creating the final archives. Never label a release notarized without
a successful submission and ticket validation. A future signing-identity change
needs permission and upgrade testing.

The app is not App Sandboxed. Hardened Runtime builds include the Audio Input
entitlement for microphone recording. Sparkle's nested code is signed separately
before the framework and app, without `codesign --deep` for signing.

## Build And Check

1. Change `CFBundleShortVersionString` in `Resources/Info.plist`, the MCP server's
   protocol version, and `CHANGELOG.md`. `CFBundleVersion` is a monotonic UTC build
   timestamp supplied by the build script; never reuse it for different content.
2. Run the synthetic tests and package without touching an installed app:

```sh
swift test
./script/build_and_run.sh --build
./dist/Reprise.app/Contents/MacOS/Reprise --check-package
node script/check_mcp.mjs dist/Reprise.app/Contents/MacOS/RepriseMCP
```

Opt-in checks use real data without touching the vault: `REPRISE_TEST_SPEECH=1`
transcribes a sealed synthetic Korean/English meeting with the Mac's speech models,
`REPRISE_ARCHIVE_SAMPLE=<captures folder>` compresses copies of the newest 150
screens, `REPRISE_LIBRARY_COPY=<library.sqlite>` converts a copy made with
`sqlite3 'file:…/library.sqlite?mode=ro' ".backup copy.sqlite"` to an encrypted library,
`REPRISE_VAULT_COPY=<folder>` encrypts a copied library folder and opens every kind of
media, and `REPRISE_TEST_KEYCHAIN=1` writes, reads and removes a throwaway keychain item.
They use a key that exists only in the test process, so the real-data checks need a
library from before 0.6; an encrypted library opens only with its own keychain key.

To check keychain access with the signed bundle, run
`./dist/Reprise.app/Contents/MacOS/Reprise --check-vault <copied folder>` and then
`./dist/Reprise.app/Contents/MacOS/RepriseMCP --vault <copied folder> --check`. A
copy outside the usual vault gets its own keychain item (account `library:<path>`);
remove it afterwards with `security delete-generic-password -s local.aria.reprise.vault
-a "library:<path>"`. Never run `--check-vault` on a copy that is still in use.

The package check runs before opening a vault, requesting permissions, or creating
the app model. The stdio check uses a temporary disabled vault. Neither test records
the screen/microphone nor calls an AI model. Native provider checks require the
explicit `REPRISE_TEST_NATIVE_PROVIDERS=1` opt-in. `REPRISE_TEST_CODEX=/absolute/path`
enables a native MCP installation/removal check in a temporary home, not the user's
configuration. `REPRISE_VERIFY_PROVIDER` is a separate, explicitly billed/limited
subscription-inference test and should not be enabled in CI.

The signing identity defaults to an available Apple Development certificate.
Set `REPRISE_SIGNING_IDENTITY` explicitly to select the intended certificate.
Forks must replace the bundle ID, update URLs and public key before distribution.
Generate a fork's own Sparkle key once, following the upstream instructions; never
reuse or request the maintainer's private key.

## Package

```sh
./script/prepare_sparkle.sh
./script/package_release.sh
```

Normal packaging requires a Developer ID signed app with a valid stapled ticket
and a passing Gatekeeper assessment. A deliberately development-signed alpha must
instead opt in with `REPRISE_ALLOW_DEVELOPMENT_RELEASE=1`; this preserves the Apple
signature but does not grant Gatekeeper approval. Free Apple Accounts
cannot supply Developer ID signing or notarization. Disclose this prominently and
do not treat `codesign --verify` or the package smoke check as installation proof.

Before publishing, assess the exact final bundle with `syspolicy_check distribution`
and test a browser-downloaded artifact on a disposable setup. Record any denial
separately from signature integrity. Do not remove quarantine, disable Gatekeeper,
or silently substitute a local unquarantined build for this test. A checksum-matching
download can still fail system policy. The app updater's Ed25519 signature does not
replace Apple notarization.

The tool bootstrap pins Sparkle 2.10.0 and verifies its release archive SHA-256.
Packaging preserves the Apple signature, includes the app and Applications link in
a DMG with copy instructions, creates a ZIP, signs the update archive/feed, and writes `SHA256SUMS` under
`dist/releases/vVERSION`. No vault, auth state, private keys or research artifacts
are copied. It refuses ad-hoc public releases and existing version directories.
`REPRISE_GITHUB_REPOSITORY` and `REPRISE_SPARKLE_ACCOUNT` support fork release setup;
they must match the fork's app configuration.

Check the final DMG by mounting it read-only at a temporary mount point, copying
its app to a temporary directory, and validating the copied code signature. Check
the ZIP after extraction as well. This proves archive readability and a file-copy
round trip, not Finder installation or Gatekeeper approval. Do not describe an
unresolved copy/installation failure as fixed by Open Anyway or by repackaging.

## Publish

Use the standalone Reprise repository, **never a parent workspace repository**.
Review the exact staged file list and scan for secrets, captures, transcripts and
personal paths before pushing. Include English/Korean README, MIT and all third-party
notices. Do not commit `.build`, `dist`, local verification journals or `.p12` files.

1. Commit the reviewed source and create an immutable `vVERSION` tag.
2. Create a draft GitHub prerelease for that exact tag. Upload the DMG, ZIP and
   `SHA256SUMS`. Confirm their names, byte lengths and SHA-256 digests.
3. Publish the prerelease and verify public download URLs.
4. Promote the generated `dist/releases/vVERSION/appcast.xml` into the repository
   root without altering its bytes, then commit and push the feed to `main`.
5. Download the public feed and verify it with
   `.build/sparkle-tools/bin/sign_update --account reprise-updates --verify appcast.xml`.
   Verify its enclosure URL, version, archive length and Ed25519 signature against
   the uploaded ZIP. Do not overwrite a published archive with a different build.

Keep the previous feed entries and release assets for supported older versions.
The packaging tool reuses the existing feed and adds the new release. A feed edit
requires a fresh signature. Private keys are not uploaded to CI in this workflow;
release signing runs on the maintainer's Mac. CI builds/tests source only.

Before claiming a future upgrade is tested, install it on a disposable test setup
and verify shutdown, relaunch, permissions, vault continuity and MCP helper paths.
The first alpha establishes the update channel but cannot by itself prove a future
version-to-version installation. Older local builds need one manual installation.

References: [Sparkle setup](https://sparkle-project.org/documentation/),
[publishing](https://sparkle-project.org/documentation/publishing/),
[manual nested-code signing](https://sparkle-project.org/documentation/sandboxing/#code-signing),
[Apple certificate types](https://developer.apple.com/help/account/certificates/certificates-overview).

## Verified Upgrade

On 2026-10-13, the maintainer manually installed alpha.2 and then completed a
Sparkle update to alpha.3. The running app changed from build `20261013192108` to
`20261013192836` at the same Applications path. Sparkle logged successful EdDSA
verification of both the feed and archive. Post-relaunch code-signature and package
checks passed. The vault path, database identity and all pre-update record IDs were
preserved. This validates that upgrade on one Mac, not all supported configurations.
