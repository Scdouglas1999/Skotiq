// A process killed mid-integration must not leave the night silent.
//
// The post-session pass integrates first and enqueues its Darkroom job second,
// so `_recoverInterruptedDarkroomJobs` has nothing to find when the kill lands
// during the integrate — the longest stretch of the night. The marker file
// this suite covers is the whole record that it happened.
//
// Tested the honest way, the same shape as darkroom_job_recovery_test.dart:
// write the marker, open the database, and read what the open did.

import 'dart:convert';
import 'dart:io';

// Only the two query primitives: drift also exports `isNull` / `isNotNull`
// column matchers that collide with the test matchers of the same name.
import 'package:drift/drift.dart' show UpdateKind, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/darkroom_jobs_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/integration_stage_marker.dart';
import 'package:skotiq_core/src/database/sqlite_busy.dart';
import 'package:skotiq_core/src/models/darkroom/darkroom_job.dart';

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('skotiq_integ_');
    dbFile = File('${tempDir.path}/skotiq.db');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  SkotiqDatabase open() => SkotiqDatabase.forTesting(
    NativeDatabase(dbFile, setup: applySqliteBusyTimeout),
  );

  Future<int> seedSession() async {
    final db = open();
    final id = await db.customInsert(
      'INSERT INTO imaging_sessions(start_time, status) VALUES (?, ?)',
      variables: [
        Variable<int>(DateTime.now().millisecondsSinceEpoch ~/ 1000),
        const Variable<String>('completed'),
      ],
    );
    await db.close();
    return id;
  }

  Future<({String? notes, List<Map<String, Object?>> events})> reopenAndRead(
    int sessionId,
  ) async {
    final db = open();
    final notes = await db
        .customSelect(
          'SELECT notes FROM imaging_sessions WHERE id = ?',
          variables: [Variable<int>(sessionId)],
        )
        .getSingle();
    final events = await db
        .customSelect(
          'SELECT event_type, category, severity, headline, body, dedupe_key '
          'FROM narrator_events WHERE session_id = ?',
          variables: [Variable<int>(sessionId)],
        )
        .get();
    await db.close();
    return (
      notes: notes.data['notes'] as String?,
      events: events.map((e) => e.data).toList(),
    );
  }

  test(
    'an interrupted integration is reported and names its orphans',
    () async {
      final sessionId = await seedSession();

      // The masters the pass was going to write. One made it to disk before the
      // kill (truncated), one never got created.
      final orphan = File('${tempDir.path}/M31_L_master_123.fits');
      await orphan.writeAsString('half a FITS');
      final never = '${tempDir.path}/M31_Ha_master_123.fits';

      await markIntegrationStarted(
        tempDir,
        InterruptedIntegration(
          sessionId: sessionId,
          targetName: 'M31',
          startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
          intendedMasterPaths: [orphan.path, never],
        ),
      );

      final read = await reopenAndRead(sessionId);

      expect(read.notes, isNotNull, reason: 'the night must not stay silent');
      expect(read.notes, contains('interrupted'));
      expect(
        read.notes,
        contains(orphan.path),
        reason: 'a truncated FITS is present and non-empty and looks finished',
      );
      expect(
        read.notes,
        isNot(contains(never)),
        reason: 'a file that was never written is not an orphan to delete',
      );

      expect(read.events, hasLength(1));
      final event = read.events.single;
      expect(event['event_type'], 'quality.integration_interrupted');
      expect(event['severity'], 'warning');
      expect(event['body'], contains(orphan.path));
      expect(event['dedupe_key'], contains('2026-08-17T03:30:00.000Z'));

      expect(
        await integrationMarkerFile(tempDir).exists(),
        isFalse,
        reason: 'reported once — the marker is consumed after the report lands',
      );
    },
  );

  test('a second open does not repeat the warning', () async {
    final sessionId = await seedSession();
    await markIntegrationStarted(
      tempDir,
      InterruptedIntegration(
        sessionId: sessionId,
        targetName: null,
        startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
        intendedMasterPaths: const [],
      ),
    );

    final first = await reopenAndRead(sessionId);
    final second = await reopenAndRead(sessionId);

    expect(first.events, hasLength(1));
    expect(second.events, hasLength(1));
    expect(second.notes, first.notes);
  });

  // The test above passes because the marker is deleted. That delete is the
  // LAST thing the report does — deliberately, so a process that dies before
  // it re-reports at the next open — and it is a file operation that can fail
  // on its own. Either way the marker outlives the event it already wrote, and
  // "reported once" then rests on nothing. The row's own dedupe key is the
  // durable half of that promise; it was written and never read.
  test('a marker that outlives its report does not repeat it', () async {
    final sessionId = await seedSession();
    final marker = InterruptedIntegration(
      sessionId: sessionId,
      targetName: 'M31',
      startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
      intendedMasterPaths: const [],
    );

    await markIntegrationStarted(tempDir, marker);
    final first = await reopenAndRead(sessionId);
    expect(first.events, hasLength(1));

    // Byte for byte what the disk holds after a kill between the INSERT and
    // the delete.
    await markIntegrationStarted(tempDir, marker);
    final second = await reopenAndRead(sessionId);

    expect(
      second.events,
      hasLength(1),
      reason: 'one interruption is one event, however often it is re-read',
    );
    expect(
      second.notes,
      first.notes,
      reason: 'the session note must not grow a copy per launch either',
    );
    expect(
      await integrationMarkerFile(tempDir).exists(),
      isFalse,
      reason: 'the marker is still consumed on the way past',
    );
  });

  test('a clean shutdown leaves nothing to report', () async {
    final sessionId = await seedSession();
    await markIntegrationStarted(
      tempDir,
      InterruptedIntegration(
        sessionId: sessionId,
        targetName: 'M42',
        startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
        intendedMasterPaths: const [],
      ),
    );
    await clearIntegrationMarker(tempDir);

    final read = await reopenAndRead(sessionId);
    expect(read.notes, isNull);
    expect(read.events, isEmpty);
  });

  test('an existing note is appended to, never replaced', () async {
    final sessionId = await seedSession();
    final db = open();
    await db.customUpdate(
      'UPDATE imaging_sessions SET notes = ? WHERE id = ?',
      variables: [
        const Variable<String>('Guiding was rough after 2am.'),
        Variable<int>(sessionId),
      ],
      updateKind: UpdateKind.update,
    );
    await db.close();

    await markIntegrationStarted(
      tempDir,
      InterruptedIntegration(
        sessionId: sessionId,
        targetName: 'M42',
        startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
        intendedMasterPaths: const [],
      ),
    );

    final read = await reopenAndRead(sessionId);
    expect(read.notes, contains('Guiding was rough after 2am.'));
    expect(read.notes, contains('interrupted'));
  });

  test(
    'an unreadable marker reports nothing and is kept for support',
    () async {
      final sessionId = await seedSession();
      await integrationMarkerFile(tempDir).writeAsString('{not json');

      final read = await reopenAndRead(sessionId);
      expect(read.notes, isNull, reason: 'no session id to attribute it to');
      expect(read.events, isEmpty);
      expect(
        await integrationMarkerFile(tempDir).exists(),
        isTrue,
        reason: 'evidence is left on disk rather than silently deleted',
      );
    },
  );

  group('the warning verifies each file before it accuses it', () {
    /// A whole FITS: a 2880-byte primary header declaring an 8-bit 100x100
    /// image, followed by that data padded to the next block.
    Future<File> wholeFits(String path) async {
      final header = StringBuffer()
        ..write('SIMPLE  =                    T'.padRight(80))
        ..write('BITPIX  =                    8'.padRight(80))
        ..write('NAXIS   =                    2'.padRight(80))
        ..write('NAXIS1  =                  100'.padRight(80))
        ..write('NAXIS2  =                  100'.padRight(80))
        ..write('END'.padRight(80));
      final bytes = <int>[
        ...header.toString().padRight(2880).codeUnits,
        ...List<int>.filled(((10000 + 2879) ~/ 2880) * 2880, 42),
      ];
      final file = File(path);
      await file.writeAsBytes(bytes);
      return file;
    }

    test(
      'a byte-complete master is complete-but-unregistered, not truncated',
      () async {
        final sessionId = await seedSession();
        final whole = await wholeFits('${tempDir.path}/M31_L_master_1.fits');
        final half = File('${tempDir.path}/M31_R_master_1.fits');
        await half.writeAsString('half a FITS');

        await markIntegrationStarted(
          tempDir,
          InterruptedIntegration(
            sessionId: sessionId,
            targetName: 'M31',
            startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
            intendedMasterPaths: [whole.path, half.path],
          ),
        );

        final read = await reopenAndRead(sessionId);
        final notes = read.notes!;

        // The whole file is not accused, and is not on the delete list.
        expect(notes, contains('${whole.path} is a complete FITS'));
        expect(notes, contains('no master row records it'));
        final deleteSentence = notes
            .split('. ')
            .firstWhere((s) => s.contains('delete them before re-running'));
        expect(deleteSentence, contains(half.path));
        expect(deleteSentence, isNot(contains(whole.path)));
      },
    );

    test('a byte-complete master the library knows about says so', () async {
      final sessionId = await seedSession();
      final whole = await wholeFits('${tempDir.path}/M31_L_master_2.fits');

      final db = open();
      await db.customInsert(
        'INSERT INTO integrated_masters(name, master_fits_path, status, '
        'accumulation_mode, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          const Variable<String>('M31 L'),
          Variable<String>(whole.path),
          const Variable<String>('ready'),
          const Variable<String>('oneShot'),
          Variable<int>(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          Variable<int>(DateTime.now().millisecondsSinceEpoch ~/ 1000),
        ],
      );
      await db.close();

      await markIntegrationStarted(
        tempDir,
        InterruptedIntegration(
          sessionId: sessionId,
          targetName: 'M31',
          startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
          intendedMasterPaths: [whole.path],
        ),
      );

      final notes = (await reopenAndRead(sessionId)).notes!;
      expect(notes, contains('the master library already holds a row for it'));
      expect(notes, isNot(contains('delete them before re-running')));
    });

    test(
      'a file that stops short of its own header is named as short',
      () async {
        final sessionId = await seedSession();
        final whole = await wholeFits('${tempDir.path}/M31_L_master_3.fits');
        // Chop the last block: still a whole number of FITS blocks, so only the
        // header's own declaration catches it.
        final bytes = await whole.readAsBytes();
        await whole.writeAsBytes(bytes.sublist(0, bytes.length - 2880));

        await markIntegrationStarted(
          tempDir,
          InterruptedIntegration(
            sessionId: sessionId,
            targetName: 'M31',
            startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
            intendedMasterPaths: [whole.path],
          ),
        );

        final notes = (await reopenAndRead(sessionId)).notes!;
        expect(notes, contains('delete them before re-running'));
        expect(notes, contains('stops 2880 bytes short'));
      },
    );
  });

  // The marker's window covers the integrate AND the Darkroom pass that
  // follows it: `AutoIntegrationService` clears it in one `finally` wrapping
  // both. Its presence therefore does not say which was in flight, and every
  // interruption was reported as "Skotiq closed while integrating this
  // session" — telling an operator whose masters were finished and registered
  // to re-run the integration, and saying nothing about the draft, the night
  // report and the delivery that had actually been cut off.
  group('which stage the kill landed in', () {
    /// The state a crash DURING THE DRAFT leaves: the pass enqueues its
    /// Darkroom job only once the masters exist, so a row still `running` at
    /// open is proof the integrate had already finished.
    Future<int> seedRunningDarkroomJob(
      int sessionId, {
      int attempts = 1,
    }) async {
      final db = open();
      final dao = DarkroomJobsDao(db);
      final jobId = await dao.enqueue(sessionId: sessionId);
      await dao.markRunning(jobId);
      await dao.updateProgress(jobId, 0.4, note: 'rendering the draft');
      if (attempts != 1) {
        await db.customStatement(
          'UPDATE darkroom_jobs SET attempts = ? WHERE id = ?',
          [attempts, jobId],
        );
      }
      await db.close();
      return jobId;
    }

    test('a kill during the DRAFT is reported as the Darkroom pass', () async {
      final sessionId = await seedSession();
      final jobId = await seedRunningDarkroomJob(sessionId);
      await markIntegrationStarted(
        tempDir,
        InterruptedIntegration(
          sessionId: sessionId,
          targetName: 'M31',
          startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
          intendedMasterPaths: const [],
        ),
      );

      final read = await reopenAndRead(sessionId);
      final notes = read.notes!;

      expect(notes, contains('The Darkroom pass was interrupted'));
      expect(notes, contains('Darkroom job #$jobId'));
      expect(
        notes,
        contains('40% of the way through'),
        reason: 'the progress the recovery preserves is what says how far',
      );
      expect(
        notes,
        isNot(contains('Skotiq closed while integrating this session')),
        reason: 'the integration had finished before the job was queued',
      );
      expect(
        notes,
        isNot(contains('run the integration again')),
        reason: 're-running finished work is not what this night needs',
      );
      expect(
        notes,
        isNot(contains('No master file had been written yet')),
        reason: 'the draft stage writes no master, so none was in danger',
      );
      expect(read.events.single['headline'], contains('The Darkroom pass'));
    });

    /// A `running` row for the same session that is NOT this pass's row.
    /// [kind] and [createdAt] are what separate them: the marker's own pass is
    /// always `dawn` (`runDawnForSession`) and is queued after the marker is
    /// written, so a `manual` row, or one that predates the marker, belongs to
    /// something else.
    Future<int> seedUnrelatedRunningJob(
      int sessionId, {
      required DarkroomJobKind kind,
      required DateTime createdAt,
    }) async {
      final db = open();
      final dao = DarkroomJobsDao(db);
      final jobId = await dao.enqueue(sessionId: sessionId, kind: kind);
      await dao.markRunning(jobId);
      await dao.updateProgress(jobId, 0.4, note: 'rendering the draft');
      await db.customStatement(
        'UPDATE darkroom_jobs SET created_at = ? WHERE id = ?',
        [createdAt.millisecondsSinceEpoch ~/ 1000, jobId],
      );
      await db.close();
      return jobId;
    }

    // The pass row is read as proof the integrate had finished — a Darkroom job
    // only exists once the masters do. That inference holds for THIS pass's
    // row and for no other. A night also carries the operator's "Process now"
    // presses, which write no marker and can already be running when the
    // integrate starts; matching on session alone read one of those as the
    // pass and told an operator whose masters were half-written that the
    // integration had finished and must not be re-run.
    test("an operator's manual pass is not read as this pass", () async {
      final sessionId = await seedSession();
      await seedUnrelatedRunningJob(
        sessionId,
        kind: DarkroomJobKind.manual,
        createdAt: DateTime.utc(2026, 8, 17, 1),
      );
      await markIntegrationStarted(
        tempDir,
        InterruptedIntegration(
          sessionId: sessionId,
          targetName: 'M31',
          startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
          intendedMasterPaths: const [],
          stage: PostSessionPassStage.integrating,
        ),
      );

      final read = await reopenAndRead(sessionId);
      final notes = read.notes!;

      expect(
        notes,
        contains('Skotiq closed while integrating this session'),
        reason: "the marker's own stage says the masters were still going",
      );
      expect(
        notes,
        isNot(contains('The integration itself had already finished')),
        reason:
            'nothing here says that, and a half-written master may be on '
            'disk',
      );
      expect(
        notes,
        contains('run the integration again'),
        reason: 'an interrupted integrate is exactly what needs re-running',
      );
    });

    // The other half of the same rule: a `dawn` row can also belong to an
    // earlier pass over this session that is still standing.
    test('a dawn job predating the marker is not read as this pass', () async {
      final sessionId = await seedSession();
      await seedUnrelatedRunningJob(
        sessionId,
        kind: DarkroomJobKind.dawn,
        createdAt: DateTime.utc(2026, 8, 16, 22),
      );
      await markIntegrationStarted(
        tempDir,
        InterruptedIntegration(
          sessionId: sessionId,
          targetName: 'M31',
          startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
          intendedMasterPaths: const [],
          stage: PostSessionPassStage.integrating,
        ),
      );

      final read = await reopenAndRead(sessionId);
      expect(
        read.notes,
        contains('Skotiq closed while integrating this session'),
      );
      expect(
        read.notes,
        isNot(contains('The integration itself had already finished')),
      );
    });

    test('a kill during the INTEGRATE still blames the integrate', () async {
      final sessionId = await seedSession();
      await markIntegrationStarted(
        tempDir,
        InterruptedIntegration(
          sessionId: sessionId,
          targetName: 'M31',
          startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
          intendedMasterPaths: const [],
        ),
      );

      final notes = (await reopenAndRead(sessionId)).notes!;
      expect(notes, contains('The post-session integration was interrupted'));
      expect(notes, contains('run the integration again'));
    });

    test(
      'a draft job that has spent its attempts says it is not coming back',
      () async {
        final sessionId = await seedSession();
        await seedRunningDarkroomJob(
          sessionId,
          attempts: kDarkroomJobMaxAttempts,
        );
        await markIntegrationStarted(
          tempDir,
          InterruptedIntegration(
            sessionId: sessionId,
            targetName: 'M31',
            startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
            intendedMasterPaths: const [],
          ),
        );

        final notes = (await reopenAndRead(sessionId)).notes!;
        expect(
          notes,
          contains(
            'start $kDarkroomJobMaxAttempts of at most '
            '$kDarkroomJobMaxAttempts',
          ),
        );
        expect(notes, contains('marked failed rather than re-queued'));
        expect(
          notes,
          isNot(contains('The job is re-queued')),
          reason: 'the row it describes was failed, not re-queued',
        );
      },
    );

    test(
      'a job left running for ANOTHER session does not claim this one',
      () async {
        final interruptedSession = await seedSession();
        final otherSession = await seedSession();
        await seedRunningDarkroomJob(otherSession);
        await markIntegrationStarted(
          tempDir,
          InterruptedIntegration(
            sessionId: interruptedSession,
            targetName: 'M31',
            startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
            intendedMasterPaths: const [],
          ),
        );

        final notes = (await reopenAndRead(interruptedSession)).notes!;
        expect(notes, contains('The post-session integration was interrupted'));
      },
    );
  });

  // The seam the pass cannot close from one transaction: the masters are
  // finalized bucket by bucket inside `PostSessionIntegrationService`, and the
  // `darkroom_jobs` row is inserted afterwards. Reproduced against the release
  // bundle by killing the headless daemon the instant `integrated_masters`
  // reached 4 while `darkroom_jobs` was still empty: the relaunch wrote "The
  // post-session integration was interrupted before it finished ... run the
  // integration again when you are ready" over four masters it had itself just
  // measured as complete and registered, and said nothing about the drafts,
  // the night report, the delivery and the morning message that never
  // happened. `darkroom_jobs`, `recipes` and `delivery_journal` all stayed at
  // zero rows across the relaunch.
  group('the integrate finished and the pass was never queued', () {
    /// A whole FITS the library knows about — what every master looks like once
    /// the integrate has committed its bucket.
    Future<String> registeredMaster(String name) async {
      final header = StringBuffer()
        ..write('SIMPLE  =                    T'.padRight(80))
        ..write('BITPIX  =                    8'.padRight(80))
        ..write('NAXIS   =                    2'.padRight(80))
        ..write('NAXIS1  =                  100'.padRight(80))
        ..write('NAXIS2  =                  100'.padRight(80))
        ..write('END'.padRight(80));
      final file = File('${tempDir.path}/$name');
      await file.writeAsBytes(<int>[
        ...header.toString().padRight(2880).codeUnits,
        ...List<int>.filled(((10000 + 2879) ~/ 2880) * 2880, 42),
      ]);
      final db = open();
      await db.customInsert(
        'INSERT INTO integrated_masters(name, master_fits_path, status, '
        'accumulation_mode, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable<String>(name),
          Variable<String>(file.path),
          const Variable<String>('ready'),
          const Variable<String>('oneShot'),
          Variable<int>(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          Variable<int>(DateTime.now().millisecondsSinceEpoch ~/ 1000),
        ],
      );
      await db.close();
      return file.path;
    }

    Future<List<Map<String, Object?>>> jobsFor(int sessionId) async {
      final db = open();
      final rows = await db
          .customSelect(
            'SELECT id, kind, state, note, attempts FROM darkroom_jobs '
            'WHERE session_id = ?',
            variables: [Variable<int>(sessionId)],
          )
          .get();
      await db.close();
      return rows.map((r) => r.data).toList();
    }

    test('the owed pass is queued and the report never blames the '
        'integration', () async {
      final sessionId = await seedSession();
      final master = await registeredMaster('M31_L_master_9.fits');
      await markIntegrationStarted(
        tempDir,
        InterruptedIntegration(
          sessionId: sessionId,
          targetName: 'M31',
          startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
          intendedMasterPaths: [master],
          stage: PostSessionPassStage.darkroomPassOwed,
        ),
      );

      final read = await reopenAndRead(sessionId);
      final notes = read.notes!;
      final jobs = await jobsFor(sessionId);

      expect(
        notes,
        contains('The Darkroom pass for this night never started.'),
      );
      expect(
        notes,
        isNot(contains('so run the integration again when you are ready')),
        reason: 'the integration is the one part of this night that finished',
      );
      expect(notes, contains('Do not run the integration again'));
      expect(
        notes,
        isNot(contains('The post-session integration was interrupted')),
      );
      expect(notes, contains('the drafts, the night report, the delivery'));
      expect(
        notes,
        contains('the master library already holds a row for it'),
        reason: 'the masters are still measured and still named',
      );

      expect(jobs, hasLength(1), reason: 'the owed pass is durable now');
      expect(jobs.single['kind'], 'dawn');
      expect(jobs.single['state'], 'queued');
      expect(jobs.single['attempts'], 0);
      expect(notes, contains('Darkroom job #${jobs.single['id']}'));
      expect(read.events.single['severity'], 'warning');
      expect(
        await integrationMarkerFile(tempDir).exists(),
        isFalse,
        reason: 'reported once, queued once',
      );
    });

    test('a second open queues nothing more and repeats nothing', () async {
      final sessionId = await seedSession();
      final master = await registeredMaster('M31_L_master_10.fits');
      await markIntegrationStarted(
        tempDir,
        InterruptedIntegration(
          sessionId: sessionId,
          targetName: 'M31',
          startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
          intendedMasterPaths: [master],
          stage: PostSessionPassStage.darkroomPassOwed,
        ),
      );

      final first = await reopenAndRead(sessionId);
      final second = await reopenAndRead(sessionId);

      expect(first.events, hasLength(1));
      expect(second.events, hasLength(1));
      expect(second.notes, first.notes);
      expect(await jobsFor(sessionId), hasLength(1));
    });

    test('a marker that survived an already-queued pass adds nothing', () async {
      // The pass WAS queued and ran; the process died in the gap between the
      // last thing it did and the `finally` that clears the marker. The job row
      // is the whole record of how it ended, and `DarkroomPassBanner` renders
      // it — a second warning would only repeat it.
      final sessionId = await seedSession();
      final master = await registeredMaster('M31_L_master_11.fits');
      final db = open();
      final jobId = await DarkroomJobsDao(db).enqueue(
        sessionId: sessionId,
        createdAt: DateTime.utc(2026, 8, 17, 3, 41),
      );
      await db.customStatement(
        "UPDATE darkroom_jobs SET state = 'done', attempts = 1 WHERE id = ?",
        [jobId],
      );
      await db.close();
      await markIntegrationStarted(
        tempDir,
        InterruptedIntegration(
          sessionId: sessionId,
          targetName: 'M31',
          startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
          intendedMasterPaths: [master],
          stage: PostSessionPassStage.darkroomPassOwed,
        ),
      );

      final read = await reopenAndRead(sessionId);

      expect(read.notes, isNull);
      expect(read.events, isEmpty);
      expect(await jobsFor(sessionId), hasLength(1));
      expect(await integrationMarkerFile(tempDir).exists(), isFalse);
    });

    test('a night that owed no pass at all is consumed in silence', () async {
      // Automatic drafting is switched off, so the masters ARE the whole night
      // and the kill cost nothing. Under the old reading this was reported as
      // an interrupted integration.
      final sessionId = await seedSession();
      final master = await registeredMaster('M31_L_master_12.fits');
      await markIntegrationStarted(
        tempDir,
        InterruptedIntegration(
          sessionId: sessionId,
          targetName: 'M31',
          startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
          intendedMasterPaths: [master],
          stage: PostSessionPassStage.mastersOnly,
        ),
      );

      final read = await reopenAndRead(sessionId);

      expect(read.notes, isNull);
      expect(read.events, isEmpty);
      expect(await jobsFor(sessionId), isEmpty);
      expect(await integrationMarkerFile(tempDir).exists(), isFalse);
    });

    test(
      'a finished master that has since gone missing is still news',
      () async {
        final sessionId = await seedSession();
        final master = await registeredMaster('M31_L_master_13.fits');
        await File(master).delete();
        await markIntegrationStarted(
          tempDir,
          InterruptedIntegration(
            sessionId: sessionId,
            targetName: 'M31',
            startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
            intendedMasterPaths: [master],
            stage: PostSessionPassStage.mastersOnly,
          ),
        );

        final notes = (await reopenAndRead(sessionId)).notes!;
        expect(notes, contains('no longer on disk'));
        expect(notes, contains(master));
        expect(await jobsFor(sessionId), isEmpty);
      },
    );

    test('a pass the machine died inside still reports as the pass', () async {
      // The marker is written before the insert and never again, so a job the
      // process died inside carries the same stage. The ROW wins: its own
      // recovery already re-queued it, and enqueueing a second one would draft
      // this night twice.
      final sessionId = await seedSession();
      final master = await registeredMaster('M31_L_master_14.fits');
      final db = open();
      final dao = DarkroomJobsDao(db);
      final jobId = await dao.enqueue(sessionId: sessionId);
      await dao.markRunning(jobId);
      await dao.updateProgress(jobId, 0.4, note: 'rendering the draft');
      await db.close();
      await markIntegrationStarted(
        tempDir,
        InterruptedIntegration(
          sessionId: sessionId,
          targetName: 'M31',
          startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
          intendedMasterPaths: [master],
          stage: PostSessionPassStage.darkroomPassOwed,
        ),
      );

      final notes = (await reopenAndRead(sessionId)).notes!;
      expect(notes, contains('The Darkroom pass was interrupted'));
      expect(notes, contains('Darkroom job #$jobId'));
      expect(notes, contains('40% of the way through'));
      expect(
        await jobsFor(sessionId),
        hasLength(1),
        reason: 'the row that was re-queued is the pass; there is no second',
      );
    });

    test('a marker from a build that did not record the stage still blames '
        'the integrate', () async {
      final sessionId = await seedSession();
      await integrationMarkerFile(tempDir).writeAsString(
        '{"sessionId":$sessionId,"targetName":"M31",'
        '"startedAtUtc":"2026-08-17T03:30:00.000Z","intendedMasterPaths":[]}',
      );

      final notes = (await reopenAndRead(sessionId)).notes!;
      expect(notes, contains('The post-session integration was interrupted'));
      expect(notes, contains('run the integration again'));
      expect(
        await jobsFor(sessionId),
        isEmpty,
        reason:
            'a marker that does not say the masters finished has not '
            'earned a pass being queued over them',
      );
    });
  });

  group('the record is corrected when the retry cap ends the job', () {
    /// A job still `running` with [attempts] starts used, and NO marker on
    /// disk — the state the fourth open finds after three kills, because the
    /// first recovery consumed the marker when it wrote its report.
    Future<int> seedCappedRunningJob(
      int sessionId, {
      required int attempts,
    }) async {
      final db = open();
      final dao = DarkroomJobsDao(db);
      final jobId = await dao.enqueue(sessionId: sessionId);
      await dao.markRunning(jobId);
      await db.customStatement(
        'UPDATE darkroom_jobs SET attempts = ? WHERE id = ?',
        [attempts, jobId],
      );
      await db.close();
      return jobId;
    }

    /// The record the FIRST recovery wrote, when the job still had starts left.
    Future<void> seedRetryPromise(int sessionId) async {
      final db = open();
      const promise =
          'Skotiq closed while Darkroom job #1 was drafting this session. '
          'The job is re-queued, so the drafts, the night report and the '
          'delivery it owes are still owed.';
      await db.customUpdate(
        'UPDATE imaging_sessions SET notes = ? WHERE id = ?',
        variables: [
          const Variable<String>(
            'The Darkroom pass was interrupted before it finished. $promise',
          ),
          Variable<int>(sessionId),
        ],
        updateKind: UpdateKind.update,
      );
      await db.customInsert(
        'INSERT INTO narrator_events('
        'session_id, timestamp, event_type, category, severity, headline, '
        'body, dedupe_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable<int>(sessionId),
          Variable<int>(
            DateTime.utc(2026, 8, 17, 3, 30).millisecondsSinceEpoch ~/ 1000,
          ),
          const Variable<String>(kInterruptedPassEventType),
          const Variable<String>('quality'),
          const Variable<String>('warning'),
          const Variable<String>(
            'The Darkroom pass was interrupted before it finished.',
          ),
          const Variable<String>(promise),
          const Variable<String>(
            '$kInterruptedPassEventType:2026-08-17T03:30:00.000Z',
          ),
        ],
      );
      await db.close();
    }

    test('a job the cap fails revokes the re-queue it was promised', () async {
      final sessionId = await seedSession();
      // In this order because every open runs the recovery: the promise is
      // what an earlier open wrote, and the job has to be left running by the
      // LAST write before the open under test.
      await seedRetryPromise(sessionId);
      final jobId = await seedCappedRunningJob(
        sessionId,
        attempts: kDarkroomJobMaxAttempts,
      );

      final read = await reopenAndRead(sessionId);

      // Two records now: the promise, and the correction that stands over it.
      expect(read.events, hasLength(2));
      final correction = read.events.firstWhere(
        (e) => (e['headline'] as String).contains('retry limit'),
      );
      expect(
        correction['headline'],
        'The Darkroom pass for this night stopped at the retry limit.',
      );
      expect(correction['body'], contains('Darkroom job #$jobId'));
      expect(correction['body'], contains('is not re-queued'));
      expect(correction['body'], contains('that re-queue is over'));
      expect(
        correction['event_type'],
        kInterruptedPassEventType,
        reason: 'Session Review reads the newest record of this type',
      );
      expect(
        correction['dedupe_key'],
        '$kInterruptedPassEventType:job:$jobId:retry-limit',
      );
      // And the night's own notes carry it, under the sentence it corrects.
      expect(read.notes, contains('are still owed'));
      expect(read.notes, contains('stopped at the retry limit'));
    });

    test('a job with starts left is left under its promise', () async {
      final sessionId = await seedSession();
      await seedRetryPromise(sessionId);
      await seedCappedRunningJob(sessionId, attempts: 1);

      final read = await reopenAndRead(sessionId);

      expect(
        read.events,
        hasLength(1),
        reason: 'it really was re-queued, so the promise still stands',
      );
      expect(read.notes, isNot(contains('stopped at the retry limit')));
    });

    test('the correction is written once, not at every later open', () async {
      final sessionId = await seedSession();
      await seedRetryPromise(sessionId);
      await seedCappedRunningJob(sessionId, attempts: kDarkroomJobMaxAttempts);

      await reopenAndRead(sessionId);
      final second = await reopenAndRead(sessionId);
      final third = await reopenAndRead(sessionId);

      expect(second.events, hasLength(2));
      expect(third.events, hasLength(2));
      expect('stopped at the retry limit'.allMatches(third.notes!).length, 1);
    });

    test('a marker still on disk reports once, not twice', () async {
      final sessionId = await seedSession();
      await seedCappedRunningJob(sessionId, attempts: kDarkroomJobMaxAttempts);
      // The marker survived, so the interruption report itself runs and takes
      // its own terminal branch. Repeating that verdict would put the same
      // news on the feed twice in one open.
      await markIntegrationStarted(
        tempDir,
        InterruptedIntegration(
          sessionId: sessionId,
          targetName: 'M31',
          startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
          intendedMasterPaths: const [],
        ),
      );

      final read = await reopenAndRead(sessionId);

      expect(read.events, hasLength(1));
      expect(read.notes, contains('marked failed rather than re-queued'));
      expect(read.notes, isNot(contains('stopped at the retry limit')));
    });

    test(
      'a capped job with no session writes no record and does not throw',
      () async {
        final db = open();
        final dao = DarkroomJobsDao(db);
        final jobId = await dao.enqueue();
        await dao.markRunning(jobId);
        await db.customStatement(
          'UPDATE darkroom_jobs SET attempts = ? WHERE id = ?',
          [kDarkroomJobMaxAttempts, jobId],
        );
        await db.close();

        final reopened = open();
        final events = await reopened
            .customSelect('SELECT count(*) AS rows FROM narrator_events')
            .getSingle();
        final job = await DarkroomJobsDao(reopened).getById(jobId);
        await reopened.close();

        expect(events.read<int>('rows'), 0);
        expect(job!.state, DarkroomJobState.failed);
      },
    );
  });

  group('InterruptedIntegration', () {
    test('round-trips through its payload', () {
      final original = InterruptedIntegration(
        sessionId: 12,
        targetName: 'NGC 7000',
        startedAtUtc: DateTime.utc(2026, 8, 17, 4),
        intendedMasterPaths: const ['/a/one.fits', '/a/two.fits'],
      );
      final parsed = InterruptedIntegration.fromJson(
        jsonEncode(original.toJson()),
      )!;

      expect(parsed.sessionId, 12);
      expect(parsed.targetName, 'NGC 7000');
      expect(parsed.startedAtUtc, original.startedAtUtc);
      expect(parsed.intendedMasterPaths, original.intendedMasterPaths);
      expect(parsed.stage, PostSessionPassStage.integrating);
    });

    test('the stage round-trips and an advance keeps everything else', () {
      final started = InterruptedIntegration(
        sessionId: 12,
        targetName: 'NGC 7000',
        startedAtUtc: DateTime.utc(2026, 8, 17, 4),
        intendedMasterPaths: const ['/a/one.fits'],
      );
      final advanced = started.at(PostSessionPassStage.darkroomPassOwed);

      expect(advanced.sessionId, started.sessionId);
      expect(advanced.targetName, started.targetName);
      expect(
        advanced.startedAtUtc,
        started.startedAtUtc,
        reason: 're-stamping it would make one interruption look like two',
      );
      expect(advanced.intendedMasterPaths, started.intendedMasterPaths);
      expect(
        InterruptedIntegration.fromJson(jsonEncode(advanced.toJson()))!.stage,
        PostSessionPassStage.darkroomPassOwed,
      );
    });

    test('a stage this build does not know reads as the integrate', () {
      expect(
        InterruptedIntegration.fromJson(
          '{"sessionId":3,"startedAtUtc":"2026-08-17T04:00Z",'
          '"stage":"somethingLater"}',
        )!.stage,
        PostSessionPassStage.integrating,
      );
    });

    test('refuses a payload with no session to attribute', () {
      expect(
        InterruptedIntegration.fromJson('{"startedAtUtc":"2026-08-17T04:00Z"}'),
        isNull,
      );
      expect(InterruptedIntegration.fromJson('{"sessionId":3}'), isNull);
      expect(InterruptedIntegration.fromJson('[]'), isNull);
    });
  });
}
