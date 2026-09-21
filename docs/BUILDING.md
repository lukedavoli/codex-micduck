# Building and releasing Codex MicDuck

The app is a Swift package with no third-party runtime dependencies. Build on macOS 15 or later with Xcode or Command Line Tools providing Swift 6, plus Python 3 for the release checks. The downloadable build targets Apple silicon (`arm64`).

## Local checks and packaging

```sh
./scripts/test.sh
./scripts/build-app.sh --local
```

The tests use isolated or fake services. Packaging does not launch the app, install it, or control Spotify. `Tests/SpotifyControllerIntegrationRunner.swift` is an explicitly manual test that controls the running Spotify app; the automated test script does not run it.

Local packaging produces a clearly named `LOCAL-UNSIGNED` DMG and an ad-hoc signed app under `dist/local/`. These are development artifacts, not public releases. There are no instructions to bypass Gatekeeper.

## Public release

Public releases require a **Developer ID Application** certificate and private key in the signing Mac's Keychain, plus a `notarytool` Keychain credential profile. An Apple Development certificate is insufficient. Store credentials with `xcrun notarytool store-credentials`; keep passwords, private keys, certificates, and account configuration outside the repository.

Set the version and build number in `Resources/Info.plist`, then run:

```sh
CODEX_MICDUCK_SIGNING_IDENTITY='Developer ID Application: Your organization (TEAMID)' \
CODEX_MICDUCK_NOTARY_PROFILE='your-keychain-profile' \
./scripts/build-app.sh --release
```

The identity and profile name are local inputs; neither is a password. Public mode refuses missing credentials or a non-Developer-ID identity. It never falls back to an ad-hoc release.

The script runs offline tests, builds `arm64`, remaps source paths, removes debug symbols, stages only needed files, and scans file contents and extended metadata for private paths and common credential markers. It signs the app with the hardened runtime and secure timestamp, notarizes and staples the app, then creates, signs, notarizes, and staples the DMG. Verification includes signature checks, ticket validation, Gatekeeper assessment, and inspection of the mounted read-only DMG. Only after those checks pass does it place the artifacts and SHA-256 checksum in `dist/release/`.

macOS may retain or regenerate its opaque provenance/integrity metadata. The script attempts to remove development provenance and disk-image checksum attributes, checks metadata values for personal paths and secrets, and preserves signing and notarization data. It does not change macOS security settings.

Use `--output DIRECTORY` for a different output folder. The script refuses to overwrite an existing app or same-version DMG; choose an empty folder or deliberately remove an obsolete build first. A failed build leaves no new public download in the output folder.

Publish the versioned `Codex-MicDuck-VERSION-arm64.dmg` and its `.sha256` file as assets of a matching GitHub Release. Download links should point at that release or its DMG. Updates are manual; there is no background update service.

Successful local checks do not constitute an Apple notarization result. Do not publish `LOCAL-UNSIGNED` artifacts, a rejected submission, or a build whose final validation failed.

Apple references: [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [customizing notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Clean public source

```sh
./scripts/export-source.py --output ../codex-micduck-public
```

This exports an allowlist of source, tests, selected resources, public docs, packaging scripts, and website files into a new directory. It excludes generated apps, build caches, private planning, editor state, credentials, and old design iterations. The output must not already exist. It scans exported bytes and metadata before declaring success; Git itself does not commit macOS extended attributes.

Review that export before creating the public repository. Use an intentional public Git author identity (for example, a GitHub no-reply email). The script does not initialize Git, make commits, or publish anything. Keep the Apache-2.0 `LICENSE` and `NOTICE` with source and binary distributions.
