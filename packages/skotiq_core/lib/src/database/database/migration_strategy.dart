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
        // Enable foreign key enforcement
        await customStatement('PRAGMA foreign_keys = ON');

        // Retired settings are pruned here, not in onCreate/onUpgrade:
        // those only fire on a fresh database or a schema-version bump,
        // and the profiles that still carry an orphaned row are exactly
        // the ones already sitting at the current version.
        await _pruneRetiredSettings();

        // Close out runs a previous process left mid-flight.
        //
        // A `sequence_runs` row is only 'running' while THIS process's
        // executor is driving it — that executor state lives in memory, so
        // nothing can still be running at the moment the database opens. Any
        // row still marked 'running' here is residue from a process that died
        // mid-run: a crash, a force quit, or the power cut at 3am that this
        // kind of software has to expect.
        //
        // Left alone, such a row is permanent: the run list keeps reporting
        // a run "running" while /api/status reports the sequencer idle, and a
        // stale row blocks the next run from starting.
        //
        // `ended_at` stays NULL. When the run actually stopped is unknown,
        // and stamping "now" would invent a duration spanning the whole
        // downtime. 'paused' is a LIVE status too — written while an executor
        // holds the run — so a process that died mid-pause leaves the same
        // stale row as one that died mid-exposure.
        final interrupted = await customUpdate(
          "UPDATE sequence_runs SET status = 'interrupted' "
          "WHERE status IN ('running', 'paused')",
          updates: {sequenceRuns},
          updateKind: UpdateKind.update,
        );
        if (interrupted > 0) {
          // ignore: avoid_print
          print(
            '[skotiq_db] Marked $interrupted sequence '
            "run${interrupted == 1 ? '' : 's'} left live by a previous "
            "process as 'interrupted'.",
          );
        }

        // Close out imaging sessions a previous process left `active`, by the
        // same rule as the runs above and BEFORE the statistics rebuild below,
        // so a night this sweep closes gets its counters rebuilt in the same
        // open. Left standing, one such row detaches every later night:
        // `startSession` refuses to open a second session while it stands, so
        // every frame registers with `session_id` NULL and the session-end
        // hooks never fire. See [_closeOrphanedImagingSessions].
        await _closeOrphanedImagingSessions();

        // Close out Darkroom jobs a previous process left mid-flight, for the
        // same reason and by the same rule as the sequence runs above: a
        // 'running' row at open belongs to a process that is gone.
        final interruptedDarkroomJobs = await _recoverInterruptedDarkroomJobs();

        // Report a post-session pass a previous process died inside. The
        // integrate runs BEFORE any Darkroom job row exists, so the recovery
        // above cannot see it and the night would otherwise go silent with a
        // truncated master sitting on disk looking finished. What the recovery
        // DID find is handed over, because a Darkroom job left running is what
        // separates a kill during the draft from a kill during the integrate.
        //
        // This block may fail, and the try/catch is the whole point. Everything in
        // this block is a POST-MORTEM: it explains a night that already
        // happened. None of it is required for the database to work, and all
        // of it writes rows keyed to sessions and jobs whose ids come from a
        // marker file a dead process left behind — ids the current database
        // may no longer contain. Under `PRAGMA foreign_keys = ON` such a write
        // throws, and a throw HERE is not one failed report: drift records the
        // failure against the connection and refuses every later open, while
        // the marker that caused it stays on disk to cause it again. That
        // turns an undamaged database into an install that never starts.
        //
        // So the report is allowed to fail. What must not fail is the open.
        try {
          final reportedSession = await _reportInterruptedIntegration(
            interruptedDarkroomJobs,
          );

          // The report above is written once per interruption, from a marker
          // the first report consumes — so a job that dies repeatedly keeps
          // the record its FIRST death wrote, which promised a re-queue the
          // cap has since cancelled. Correct those here, now that the recovery
          // has said which jobs it ended for good.
          await _supersedeRetryPromiseForCappedJobs(
            interruptedDarkroomJobs,
            reportedSessionId: reportedSession,
          );
        } catch (error, stackTrace) {
          // ignore: avoid_print
          print(
            '[skotiq_db] WARNING: reporting an interrupted post-session '
            'pass failed ($error). The database opens anyway — this report is '
            'a courtesy, not a precondition. Discarding the marker that drove '
            'it so the failure cannot repeat at every launch.\n$stackTrace',
          );
          await _discardIntegrationMarkerAfterFailedReport();
        }

        // Rebuild session statistics that a dead process never got to write.
        //
        // `imaging_sessions.total_exposures` / `total_integration_secs` are
        // denormalised counters accumulated IN MEMORY by SessionService and
        // flushed when the session ends. A session that never ends cleanly
        // therefore keeps zeros forever — even though every frame it captured
        // is safely in `captured_images` with the right `session_id`.
        //
        // Analytics sums those counters, so the loss is user-visible and
        // permanent without this rebuild.
        //
        // `successful_exposures` is rebuilt alongside the total because it is
        // what the Analytics history view counts; rebuilding only the total
        // leaves every historical night reading "0 frames / 0.0h" there.
        //
        // Only sessions that under-report AND demonstrably have frames are
        // touched, so a correctly-written richer count is never overwritten (a
        // clean session's total legitimately also counts FAILED exposures,
        // which leave no image row). `failed_exposures` is left alone — a
        // failure writes no frame, so the rows on disk cannot say how many
        // there were.
        final rebuilt = await customUpdate(
          'UPDATE imaging_sessions SET '
          'total_exposures = (SELECT COUNT(*) FROM captured_images c '
          'WHERE c.session_id = imaging_sessions.id), '
          'successful_exposures = (SELECT COUNT(*) FROM captured_images c '
          'WHERE c.session_id = imaging_sessions.id), '
          'total_integration_secs = (SELECT IFNULL(SUM(c.exposure_duration), 0) '
          'FROM captured_images c WHERE c.session_id = imaging_sessions.id) '
          'WHERE (total_exposures = 0 OR successful_exposures = 0) '
          'AND EXISTS ('
          'SELECT 1 FROM captured_images c WHERE c.session_id = '
          'imaging_sessions.id)',
          updates: {imagingSessions},
          updateKind: UpdateKind.update,
        );
        if (rebuilt > 0) {
          // ignore: avoid_print
          print(
            '[skotiq_db] Rebuilt statistics for $rebuilt imaging '
            'session${rebuilt == 1 ? '' : 's'} from the frames actually '
            'on record.',
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

    await _ensureDefaultSettings();
    await _createCustomIndexes();
  }

  /// Every statement a fresh install's schema is made of, in dependency order.
  ///
  /// Split out of `onCreate` so the whole set runs inside that callback's one
  /// transaction and the reader can see where the atomic boundary is.
  Future<void> _createSchema(Migrator m) async {
    await m.createAll();
    await _createFrameForensicsTable();
    await _ensureCapturedImagesProducingNodeColumns();
    await _createStackedResultsTable();
    await _createProjectsTables();
    await _createPostSessionTables();
    await _ensureIntegratedMastersOverlayColumns();
    await _createNightReportsTable();
    await _ensureIntegratedMastersV42Columns();
    await _createCampaignsTable();
    await _ensureIntegratedMastersV44Columns();
    await _createNarrowbandCompositesTable();
    await _createMosaicTables();
    await _createCalibrationTagsTable();
    // After the post-session tables: `recipes` references
    // `integrated_masters`, and `delivery_journal` references both
    // `delivery_targets` and `darkroom_jobs`.
    await _createDarkroomTables();
    await _createCustomIndexes();
    await _ensureDefaultSettings();
  }
}
