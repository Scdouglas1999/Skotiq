// Three facts delivery has to keep straight when something is wrong with a
// destination or with the operator's patience:
//
//   1. ONE UNDECODABLE ROW COSTS ONLY ITSELF. `delivery_targets` rows are
//      decoded one by one; a row this build cannot read is named in the
//      report and skipped, and every other destination still receives the
//      night. It used to abort the whole read, so a single bad row meant
//      NOTHING was delivered anywhere and nothing was journalled.
//   2. AN UNPARSEABLE CONFIG IS A CONFIGURATION ERROR. `config_json` that is
//      not JSON is terminal and named, not a retryable `transportFailure`
//      carrying a raw `FormatException` — a row whose text never changes must
//      not spend the night's retry budget.
//   3. A STOP LEAVES THE FILES OWED. Files the pass had not reached when the
//      operator stopped it keep `retrying` rows with their attempt counts
//      untouched, so the next sweep — including the one the next boot runs —
//      resumes them. They used to be written `failed`, which is terminal, and
//      the sweep reads only `retrying`.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/darkroom_jobs_dao.dart';
import 'package:skotiq_core/src/database/daos/delivery_journal_dao.dart';
import 'package:skotiq_core/src/database/daos/delivery_targets_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/darkroom/delivery.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/artifact_transport.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_artifact.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_service.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_transport_factory.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/watched_folder_transport.dart';
import 'package:skotiq_core/src/services/notification/secrets_store.dart';
import 'package:path/path.dart' as p;

/// Accepts every file and records what it was handed.
class _AcceptingTransport implements ArtifactTransport {
  final List<String> delivered = [];

  @override
  ArtifactDestinationKind get kind => ArtifactDestinationKind.watchedFolder;

  @override
  Future<void> open(List<DeliveryFile> artifacts) async {}

  @override
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact) async {
    delivered.add(artifact.fileName);
    return TransportDeliveryOutcome(
      disposition: DeliveryDisposition.delivered,
      checksum: artifact.checksum,
      destinationDescription: 'test://${artifact.fileName}',
    );
  }

  @override
  Future<void> close() async {}
}

/// Reports free space without touching a real filesystem.
class _AmpleSpace implements FreeSpaceProbe {
  @override
  Future<int> freeBytes(String path) async => 1 << 40;
}

