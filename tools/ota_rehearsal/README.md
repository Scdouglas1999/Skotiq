# OTA rehearsal

Runs a real Linux release bundle through a real update, against a stand-in
for GitHub Releases, with a throwaway signing key. Run it before provisioning
or rotating the update key, and before any release that changes the updater,
the manifest tool or the release workflow. The updater is the one component
an update cannot repair: if the first signed release cannot download, apply,
swap or roll back, every install needs a manual reinstall.

Nothing here touches the real key, the real GitHub, or the host's trust
store. It needs Linux with unprivileged user namespaces (`unshare -r` works),
`Xvfb`, Python 3 with `cryptography`, and the Flutter + Rust toolchains.

## How it reaches an unmodified release binary

A shipped build only talks to `https://api.github.com`, `https://github.com`
and `https://objects.githubusercontent.com`, and Dart's TLS on Linux trusts
only the system CA bundle (it ignores `SSL_CERT_FILE`). `netns_shim.sh` runs
everything inside an unprivileged user + mount + network namespace in which
`/etc/hosts` sends those three names to 127.0.0.1, the CA bundle has the
rehearsal CA appended, and loopback is the only interface. The bundle under
test is exactly what `flutter build linux` produced; the app has no test
hook for pointing it elsewhere, and needs none.

## Files

| File | What it does |
|------|--------------|
| `make_keys.py` | Throwaway Ed25519 keypair (same formats as the CI secrets), a second "wrong" key, and a rehearsal CA + server certificate. |
| `build_bundle.sh` | One Linux bundle, step for step as the `linux` job in `.github/workflows/release.yml` builds it (bridge, `--dart-define=SKOTIQ_UPDATE_PUBLIC_KEY`, libraw, launcher, `updater`, license files), copied out so N and N+1 can coexist. |
| `package_release.sh` | Packages and signs one target through `tool/build_update_manifest.dart` with the arguments CI passes, including the per-tag download URL. |
| `prepare_linux.sh` | Builds every release the scenarios serve (good, tampered, wrong key, unsigned, misnamed, other platform only, downgrade, a build that cannot start) and writes `scenarios.json`. |
| `fake_github.py` | The three GitHub hosts on one TLS port: releases API, the 302 from `github.com`, asset bytes with Range support, and truncate / drop / stall modes. Logs every request. |
| `netns_shim.sh` | The namespace described above. |
| `rehearse_linux.py` | Installs N in a scratch directory, starts it headless on a private Xvfb display with scratch data, database and HOME, seeds a profile and a setting, and drives check, download and apply through `/api/system/update/*`. Records what the API said, what is on disk, which build answers afterwards, and whether N is intact and still starts. |

## Running it

```bash
R=~/.cache/sk-ota                       # anywhere outside the repository
export CARGO_TARGET_DIR=~/.cache/ns-targets/ota-rehearsal

python3 tools/ota_rehearsal/make_keys.py $R/keys

# N and N+1. The marker is written into the bundle so the installed build
# can be read off the disk as well as off /api/system/version.
tools/ota_rehearsal/build_bundle.sh 7.1.90 90 $R/keys/update_public.b64 $R/builds/fixed-N  N-7.1.90
SKIP_RUST=1 \
tools/ota_rehearsal/build_bundle.sh 7.1.91 91 $R/keys/update_public.b64 $R/builds/fixed-N1 N1-7.1.91

tools/ota_rehearsal/prepare_linux.sh $R fixed $R/builds/fixed-N $R/builds/fixed-N1 7.1.90 90 7.1.91 91

tools/ota_rehearsal/netns_shim.sh $R/keys \
  python3 tools/ota_rehearsal/rehearse_linux.py --root $R --set fixed \
    --bundle-n $R/builds/fixed-N --scenarios $R/dist/fixed/scenarios.json \
    --keys $R/keys --display :79
```

`--only happy_path wrong_key` runs a subset. Pick a free `--display`
(`ls /tmp/.X11-unix`). The exit status is the number of scenarios whose
outcome did not match; per-scenario evidence is in
`$R/run/<set>/<scenario>/evidence.json`, with the app logs beside it and every
request the fake GitHub answered in `$R/run/<set>/requests.log`.

Each bundle build takes several minutes and needs roughly 4 GB of free memory.
`SKIP_RUST=1` on the second build reuses the bridge and updater from the
first.

## Scenarios

| Scenario | Serves | Expected |
|----------|--------|----------|
| `happy_path` | N+1, signed | N swaps to N+1, N+1 answers with the new version, the profile and setting survived, staging is gone |
| `tampered_package` | one byte of the zip flipped after signing | refused at download, N untouched and still starts |
| `wrong_key` | signed with a key the build does not trust | refused at download |
| `unsigned_manifest` | no signature (what CI publishes while the secret is unset) | refused at download |
| `manifest_disagrees_with_name` | a Windows manifest named `manifest-linux-x64.json` | refused at check, loudly |
| `truncated_download` | half the bytes, then the connection closes | refused at download |
| `connection_dropped` | 64 KiB, then the socket is shut | refused at download |
| `downgrade_offer` | an older build, properly signed | no update offered |
| `other_platform_only` | only a Windows manifest | no update, with a reason |
| `staging_disk_full` | staging on a 40 MB tmpfs | refused at download |
| `updater_verify_fails` | a staged file changed after verification | the updater's own hash check rolls back and N comes back up |
| `new_build_cannot_start` | an N+1 whose executable exits 1 | the updater rolls back to N and starts it |
| `install_not_writable` | install bind-mounted read-only (what the appliance unit's `ProtectSystem=strict` does) | apply refused before the app exits; N keeps running |
| `headless_by_argv` | N started with `--headless --port --auth-token` instead of env vars | N+1 comes back headless on the same port |

## Android

The same fake GitHub serves APKs to a rooted emulator (a `google_apis`
image, not `google_play`):

```bash
# N and N+1 from one throwaway keystore (never ~/Documents/Skotiq-signing)
tools/ota_rehearsal/build_apk.sh 7.1.92 92 $R/keys/update_public.b64 $R/android-keystore $R/builds/apk/n.apk
tools/ota_rehearsal/build_apk.sh 7.1.93 93 $R/keys/update_public.b64 $R/android-keystore $R/builds/apk/skotiq-7.1.93-android-x86_64.apk
tools/ota_rehearsal/package_release.sh $R/builds/apk/skotiq-7.1.93-android-x86_64.apk 7.1.93 93 android x64 $R/dist/android $R/keys/update_private.b64

emulator -avd <avd> -no-window -no-audio -port 5584 -read-only &
python3 tools/ota_rehearsal/fake_github.py --port 18443 --scenario <scenario.json> \
  --cert $R/keys/tls/srv.crt --key $R/keys/tls/srv.key --log $R/android-requests.log &
tools/ota_rehearsal/android_prepare.sh $R/keys emulator-5584 18443
adb -s emulator-5584 install n.apk
```

`android_prepare.sh` adds the rehearsal CA through a tmpfs over
`/system/etc/security/cacerts` (the store Dart reads on Android), bind-mounts
`/system/etc/hosts`, and carries port 443 to the host with `adb reverse`;
none of it survives the emulator shutting down. `adb_ui.py` reads and taps
the screen through uiautomator. The taps a real user makes are listed in the
rehearsal report: skip connection (or connect), the update offer, Install Now,
the one-time "Allow from this source" grant, and Android's own Update button.

## What this does not cover

Windows (the `updater.exe` swap under file locks, `build_update_package.ps1`)
cannot run here. The GUI prompt path is covered by widget tests, not by this
harness.
