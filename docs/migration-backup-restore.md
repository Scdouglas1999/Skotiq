# Migration, Backup, and Restore Guide

Use this guide before upgrading Skotiq, moving a profile to another
computer, or restoring a headless imaging host.

Skotiq backups are JSON files with a `.skbackup` extension. The current
backup format is version `3.0`; backups in the older `2.x` formats still
restore.

## What a Backup Contains

A backup holds the whole database: application settings, equipment profiles,
and every other table (sequences and templates, targets, projects and
integration goals, imaging sessions and the captured-image records, calibration
libraries, science measurements, notes, run history, Darkroom recipes and
masters, and any table a later version adds). It leaves out only:

- a run's crash-recovery checkpoint (restored, it would offer to resume a run
  that never ran on this machine);
- the Darkroom job queue and its send log (a restored queued job would start
  by itself);
- the backup folder setting, which describes this machine's disks.

The list is `backupExcludedTables` in
`packages/skotiq_core/lib/src/services/backup_service/schema_tables.dart`.

Backups do not include files outside the database:

- Captured image files and Darkroom masters on disk
- Logs, cached thumbnails, plate-solve indexes, survey images, or downloaded
  catalogs
- Native driver installers, ASCOM/INDI/Alpaca server configuration, PHD2
  profiles, OS permissions, firewall rules, or udev rules

Copy those external files and driver profiles separately before replacing a
machine or reinstalling the operating system.

## Before You Upgrade

1. Open Skotiq on the existing install.
2. Go to Settings > Backup & Restore.
3. Select Create Backup.
4. Store the `.skbackup` file outside the Skotiq data directory, such as on
   another disk or cloud-synced folder.
5. Copy captured images, PHD2 profiles, plate-solve indexes, and driver-specific
   configuration separately.
6. Shut down Skotiq cleanly before replacing binaries or moving the profile.

For release-candidate validation, also keep a copy of the entire old profile or
database directory. Automated migration tests are useful, but they do not replace
a manual upgrade from a real older profile.

## Restore on the Same Computer

1. Install and launch the target Skotiq version.
2. Go to Settings > Backup & Restore.
3. Select Import Backup, or the restore button of a backup in the list.
4. Choose how to restore it (see "Merge and Replace" below) and confirm.
5. A merge is done when the progress bar ends; restart Skotiq before the next
   run so every screen reads the changed database. A replace takes effect when
   Skotiq next starts: press Restart now, or Cancel replace to keep the
   current database.
6. Verify the equipment profile, saved targets, and sequence library before
   connecting hardware.

## Restore to a Remote or Headless Host

When the desktop UI is connected to a `NetworkBackend`, the Backup & Restore
screen manages files stored on the connected Skotiq host.

Available remote operations are backed by these headless routes:

- `GET /api/backup/list`
- `POST /api/backup/create`
- `POST /api/backup/restore`
- `GET /api/backup/restore-state`
- `POST /api/backup/replace/cancel`
- `POST /api/backup/replace/acknowledge`
- `POST /api/backup/auto-save`
- `POST /api/backup/upload-restore`
- `GET /api/backup/<id>/metadata`
- `GET /api/backup/<id>/download`
- `DELETE /api/backup/<id>`

Remote restore requires an admin-scoped token. Uploaded restore files are limited
to 256 MiB and must use a `.skbackup` or `.json` filename. The server sanitizes
the uploaded filename and stores it in the host backup directory before restore.

Recommended remote migration flow:

1. Start the headless host with authentication enabled.
2. Run `/api/self-test` and confirm the reported auth mode, storage paths, route
   count, and platform capabilities.
3. In a connected desktop client, open Settings > Backup & Restore.
4. Select Import Backup and choose the backup file from the client machine.
5. Choose Merge or Replace, and wait for the result.
6. Restart the headless host. A replace only takes effect at that restart.
7. Reconnect with the desktop or mobile client and verify that profile, target,
   and sequence data loaded correctly.

## Merge and Replace

A restore first reads the backup into a database file of its own, so a file
that is damaged, cut short or from a newer Skotiq fails there and the live
database is not touched.

**Merge** (`"mode": "merge"`, the default) adds the records the backup has and
the database does not, in one transaction:

- A backup row is the same record as a live row when the two agree on what
  identifies it (a target's creation or its name, catalog id and coordinates; a
  frame's file and capture time; and so on), not on the row id. The rule of
  each table is `backupMergeRules` in
  `packages/skotiq_core/lib/src/services/backup_service/merge.dart`.
- A record that is already here keeps the live version, and nothing is added
  inside it (a sequence's steps, a frame's measurements, a target's goals).
- A record that is not here is added, under a new id when its own is taken,
  and everything that belongs to it follows it.
- A row whose owner was left out, or is not in the backup, is left out too.
  Nothing is attached to a record it did not come with, and no link is cleared.
- Settings and the weather safety limits are not changed. An equipment profile
  with the same name keeps the live version.

The result lists the rows added, the rows that were here already, and the rows
left out by table and by reason.

**Replace** (`"mode": "replace"`) makes the database the backup: settings,
profiles and every record. It writes a safety backup of the current database
to the backup folder first, then asks for the swap, which the next start
performs: the current file is moved aside as `skotiq-replaced-<time>-skotiq.db`
(never deleted) and the new one takes its name. If any step fails, including
the swap at start-up, the current database stays as it was and the Backup
screen says why. This machine's backup folder setting is kept. Image files on
disk are not touched.

A backup written by 8.x (format 2.x) holds some per-frame tables without the
sessions and frames they belong to. Those rows are restored only into a
database that already has them.

## Migration Verification

Before declaring a release candidate upgrade-ready, verify both automated and
manual paths:

- Run `flutter test test\services\database_migration_test.dart` from
  `packages/skotiq_core`.
- Confirm the schema-12 upgrade test reaches the current schema version and
  contains every current Drift-managed table.
- Restore a `.skbackup` from the previous public or internal build.
- Manually upgrade a copied older release-authentic profile/database by launching the new app
  against it.
- Confirm application settings, equipment profiles, targets, sequences, and
  sequence templates are present after restart.
- Confirm images and external files are handled according to the "What a Backup
  Contains" section rather than assumed to be inside the backup.

Record the exact source version, target version, OS, backup file path, manual
profile path, command output, and result in the release checklist.
The manual artifact gate is recorded in
`docs/production-readiness/manual-migration-probe.md`, and accepted migration
limitations must remain aligned with `docs/known-limitations.md`.

## Rollback

If a migration or restore fails:

1. Stop Skotiq before changing files.
2. Preserve the failed target data directory for debugging.
3. Reinstall the prior known-good build.
4. Restore the pre-upgrade `.skbackup`.
5. Restore copied external assets such as captured images, catalogs, PHD2
   profiles, plate-solve indexes, and driver configuration.
6. Record the failing source version, target version, platform, backup metadata,
   and error message in the release audit log.

Do not continue an imaging session after a failed migration until profile,
sequence, save-path, and device settings have been checked.
