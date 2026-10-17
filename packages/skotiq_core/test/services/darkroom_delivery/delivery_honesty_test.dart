// What delivery is allowed to SAY about a failure.
//
// Four statements the morning report and the retry sweep both read, each one
// pinned here because getting it wrong sends the operator after the wrong
// thing:
//
//   1. A staged copy lives in the DESTINATION. When it cannot be read back,
//      the SOURCE is stat-ed at failure time and the verdict names whichever
//      side actually went away — a vanished NAS is retryable and must never be
//      recorded as the rig having lost the master.
//   2. A journal write that itself fails is an unjournalled file, not a
//      retrying one. Nothing persisted means no sweep will ever pick it up, so
//      counting it as "retrying" promises a retry that cannot happen.
//   3. A destination that selected nothing, or selected a class this job did
//      not produce, says so — it is not folded into "no destination is
//      enabled".
//   4. A destination list that could not be read is not the same fact as an
//      empty one.

import 'dart:async';
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
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_service.dart';
import 'package:path/path.dart' as p;

/// Bytes enough that the copy is still in flight when a zero-delay timer runs.
/// The copy happens on the IO thread pool, so the event loop is free the
/// instant [AtomicFileWrite.stage] awaits it.
const int _bigEnoughToRace = 256 * 1024 * 1024;

/// A transport that always accepts the file, so every assertion below is
/// about what the SERVICE said, not about a transport failing.
class _ScriptedTransport implements ArtifactTransport {
  _ScriptedTransport({required this.kind});

  @override
  final ArtifactDestinationKind kind;

  final List<String> delivered = [];

  @override
  Future<void> open(List<DeliveryFile> artifacts) async {}

  @override
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact) async {
    delivered.add(artifact.sourcePath);
    return TransportDeliveryOutcome(
      disposition: DeliveryDisposition.delivered,
      checksum: artifact.checksum,
      destinationDescription: 'test://${artifact.fileName}',
    );
  }

  @override
  Future<void> close() async {}
}

/// A journal whose writes are refused, the way a locked or read-only database
/// refuses them.
class _RefusingJournal extends DeliveryJournalDao {
  _RefusingJournal(super.db);

  int recordAttemptCalls = 0;

  @override
  Future<DeliveryJournalEntry> recordAttempt({
    required int targetId,
    required int jobId,
    required String filePath,
    int? bytes,
    DateTime? now,
  }) async {
    recordAttemptCalls++;
    throw StateError('database is locked');
  }
}

/// A targets DAO whose list read fails, the way a corrupt page does.
class _UnreadableTargets extends DeliveryTargetsDao {
  _UnreadableTargets(super.db);

  @override
  Future<DeliveryTargetsRead> readEnabled() async {
    throw StateError('database disk image is malformed');
  }
}

