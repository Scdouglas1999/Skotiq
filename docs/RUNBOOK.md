# Skotiq Operational Runbook

First-responder checklist for the five failures that ops/support hit most often.
Each scenario lists user-reported symptoms, the diagnostics that confirm root
cause, the fix, and how to verify recovery.

> **Audience.** Sysadmins, on-call support, and developers triaging field
> reports. Not an end-user guide; pair with
> [troubleshooting/common-issues.md](troubleshooting/common-issues.md) when a
> finding needs to be communicated back to the user.
>
> **Scope.** Skotiq desktop v2.5.x. Mobile-companion failures are
> out-of-scope.

## Log paths (canonical)

These paths are what `LoggingService.initialize()` uses. Flutter
`path_provider` builds the application-support folder from `CompanyName` and
`ProductName` in `Runner.rc` (Windows), `PRODUCT_BUNDLE_IDENTIFIER` (macOS) and
`APPLICATION_ID` (Linux), so a build with different values writes elsewhere.
Confirm the actual log directory by reading the
`Log directory: …` line that `LoggingService` writes on startup (see
`packages/skotiq_core/lib/src/services/logging_service.dart:119`).

| OS | Logs | Drift DB | Sequence checkpoint |
|---|---|---|---|
| Windows | `%APPDATA%\Skotiq\Skotiq\logs\` | `%USERPROFILE%\Documents\Skotiq\skotiq.db` | `%USERPROFILE%\Documents\Skotiq\profiles\skotiq_session.checkpoint` |
| macOS | `~/Library/Application Support/com.skotiq.desktop/logs/` | `~/Documents/Skotiq/skotiq.db` | `~/Documents/Skotiq/profiles/skotiq_session.checkpoint` |
| Linux | `~/.local/share/com.skotiq.desktop/logs/` | `~/Documents/Skotiq/skotiq.db` | `~/Documents/Skotiq/profiles/skotiq_session.checkpoint` |

> **Why two different roots?** Logs use `getApplicationSupportDirectory()`
> (`logging_service.dart:104`); the database and checkpoints use
> `getApplicationDocumentsDirectory()` (`database.dart:1619`,
> `desktop_logging_init.dart:35`). Both produce `~/Documents/Skotiq/` on
> macOS/Windows because the desktop bootstrap forces the `Skotiq/`
> subfolder explicitly.

---

## 1. Frozen startup

**Symptoms** (from user)
- "App opens to splash and never advances."
- "Window appears but stays grey/blank."
- "Clicked the icon, nothing happens, no error."
- "Splash flashes then closes."

**Diagnostic**

1. Pull the latest log from the OS-appropriate path above. Look at the tail —
   the bootstrap writes deterministic anchors so you can pinpoint the stall.

   ```powershell
   # Windows
   Get-Content "$env:APPDATA\Skotiq\logs\skotiq.log" -Tail 200
   ```

   ```bash
   # macOS
   tail -200 ~/Library/Application\ Support/Skotiq/logs/skotiq.log

   # Linux
   tail -200 ~/.local/share/com.skotiq.desktop/logs/skotiq.log
   ```

2. Grep for the bootstrap anchors. Each is logged by
   `desktop_logging_init.dart` / `desktop_app_bootstrap.dart` in order:

   | Pattern | Stage reached |
   |---|---|
   | `Native bridge initialized` | Rust FFI loaded |
   | `Logging service initialized` | `LoggingService` came up |
   | `Log directory:` | App data dir resolved + writable |
   | `Profile and settings storage initialized` | Native profile/settings DB opened |
   | `Database initialized` | Drift opened `skotiq.db` |
   | `Catalog manager initialized` | Catalog dir created and loaded |
   | `Headless mode running` / `runApp` | Main isolate handed off to UI |

   The **last anchor that appears** tells you where startup is stuck.

3. Bypass GUI startup with the headless entry. If headless boots, the failure
   is in the Flutter UI / window manager layer (GPU, font, plugin). If headless
   also hangs, the failure is below the UI (FFI, DB, drift migration).

   ```powershell
   # Windows — set the env var, then launch
   $env:SKOTIQ_HEADLESS = "1"
   & "C:\Program Files\Skotiq\skotiq.exe"
   ```

   ```bash
   # macOS / Linux
   SKOTIQ_HEADLESS=1 ./skotiq_desktop
   ```

   Or use the explicit flag the binary accepts (`main.dart:20`):

   ```powershell
   & "C:\Program Files\Skotiq\skotiq.exe" --headless
   ```

**Root cause matrix**

| Last log anchor | Likely cause | Evidence |
|---|---|---|
| _(no log file at all)_ | App data directory unwritable; antivirus blocked exe; missing VCRuntime | Confirm the folder exists and is writable; reinstall the VC++ redistributable |
| `Native bridge initialized` then silence | FRB hash mismatch or DLL load failure | Log will usually carry `Failed to lookup symbol` or `BAD_IMAGE` — see [FRB_TROUBLESHOOTING.md](FRB_TROUBLESHOOTING.md) |
| `Logging service initialized` then silence | Profile/settings storage path inaccessible (network drive, OneDrive sync conflict) | Move profile dir to a local path; relaunch |
| `Database initialized` missing after profile init | Drift migration loop or corrupt SQLite file | See scenario 4 + scenario "OTA rollback" below; integrity-check the DB |
| `Database initialized` succeeds but no `runApp` | UI-thread block: GPU shader compile, custom font load, window-manager init | Try `SKOTIQ_HEADLESS=1` — if that boots, capture a graphics-driver diagnostic next launch |
| Repeated `Failed to initialize driver` for one device | A vendor SDK is hanging during early discovery | Disconnect the offending USB device, relaunch, then reconnect after the UI is up |

**Fix**

A. **Settings-only corruption** — back up and remove the Drift DB:

```powershell
# Windows
$db = "$env:USERPROFILE\Documents\Skotiq\skotiq.db"
Move-Item $db "$db.bak.$(Get-Date -Format yyyyMMddHHmmss)"
```

```bash
# macOS / Linux
mv ~/Documents/Skotiq/skotiq.db \
   ~/Documents/Skotiq/skotiq.db.bak.$(date +%Y%m%d%H%M%S)