void main() {
  late Directory tempDir;
  late Directory sourceDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_delivery_isolation_');
    sourceDir = await Directory(p.join(tempDir.path, 'masters')).create();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  SkotiqDatabase open() => SkotiqDatabase.forTesting(NativeDatabase.memory());

  Future<String> master(String name) async {
    final file = File(p.join(sourceDir.path, name));
    await file.writeAsBytes(List<int>.filled(4096, 7));
    return file.path;
  }

  /// Write a `delivery_targets` row straight through SQL, so a value the DAO
  /// would never write — an artifact class this build does not know — can be
  /// put in the column exactly as an older build or a hand edit leaves it.
  Future<int> insertRow(
    SkotiqDatabase db, {
    required String name,
    required String configJson,
    required String contentJson,
    String kind = 'watched_folder',
  }) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
      'INSERT INTO delivery_targets('
      'name, kind, config_json, enabled, content_json, created_at, updated_at'
      ') VALUES (?, ?, ?, 1, ?, ?, ?)',
      [name, kind, configJson, contentJson, now, now],
    );
    final rows = await db
        .customSelect(
          'SELECT id FROM delivery_targets WHERE name = ?',
          variables: [Variable<String>(name)],
        )
        .get();
    return rows.single.read<int>('id');
  }

  group('an undecodable destination row', () {
    test(
      'is its own failure and never voids the destinations that decode',
      () async {
        final db = open();
        addTearDown(db.close);
        final dropDir = await Directory(p.join(tempDir.path, 'good')).create();
        await insertRow(
          db,
          name: 'good-nas',
          configJson: jsonEncode({'path': dropDir.path, 'rigId': 'rig'}),
          contentJson: jsonEncode(['linear_masters']),
        );
        final badId = await insertRow(
          db,
          name: 'bad-row',
          configJson: jsonEncode({'path': dropDir.path}),
          contentJson: jsonEncode(['hdr_composite']),
        );

        final read = await DeliveryTargetsDao(db).readEnabled();
        expect(read.destinations.map((d) => d.name), ['good-nas']);
        expect(read.undecodable.single.id, badId);
        expect(read.undecodable.single.label, 'bad-row');

        final transport = _AcceptingTransport();
        final jobId = await DarkroomJobsDao(db).enqueue();
        final report =
            await DeliveryService(
              targets: DeliveryTargetsDao(db),
              journal: DeliveryJournalDao(db),
              transportFactory: (_, __) => transport,
            ).deliverJobArtifacts(
              await DeliveryArtifactSet.build(
                jobId: jobId,
                sources: {
                  ArtifactContent.linearMasters: [await master('L.fits')],
                },
              ),
            );

        // The readable destination received the night.
        expect(transport.delivered, ['L.fits']);
        expect(report.delivered, 1);
        // And the row that would not decode is named on its own.
        expect(report.problems.single, contains('bad-row'));
        expect(report.problems.single, contains('hdr_composite'));
        expect(report.everythingLanded, isFalse);
      },
    );

    test('names the constraint that actually rejected the value', () async {
      final db = open();
      addTearDown(db.close);
      await insertRow(
        db,
        name: 'bad-content',
        configJson: '{}',
        contentJson: jsonEncode(['hdr_composite']),
      );

      final reason = (await DeliveryTargetsDao(
        db,
      ).readAll()).undecodable.single.reason;
      // `content_json` carries no CHECK constraint (see
      // `_createDarkroomTables`); saying it does points the operator at a
      // database rule that never ran.
      expect(reason, isNot(contains('CHECK')));
      expect(reason, contains('hdr_composite'));
      expect(reason, contains('linear_masters'));
      expect(reason, contains('free text'));
    });

    test('a row whose kind is outside the CHECK says so', () async {
      final db = open();
      addTearDown(db.close);
      // The column's CHECK is what a legal `kind` is enforced by, so a row
      // that carries an illegal one is written with the constraint off.
      await db.customStatement('PRAGMA ignore_check_constraints = ON');
      await insertRow(
        db,
        name: 'bad-kind',
        kind: 'carrier_pigeon',
        configJson: '{}',
        contentJson: jsonEncode(['linear_masters']),
      );

      final reason = (await DeliveryTargetsDao(
        db,
      ).readAll()).undecodable.single.reason;
      expect(reason, contains('carrier_pigeon'));
      expect(reason, contains('CHECK'));
    });
  });

  group('a destination whose config_json is not JSON', () {
    test(
      'fails terminally as a configuration error, not a transport one',
      () async {
        final db = open();
        addTearDown(db.close);
        await insertRow(
          db,
          name: 'broken-config',
          configJson: 'not json at all',
          contentJson: jsonEncode(['linear_masters']),
        );

        final journal = DeliveryJournalDao(db);
        final targets = DeliveryTargetsDao(db);
        final jobId = await DarkroomJobsDao(db).enqueue();
        final report =
            await DeliveryService(
              targets: targets,
              journal: journal,
              transportFactory: DefaultArtifactTransportFactory(
                secrets: SecretsStore(InMemorySecureKeyValueStore()),
                targets: targets,
                freeSpace: _AmpleSpace(),
              ).call,
            ).deliverJobArtifacts(
              await DeliveryArtifactSet.build(
                jobId: jobId,
                sources: {
                  ArtifactContent.linearMasters: [await master('L.fits')],
                },
              ),
            );

        expect(report.failed, 1);
        expect(report.retrying, 0, reason: 'no attempt can change the text');
        final row = (await journal.listForJob(jobId)).single;
        expect(row.state, DeliveryAttemptState.failed);
        expect(row.lastError, contains('configurationInvalid'));
        expect(row.lastError, isNot(contains('FormatException')));
        expect(row.lastError, contains('not JSON'));
      },
    );
  });

  group('a stop during delivery', () {
    test(
      'leaves the files it did not reach owed, and never reports success',
      () async {
        final db = open();
        addTearDown(db.close);
        await insertRow(
          db,
          name: 'nas',
          configJson: jsonEncode({'path': tempDir.path}),
          contentJson: jsonEncode(['linear_masters']),
        );

        final journal = DeliveryJournalDao(db);
        final jobId = await DarkroomJobsDao(db).enqueue();
        final transport = _AcceptingTransport();
        // Stop after the first file has been handed over.
        final report =
            await DeliveryService(
              targets: DeliveryTargetsDao(db),
              journal: journal,
              transportFactory: (_, __) => transport,
            ).deliverJobArtifacts(
              await DeliveryArtifactSet.build(
                jobId: jobId,
                sources: {
                  ArtifactContent.linearMasters: [
                    await master('L.fits'),
                    await master('R.fits'),
                    await master('G.fits'),
                  ],
                },
              ),
              isCancelled: () => transport.delivered.isNotEmpty,
            );

        expect(transport.delivered, ['L.fits']);
        expect(report.delivered, 1);
        expect(report.stoppedPending, 2);
        expect(report.failed, 0, reason: 'a stop is not a failure');
        expect(report.everythingLanded, isFalse);
        expect(report.wasStopped, isTrue);
        expect(
          report.destinations.single.summary,
          contains('stopped during delivery, 2 files pending'),
        );

        // The sweep reads `retrying` rows and nothing else, so this is the
        // whole test of "will they ever be picked up again".
        final owed = await journal.listPendingRetry();
        expect(owed.map((row) => p.basename(row.filePath)).toSet(), {
          'R.fits',
          'G.fits',
        });
        // No attempt was made, so no attempt was charged.
        expect(owed.map((row) => row.attempts).toSet(), {0});
        expect(owed.first.lastError, contains('still owed'));
      },
    );

    test(
      'does not reset the budget of a row a sweep had already spent',
      () async {
        final db = open();
        addTearDown(db.close);
        final journal = DeliveryJournalDao(db);
        final targetId = await insertRow(
          db,
          name: 'nas',
          configJson: jsonEncode({'path': tempDir.path}),
          contentJson: jsonEncode(['linear_masters']),
        );
        final jobId = await DarkroomJobsDao(db).enqueue();
        final path = await master('L.fits');
        // Three attempts already spent on this file by earlier passes.
        for (var i = 0; i < 3; i++) {
          await journal.recordAttempt(
            targetId: targetId,
            jobId: jobId,
            filePath: path,
          );
        }
        expect((await journal.listPendingRetry()).single.attempts, 3);

        await journal.recordStillOwed(
          targetId: targetId,
          jobId: jobId,
          filePath: path,
          reason: 'stopped',
        );

        final row = (await journal.listPendingRetry()).single;
        expect(row.attempts, 3);
        expect(row.state, DeliveryAttemptState.retrying);
      },
    );
  });
}
