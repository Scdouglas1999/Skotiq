part of '../database.dart';

extension _SkotiqDatabaseMigration on SkotiqDatabase {
  MigrationStrategy _buildMigrationStrategy() {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        // ONE transaction for the whole fresh-install schema, with the schema
        // version stamped inside it.
        //
        // Drift runs `onCreate` in auto-commit and writes `user_version` only
        // after the callback returns (`DelegatedDatabase._runMigrations`), so
        // a process killed part-way through a first boot leaves committed
        // tables under version 0. Version 0 reads as "brand new database" on
        // the next open, drift re-enters this callback, and the first
        // duplicate `CREATE INDEX` aborts startup — permanently, because
        // every later launch repeats it. Measured on the release bundle: a
        // kill anywhere between ~0.4 s and ~0.75 s of the very first boot
        // bricked the install.
        //
        // Committing the tables and the version together leaves the file
        // either empty or complete. A kill before the COMMIT rolls back
        // through the journal on the next open, and drift creates the schema
        // again from scratch.
        await customStatement('BEGIN');
        try {
          await _createSchema(m);
          // Inside the transaction on purpose. Drift writes the same value
          // again once this callback returns; that repeat is a no-op.
          await customStatement('PRAGMA user_version = $schemaVersion');
          await customStatement('COMMIT');
        } catch (error, stackTrace) {
          try {
            await customStatement('ROLLBACK');
          } catch (rollbackError) {
            // The original failure is the one the operator has to see, so it
            // is what propagates. A rollback that ITSELF fails means a
            // partial schema may survive on disk, which the next launch's
            // pre-flight then moves aside — say so rather than lose it.
            // ignore: avoid_print
            print(
              '[skotiq_db] WARNING: rolling back an interrupted schema '
              'creation failed: $rollbackError',
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
      },
      beforeOpen: (details) async {
        await customStatement('PRAGMA foreign_keys = ON');

        // Retired settings are pruned here, not in onCreate/onUpgrade:
        // those only fire on a fresh database or a schema-version bump,
        // and the profiles that still carry an orphaned row are exactly
        // the ones already sitting at the current version.
        await _pruneRetiredSettings();
        await _migrateSkyAtlasToOptIn();

        // A solved row's scalar rotation must agree with its own CD matrix;
        // rows written before the parser handled mirrored frames do not.
        final rotationsRepaired = await repairSolvedRotationFromCd(this);
        if (rotationsRepaired > 0) {
          // ignore: avoid_print
          print(
            '[skotiq_db] Rewrote the solved rotation of $rotationsRepaired '
            "frame${rotationsRepaired == 1 ? '' : 's'} to match "
            'the stored CD matrix.',
          );
        }

        // WHY a second integrity check here in addition to the pre-flight in
        // `_openConnection()`: the pre-flight catches corruption present
        // when the app starts, but cannot catch in-session corruption from a
        // crash, an SSD bit-flip, or a forced unmount. Running
        // `PRAGMA integrity_check` once per open is cheap (microseconds on a
        // small DB) and gives ops a structured warning in logs the moment
        // corruption first manifests rather than the next time the app
        // happens to read a damaged page. We do NOT auto-recover from here —
        // the connection is already live in a background isolate and we
        // cannot rotate the file out from under it safely.
        final integrityRow = await customSelect(
          'PRAGMA integrity_check;',
        ).get();
        final ok =
            integrityRow.length == 1 &&
            integrityRow.first.data['integrity_check'] == 'ok';
        if (!ok) {
          // Emit through dart:developer-style logging would be nice, but
          // logging_service is not on the database layer's dependency
          // graph. A plain `print` matches the convention used elsewhere in
          // this file for migration-time diagnostics and is captured by the
          // app's stdout/stderr log sinks.
          // ignore: avoid_print
          print(
            '[skotiq_db] WARNING: PRAGMA integrity_check failed at '
            'beforeOpen: ${integrityRow.map((r) => r.data['integrity_check']).join('; ')}. '
            'Database remains live; restart the app to trigger the '
            'corruption-recovery rotation.',
          );
        }
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // ONE transaction for the whole upgrade, with the schema version
        // stamped inside it — the same boundary `onCreate` above already
        // draws, for the same reason.
        //
        // Drift runs `onUpgrade` in auto-commit and writes `user_version`
        // only after the callback returns, so every statement below committed
        // as it ran while the version on disk stayed at the OLD number. A
        // process killed part-way through — the power cut at 3am, an OOM kill,
        // an operator closing the laptop on the launch after an update — left
        // a file that is half at the new schema and labelled as being entirely
        // at the old one. The next launch then re-runs the whole chain over
        // it, and every step is only as re-runnable as its own guard: the
        // `IF NOT EXISTS` ones survive it, while the rename-create-copy-drop
        // rebuilds do not (see the v30 `guide_rms_history` block, which is why
        // that one now resumes).
        //
        // Committing the statements and the version together leaves the file
        // either entirely before the upgrade or entirely after it. A kill
        // before the commit rolls back through the journal on the next open,
        // and the upgrade runs again from a state it has already handled once.
        //
        // WHY drift's `transaction()` here and a raw `BEGIN` in `onCreate`:
        // the upgrade chain reaches `Migrator.alterTable`, which opens a
        // transaction of its OWN to run SQLite's twelve-step table rebuild. A
        // raw `customStatement('BEGIN')` is invisible to drift's transaction
        // bookkeeping, so drift then issues a second `BEGIN` and SQLite
        // rejects it — `cannot start a transaction within a transaction`,
        // which broke every upgrade from a schema old enough to reach an
        // `alterTable` step. Going through `transaction()` lets drift see the
        // outer one and nest the inner as a savepoint. `onCreate` calls only
        // `createAll`, which opens nothing, so its raw form is left alone.
        //
        // Before anything rewrites the file: a copy of it as it is now.
        // Outside the transaction because `VACUUM INTO` cannot run inside one,
        // and first because a snapshot taken after the first statement is a
        // snapshot of a database mid-upgrade. See
        // [_writePreMigrationBackup] for why an upgrade is the one operation
        // that needs this and what it protects against.
        await _writePreMigrationBackup(from);

        await transaction(() async {
          await _runUpgrade(m, from);
          // Inside the transaction on purpose. Drift writes the same value
          // again once this callback returns; that repeat is a no-op.
          await customStatement('PRAGMA user_version = $schemaVersion');
        });
      },
    );
  }

  /// Every step of the upgrade chain, in version order.
  ///
  /// Split out of `onUpgrade` so the whole chain runs inside that callback's
  /// one transaction and the reader can see where the atomic boundary is —
  /// the same split, for the same reason, as [_createSchema].
  Future<void> _runUpgrade(Migrator m, int from) async {
    await _upgradeSchemaV2ToV17(m, from);
    await _upgradeSchemaV18ToV22(m, from);
    await _upgradeSchemaV23ToV31(m, from);
    await _upgradeSchemaV32ToV40(m, from);
    await _upgradeSchemaV41(m, from);
    await _upgradeSchemaV42(m, from);
    await _upgradeSchemaV43(m, from);
    await _upgradeSchemaV44(m, from);
    await _upgradeSchemaV45(m, from);
    await _upgradeSchemaV46(m, from);
    await _upgradeSchemaV47(m, from);
    await _upgradeSchemaV48(m, from);
    await _upgradeSchemaV49(m, from);
    await _upgradeSchemaV50(m, from);
    await _upgradeSchemaV51(m, from);
    await _upgradeSchemaV52(m, from);
    await _upgradeSchemaV53(m, from);
    await _upgradeSchemaV54(m, from);
    await _upgradeSchemaV55(m, from);
    await _upgradeSchemaV56(m, from);
    await _upgradeSchemaV57(m, from);
    await _upgradeSchemaV58(m, from);
    await _upgradeSchemaV59(m, from);
    await _upgradeSchemaV60(m, from);
    await _upgradeSchemaV61(m, from);
    await _upgradeSchemaV62(m, from);
    await _upgradeSchemaV63(m, from);
    await _upgradeSchemaV64(m, from);
    await _upgradeSchemaV65(m, from);
    await _upgradeSchemaV66(m, from);

    // Whatever the steps above did not create: a table or index declared in
    // drift needs no step of its own to reach an upgraded database.
    await _createMissing(
      m,
      allSchemaEntities,
      keepGoingPastIndexFailures: true,
    );
    await _ensureDefaultSettings();
  }

  /// A fresh install's schema: everything drift declares, then the settings
  /// seed.
  ///
  /// Split out of `onCreate` so both run inside that callback's one
  /// transaction and the reader can see where the atomic boundary is.
  Future<void> _createSchema(Migrator m) async {
    await m.createAll();
    await _ensureDefaultSettings();
  }
}
