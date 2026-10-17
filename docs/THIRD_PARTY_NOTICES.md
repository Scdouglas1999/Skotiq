# Third-Party Notices — Skotiq 5.0.0

This notice describes the components redistributed in the official 5.0.0
artifacts produced by `.github/workflows/release.yml`:

- `skotiq-5.0.0-windows-x64.zip`
- `skotiq-5.0.0-linux-x64.tar.gz`
- `skotiq-5.0.0-android-universal.apk`

Skotiq's own code and assets are governed by `SKOTIQ-LICENSE.txt`
(the Skotiq Source-Available License, version 1.2). Third-party components
remain governed by their respective licenses. The desktop archives contain
this notice, the Skotiq license, and `LICENSES/LGPL-2.1.txt`; the GitHub
release also publishes those files plus `SOURCE-COMMIT.txt` as separate assets. Flutter's generated
`NOTICES.Z` remains embedded in each Flutter application and is the detailed
notice bundle for resolved Dart, Flutter, plugin, font, and icon dependencies.

## Native libraries distributed in the desktop archives

| Component | How it is shipped | License / notice |
| --- | --- | --- |
| Skotiq native bridge | `skotiq_bridge.dll` on Windows; `libskotiq_bridge.so` on Linux | Skotiq Source-Available License for first-party code; statically linked Rust crates retain their licenses below. |
| LibRaw | Dynamically linked `libraw.dll` / `libraw.so` next to the bridge | LibRaw is dual-licensed LGPL-2.1-or-later or CDDL-1.0. Skotiq uses the LGPL option. The full LGPL-2.1 text is in `LICENSES/LGPL-2.1.txt`; dynamic linking preserves replacement/relinking. Source: <https://www.libraw.org/download>. |
| SQLite | Hermetic `libsqlite3.so` native asset from `package:sqlite3` (Linux/desktop archive) | Public domain. See <https://www.sqlite.org/copyright.html>. |
| Microsoft Visual C++ runtime | Redistributable runtime DLLs staged by the Windows toolchain | Redistributed under the Microsoft Visual Studio license. |
| WebRTC native libraries | Included by `flutter_webrtc` where required | BSD-style WebRTC/Chromium notices are included in Flutter's generated notice bundle. |

The Linux bridge dynamically uses the system's libusb, libudev, OpenSSL, and
other platform libraries. Skotiq deliberately does **not** statically
vendor libusb. The release build installs the development packages only to
link against the shared libraries; these libraries are not copied into the
archive.

## Rust dependencies

The native bridge statically links its resolved Rust dependency graph from
`native/skotiq_native/Cargo.lock`. The release gate runs the repository's
license policy across all targets. Its allowed set is:

- MIT, Apache-2.0, Apache-2.0 WITH LLVM-exception
- BSD-2-Clause, BSD-3-Clause, ISC, 0BSD, Zlib
- Unicode-DFS-2016, Unicode-3.0, CC0-1.0
- MPL-2.0, OpenSSL, BSL-1.0

Representative direct dependencies include Flutter Rust Bridge (MIT or
Apache-2.0), Tokio (MIT), Serde (MIT or Apache-2.0), image (MIT or
Apache-2.0), wgpu (MIT or Apache-2.0), rusb (MIT), Reqwest (MIT or
Apache-2.0), Chrono (MIT or Apache-2.0), Rayon (MIT or Apache-2.0), and
Quick-XML (MIT). Exact versions and transitive dependencies are recorded in
the shipped source tag's Cargo lockfile.

## Flutter, Dart, plugins, fonts, and icons

Flutter generates an application notice bundle from every resolved package.
It covers the exact versions pinned by the app and workspace lockfiles,
including Flutter, Dart packages, platform plugins, `flutter_webrtc`,
`mobile_scanner`, Lucide icons, Hanken Grotesk, and Spline Sans Mono. The
Lucide ISC/MIT notice is also tracked at `third_party/lucide_icons/LICENSE`;
the font OFL-1.1 texts are tracked beside the fonts under
`packages/skotiq_ui/assets/fonts/`.

## Bundled astronomical catalog data

The desktop bundle includes transformed OpenNGC and HYG catalog packs. Both
datasets are licensed CC BY-SA 4.0. The bundled
`assets/planetarium/catalogs/README.md` provides the required attribution,
source links, transformation description, and license link. The transformed
catalog packs themselves are offered under CC BY-SA 4.0; that data license
does not replace the license for Skotiq's program code.

No JPL ephemeris kernel is bundled or redistributed. Sun and moon positions
are computed from the Astronomical Almanac low-precision series in
`native/skotiq_native/sequencer/src/scheduling/ephemeris.rs`.

## Vendor device SDKs are not redistributed

The official 5.0.0 workflow does **not** contain the gitignored `SDKs/`
directory and does not copy vendor camera or mount SDK binaries into any
artifact. Native vendor paths work only when the user has installed a
compatible vendor library or driver. ZWO, QHY, Player One, SVBony, Atik, FLI,
Moravian, ToupTek-family, SBIG, Fujifilm, and SkyWatcher SDK binaries must not
be added to an official artifact until their redistribution terms are
confirmed and their required notices are included.

## External programs not redistributed

ASTAP, astrometry.net, PHD2, INDI servers/drivers, ASCOM Platform, Alpaca
servers, and device drivers are user-installed external programs. Skotiq
invokes or communicates with them but does not include them in the 5.0.0
artifacts.

## Reproducing the audit

Use the release source tag and lockfiles as the authority:

```bash
cd native/skotiq_native
cargo deny check licenses
cargo metadata --locked --format-version 1

cd ../../apps/desktop
flutter pub deps
cd ../mobile
flutter pub deps
```

This document records the project's redistribution review and is not legal
advice.
