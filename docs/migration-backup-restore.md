# Migration, Backup, and Restore Guide

Use this guide before upgrading Skotiq, moving a profile to another
computer, or restoring a headless imaging host.

Skotiq backups are JSON files with a `.skbackup` extension. The current
backup format is version `2.0`.

## What a Backup Contains

Backups created by `BackupService` include:

- Application settings
- Equipment profiles
- Sequences and sequence templates
- Targets
- Backup metadata: format version, app version, platform, created time, and
  category counts

Backups do not currently include:

- Captured image files
- Imaging session history and captured-image database rows
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
3. Select Import Backup.
4. Choose the `.skbackup` or compatible `.json` backup file.
5. Confirm the restore.
6. Restart Skotiq after a successful restore so settings, active profiles,
   and backend services reload from the restored data.
7. Verify the equipment profile, saved targets, and sequence library before
   connecting hardware.

The Settings UI uses merge-style restore. Existing settings with the same keys
are updated. Equipment profiles and targets are inserted with conflict handling,
and imaging session history is preserved.

## Restore to a Remote or Headless Host

When the desktop UI is connected to a `NetworkBackend`, the Backup & Restore
screen manages files stored on the connected Skotiq host.

Available remote operations are backed by these headless routes:

- `GET /api/backup/list`
- `POST /api/backup/create`
- `POST /api/backup/restore`
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
5. Wait for the upload-and-restore result.
6. Restart the headless host.
7. Reconnect with the desktop or mobile client and verify that profile, target,
   and sequence data loaded correctly.

## Replace vs Merge Behavior

The local Settings UI and default remote client calls restore with
`replaceExisting: false`. This is the safer public-release default because it
preserves imaging sessions and captured-image database rows.

The headless API also accepts `replaceExisting: true` on restore requests. That
mode clears equipment profiles, sequences, sequence nodes, and targets before
importing the backup. It still preserves imaging sessions and captured-image
history. Use it only when intentionally rebuilding a host from a known backup.

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