```

The next launch creates a fresh DB with default settings (see
`database.dart:108` `MigrationStrategy.onCreate`). The user loses non-default
settings; targets/profiles/sessions are gone unless restored from backup.

B. **Driver hang on startup** — launch headless to skip the auto-discover that
the GUI runs, then connect devices one-by-one from the UI once it boots.

C. **Native bridge load failure** — confirm `skotiq_bridge.dll` (Windows) /
`libskotiq_bridge.dylib` (macOS) / `libskotiq_bridge.so` (Linux) is
present beside the executable; reinstall if missing.

**Verification**

- Relaunch. Watch the log file as it streams (PowerShell `Get-Content -Wait`,
  Unix `tail -f`). All eight bootstrap anchors should appear inside ~5 s.
- If headless was the only path that booted, do not run a sequence until the
  GUI launches cleanly — checkpoint resume is GUI-mediated.

**Escalation**

File an issue at https://github.com/Scdouglas1999/Skotiq/issues with:

1. Full log file (`$env:APPDATA\Skotiq\logs\skotiq.log`).
2. Last successful launch date.
3. Whether `SKOTIQ_HEADLESS=1` boots.
4. Output of `Get-ChildItem "$env:APPDATA\Skotiq" -Recurse | Measure-Object`
   so we can see whether the data dir is even being written to.

---

## 2. Plate-solve fails

**Symptoms**
- "Plate solve takes >60 s and times out."
- "Solver returns 'No WCS file created'."
- "ASTAP exits non-zero / can't find solution."
- "Centering fails because plate solve never succeeds."

**Diagnostic**

1. Confirm the configured ASTAP path exists. The default path Skotiq
   suggests when picking the executable is
   (`packages/skotiq_app/lib/screens/settings/widgets/plate_solving_settings.dart:50`):

   | OS | Default ASTAP install dir |
   |---|---|
   | Windows | `C:\Program Files\astap\astap.exe` |
   | macOS | `/Applications/ASTAP.app/Contents/MacOS/astap` |
   | Linux | `/usr/bin/astap` |

   ```powershell
   # Windows
   Test-Path 'C:\Program Files\astap\astap.exe'
   ```

   ```bash
   # macOS
   ls -l /Applications/ASTAP.app/Contents/MacOS/astap

   # Linux
   which astap && astap -h | head -3
   ```

2. Reproduce the solver invocation outside Skotiq. Take a FITS the app
   failed on and run ASTAP with the same arguments Skotiq builds
   (`plate_solve_service.dart:114-126`):

   ```powershell
   # Windows — replace <fits> and <ra-hours>/<dec> with values from your session
   & 'C:\Program Files\astap\astap.exe' `
     -f <fits> `
     -r 30 `
     -ra (15 * <ra-hours>) `
     -spd (90 + <dec>)
   ```

   ```bash
   # macOS / Linux — same arguments
   astap -f <fits> -r 30 -ra $(echo "15 * <ra-hours>" | bc) -spd $(echo "90 + <dec>" | bc)
   ```

   ASTAP writes a `.wcs` next to the input on success. Skotiq reads that
   file (`plate_solve_service.dart:149-152`).

3. Grep the Skotiq log for the solver output that the service logs:

   ```powershell
   Select-String "ASTAP failed" "$env:APPDATA\Skotiq\logs\skotiq.log"
   Select-String "Plate solve timed out" "$env:APPDATA\Skotiq\logs\skotiq.log"
   Select-String "No WCS file created" "$env:APPDATA\Skotiq\logs\skotiq.log"
   ```

> **Planned for v2.6.** A dedicated `--diagnostic plate-solve <fits>` CLI flag
> is on the roadmap but is not implemented in
> v2.5.x. Use the manual ASTAP invocation above until it lands.

**Root cause matrix**

| Evidence | Cause |
|---|---|
| `Test-Path` returns false / executable missing | ASTAP not installed, or installed to a non-default path the user never set in Settings |
| ASTAP exits non-zero with "No star catalog" | Star catalog (D50, V17, H18) not installed in ASTAP's lookup dir |
| ASTAP returns "No solution" but standalone manual run solves | Search radius (`searchRadius`) too small; RA/Dec hint wrong (mount sync drift); pixel scale hint off |
| `Plate solve timed out` after `config.timeoutSeconds` | Image too large for solver; solver hanging on disk I/O; PC under heavy load |
| Solver works on saved FITS, fails on live capture | Live image still being written when solve fires (race) — check that capture finalised before solve |
| `Error: <FileSystemException>` in log | Path with non-ASCII chars; ASTAP < 2020 cannot read those on Windows |

**Fix**

A. **Wrong ASTAP path** — open Settings → Plate Solving → "ASTAP executable",
pick the actual install dir. Setting persists via
`appSettingsProvider.setAstapPath` (`plate_solving_settings.dart:72`).

B. **Missing star catalog** — install ASTAP's V17 (or H18 for narrow fields)
catalog package from <https://www.hnsky.org/astap.htm> into ASTAP's program
directory and restart Skotiq.

C. **Wrong hint** — clear the mount sync, slew to a bright reference target,
sync, and retry. If centering is firing the solve, increase the centering
tolerance to give the loop more headroom.

D. **Timeout** — raise `plate_solve_timeout_secs` in Settings or pre-bin the
image. The Dart-side timeout is enforced at
`plate_solve_service.dart:132`.

**Verification**

- Capture a frame, hit "Solve" manually from the imaging screen, watch the
  log:

  ```
  ... INFO  [PlateSolveService] Solve succeeded ra=... dec=... rotation=...
  ```

- Confirm a `.wcs` file appears next to the FITS in the capture dir.

**Escalation**

Attach to the issue:

1. The failing FITS file (or a link to it; FITS can be large).
2. The Skotiq log slice that brackets the failed solve.
3. The exact ASTAP version (`astap --version`).
4. Whether the same FITS solves standalone with the manual command above.

Cross-link: [troubleshooting/common-issues.md#plate-solving-fails](troubleshooting/common-issues.md#plate-solving-fails).

---

## 3. OTA rollback

**Symptoms**
- "Updated to 2.5.x; app won't start now."
- "Crash immediately after update."
- "Different version reported than what installer says I installed."
- "Update applied OK but a critical feature is broken in this build."

**Diagnostic**

1. Determine what the installer thinks is installed. The updater writes a
   manifest at the install root after success
   (`native/skotiq_native/updater/src/main.rs:43`):

   ```powershell
   # Windows
   Get-Content "C:\Program Files\Skotiq\post_install_hashes.json" |
     ConvertFrom-Json | Select-Object -ExpandProperty written_at
   ```

   ```bash
   # Linux / macOS — adjust install root
   cat /opt/skotiq/post_install_hashes.json | jq .written_at
   ```

   If `post_install_hashes.json` is **missing**, the updater either never
   finished or already rolled back automatically (the updater removes it on
   failure — see `main.rs:282-317` `finalize_failure`).

2. Check for in-flight backup artifacts. The updater performs a
   **move-then-copy** apply: each replaced file is renamed to
   `<file>.skotiq-bak` before being overwritten (`main.rs:36-38`). On
   failure, it walks the rollback log and renames the `.bak` back. If the
   process was killed mid-apply, those `.bak` files survive.

   ```powershell
   # Windows
   Get-ChildItem 'C:\Program Files\Skotiq' -Recurse -Filter '*.skotiq-bak'
   ```

   ```bash
   find /opt/skotiq -name '*.skotiq-bak' -type f
   ```

3. Check for the rollback log. If it exists, the updater either crashed mid-
   apply or failed verification. Inspect it to learn which files were
   touched (`main.rs:50, 100-112`):

   ```powershell
   # The backup directory is whatever was passed via --backup-dir at update time.
   # By convention this is %LOCALAPPDATA%\Skotiq\updates\backup\ for installer
   # builds; check the update-manager log entries for the exact path used.
   Get-Content "$env:LOCALAPPDATA\Skotiq\updates\backup\rollback_log.json"
   ```

4. Pull the updater's last error log. The updater writes a stable file path
   even when the parent app is gone (`main.rs:134`):

   ```powershell
   Get-Content "$env:TEMP\skotiq_update_error.log"
   ```

   ```bash
   cat /tmp/skotiq_update_error.log
   ```

**Root cause matrix**

| Evidence | Cause | Action |
|---|---|---|
| `.skotiq-bak` files remain in install dir | Updater was killed before commit / rollback step | Manual rollback (below) |
| `skotiq_update_error.log` shows "hash mismatch" | Network corruption during download; the updater already auto-rolled back | Re-download installer; verify SHA-256 against release page |
| `rollback_log.json` exists; `skotiq_update_error.log` shows "Rollback also failed" | Disk-full or permission failure during rollback | Manual rollback + escalate |
| Update finished, app crashes on launch | New version has a bug, not an updater issue | In-app rollback via `POST /api/system/update/rollback` while the restore point survives (fix B); else reinstall previous installer |
| `post_install_hashes.json` newer than expected, version banner unchanged | Stale Flutter bundle copy (rare; usually FRB hash mismatch) | Reinstall current installer |

**Fix**

> **In-app rollback.** The updater now supports a dedicated `--rollback`
> flag (`native/skotiq_native/updater/src/main.rs`, `run_rollback`). The
> preferred path is to drive it from the app: `POST /api/system/update/rollback`
> (admin scope) or the desktop UpdateService, which relaunches the updater in
> `--rollback` mode to restore the previous version from the retained restore
> point (`updates/backup/rollback_log.json` + `restore_point/`). This works
> only while the restore point exists — after an apply and before the next
> launch confirms the new build healthy (the boot verifier then reclaims the
> backup dir). When no restore point remains, the endpoint returns **501**;
> use the manual recovery below.

A. **Manual rollback when `.skotiq-bak` files exist** — close Skotiq
completely, then for each file:

```powershell
# Windows — replace the new file with its backup, then drop the .bak suffix.
$root = 'C:\Program Files\Skotiq'
Get-ChildItem $root -Recurse -Filter '*.skotiq-bak' | ForEach-Object {
    $orig = $_.FullName -replace '\.skotiq-bak$', ''
    if (Test-Path $orig) { Remove-Item $orig }
    Rename-Item $_.FullName $orig
}
# Then remove the half-written manifests so the boot-verify path doesn't object.
Remove-Item "$root\post_install_hashes.json" -ErrorAction SilentlyContinue
Remove-Item "$root\rollback_log.json"        -ErrorAction SilentlyContinue
```

```bash
# Linux / macOS
root=/opt/skotiq
find "$root" -name '*.skotiq-bak' -type f | while read bak; do
    orig="${bak%.skotiq-bak}"
    rm -f "$orig"
    mv "$bak" "$orig"