void main() {
  late Directory tempDir;
  late Directory source;
  late Directory destination;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_delivery_honesty_');
    source = await Directory(p.join(tempDir.path, 'masters')).create();
    destination = await Directory(p.join(tempDir.path, 'nas')).create();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<DeliveryFile> master(String name, {int bytes = 64}) async {
    final file = File(p.join(source.path, name));
    await file.writeAsBytes(List<int>.filled(bytes, 7));
    return DeliveryFile.describe(file.path);
  }

  group('a staged copy that cannot be read back', () {
    test('names the destination, not the source, when the destination is '
        'removed mid-copy', () async {
      final path = p.join(source.path, 'huge_master.fits');
      final handle = await File(path).open(mode: FileMode.write);
      await handle.setPosition(_bigEnoughToRace - 1);
      await handle.writeByte(0);
      await handle.close();
      final artifact = await DeliveryFile.describe(path);

      // The NAS goes away while the bytes are in flight — the harness case,
      // in-process. The copy runs on the IO pool, so this timer fires first.
      Timer(Duration.zero, () => destination.deleteSync(recursive: true));

      await expectLater(
        AtomicFileWrite.stage(
          artifact: artifact,
          deliveredName: artifact.fileName,
          directory: destination,
          jobId: 7,
        ),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.destinationUnreachable,
              )
              .having((f) => f.retryable, 'retryable', isTrue)
              .having((f) => f.message, 'message', contains(destination.path))
              .having(
                (f) => f.message,
                'message',
                contains('still on the rig'),
              ),
        ),
      );
      expect(
        await File(path).exists(),
        isTrue,
        reason: 'delivery copies; the source is never the casualty',
      );
    });

    test('says sourceMissing only when the source really is gone', () async {
      final artifact = await master('vanished.fits');
      await File(artifact.sourcePath).delete();

      await expectLater(
        AtomicFileWrite.stage(
          artifact: artifact,
          deliveredName: artifact.fileName,
          directory: destination,
          jobId: 7,
        ),
        throwsA(
          isA<DeliveryFailure>()
              .having((f) => f.kind, 'kind', DeliveryFailureKind.sourceMissing)
              .having((f) => f.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('a destination that refuses the read back is the destination\'s '
        'permissions', () async {
      final artifact = await master('locked.fits');
      // The staged name exists already, writable but not readable. The copy
      // lands; reading it back is what the destination refuses.
      final stagedPath = p.join(
        destination.path,
        '.${artifact.fileName}.7$kStagedDeliverySuffix',
      );
      await File(stagedPath).writeAsBytes(const []);
      final chmod = await Process.run('chmod', ['0222', stagedPath]);
      expect(chmod.exitCode, 0, reason: 'the test needs a write-only file');

      await expectLater(
        AtomicFileWrite.stage(
          artifact: artifact,
          deliveredName: artifact.fileName,
          directory: destination,
          jobId: 7,
        ),
        throwsA(
          isA<DeliveryFailure>()
              .having(
                (f) => f.kind,
                'kind',
                DeliveryFailureKind.permissionDenied,
              )
              .having((f) => f.message, 'message', contains(stagedPath))
              .having(
                (f) => f.message,
                'message',
                contains('still on the rig'),
              ),
        ),
      );
      expect(await File(artifact.sourcePath).exists(), isTrue);
    });
  });

  group('a delivery service that cannot write its journal', () {
    late File dbFile;

    setUp(() {
      dbFile = File(p.join(tempDir.path, 'skotiq.db'));
    });

    SkotiqDatabase open() => SkotiqDatabase.forTesting(NativeDatabase(dbFile));

    Future<int> destinationRow(
      SkotiqDatabase db, {
      String name = 'nas',
      Set<ArtifactContent> content = const {ArtifactContent.linearMasters},
    }) {
      return DeliveryTargetsDao(db).create(
        name: name,
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: jsonEncode({'path': destination.path}),
        content: content,
      );
    }

    Future<DeliveryArtifactSet> artifactSet(
      int jobId, {
      ArtifactContent content = ArtifactContent.linearMasters,
    }) async {
      final file = await master('L_master.fits');
      return DeliveryArtifactSet.build(
        jobId: jobId,
        sources: {
          content: [file.sourcePath],
        },
      );
    }

    test('counts the file as unjournalled, never as retrying', () async {
      final db = open();
      addTearDown(db.close);
      final jobId = await DarkroomJobsDao(db).enqueue();
      await destinationRow(db);
      final journal = _RefusingJournal(db);
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: journal,
        transportFactory: (_, __) =>
            _ScriptedTransport(kind: ArtifactDestinationKind.watchedFolder),
        journalWriteBackoff: Duration.zero,
      );

      final report = await service.deliverJobArtifacts(
        await artifactSet(jobId),
      );

      expect(
        report.retrying,
        0,
        reason: 'nothing persisted, so no sweep can ever retry it',
      );
      expect(report.unjournalled, 1);
      expect(report.everythingLanded, isFalse);
      expect(report.destinations.single.problems.single, contains('journal'));
      expect(
        report.summary,
        contains('1 not journalled'),
        reason: 'the morning report states the journal write failed',
      );
      expect(
        journal.recordAttemptCalls,
        greaterThan(1),
        reason: 'a journal write is asked again, a bounded number of times',
      );
      expect(await DeliveryJournalDao(db).listForJob(jobId), isEmpty);
    });
  });

  group('a destination that is given no files', () {
    late File dbFile;

    setUp(() {
      dbFile = File(p.join(tempDir.path, 'skotiq.db'));
    });

    SkotiqDatabase open() => SkotiqDatabase.forTesting(NativeDatabase(dbFile));

    test('with nothing selected says so instead of "no destination is '
        'enabled"', () async {
      final db = open();
      addTearDown(db.close);
      final jobId = await DarkroomJobsDao(db).enqueue();
      await DeliveryTargetsDao(db).create(
        name: 'spare-drive',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: jsonEncode({'path': destination.path}),
        content: const {},
      );
      final service = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) =>
            _ScriptedTransport(kind: ArtifactDestinationKind.watchedFolder),
      );
      final file = await master('L_master.fits');

      final report = await service.deliverJobArtifacts(
        await DeliveryArtifactSet.build(
          jobId: jobId,
          sources: {
            ArtifactContent.linearMasters: [file.sourcePath],
          },
        ),
      );

      expect(report.destinations, hasLength(1));
      expect(report.summary, contains('spare-drive'));
      expect(report.summary, contains('nothing selected'));
      expect(report.summary, isNot(contains('No delivery destination')));
    });

    test(
      'that selected a class this job did not produce says which class',
      () async {
        final db = open();
        addTearDown(db.close);
        final jobId = await DarkroomJobsDao(db).enqueue();
        await DeliveryTargetsDao(db).create(
          name: 'report-only',
          kind: ArtifactDestinationKind.watchedFolder,
          configJson: jsonEncode({'path': destination.path}),
          content: const {ArtifactContent.nightReport},
        );
        final service = DeliveryService(
          targets: DeliveryTargetsDao(db),
          journal: DeliveryJournalDao(db),
          transportFactory: (_, __) =>
              _ScriptedTransport(kind: ArtifactDestinationKind.watchedFolder),
        );
        final file = await master('L_master.fits');

        final report = await service.deliverJobArtifacts(
          await DeliveryArtifactSet.build(
            jobId: jobId,
            sources: {
              ArtifactContent.linearMasters: [file.sourcePath],
            },
          ),
        );

        expect(report.summary, contains('report-only'));
        expect(report.summary, contains(ArtifactContent.nightReport.wire));
        expect(report.summary, isNot(contains('No delivery destination')));
      },
    );

    test(
      'a destination list that could not be read is not an empty one',
      () async {
        final db = open();
        addTearDown(db.close);
        final jobId = await DarkroomJobsDao(db).enqueue();
        final service = DeliveryService(
          targets: _UnreadableTargets(db),
          journal: DeliveryJournalDao(db),
          transportFactory: (_, __) =>
              _ScriptedTransport(kind: ArtifactDestinationKind.watchedFolder),
        );
        final file = await master('L_master.fits');

        final report = await service.deliverJobArtifacts(
          await DeliveryArtifactSet.build(
            jobId: jobId,
            sources: {
              ArtifactContent.linearMasters: [file.sourcePath],
            },
          ),
        );

        expect(report.summary, isNot(contains('No delivery destination')));
        expect(report.summary, contains('could not be read'));
        expect(report.everythingLanded, isFalse);
      },
    );
  });
}
