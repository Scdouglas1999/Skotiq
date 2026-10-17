// Delivery against a real v58 database and a fault-injected transport.
//
// The load-bearing claim is that retry state lives in `delivery_journal` and
// nowhere else: the restart tests close the database, reopen it, build a
// COMPLETELY NEW DeliveryService, and expect the sweep to pick up exactly
// where the dead process left off.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/darkroom_jobs_dao.dart';
import 'package:skotiq_core/src/database/daos/delivery_journal_dao.dart';
import 'package:skotiq_core/src/database/daos/delivery_targets_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/darkroom/delivery.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/artifact_transport.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/atomic_file_write.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_artifact.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_failure.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_naming.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_retry_policy.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_service.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/watched_folder_transport.dart';
import 'package:path/path.dart' as p;

/// A transport whose behaviour the test dictates per file.
class _ScriptedTransport implements ArtifactTransport {
  _ScriptedTransport({
    required this.kind,
    this.openFailure,
    this.deliverFailure,
    this.disposition = DeliveryDisposition.delivered,
  });

  @override
  final ArtifactDestinationKind kind;

  DeliveryFailure? openFailure;
  DeliveryFailure? deliverFailure;
  DeliveryDisposition disposition;

  final List<String> delivered = [];
  int opens = 0;
  int closes = 0;

  @override
  Future<void> open(List<DeliveryFile> artifacts) async {
    opens++;
    final failure = openFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact) async {
    final failure = deliverFailure;
    if (failure != null) throw failure;
    delivered.add(artifact.sourcePath);
    return TransportDeliveryOutcome(
      disposition: disposition,
      checksum: artifact.checksum,
      destinationDescription: 'test://${artifact.fileName}',
    );
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

/// Records the job id the transport serving each file was built with — which
/// is the id the staged file name carries.
class _JobIdRecordingTransport implements ArtifactTransport {
  _JobIdRecordingTransport({required this.jobId, required this.seen});

  final int jobId;
  final Map<String, int> seen;

  @override
  ArtifactDestinationKind get kind => ArtifactDestinationKind.watchedFolder;

  @override
  Future<void> open(List<DeliveryFile> artifacts) async {}

  @override
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact) async {
    seen[artifact.sourcePath] = jobId;
    return TransportDeliveryOutcome(
      disposition: DeliveryDisposition.delivered,
      checksum: artifact.checksum,
      destinationDescription: 'test://${artifact.fileName}',
    );
  }

  @override
  Future<void> close() async {}
}

void main() {
  late Directory tempDir;
  late File dbFile;
  late Directory source;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_delivery_svc_');
    dbFile = File(p.join(tempDir.path, 'skotiq.db'));
    source = await Directory(p.join(tempDir.path, 'masters')).create();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  SkotiqDatabase open() => SkotiqDatabase.forTesting(NativeDatabase(dbFile));

  /// Queue a real `darkroom_jobs` row. A journal row references one by
  /// foreign key, so delivery cannot be tested against an invented job id.
  Future<int> enqueueJob(SkotiqDatabase db) => DarkroomJobsDao(db).enqueue();

  Future<DeliveryArtifactSet> artifactSet({
    int jobId = 1,
    List<String> names = const ['M31_Ha_master.fits'],
  }) async {
    final paths = <String>[];
    for (final name in names) {
      final file = File(p.join(source.path, name));
      await file.writeAsString('bytes-of-$name');
      paths.add(file.path);
    }
    return DeliveryArtifactSet.build(
      jobId: jobId,
      sources: {ArtifactContent.linearMasters: paths},
    );
  }

  Future<int> createWatchedFolder(
    SkotiqDatabase db, {
    String name = 'nas',
    bool enabled = true,
    ArtifactDestinationKind kind = ArtifactDestinationKind.watchedFolder,
  }) {
    return DeliveryTargetsDao(db).create(
      name: name,
      kind: kind,
      configJson: jsonEncode({'path': '/mnt/nas', 'peerId': 'office-pc'}),
      enabled: enabled,
      content: const {ArtifactContent.linearMasters},
    );
  }

  group('delivering a job', () {
    test(
      'journals a delivered row per file and reports where it went',
      () async {
        final db = open();
        addTearDown(db.close);
        await enqueueJob(db);
        final targetId = await createWatchedFolder(db);
        final transport = _ScriptedTransport(
          kind: ArtifactDestinationKind.watchedFolder,
        );
        final service = DeliveryService(
          targets: DeliveryTargetsDao(db),
          journal: DeliveryJournalDao(db),
          transportFactory: (_, __) => transport,
        );
        final set = await artifactSet(names: ['a.fits', 'b.fits']);

        final report = await service.deliverJobArtifacts(set);

        expect(report.delivered, 2);
        expect(report.failed, 0);
        expect(report.summary, contains('nas: 2 delivered'));
        expect(transport.opens, 1);
        expect(transport.closes, 1);

        final rows = await DeliveryJournalDao(db).listForJob(1);
        expect(rows.length, 2);
        for (final row in rows) {
          expect(row.state, DeliveryAttemptState.delivered);
          expect(row.targetId, targetId);
          expect(row.attempts, 1);
          expect(row.checksum, isNotNull);
          expect(row.bytes, greaterThan(0));
          expect(row.deliveredAt, isNotNull);
        }
      },
    );

    test('a destination that fails to open journals every file with the '
        'mechanism, and delivery still returns', () async {
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(db);
      final transport = _ScriptedTransport(
        kind: ArtifactDestinationKind.watchedFolder,
        openFailure: const DeliveryFailure(
          DeliveryFailureKind.destinationUnreachable,
          '/mnt/nas is not on the filesystem right now',
        ),
      );
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => transport,
      );

      final report = await service.deliverJobArtifacts(
        await artifactSet(names: ['a.fits', 'b.fits']),
      );

      expect(report.retrying, 2);
      expect(report.delivered, 0);
      expect(transport.closes, 1, reason: 'the transport is always released');

      final rows = await DeliveryJournalDao(db).listForJob(1);
      expect(rows.every((r) => r.state == DeliveryAttemptState.retrying), true);
      expect(
        rows.first.lastError,
        contains('destinationUnreachable'),
        reason: 'the journal names the mechanism, not just "failed"',
      );
    });

    test('a failure no retry can change is recorded as failed on the first '
        'attempt', () async {
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(db);
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => _ScriptedTransport(
          kind: ArtifactDestinationKind.watchedFolder,
          deliverFailure: const DeliveryFailure(
            DeliveryFailureKind.destinationConflict,
            'that name is taken by different bytes',
          ),
        ),
      );

      final report = await service.deliverJobArtifacts(await artifactSet());

      expect(report.failed, 1);
      expect(report.retrying, 0);
      final row = (await DeliveryJournalDao(db).listForJob(1)).single;
      expect(row.state, DeliveryAttemptState.failed);
      expect(row.attempts, 1);
      expect(row.lastError, contains('destinationConflict'));
    });

    test('a transport that throws something untyped never escapes into the '
        'pipeline', () async {
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(db);
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => _ThrowingTransport(),
      );

      final report = await service.deliverJobArtifacts(await artifactSet());

      expect(report.retrying, 1);
      final row = (await DeliveryJournalDao(db).listForJob(1)).single;
      expect(row.lastError, contains('transportFailure'));
    });