done
rm -f "$root/post_install_hashes.json" "$root/rollback_log.json"
```

B. **In-app rollback after a healthy apply** — a successful apply no longer
deletes the originals; it parks them under
`updates/backup/restore_point/` next to `rollback_log.json`. While that
restore point survives (until the next launch confirms the new build
healthy), trigger a rollback via `POST /api/system/update/rollback` or the
desktop UpdateService. If the restore point was already reclaimed (the new
build booted cleanly), reinstall the previous version using its installer —
Skotiq does not retain a copy of the prior binary tree past that point.

C. **Verify before relaunch** — recompute the entry-point hashes against the
manifest if you still have it; the boot-time `verifyPendingInstall` re-hashes
on first launch and refuses to start on mismatch (`main.rs:40-43`).

**Verification**

- Launch Skotiq. The version banner in the title bar / `/api/info` should
  match the version you rolled back to.
- `Get-ChildItem` (or `find`) should report zero `.skotiq-bak` files
  remaining.

**Escalation**

Attach to the issue:

1. The `skotiq_update_error.log` from `$env:TEMP` / `/tmp`.
2. `rollback_log.json` (if present) — it lists exactly which files the updater
   touched.
3. Output of `Get-ChildItem -Recurse | Where-Object Length` so we can compare
   binary sizes to the release manifest.

---

## 4. Sequence won't resume

**Symptoms**
- "Checkpoint exists but sequence won't resume."
- "Resume dialog appears, click Resume, executor errors out."
- "Resumed sequence runs from start instead of where it stopped."
- "App says 'checkpoint version mismatch'."

**Diagnostic**

1. Confirm the checkpoint file exists and is readable. The path resolves from
   `getApplicationDocumentsDirectory()` via `initializeCheckpoints()`
   (`sequence_executor.dart:1339-1342`); the filename is fixed
   (`native/skotiq_native/sequencer/src/checkpoint.rs:339-340`):

   ```powershell
   # Windows
   $cp = "$env:USERPROFILE\Documents\Skotiq\profiles\skotiq_session.checkpoint"
   Test-Path $cp
   Get-Item $cp | Select-Object FullName, Length, LastWriteTime
   ```

   ```bash
   # macOS / Linux
   cp=~/Documents/Skotiq/profiles/skotiq_session.checkpoint
   ls -la "$cp"
   ```

2. Inspect the checkpoint. It is plain JSON written with
   `serde_json::to_string_pretty` (`checkpoint.rs:383`):

   ```powershell
   Get-Content $cp | ConvertFrom-Json | Select-Object version, sequence_id, current_node_id
   ```

   ```bash
   jq '{version, sequence_id, current_node_id}' "$cp"
   ```

3. Compare the `version` field against the on-disk Rust constant. The
   sequencer rejects checkpoints with `version > CHECKPOINT_VERSION` outright
   (`checkpoint.rs:450-456`) and rejects pre-trigger-state checkpoints with
   `version < CHECKPOINT_VERSION && trigger_state.is_none()`
   (`checkpoint.rs:459`).

   | Constant | Value (v2.5.x) | File:line |
   |---|---|---|
   | `CHECKPOINT_VERSION` | `2` | `native/skotiq_native/sequencer/src/checkpoint.rs:19` |
   | Drift `schemaVersion` | `28` | `packages/skotiq_core/lib/src/database/database.dart:103` |

   > **Why both matter.** The checkpoint file is owned by Rust and uses its
   > own version. The Dart side stores sequence definitions, target lists, and
   > equipment profiles in Drift — if the Drift schema rolled back below 28,
   > `sequence_id` references in the checkpoint may dangle. Treat a sequence
   > resume failure as suspect on either side.

4. Look at the executor log near the resume attempt:

   ```powershell
   Select-String "Checkpoint|CHECKPOINT|trigger_state|resume" `
                 "$env:APPDATA\Skotiq\logs\skotiq.log" -Context 0,3
   ```

