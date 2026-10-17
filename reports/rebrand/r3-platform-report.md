# r3-platform rebrand report

Area: app identity, installers, CI, scripts, packaging, and first-launch
migration of existing installs. Worktree started at `0f14e3843` on branch
`rebrand/skotiq-r3-platform` (verified with `git rev-parse HEAD`; tree was
clean).

Conventions in this report: the pre-rename product is "the old name" or
"pre-rename". Where a literal old path matters it is written masked as
`<old>` (e.g. `com.example.<old>_desktop`) so this file itself stays clean
of the old name — the only repo files allowed to spell it are the
allowlisted migration file and its test
(`tools/rebrand/legacy_allowlist.txt`).

## Platform identity

- Windows: `BINARY_NAME` is now `skotiq` (shipped exe `skotiq.exe`);
  `Runner.rc` CompanyName/FileDescription/InternalName/OriginalFilename/
  ProductName/copyright are Skotiq; window title in `main.cpp` is "Skotiq".
  App-support now resolves to `%APPDATA%\Skotiq\Skotiq` (path_provider
  builds `<CompanyName>\<ProductName>` from `Runner.rc`; the old values
  were `com.example` + `<old>_desktop`).
- Linux: `BINARY_NAME` `skotiq`, `APPLICATION_ID` `com.skotiq.desktop`,
  GTK window/header title "Skotiq", bundled icons already `skotiq_*.png`.
  No `.desktop` file exists in the repo (the release artifact is a raw
  tar.gz bundle with no desktop-integration step) — noted, nothing to
  convert.
- macOS: `PRODUCT_NAME` `Skotiq`, bundle id `com.skotiq.desktop`, app
  references/test host/scheme names now `Skotiq.app`, copyright Skotiq.
- Android: verified — `android:label` Skotiq, `namespace`/`applicationId`
  `com.skotiq.mobile`, Kotlin sources already under
  `kotlin/com/skotiq/mobile/` with matching `package` declarations, update
  FileProvider authority is `${applicationId}.updateprovider`, critical
  notification channel id `skotiq_critical`, deep-link scheme `skotiq`.
- iOS: verified — display name "Skotiq Mobile", bundle id
  `com.skotiq.mobile` (+ `...RunnerTests`), app group
  `group.com.skotiq.app` in both entitlements and the Swift extension
  sources, `_skotiq._tcp` in the mDNS declaration. The three extension
  targets (AppIntents/LiveActivity/WatchComplication) are not yet wired
  into the pbxproj at all — they are standalone sources whose Info.plists
  use `$(PRODUCT_BUNDLE_IDENTIFIER)`, so nothing to convert there.
- Web: `manifest.json` name/short_name and `index.html` title/meta are
  Skotiq; `web_run_watch` manifest already read "Skotiq Run-Watch".

## CI, release and packaging

- `linux-release-build.yml` and `release.yml`: the Flutter binary is
  `skotiq`, which collided with the existing launcher wrapper of the same
  name. Resolution: packaging now moves the real binary to `skotiq.bin`
  and the `skotiq` wrapper execs it (`LD_LIBRARY_PATH` +
  `GDK_BACKEND=x11`, unchanged semantics). The glibc-floor audit scans
  `skotiq.bin` and `lib/*.so`.
- `release.yml`/`windows-release-build.yml`: required Windows executable
  is `skotiq.exe`; release assets already used `skotiq-<ver>-<platform>`
  naming.
- `installer.iss`: exe `skotiq.exe`, version synced to `version.yaml`
  (7.1.0), and `DefaultDirName` changed to `{localappdata}\Programs\Skotiq`
  with `PrivilegesRequired=lowest` to match the documented
  `%LOCALAPPDATA%\Programs\Skotiq` install location.
- Appliance packaging: `skotiq-headless.service`, `install.sh`,
  `Dockerfile`, `build_pi_image.sh` now exec/verify `skotiq` and point the
  doc URL at `github.com/Scdouglas1999/Skotiq`.
- mDNS: `_skotiq._tcp` is consistent between desktop advertisement
  (`packages/skotiq_remote_protocol/lib/src/discovery/mdns_registration.dart:50`,
  r2-owned), the Avahi service file
  (`packaging/appliance/avahi/skotiq.service:37`), and the client-side
  discovery browser
  (`packages/skotiq_remote_protocol/lib/src/enhanced_discovery.dart:847`,
  r2-owned). No change needed — all three already agree.
- Repo URL: only `packaging/appliance/systemd/skotiq-headless.service`
  carried a repo URL; now `github.com/Scdouglas1999/Skotiq`. Workflows use
  `${GITHUB_REPOSITORY}` (no literal URL to fix).
- Android signing `CN`: the only CN in the tree is the CI-generated
  *debug* keystore (`CN=Android Debug,O=Android,C=US` in
  `release.yml:132`). That is AGP's canonical debug identity, not a
  product name — left as is. The production upload keystore is a GitHub
  secret and its CN is outside the repo.
