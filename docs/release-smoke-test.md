# Release Smoke Test (clean machine)

`melos run analyze` and `melos run test` prove the code is sound. They do **not**
prove the shipped artifact *boots on a machine without your dev environment* —
that is where packaging failures hide (a missing bundled DLL/`.so`, an FFI hash
mismatch, a glibc floor, a debug-only path). This runbook is the gate between
"CI is green" and "tag the release." Run it on **real, dev-free machines** (or
clean VMs/containers) before publishing.

Do this every release. Record the result table at the bottom in the release
evidence (`docs/release-evidence/<version>.md`).

## 0. Build the artifacts

Build the three shipped artifacts the same way `.github/workflows/release.yml`
does (or download them from the tag's release-workflow run):

| Artifact | Build |
| --- | --- |
| Windows x64 zip | `melos run build:desktop:windows` then stage with `scripts/stage_windows_release.ps1 -Profile Release` |
| Linux x64 tarball | `melos run build:desktop:linux` (bundle native bridge + libraw + hermetic sqlite native asset) |
| Android universal APK | `melos run build:mobile:android` (`flutter build apk --release`) |

The artifact you smoke-test must be the **packaged** one (zip/tarball/apk), not
the raw `build/` output — the bundling step is exactly what this test exercises.

## 1. Windows zip — boots on a clean box

On a Windows 10/11 machine **without** Visual Studio, Flutter, or the dev tools:

- [ ] Extract `skotiq-<version>-windows-x64.zip` and run `skotiq_desktop.exe`.
- [ ] App window opens — no "missing `*.dll`" / "VCRUNTIME140.dll not found" dialog.
- [ ] The native bridge loads (no FFI/codegen-hash error on startup; equipment
      discovery screen is reachable).
- [ ] No ASCOM Platform installed yet → ASCOM paths are offered but fail with an
      explicit reason, not a crash (see step 5).

## 2. Linux tarball — boots on a clean box

On a clean Linux box or fresh VM/container (Debian/Ubuntu Bookworm is the floor;
also try a current rolling-release desktop) **without** the dev toolchain:

- [ ] Extract `skotiq-<version>-linux-x64.tar.gz`, run `./skotiq`.
- [ ] App launches — GTK3/libsecret present (document any runtime packages the
      user must install).
- [ ] Bundled `libskotiq_bridge.so`, `libraw`, and hermetic `libsqlite3.so`
      (package:sqlite3 native asset) load from the bundle.
- [ ] Built against the glibc floor — it does **not** fail with
      `GLIBC_2.3x not found` on the Bookworm/Raspberry Pi appliance target.

## 3. Android APK — installs and pairs

On a real Android phone/tablet:

- [ ] Sideload `skotiq-<version>-android-universal.apk` ("Install unknown
      apps"). Expect the OS to flag it as **debug-signed** — that is the
      documented beta posture, not a failure.
- [ ] App opens.
- [ ] Pair to a running desktop or headless instance over the LAN by QR code /
      6-word code, and confirm live session data appears (monitor + light
      control).

## 4. Native bridge loads (all platforms)

- [ ] On each platform above, confirm the Rust native bridge actually loaded —
      not a stub, not a silent failure. A missing bridge must **fail loud** (see
      [`no-fake-hardware-policy.md`](no-fake-hardware-policy.md)), so a clean
      boot that reaches device discovery is the positive signal.

## 5. Missing hardware fails loud (not weird)

With **no** drivers or devices connected, confirm Skotiq degrades honestly:

- [ ] Discovery returns an empty list (or a clear "none found"), not fabricated
      devices.
- [ ] Attempting to connect a non-present device returns an **explicit error**,
      not a silent no-op or fake "connected" state.
- [ ] Simulator paths are only reachable when explicitly enabled; production
      builds reject `sequencer/simulation` with `simulation_mode_unavailable`.
- [ ] Safety-critical unknowns (no weather source) **fail closed** — the run
      gates/pauses rather than imaging blind.

## Result table (paste into release evidence)

| Check | Windows | Linux | Android | Notes |
| --- | --- | --- | --- | --- |
| Artifact boots on clean machine | ☐ | ☐ | n/a | |
| Native bridge loads | ☐ | ☐ | n/a | |
| Pairs over LAN | n/a | n/a | ☐ | |
| Missing hardware fails loud | ☐ | ☐ | n/a | |
| OS / build tested | | | | exact OS + driver versions |

If any box fails, it is a **release blocker** until fixed or explicitly scoped
out in `docs/known-limitations.md`. A green CI run is necessary but not
sufficient — this runbook is what lets the release notes honestly say the
artifact runs.