5. Check the backup. `CheckpointManager` keeps `.bak` next to the primary; on
   primary failure it falls back to backup and self-heals
   (`checkpoint.rs:421-433`):

   ```powershell
   Test-Path "$cp.bak"
   ```

**Root cause matrix**

| Evidence | Cause |
|---|---|
| File missing entirely | Sequence never reached the 30-second streaming checkpoint cadence (`executor.rs:1268`); nothing to resume |
| `version > 2` in JSON | User downgraded; new checkpoint format unreadable by this binary |
| `version < 2 && trigger_state == null` | Pre-v2 checkpoint without trigger state; executor refuses to resume to avoid losing guiding/dither/meridian state |
| Primary fails to parse, backup also corrupt | Disk error mid-write; both files truncated |
| `sequence_id` in checkpoint not in Drift `sequences` table | Drift DB was wiped (scenario 1 fix A) or migration deleted the sequence row |
| Resume hangs at "restoring trigger state" | Trigger snapshot references a now-disconnected device (camera unplugged) |

**Fix**

A. **Stale / incompatible checkpoint** — back it up and clear it. The
sequence has to be restarted from the top, but the rest of the app stays
healthy:

```powershell
# Windows
$cp = "$env:USERPROFILE\Documents\Skotiq\profiles\skotiq_session.checkpoint"
Move-Item $cp "$cp.disabled.$(Get-Date -Format yyyyMMddHHmmss)"
Move-Item "$cp.bak" "$cp.bak.disabled.$(Get-Date -Format yyyyMMddHHmmss)" -ErrorAction SilentlyContinue
```

