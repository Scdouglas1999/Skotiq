# Release Signing

Nightshade's release pipeline (`.github/workflows/release.yml`) has three
independent signing tracks. **Every track is fail-closed: if its secret is
absent the build still succeeds but ships unsigned/fail-closed-disabled. A
secret that is _present but broken_ fails the build loudly rather than silently
downgrading.**

None of the signing material is in the repo. The workflow only _reads_ the
GitHub Actions secrets below; an owner must create them in
**Settings → Secrets and variables → Actions**.

## Required secrets

| Secret | Track | Consumer | Absent → behavior |
| --- | --- | --- | --- |
| `NIGHTSHADE_UPDATE_PUBLIC_KEY` | OTA | The Windows, Linux and Android jobs bake it into the app via `--dart-define` on `flutter build windows`, `flutter build linux` and `flutter build apk` | Empty define → runtime OTA stays fail-closed-disabled (the app refuses every update). Build succeeds. |
| `NIGHTSHADE_UPDATE_PRIVATE_KEY` | OTA | `scripts/build_update_package.ps1` (Windows) and `packages/nightshade_updater/tool/build_update_manifest.dart` (Linux, Android) sign the canonical manifest payload | Manifest emitted unsigned → no build can apply it (fail-closed). Build succeeds. |
| `WINDOWS_SIGNING_CERT_BASE64` | Authenticode | "Authenticode sign (optional)" step signs every `*.exe`/`*.dll` in the Release tree | Step skips → unsigned beta (SmartScreen prompt). |
| `WINDOWS_SIGNING_CERT_PASSWORD` | Authenticode | PFX password for `signtool` | Only used when the cert is present. |
| `ANDROID_KEYSTORE_BASE64` | Android | "Decode release keystore" step writes `$RUNNER_TEMP/release.jks` and exports `KEYSTORE_FILE` | `KEYSTORE_FILE` unset → `build.gradle.kts` falls back to the debug keystore (debug-signed beta). |
| `ANDROID_KEYSTORE_PASSWORD` | Android | gradle env `KEYSTORE_PASSWORD` | Required when `KEYSTORE_FILE` is set, else gradle throws. |
| `ANDROID_KEY_ALIAS` | Android | gradle env `KEY_ALIAS` | Required when `KEYSTORE_FILE` is set, else gradle throws. |
| `ANDROID_KEY_PASSWORD` | Android | gradle env `KEY_PASSWORD` | Required when `KEYSTORE_FILE` is set, else gradle throws. |

The Android secrets map onto the gradle env vars
(`signingConfigs.release` in `apps/mobile/android/app/build.gradle.kts`):
`KEYSTORE_FILE`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`. When
`KEYSTORE_FILE` is set the keystore file **and** all three credentials must be
present or the build throws (fail-closed: never silently debug-sign a build
meant for production).

## Generating the signing material (owner, one time each)

### OTA Ed25519 keypair

See `docs/OTA_UPDATE_TESTING.md` → **"OTA signing keys"** for the canonical
generator. Store `PRIVATE` as `NIGHTSHADE_UPDATE_PRIVATE_KEY`, `PUBLIC` as
`NIGHTSHADE_UPDATE_PUBLIC_KEY`. The signer constructs the canonical payload with
the same Dart serializer the runtime verifier
(`update_verifier.dart` `_canonicalManifestPayload`) uses, so the signed bytes
byte-match what the app verifies.

### Windows Authenticode certificate

Provision an OV/EV code-signing certificate as a PFX, then base64-encode it:

```bash
base64 -w0 codesign.pfx          # -> WINDOWS_SIGNING_CERT_BASE64
# password -> WINDOWS_SIGNING_CERT_PASSWORD
```

### Android upload/release keystore

```bash
keytool -genkeypair -v -keystore release.jks -storetype JKS \
  -keyalg RSA -keysize 2048 -validity 10000 -alias nightshade
base64 -w0 release.jks            # -> ANDROID_KEYSTORE_BASE64
# store password -> ANDROID_KEYSTORE_PASSWORD
# alias          -> ANDROID_KEY_ALIAS  (e.g. nightshade)
# key password   -> ANDROID_KEY_PASSWORD
```

The release job builds **per-ABI** APKs (`flutter build apk --release
--split-per-abi`): `armeabi-v7a`, `arm64-v8a`, `x86_64`, published as
`nightshade-<version>-android-<abi>.apk`. These are sideload artifacts; all
splits share one `versionCode`. Distinct per-ABI `versionCode`s are only needed
for a Play Store upload and are intentionally out of scope here.

## Update hosting

Every release job publishes a signed manifest next to the package it
describes, named for the target it was built for:

```
manifest-windows-x64.json   nightshade-<version>-windows-x64.zip
manifest-linux-x64.json     nightshade-<version>-linux-x64.zip
manifest-android-arm64.json nightshade-<version>-android-arm64-v8a.apk
manifest-android-arm.json   nightshade-<version>-android-armeabi-v7a.apk
manifest-android-x64.json   nightshade-<version>-android-x86_64.apk
```

The per-target names matter: the publish job flattens every build job's
artifacts into one directory, so a shared `manifest.json` would leave one
arbitrary platform's manifest standing and the rest undiscoverable.

Each manifest's `downloadUrl` is baked to the **immutable per-tag** asset URL:

```
https://github.com/<owner>/<repo>/releases/download/v<version>/<asset>
```

Shipped builds find these by reading the GitHub Releases API, so nothing has to
be hosted and `NIGHTSHADE_UPDATE_SERVER` need not be set. Setting it still
overrides the source, which is how an appliance is pointed at a private build
host.

Because `downloadUrl` is part of the signed payload, any change of hosting
(GitHub Releases → S3/other) re-breaks the signature and requires re-signing the
manifest with the matching `downloadUrl`.

To check that a published release is actually signed — an unsigned one builds
and publishes normally, and only refuses at download time, so it is easy to
miss:

```sh
curl -sSL https://github.com/<owner>/<repo>/releases/download/v<version>/manifest-linux-x64.json \
  | python3 -c 'import json,sys; print("signed" if json.load(sys.stdin).get("signature") else "UNSIGNED - OTA is off")'
```

## Fail-closed contract (summary)

- No `NIGHTSHADE_UPDATE_PUBLIC_KEY` → app cannot authenticate any update; OTA off.
- No `NIGHTSHADE_UPDATE_PRIVATE_KEY` → manifest unsigned; no app applies it.
- No `WINDOWS_SIGNING_CERT_BASE64` → Windows binaries unsigned (beta).
- No `ANDROID_KEYSTORE_BASE64` → APKs debug-signed (beta).
- Secret **present but broken** (bad cert, missing keystore creds, wrong key) →
  the build **fails loudly**; it never silently produces an unsigned/downgraded
  "release".