- Secrets renamed: **none** — no secret name in any workflow contains the
  old product name; `ANDROID_KEYSTORE_*`, `WINDOWS_SIGNING_CERT_*` and
  `SKOTIQ_UPDATE_*` are already named for Skotiq or are product-neutral.

## Scripts and tools

Updated every reference to the old executable name across `scripts/`
(`build_native.sh`, `capture-readme-screenshots.ps1`, `copy_macos_lib.sh`,
`deploy_imaging.bat`, `docker_build_linux.sh`,
`stage_windows_release.ps1`, `start_headless.bat`), `tools/harness/`
(sim-night scripts, `soak.py`), `tools/ota_rehearsal/` (bundle launcher
now mirrors the `skotiq` wrapper + `skotiq.bin` binary layout, and the
"broken build" fixture breaks `skotiq.bin`), `tools/production/` (smoke
tests and the Windows bundle audit now check `skotiq.exe`/`skotiq`),
`tools/ui_audit/drive_linux.py`, `tools/skotiq_relay/README.md`, and the
launch docs in `main_headless.dart`. `melos.yaml` scopes and
`package:skotiq_desktop` imports were left: `skotiq_desktop` is the Dart
package name of `apps/desktop` (parallel to `skotiq_mobile`) and not the
old product name.

## Legacy install migration

New file `packages/skotiq_core/lib/src/utils/legacy_install_migration.dart`
(allowlisted in `tools/rebrand/legacy_allowlist.txt` together with its
test — the only two files in the repo that may spell the old name). All
old paths below were read out of snapshot `663267b75`, not guessed:

- `migrateLegacyInstall(...)` runs in `prepareDesktopLogDirectory`
  (`apps/desktop/lib/desktop_logging_init.dart`), the single funnel every
  desktop launch mode passes through before the bridge, database and log
  files open. It runs before `configureSkotiqDataDirectory` publishes the
  root into the process environment, and every step converts failure into
  a logged warning so it can never block startup.
- Old app-support roots moved/merged into the resolved new root:
  - Linux `~/.local/share/com.example.<old>_desktop` (the old
    APPLICATION_ID) plus the `<old>_desktop` executable-name fallback
    that path_provider checks;
  - macOS `~/Library/Application Support/com.example.<old>Desktop`;
  - Windows `%APPDATA%\com.example\<old>_desktop` (old Runner.rc
    CompanyName/ProductName). Windows secure storage is an encrypted JSON
    file inside this root, so it rides the move; shared_preferences on
    Linux and Windows is `shared_preferences.json` inside the same root.
  - When the new root already exists the move becomes a non-destructive
    merge: collisions keep BOTH files (warning logged), never overwrite.
- Inner renames under data/documents/database roots: every old-name
  basename occurrence (`<old>` -> `skotiq`, `<Old>` -> `Skotiq`,
  case-sensitive), so `<old>.db`, `<old>*.log`, `<old>-corrupt-*-<old>.db`,
  `<Old>/` and any other product-generated name land on the same name a
  fresh install would write. Collisions land as `<target>.legacy` so
  nothing is lost.
- Documents subtree `<Old>/` -> `Skotiq/` inside the resolved documents
  root (database, pairing.db, profiles). The inner-rename pass only scans
  the app's own `Skotiq/` subtree — never the whole Documents folder
  (a real box with ~2M files under Documents made this necessary).