```bash
# macOS / Linux
cp=~/Documents/Skotiq/profiles/skotiq_session.checkpoint
mv "$cp" "$cp.disabled.$(date +%Y%m%d%H%M%S)"
mv "$cp.bak" "$cp.bak.disabled.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
```

B. **Primary corrupt, backup good** — the executor auto-recovers on next load
(`checkpoint.rs:421-433`), no manual action needed. The log will print
`Recovered checkpoint from backup file`. If you don't see it, the backup is
also bad and you need fix A.

C. **Sequence_id dangling** — restore the Drift DB from a backup (scenario 1
fix A in reverse), or accept the loss and clear the checkpoint.

D. **Trigger-state references missing device** — reconnect the device before
clicking Resume. The executor blocks on the original device ID format
(`native:vendor:id`, `indi:host:port:device`, `ascom:prog_id`,
`alpaca:host:port:device_number`). Reconnecting via a different protocol
gives a different device ID and the resume will not match.

**Verification**

- Open the sequencer screen. The "Resume" affordance should clear; the
  sequence is selectable to run from scratch.
- If you took fix B (auto-recovery), the next sequence run should write a new
  `.checkpoint` + `.bak` within 30 seconds (`executor.rs:1268`); confirm both
  files appear with fresh `LastWriteTime`.