    test('a disabled destination is not visited at all', () async {
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(db, enabled: false);
      final transport = _ScriptedTransport(
        kind: ArtifactDestinationKind.watchedFolder,
      );
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => transport,
      );

      final report = await service.deliverJobArtifacts(await artifactSet());

      expect(report.destinations, isEmpty);
      expect(transport.opens, 0);
      expect(await DeliveryJournalDao(db).listForJob(1), isEmpty);
    });

    test('a peer destination is published, not claimed as delivered', () async {
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(
        db,
        name: 'office-pc',
        kind: ArtifactDestinationKind.peer,
      );
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => _ScriptedTransport(
          kind: ArtifactDestinationKind.peer,
          disposition: DeliveryDisposition.awaitingPull,
        ),
      );

      final report = await service.deliverJobArtifacts(await artifactSet());

      expect(report.awaitingPull, 1);
      expect(report.delivered, 0);
      final row = (await DeliveryJournalDao(db).listForJob(1)).single;
      expect(row.state, DeliveryAttemptState.retrying);
      expect(
        row.deliveredAt,
        isNull,
        reason: 'serving bytes is not the same as the bytes arriving',
      );
    });

    test('a re-run does not walk an acknowledged peer row backwards, and does '
        'not offer the file again', () async {
      // The power-cut shape: the pass published for a desktop, the desktop
      // pulled one file and acknowledged it, and then open-time recovery
      // re-queued the `running` job so the whole pass runs again over the same
      // artifacts. The acknowledged row used to be upserted back to `retrying`
      // with its `delivered_at` left set — a row saying both that the file
      // arrived and that it has not — and the rig went on offering the desktop
      // a file it had already pulled.
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      final targetId = await createWatchedFolder(
        db,
        name: 'office-pc',
        kind: ArtifactDestinationKind.peer,
      );
      final journal = DeliveryJournalDao(db);
      final transport = _ScriptedTransport(
        kind: ArtifactDestinationKind.peer,
        disposition: DeliveryDisposition.awaitingPull,
      );
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: journal,
        transportFactory: (_, __) => transport,
      );
      final set = await artifactSet(names: ['a.fits', 'b.fits']);
      await service.deliverJobArtifacts(set);
      final pulled = set.artifacts.first.sourcePath;

      // What `PeerManifestService.acknowledgePull` writes when the desktop
      // reports the bytes landed.
      final acknowledged = await journal.markDelivered(
        targetId: targetId,
        jobId: 1,
        filePath: pulled,
        checksum: set.artifacts.first.checksum,
        bytes: set.artifacts.first.bytes,
        now: DateTime.utc(2026, 8, 16, 6),
      );

      final rerun = await service.deliverJobArtifacts(
        await artifactSet(names: ['a.fits', 'b.fits']),
      );

      expect(rerun.alreadyDelivered, 1);
      expect(rerun.awaitingPull, 1);
      expect(rerun.retrying, 0);
      expect(rerun.failed, 0);
      expect(
        rerun.summary,
        'office-pc: 1 already delivered before this pass, 1 awaiting pull',
      );
      expect(
        transport.delivered.where((path) => path == pulled).length,
        1,
        reason: 'the file the desktop already has is not published again',
      );

      final row = (await journal.listForJob(
        1,
      )).firstWhere((entry) => entry.filePath == pulled);
      expect(row.state, DeliveryAttemptState.delivered);
      expect(row.attempts, acknowledged.attempts);
      expect(row.deliveredAt, DateTime.utc(2026, 8, 16, 6));
      expect(
        await journal.listPendingRetry(),
        hasLength(1),
        reason: 'only the file the desktop has not pulled is still owed',
      );
    });

    test('a destination that will not open states its cause once, not once '
        'per file', () async {
      // The refusal is one fact about the destination, so the morning report
      // states it one time and says how many files it held up. Every file
      // still gets its own journal row — that is the sweep's work list — and
      // per-file causes still list per file.
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(db, name: 'full-drop');
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => _ScriptedTransport(
          kind: ArtifactDestinationKind.watchedFolder,
          openFailure: const DeliveryFailure(
            DeliveryFailureKind.insufficientSpace,
            '/mnt/nas has 4 MB free; this delivery needs 1.2 GB',
          ),
        ),
      );

      final report = await service.deliverJobArtifacts(
        await artifactSet(names: ['a.fits', 'b.fits', 'c.fits']),
      );

      final destination = report.destinations.single;
      expect(destination.retrying, 3);
      expect(destination.problems, hasLength(1));
      expect(
        destination.problems.single,
        '3 files were not sent to full-drop: insufficientSpace: /mnt/nas has '
        '4 MB free; this delivery needs 1.2 GB',
      );
      final rows = await DeliveryJournalDao(db).listForJob(1);
      expect(rows, hasLength(3));
      expect(
        rows.every((r) => r.lastError!.contains('insufficientSpace')),
        isTrue,
        reason: 'every file still carries the mechanism in its own row',
      );
    });
  });

  group('the overnight retry sweep', () {
    test('waits out the backoff before spending another attempt', () async {
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(db);
      var now = DateTime.utc(2026, 8, 16, 5);
      final transport = _ScriptedTransport(
        kind: ArtifactDestinationKind.watchedFolder,
        openFailure: const DeliveryFailure(
          DeliveryFailureKind.destinationUnreachable,
          'the share is not mounted',
        ),
      );
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => transport,
        clock: () => now,
      );
      await service.deliverJobArtifacts(await artifactSet());

      now = now.add(const Duration(seconds: 30));
      final tooEarly = await service.sweepDueRetries();

      expect(tooEarly.retrying, 1);
      expect(transport.opens, 1, reason: 'the backoff has not elapsed');
      expect((await DeliveryJournalDao(db).listForJob(1)).single.attempts, 1);

      now = now.add(const Duration(minutes: 2));
      await service.sweepDueRetries();

      expect(transport.opens, 2);
      expect((await DeliveryJournalDao(db).listForJob(1)).single.attempts, 2);
    });

    test('resumes across a restart from the journal alone', () async {
      var now = DateTime.utc(2026, 8, 16, 5);
      final set = await artifactSet();

      // The process that ran the dawn job fails to reach the NAS, then dies.
      final first = open();
      await enqueueJob(first);
      await createWatchedFolder(first);
      final failing = DeliveryService(
        targets: DeliveryTargetsDao(first),
        journal: DeliveryJournalDao(first),
        transportFactory: (_, __) => _ScriptedTransport(
          kind: ArtifactDestinationKind.watchedFolder,
          openFailure: const DeliveryFailure(
            DeliveryFailureKind.destinationUnreachable,
            'the share is not mounted',
          ),
        ),
        clock: () => now,
      );
      await failing.deliverJobArtifacts(set);
      await first.close();

      // A completely new process, a completely new service. Nothing carries
      // over except the rows on disk.
      now = now.add(const Duration(minutes: 5));
      final second = open();
      addTearDown(second.close);
      final recovered = _ScriptedTransport(
        kind: ArtifactDestinationKind.watchedFolder,
      );
      final resumed = DeliveryService(
        targets: DeliveryTargetsDao(second),
        journal: DeliveryJournalDao(second),
        transportFactory: (_, __) => recovered,
        clock: () => now,
      );

      final report = await resumed.sweepDueRetries();

      expect(report.delivered, 1);
      expect(recovered.delivered, [set.artifacts.single.sourcePath]);
      final row = (await DeliveryJournalDao(second).listForJob(1)).single;
      expect(row.state, DeliveryAttemptState.delivered);
      expect(row.attempts, 2, reason: 'the first attempt is still counted');
      expect(
        row.lastError,
        contains('destinationUnreachable'),
        reason: 'a delivery that recovered says so rather than looking clean',
      );
    });

    test(
      'stops after the attempt budget and says how many attempts it took',
      () async {
        final db = open();
        addTearDown(db.close);
        await enqueueJob(db);
        await createWatchedFolder(db);
        var now = DateTime.utc(2026, 8, 16, 5);
        final service = DeliveryService(
          targets: DeliveryTargetsDao(db),
          journal: DeliveryJournalDao(db),
          policy: const DeliveryRetryPolicy(
            maxAttempts: 3,
            firstBackoff: Duration(minutes: 1),
          ),
          transportFactory: (_, __) => _ScriptedTransport(
            kind: ArtifactDestinationKind.watchedFolder,
            openFailure: const DeliveryFailure(
              DeliveryFailureKind.destinationUnreachable,
              'the share is not mounted',
            ),
          ),
          clock: () => now,
        );
        await service.deliverJobArtifacts(await artifactSet());

        for (var i = 0; i < 4; i++) {
          now = now.add(const Duration(hours: 1));
          await service.sweepDueRetries();
        }

        final row = (await DeliveryJournalDao(db).listForJob(1)).single;
        expect(row.state, DeliveryAttemptState.failed);
        expect(row.attempts, 3);
        expect(row.lastError, contains('after 3 attempts'));
      },
    );

    // A transport is built with a job id, and the atomic write derives its
    // staged name from it (`.<name>.<jobId>.skdelivery-part`). One transport
    // opened on the FIRST due row therefore staged every other night's files
    // under that night's job: two nights whose masters share a delivered name
    // collided on one staged path, and the litter a kill leaves behind named a
    // job that never touched the file.
    test(
      'a sweep spanning two nights sends each row under its own job id',
      () async {
        final db = open();
        addTearDown(db.close);
        final firstJob = await enqueueJob(db);
        final secondJob = await enqueueJob(db);
        await createWatchedFolder(db);
        var now = DateTime.utc(2026, 8, 16, 5);
        final jobIdPerFile = <String, int>{};
        final service = DeliveryService(
          targets: DeliveryTargetsDao(db),
          journal: DeliveryJournalDao(db),
          transportFactory: (_, jobId) =>
              _JobIdRecordingTransport(jobId: jobId, seen: jobIdPerFile),
          clock: () => now,
        );

        // Both nights fail their first attempt, so both owe a retry.
        for (final (jobId, name) in [
          (firstJob, 'night-one.fits'),
          (secondJob, 'night-two.fits'),
        ]) {
          await DeliveryJournalDao(db).recordAttempt(
            targetId: 1,
            jobId: jobId,
            filePath: (await artifactSet(
              jobId: jobId,
              names: [name],
            )).artifacts.single.sourcePath,
            bytes: 10,
            now: now,
          );
          await DeliveryJournalDao(db).markRetrying(
            targetId: 1,
            jobId: jobId,
            filePath: p.join(source.path, name),
            error: 'the share is not mounted',
            now: now,
          );
        }

        now = now.add(const Duration(hours: 3));
        final report = await service.sweepDueRetries();

        expect(report.delivered, 2);
        expect(jobIdPerFile[p.join(source.path, 'night-one.fits')], firstJob);
        expect(jobIdPerFile[p.join(source.path, 'night-two.fits')], secondJob);
      },
    );

    test('a peer row is left waiting for its pull, not retried', () async {
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(
        db,
        name: 'office-pc',
        kind: ArtifactDestinationKind.peer,
      );
      var now = DateTime.utc(2026, 8, 16, 5);
      final transport = _ScriptedTransport(
        kind: ArtifactDestinationKind.peer,
        disposition: DeliveryDisposition.awaitingPull,
      );
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => transport,
        clock: () => now,
      );
      await service.deliverJobArtifacts(await artifactSet());

      now = now.add(const Duration(hours: 3));
      final report = await service.sweepDueRetries();

      expect(report.awaitingPull, 1);
      expect(transport.opens, 1, reason: 'the sweep does not re-publish');
      expect((await DeliveryJournalDao(db).listForJob(1)).single.attempts, 1);
    });

    test('a published file the RIG has lost fails on the rig, and stops being '
        'the desktop\'s debt', () async {
      // The peer arm counted every row straight into `awaitingPull` without
      // reading the rig's own disk, so an artifact deleted after publication
      // was reported "waiting for office-pc to pull" for ever — no error, no
      // terminal state, attempts untouched — while the manifest endpoint was
      // already refusing to serve it as `sourceMissing`. Every other transport
      // describes its source on every pass; this one now does too.
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(
        db,
        name: 'office-pc',
        kind: ArtifactDestinationKind.peer,
      );
      var now = DateTime.utc(2026, 8, 16, 5);
      final transport = _ScriptedTransport(
        kind: ArtifactDestinationKind.peer,
        disposition: DeliveryDisposition.awaitingPull,
      );
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => transport,
        clock: () => now,
      );
      await service.deliverJobArtifacts(await artifactSet());

      // The file leaves the rig before the desktop ever pulls it.
      await File(p.join(source.path, 'M31_Ha_master.fits')).delete();

      now = now.add(const Duration(hours: 3));
      final report = await service.sweepDueRetries();

      expect(
        report.awaitingPull,
        0,
        reason: 'there is nothing left for the desktop to collect',
      );
      expect(report.failed, 1);
      expect(
        report.everythingLanded,
        isFalse,
        reason: 'a file that left the rig unpulled did not land',
      );
      final row = (await DeliveryJournalDao(db).listForJob(1)).single;
      expect(row.state, DeliveryAttemptState.failed);
      expect(row.lastError, contains('sourceMissing'));
      expect(
        row.lastError,
        contains('never pulled it'),
        reason: 'the sentence names which side lost the file',
      );
      expect(
        row.attempts,
        1,
        reason:
            'reading the rig\'s own disk is not another publication, so '
            'the count still says how many times the file was offered',
      );
      expect(
        transport.opens,
        1,
        reason: 'the check opens no transport — nothing is re-published',
      );
    });

    test('a published file still on the rig is left waiting, and is not '
        'hashed to find that out', () async {
      // The existence check is `stat`, not `describe`: a peer row is looked at
      // on every heartbeat pass for as long as the desktop leaves it unpulled,
      // and hashing there would re-read every published master on an appliance
      // that is also integrating. Pinned by permissions rather than by timing:
      // a file that cannot be READ but can be stat-ed still reports as waiting.
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(
        db,
        name: 'office-pc',
        kind: ArtifactDestinationKind.peer,
      );
      var now = DateTime.utc(2026, 8, 16, 5);
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => _ScriptedTransport(
          kind: ArtifactDestinationKind.peer,
          disposition: DeliveryDisposition.awaitingPull,
        ),
        clock: () => now,
      );
      await service.deliverJobArtifacts(await artifactSet());
      final master = File(p.join(source.path, 'M31_Ha_master.fits'));
      await Process.run('chmod', ['000', master.path]);
      addTearDown(() => Process.run('chmod', ['644', master.path]));
      expect(
        () => master.openSync().closeSync(),
        throwsA(isA<FileSystemException>()),
        reason:
            'the read must really be denied, or this test proves nothing '
            'about which of stat and read the sweep performs',
      );

      now = now.add(const Duration(hours: 3));
      final report = await service.sweepDueRetries();

      expect(report.awaitingPull, 1);
      expect(report.failed, 0);
      expect(
        (await DeliveryJournalDao(db).listForJob(1)).single.state,
        DeliveryAttemptState.retrying,
      );
    });

    test(
      'a switched-off peer is suspended, not reported as awaiting a pull',
      () async {
        // The sweep used to take the peer branch before it read the switch, so
        // a destination the operator had turned off was reported as "12
        // awaiting pull" — while `PeerManifestService` resolves peers through
        // `readEnabled` and answered that same peer id with
        // `unknown_delivery_peer`. Nothing could ever pull those files.
        final db = open();
        addTearDown(db.close);
        await enqueueJob(db);
        final targetId = await createWatchedFolder(
          db,
          name: 'office-pc',
          kind: ArtifactDestinationKind.peer,
        );
        var now = DateTime.utc(2026, 8, 16, 5);
        final transport = _ScriptedTransport(
          kind: ArtifactDestinationKind.peer,
          disposition: DeliveryDisposition.awaitingPull,
        );
        final service = DeliveryService(
          targets: DeliveryTargetsDao(db),
          journal: DeliveryJournalDao(db),
          transportFactory: (_, __) => transport,
          clock: () => now,
        );
        await service.deliverJobArtifacts(await artifactSet());
        await DeliveryTargetsDao(db).update(targetId, enabled: false);

        now = now.add(const Duration(hours: 3));
        final report = await service.sweepDueRetries();

        expect(report.awaitingPull, 0);
        expect(report.suspended, 1);
        expect(
          report.destinations.single.problems.single,
          contains('no paired desktop can pull them while it is off'),
        );
        expect(
          report.everythingLanded,
          isFalse,
          reason: 'a file nothing can pull has not landed',
        );
      },
    );

    test('a destination switched off mid-night pauses without spending an '
        'attempt', () async {
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      final targetId = await createWatchedFolder(db);
      var now = DateTime.utc(2026, 8, 16, 5);
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => _ScriptedTransport(
          kind: ArtifactDestinationKind.watchedFolder,
          openFailure: const DeliveryFailure(
            DeliveryFailureKind.destinationUnreachable,
            'the share is not mounted',
          ),
        ),
        clock: () => now,
      );
      await service.deliverJobArtifacts(await artifactSet());
      await DeliveryTargetsDao(db).update(targetId, enabled: false);

      now = now.add(const Duration(hours: 1));
      final report = await service.sweepDueRetries();

      expect(
        report.suspended,
        1,
        reason:
            'a switched-off destination is owed nothing until the operator '
            'switches it back on; counting it as retrying reads as work the '
            'sweep is about to do',
      );
      expect(report.retrying, 0);
      expect(
        report.destinations.single.problems.single,
        contains('switched off'),
      );
      expect(report.destinations.single.summary, contains('suspended'));
      expect((await DeliveryJournalDao(db).listForJob(1)).single.attempts, 1);
    });

    test(
      'the earliest due time is the policy\'s rung, not the sweep tick',
      () async {
        // What the sweeper's short cadence asks. Answering it from the journal
        // is what lets a row due 60 seconds from now be attempted 60 seconds
        // from now rather than at whatever tick comes next.
        final db = open();
        addTearDown(db.close);
        await enqueueJob(db);
        await createWatchedFolder(db);
        var now = DateTime.utc(2026, 8, 16, 5);
        final service = DeliveryService(
          targets: DeliveryTargetsDao(db),
          journal: DeliveryJournalDao(db),
          transportFactory: (_, __) => _ScriptedTransport(
            kind: ArtifactDestinationKind.watchedFolder,
            openFailure: const DeliveryFailure(
              DeliveryFailureKind.destinationUnreachable,
              'the share is not mounted',
            ),
          ),
          clock: () => now,
        );

        expect(
          await service.earliestRetryDueAt(),
          isNull,
          reason: 'an empty journal owes nothing, and no wake is needed for it',
        );

        await service.deliverJobArtifacts(await artifactSet());

        expect(
          await service.earliestRetryDueAt(),
          now.add(const Duration(minutes: 1)),
          reason: 'the first rung of the documented 1m/3m/9m ladder',
        );
        expect(await service.hasDueRetries(), isFalse);

        now = now.add(const Duration(seconds: 59));
        expect(await service.hasDueRetries(), isFalse);

        now = now.add(const Duration(seconds: 2));
        expect(
          await service.hasDueRetries(),
          isTrue,
          reason: 'a second past the rung is due; the sweeper wakes on this',
        );
      },
    );

    test('a suspended row is not a due row', () async {
      // A switched-off destination's rows stay `retrying` for as long as the
      // switch is off — the sweep states them and skips them without touching
      // the row. Counting them as due answers "due" on every 30-second check
      // for ever, which sweeps every OTHER destination on that cadence too.
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      final targetId = await createWatchedFolder(db);
      var now = DateTime.utc(2026, 8, 16, 5);
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => _ScriptedTransport(
          kind: ArtifactDestinationKind.watchedFolder,
          openFailure: const DeliveryFailure(
            DeliveryFailureKind.destinationUnreachable,
            'the share is not mounted',
          ),
        ),
        clock: () => now,
      );
      await service.deliverJobArtifacts(await artifactSet());
      await DeliveryTargetsDao(db).update(targetId, enabled: false);

      now = now.add(const Duration(hours: 6));
      expect(
        (await DeliveryJournalDao(db).listPendingRetry()).single.state,
        DeliveryAttemptState.retrying,
        reason: 'the row is still owed — it is just owed to a switch',
      );
      expect(await service.earliestRetryDueAt(), isNull);
      expect(await service.hasDueRetries(), isFalse);

      await DeliveryTargetsDao(db).update(targetId, enabled: true);

      expect(
        await service.hasDueRetries(),
        isTrue,
        reason: 'switching it back on is what makes the backlog due again',
      );
    });

    test('a file awaiting a peer\'s pull is not a due row', () async {
      // Measured against the release bundle: one published-but-unpulled peer
      // file made the 30-second due check answer "due" for ever, so the
      // sweeper ran a full pass and logged `peer-office: 1 awaiting pull`
      // every 30 seconds — seven identical INFO lines in 3 1/2 minutes, and
      // the row untouched throughout, because `_sweepDestination`
      // short-circuits a peer to awaitingPull and does no work at all. That is
      // the NORMAL state between the dawn job and the operator's morning.
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(
        db,
        name: 'peer-office',
        kind: ArtifactDestinationKind.peer,
      );
      var now = DateTime.utc(2026, 8, 16, 5);
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => _ScriptedTransport(
          kind: ArtifactDestinationKind.peer,
          disposition: DeliveryDisposition.awaitingPull,
        ),
        clock: () => now,
      );
      await service.deliverJobArtifacts(await artifactSet());

      expect(
        (await DeliveryJournalDao(db).listPendingRetry()).single.state,
        DeliveryAttemptState.retrying,
        reason: 'the row is still pending — it is pending on the peer',
      );
      now = now.add(const Duration(hours: 6));
      expect(await service.earliestRetryDueAt(), isNull);
      expect(
        await service.hasDueRetries(),
        isFalse,
        reason:
            'the next move is a pull by the desktop, not a retry by the '
            'rig, so there is nothing for the short cadence to wake for',
      );
    });

    test('a published file the rig has lost IS a due row, once', () async {
      // The peer arm can change exactly one thing about a published row: take
      // it terminal when the rig no longer holds the file. Nothing told the
      // short cadence about it, so the row said "waiting for the desktop to
      // pull" for up to fifteen minutes while the manifest endpoint had already
      // stopped offering it — measured against the release bundle, 200 seconds
      // of polling with `state=retrying, attempts=1, last_error=NULL`.
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(
        db,
        name: 'peer-office',
        kind: ArtifactDestinationKind.peer,
      );
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => _ScriptedTransport(
          kind: ArtifactDestinationKind.peer,
          disposition: DeliveryDisposition.awaitingPull,
        ),
      );
      await service.deliverJobArtifacts(await artifactSet());

      expect(
        await service.hasDueRetries(),
        isFalse,
        reason: 'the rig still holds it, so there is nothing to wake for',
      );

      await File(p.join(source.path, 'M31_Ha_master.fits')).delete();

      expect(
        await service.hasDueRetries(),
        isTrue,
        reason: 'the file left the rig; that is this rig\'s own fact to state',
      );

      await service.sweepDueRetries();

      final row = (await DeliveryJournalDao(db).listForJob(1)).single;
      expect(row.state, DeliveryAttemptState.failed);
      expect(row.lastError, contains('sourceMissing'));
      expect(
        row.attempts,
        1,
        reason: 'the sweep read the disk; it did not offer the file again',
      );
      expect(
        await service.hasDueRetries(),
        isFalse,
        reason:
            'a failed row is not pending, so this question can be answered '
            'yes at most once per file — which is what keeps it from being '
            'the permanent sweep loop counting awaiting-pull rows was',
      );
    });

    test('a suspended peer\'s lost file is not a due row', () async {
      // Off is off. The sweep returns before the peer arm on a switched-off
      // destination, so waking for one of its rows would run a pass that
      // touches nothing — the shape of the loop, with a missing file as the
      // excuse.
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      final targetId = await createWatchedFolder(
        db,
        name: 'peer-office',
        kind: ArtifactDestinationKind.peer,
      );
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => _ScriptedTransport(
          kind: ArtifactDestinationKind.peer,
          disposition: DeliveryDisposition.awaitingPull,
        ),
      );
      await service.deliverJobArtifacts(await artifactSet());
      await DeliveryTargetsDao(db).update(targetId, enabled: false);
      await File(p.join(source.path, 'M31_Ha_master.fits')).delete();

      expect(await service.hasDueRetries(), isFalse);

      await DeliveryTargetsDao(db).update(targetId, enabled: true);

      expect(
        await service.hasDueRetries(),
        isTrue,
        reason: 'switching it back on is what makes the row the rig\'s again',
      );
    });

    test(
      'a genuinely due row still wakes the check past an unpulled peer',
      () async {
        // The other half of the same claim: going quiet for the peer must not
        // go quiet for the destination that really is owed an attempt.
        final db = open();
        addTearDown(db.close);
        await enqueueJob(db);
        await createWatchedFolder(
          db,
          name: 'peer-office',
          kind: ArtifactDestinationKind.peer,
        );
        await createWatchedFolder(db, name: 'nas');
        var now = DateTime.utc(2026, 8, 16, 5);
        final service = DeliveryService(
          targets: DeliveryTargetsDao(db),
          journal: DeliveryJournalDao(db),
          transportFactory: (destination, _) =>
              destination.kind == ArtifactDestinationKind.peer
              ? _ScriptedTransport(
                  kind: ArtifactDestinationKind.peer,
                  disposition: DeliveryDisposition.awaitingPull,
                )
              : _ScriptedTransport(
                  kind: ArtifactDestinationKind.watchedFolder,
                  openFailure: const DeliveryFailure(
                    DeliveryFailureKind.destinationUnreachable,
                    'the share is not mounted',
                  ),
                ),
          clock: () => now,
        );
        await service.deliverJobArtifacts(await artifactSet());

        expect(
          await service.earliestRetryDueAt(),
          now.add(const Duration(minutes: 1)),
          reason: 'the share\'s own first rung, unaffected by the peer row',
        );
        expect(await service.hasDueRetries(), isFalse);

        now = now.add(const Duration(minutes: 1, seconds: 1));
        expect(await service.hasDueRetries(), isTrue);
      },
    );

    test('a source deleted between attempts stops being retried', () async {
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      await createWatchedFolder(db);
      var now = DateTime.utc(2026, 8, 16, 5);
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) => _ScriptedTransport(
          kind: ArtifactDestinationKind.watchedFolder,
          openFailure: const DeliveryFailure(
            DeliveryFailureKind.destinationUnreachable,
            'the share is not mounted',
          ),
        ),
        clock: () => now,
      );
      final set = await artifactSet();
      await service.deliverJobArtifacts(set);
      await File(set.artifacts.single.sourcePath).delete();

      now = now.add(const Duration(hours: 1));
      final report = await service.sweepDueRetries();

      expect(report.failed, 1);
      final row = (await DeliveryJournalDao(db).listForJob(1)).single;
      expect(row.state, DeliveryAttemptState.failed);
      expect(row.lastError, contains('sourceMissing'));
    });

    // `delivery_journal.last_error` is the sentence the morning report and the
    // Settings > Delivery status line both print. It used to name the act and
    // not the cause — "failed: Cannot copy file to '<staged path>'" — for
    // every refusal the filesystem could make, so a full drive, a read-only
    // mount and a name the filesystem would not take all read identically.
    // The real transport, a real refused copy, and the row the operator reads.
    test('a copy the filesystem refuses journals the reason it gave, not just '
        'that it failed', () async {
      final db = open();
      addTearDown(db.close);
      await enqueueJob(db);
      final drop = await Directory(p.join(tempDir.path, 'drop')).create();
      await DeliveryTargetsDao(db).create(
        name: 'nas',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: jsonEncode({'path': drop.path, kDeliveryRigIdKey: ''}),
        content: const {ArtifactContent.linearMasters},
      );
      final set = await artifactSet();
      // A directory sitting on the staged name. `File.copy` onto a directory
      // is EISDIR on every platform Skotiq ships to, and unlike a
      // permission bit no user — root included — can copy over it, so this
      // reproduces a genuine OS refusal deterministically.
      await Directory(
        p.join(
          drop.path,
          '.${set.artifacts.single.fileName}.1$kStagedDeliverySuffix',
        ),
      ).create();

      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (destination, jobId) =>
            WatchedFolderTransport(destination: destination, jobId: jobId),
      );

      final report = await service.deliverJobArtifacts(set);
      expect(report.delivered, 0);

      final row = (await DeliveryJournalDao(db).listForJob(1)).single;
      expect(row.lastError, contains('M31_Ha_master.fits'));
      expect(
        row.lastError,
        contains('errno '),
        reason: 'the operator sentence must carry the reason the OS gave',
      );
      expect(
        row.lastError,
        isNot(endsWith("$kStagedDeliverySuffix'")),
        reason: 'the sentence used to end at the act it could not perform',
      );
    });
  });

  group('the retry schedule', () {
    test('backs off geometrically and then holds at the ceiling', () {
      const policy = DeliveryRetryPolicy.standard;

      expect(policy.backoffAfter(1), const Duration(minutes: 1));
      expect(policy.backoffAfter(2), const Duration(minutes: 3));
      expect(policy.backoffAfter(3), const Duration(minutes: 9));
      expect(policy.backoffAfter(4), const Duration(minutes: 27));
      expect(policy.backoffAfter(5), const Duration(minutes: 30));
      expect(policy.backoffAfter(50), const Duration(minutes: 30));
    });

    test('spends its budget and stops', () {
      const policy = DeliveryRetryPolicy.standard;

      expect(policy.isExhausted(7), isFalse);
      expect(policy.isExhausted(8), isTrue);
    });
  });
}

/// A transport that fails with something that is not a [DeliveryFailure], the
/// way a driver bug or a platform exception would.
class _ThrowingTransport implements ArtifactTransport {
  @override
  ArtifactDestinationKind get kind => ArtifactDestinationKind.watchedFolder;

  @override
  Future<void> open(List<DeliveryFile> artifacts) async {}

  @override
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact) async {
    throw StateError('the driver fell over');
  }

  @override
  Future<void> close() async {}
}