- Pinned `SKOTIQ_DATABASE_DIR` gets the same inner rename pass (covers the
  appliance's `/var/lib/skotiq/database`).
- Relocated roots (`SKOTIQ_DATA_DIR` set): when the new root's basename is
  `skotiq` (e.g. `/var/lib/skotiq`), a same-named sibling under the old
  product name is folded in non-destructively.
- macOS NSUserDefaults plist renamed
  `~/Library/Preferences/<old-bundle-id>.plist` -> `<new-bundle-id>.plist`;
  Linux/macOS cache dirs moved.
- Appliance leftovers on Linux: `headless.env` under the old conf dir is
  translated (env-var prefix + the three appliance path prefixes) when the
  process can write the conf dir — in practice only a root launch, so the
  warning text spells out the exact sudo/sed commands. A leftover old
  systemd unit file and leftover appliance state dir produce warnings with
  the commands to remove/merge them. The appliance pieces cannot be
  migrated by the unprivileged service account itself; they are
  deliberately warnings-first.
- Secure storage: `SecretsStore`'s key prefix changed from the old
  initials namespace to `skotiq.notif.v1.`; on first use it re-keys every
  `SecretField` from the old namespace (never clobbering an existing new
  key), which covers Linux/macOS keyring entries.
- Old `<OLD>_*` env vars are NOT honored — a set one produces a warning
  telling the operator the `SKOTIQ_*` names replaced it.
- Android: the old `applicationId` makes the old install a separate
  sandboxed package; no in-place migration is possible there (as required
  by the brief). iOS keeps the same app group (`group.com.skotiq.app`).
- Explicitly out of scope: absolute paths stored inside database rows
  (e.g. a saved capture directory) are user data; rewriting strings in
  SQLite during startup migration risks corrupting real installs.

## Verification log

Commands run so far (each as `cmd > log 2>&1; echo EXIT=$?`):

- `cd packages/skotiq_core && flutter analyze lib/src/utils/legacy_install_migration.dart lib/src/services/notification/secrets_store.dart test/utils/legacy_install_migration_test.dart` — EXIT=0 (after fixing a private-typedef-in-public-API lint, an undefined `entries` in `_mergeTree`, and an unused variable in the test).
- `cd packages/skotiq_core && flutter test --concurrency=4 test/utils/legacy_install_migration_test.dart > /tmp/migration_test.log 2>&1` — first run EXIT=1 (Windows fixture `createSync` without `recursive`); second run EXIT=0, 17/17 tests pass.
- `cd apps/desktop && flutter analyze lib/desktop_logging_init.dart lib/main_headless.dart` — EXIT=0.
- `cd apps/desktop && flutter test --concurrency=4 test/headless/desktop_log_directory_test.dart test/headless/host_checkpoint_directory_test.dart` — first run EXIT=1: the env-absent test reached `getApplicationDocumentsDirectory()`'s platform channel with no binding; fixed by making the documents-root resolution in `prepareDesktopLogDirectory` best-effort. Second run EXIT=0, 6/6 pass.
- `cd packages/skotiq_core && flutter test --concurrency=4 test/services/notification/secrets_store_test.dart` — EXIT=0, 8/8 pass.
- `python3 tools/rebrand/rebrand.py --check` — EXIT=0, `0 leftover mention(s)` outside the allowlist.
- `python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]" .github/workflows/*.yml` — EXIT=0.
- `cd native/skotiq_native && cargo build -j 8 --release` — EXIT=0 (~3m45s; produces `libskotiq_bridge.so` and `updater`).
- `cd apps/desktop && flutter build linux --release` — first run EXIT=2 raced the in-flight cargo build (CMake could not find `libskotiq_bridge.so` yet); re-run after cargo finished EXIT=0; bundle contains `skotiq` + `lib/libskotiq_bridge.so`.
- `xvfb-run -a timeout 60s env SKOTIQ_HEADLESS=1 SKOTIQ_DATABASE_DIR=$TMPDIR/launch-db LIBGL_ALWAYS_SOFTWARE=1 ./skotiq --headless` — first run EXIT=124: stalled before the data-directory line. Cause: the migration's inner-rename pass walked the whole resolved Documents root (2,194,952 files on this box). Fixed by scanning only `<documents>/Skotiq`; also broadened the rename rule to replace every old-name occurrence in a basename, after seeing `<old>-corrupt-<ts>-<old>.db` keep its embedded suffix.
- Same launch re-run with `timeout 120s` — EXIT=124 (expected: the headless service runs until killed). The run performed a REAL migration on this box — `<Documents>/<Old>` -> `<Documents>/Skotiq` plus inner renames of `<old>.db`, `<old>-preRestore-*.db`, `<old>-premigration-*.db`, `<old>-corrupt-*` and `<old>_autosave_*.nsbackup` — then logged `[OK] Native bridge initialized`, `[OK] Data directory: ~/.local/share/skotiq`, `[OK] Profile and settings storage initialized` and served the headless API on `http://127.0.0.1:8080` until the timeout.
- `cd packages/skotiq_core && flutter test --concurrency=4 test/utils/legacy_install_migration_test.dart` (post-fix) — EXIT=0, 17/17 pass; `flutter analyze lib/src/utils/legacy_install_migration.dart` — EXIT=0, no issues.
- Android: `flutter build apk --debug` not run — no Android SDK on this machine (`ANDROID_HOME` unset, no `~/Android/Sdk`).

## Residual items for other agents

- `native/skotiq_native` (r1): the Rust OTA updater's `APP_EXECUTABLE`
  constant names the relaunch binary per platform; it must become
  `skotiq(.exe)` — and on Linux `skotiq.bin`, since `skotiq` is now the
  launcher wrapper that sets `LD_LIBRARY_PATH`/`GDK_BACKEND`.
- `packages/skotiq_updater` (r2): tests and a doc comment in
  `update_service.dart` name `skotiq_desktop(.exe)` as the shipped binary;
  they are fixtures so nothing breaks, but they should be updated to read
  `skotiq(.exe)`/`skotiq.bin` for accuracy.
- `apps/mobile_e2e` and `melos.yaml`: `skotiq_desktop` remains the pubspec
  package name for `apps/desktop` — intentional, parallels
  `skotiq_mobile`.

## Known limitations

- Windows/macOS packaging could not be exercised on this Linux box;
  the Inno Setup script and macOS xcconfigs were updated by inspection.
- Android APK build not attempted (no SDK — see verification log).
- The migration cannot rewrite absolute paths stored inside database rows
  (by design — see above); settings or sequences that captured
  `<old>`-era paths keep working only if the user repoints them.