**Escalation**

Attach to the issue:

1. The corrupt `.checkpoint` and `.bak` (small, safe to share — they contain
   no credentials).
2. The slice of the log between `Started sequence` and the resume failure.
3. The output of `jq '{version, sequence_id, trigger_state | keys}' "$cp"`.

---

## 5. Headless unreachable

**Symptoms**
- "Web dashboard / mobile app can't connect."
- "Curl gets `Connection refused` from another machine."
- "Mobile auto-discovery never finds the server."
- "401 Unauthorized on every request."
- "Browser blocks request: CORS error."

**Diagnostic**

1. Confirm the server is up and what it thinks its config is.
   `/api/info` is intentionally public (`headless_api_server.dart:1067-1068`):

   ```powershell
   # From the imaging machine itself — public endpoint, no auth needed
   Invoke-RestMethod http://127.0.0.1:8080/api/info |
       Select-Object version, authenticationMode, authRequired
   ```

   ```bash
   curl -s http://127.0.0.1:8080/api/info |
       jq '{version, authenticationMode, authRequired}'
   ```

   `bindMode` is **not** in `/api/info`; it is returned by `/api/self-test`
   (`headless_api_server.dart:1483-1490`). That endpoint requires auth when
   tokens are configured:

   ```powershell
   Invoke-RestMethod `
     -Headers @{ Authorization = "Bearer $env:SKOTIQ_AUTH_TOKEN" } `
     http://127.0.0.1:8080/api/self-test |
     Select-Object -ExpandProperty server
   ```

2. Determine the bind mode. The server defaults to **loopback only**
   (`headless_api_server.dart:154`); LAN binding flips on when **any** auth
   token is configured or `--allow-unauthenticated-lan` is passed
   (`main_headless.dart:286-294`). `/api/self-test` exposes the decision under
   `server.bindMode`:

   | `bindMode` | What that means |
   |---|---|
   | `loopback` | `127.0.0.1` only. LAN clients **cannot** reach this server. |
   | `lan` | `0.0.0.0` (any IPv4). LAN clients can connect if firewall allows. |

3. If `bindMode` is `lan` but LAN still can't reach — it's a firewall or
   network problem. Verify the port is listening on the right interface:

   ```powershell
   # Windows
   Get-NetTCPConnection -LocalPort 8080 -State Listen |
       Select-Object LocalAddress, LocalPort
   # Expect: 0.0.0.0  8080 for lan mode; 127.0.0.1 8080 for loopback.
   ```

   ```bash
   ss -tlnp | grep :8080
   # Or: netstat -an | grep 8080
   ```

4. Test reachability from a second machine on the LAN:

   ```bash
   # From a phone/laptop on the same network
   curl -v http://<imaging-machine-lan-ip>:8080/api/info
   ```

5. Check the auth path. The Skotiq log records the auth banner at boot
   (`headless_api_server.dart:1485-1488`). The server enforces auth on
   every protected route; `/api/info` and `/api/pairing/*` are the only
   public exceptions (`headless_api_server.dart:1067-1072`). Pull recent
   `[AUTH]` lines:

   ```powershell
   Select-String "\[AUTH\]" "$env:APPDATA\Skotiq\logs\skotiq.log" |
       Select-Object -Last 20
   ```

6. WebSocket clients use a one-shot ticket flow, not a header. The browser
   cannot send `Authorization:` on the WS upgrade, so it must first POST
   `/api/ws/ticket` with its bearer and present `?ticket=<value>` on
   `/events`. Browsers blocked by this will show a
   missing-ticket 401 in the WS upgrade, not a CORS error.

**Bind-address matrix**

| Goal | Required configuration |
|---|---|
| Same-machine automation only | No flags. Server binds `127.0.0.1` automatically. |
| Authenticated LAN (recommended) | `--require-auth` (random token printed at boot) **or** `SKOTIQ_AUTH_TOKEN=…` / `--auth-token=…` |
| Scoped-token LAN | `SKOTIQ_VIEW_TOKEN` + `SKOTIQ_CONTROL_TOKEN`. Admin token covers everything; view-only is read-only. |
| Unauthenticated LAN (dev only) | `--allow-unauthenticated-lan` or `SKOTIQ_ALLOW_UNAUTHENTICATED_LAN=true`. **Do not use on a real LAN.** |
| Custom port | `--port=<n>` or `SKOTIQ_PORT=<n>` (default `8080`) |
| CORS allow-list for a browser dashboard | `--cors-origin=https://app.example.com` (repeat for multiple) or comma-separated `SKOTIQ_CORS_ORIGINS=` |

Source: `apps/desktop/lib/main_headless.dart:49-58, 226-280, 286-294`.

**Root cause matrix**

| Evidence | Cause | Fix |
|---|---|---|
| `/api/info` returns OK on `127.0.0.1` but `Connection refused` from LAN | Server is in loopback mode (no token configured) | Set `SKOTIQ_AUTH_TOKEN` or pass `--require-auth`, restart |
| `bindMode: lan` reported, but LAN client times out | Windows Firewall / `ufw` blocking the port | See [troubleshooting/firewall.md](troubleshooting/firewall.md); add inbound rule on TCP 8080 |
| Every authenticated request returns 401 | Wrong scope or expired pairing-issued token | Verify scope with `/api/info → authScopes`; rotate token; reissue from pairing dialog |
| Browser dashboard works, fetch from a third-party origin fails with CORS | Origin not in allow-list | Add `--cors-origin=<origin>`; restart |
| WS upgrade returns 401 / 426 | Browser sent no ticket; server only accepts `?ticket=` for WS | Re-pair the client (the pairing flow handles the ticket POST automatically) |
| Mobile auto-discovery silent | Server in loopback mode, so the UDP advertiser at port `45679` never starts (`main_headless.dart:344-358`) | Same fix as bind-mode loopback |
| `/api/info` itself hangs | Server thread starved; check for sequence-related deadlock | Stop the server, capture the log, file an issue |

**Fix**

A. **Loopback when LAN was wanted** — restart with auth:

```powershell
$env:SKOTIQ_AUTH_TOKEN = (New-Guid).Guid
& "C:\Program Files\Skotiq\skotiq.exe" --headless
```

```bash
export SKOTIQ_AUTH_TOKEN=$(uuidgen)
./skotiq_desktop --headless
```

The boot banner prints the LAN URL and the redacted token
(`main_headless.dart:401-410`).

B. **Firewall blocked** — see [troubleshooting/firewall.md](troubleshooting/firewall.md).
Add an inbound rule for TCP `$SKOTIQ_PORT` and (optional) UDP `45679` for
LAN discovery.

C. **CORS blocked** — pass `--cors-origin=` for each browser origin that
needs to call the API. `cors_policy.dart:13-50` rejects unknown origins by
omitting the CORS header entirely, which is what browser devtools surface as
a CORS error.

D. **Token-scope mismatch** — call `/api/info` and confirm the scopes:

```powershell
Invoke-RestMethod http://127.0.0.1:8080/api/info |
    Select-Object -ExpandProperty authScopes
```

If the client needs `control` (slew/expose/sequence) but only has a `view`
token, all writes will 401. Issue a `control` or `admin` token via the env
vars in [headless-secure-setup.md](headless-secure-setup.md) and restart.

**Verification**

Run the [headless-secure-setup.md](headless-secure-setup.md) verification
checklist:

1. `Invoke-RestMethod http://localhost:8080/api/info` returns the expected
   `version`, `authMode`, `bindMode`.
2. `Invoke-WebRequest http://localhost:8080/api/self-test` without a header
   returns 401 (when auth is required).
3. The same request **with** the bearer header returns 200 and a JSON body
   that includes `storagePaths`, `database`, and `server.bindMode`.
4. From a second LAN device:
   `curl -H "Authorization: Bearer $TOKEN" http://<host>:8080/api/self-test`
   returns 200.
5. Mobile client lists the server in auto-discovery within ~5 s of launch.

**Escalation**

Attach to the issue:

1. Output of `Invoke-RestMethod http://localhost:8080/api/info` (it is safe to
   share — no credentials are exposed).
2. `Get-NetTCPConnection -LocalPort 8080` / `ss -tlnp | grep 8080`.
3. The `[API]`, `[AUTH]`, and `[WS]` log slices that bracket the failed
   request.
4. The exact CORS origin the failing browser is sending (visible in DevTools
   → Network → request headers → `Origin:`).

---

## Appendix A — Bug-report bundle

When in doubt, run this to collect everything we ask for above:

```powershell
# Windows
$out = "$env:USERPROFILE\Desktop\skotiq-bundle-$(Get-Date -Format yyyyMMddHHmmss)"
New-Item -ItemType Directory -Path $out | Out-Null
Copy-Item "$env:APPDATA\Skotiq\logs\*"                $out -Recurse
Copy-Item "$env:USERPROFILE\Documents\Skotiq\profiles\skotiq_session.checkpoint" $out -ErrorAction SilentlyContinue
Copy-Item "$env:USERPROFILE\Documents\Skotiq\profiles\skotiq_session.checkpoint.bak" $out -ErrorAction SilentlyContinue
Copy-Item "$env:TEMP\skotiq_update_error.log"         $out -ErrorAction SilentlyContinue
Invoke-RestMethod http://127.0.0.1:8080/api/info | ConvertTo-Json -Depth 10 | Out-File "$out\api-info.json"
Compress-Archive "$out\*" "$out.zip"
```

```bash
# macOS / Linux
out=$HOME/skotiq-bundle-$(date +%Y%m%d%H%M%S)
mkdir -p "$out"
cp -r ~/Library/Application\ Support/Skotiq/logs/* "$out/" 2>/dev/null || \
    cp -r ~/.local/share/com.skotiq.desktop/logs/* "$out/" 2>/dev/null
cp ~/Documents/Skotiq/profiles/skotiq_session.checkpoint*     "$out/" 2>/dev/null
cp /tmp/skotiq_update_error.log                                   "$out/" 2>/dev/null
curl -s http://127.0.0.1:8080/api/info > "$out/api-info.json"
tar czf "$out.tar.gz" -C "$out" .
```

Open https://github.com/Scdouglas1999/Skotiq/issues and attach the
archive.

## Appendix B — See also

- [troubleshooting/common-issues.md](troubleshooting/common-issues.md) —
  user-facing troubleshooting (camera not detected, image quality, etc.).
- [headless-secure-setup.md](headless-secure-setup.md) — full reference for
  the headless server, scopes, and CORS.
- [troubleshooting/firewall.md](troubleshooting/firewall.md) — port + rule
  details for Windows Firewall, `ufw`, and macOS PF.
- [FRB_TROUBLESHOOTING.md](FRB_TROUBLESHOOTING.md) — DLL hash-mismatch and
  FFI codegen failures.
- [migration-backup-restore.md](migration-backup-restore.md) — what the Drift
  DB and profile-storage backup actually contains.
- [OTA_UPDATE_TESTING.md](OTA_UPDATE_TESTING.md) — what the updater does step
  by step (the source-of-truth for scenario 3).
