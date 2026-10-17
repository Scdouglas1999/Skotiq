// The rig's side of peer delivery, end to end over a real v58 database: the
// publication is journal rows, the manifest is built from them, and an
// acknowledgement is the only thing that turns a published row into a
// delivered one.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/darkroom_jobs_dao.dart';
import 'package:skotiq_core/src/database/daos/delivery_journal_dao.dart';
import 'package:skotiq_core/src/database/daos/delivery_targets_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/darkroom/delivery.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_artifact.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_failure.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_manifest.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/delivery_service.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/peer_manifest_service.dart';
import 'package:skotiq_core/src/services/darkroom_delivery/peer_publication_transport.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late Directory source;
  late SkotiqDatabase db;
  late DeliveryTargetsDao targets;
  late DeliveryJournalDao journal;
  late PeerManifestService peers;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_peer_manifest_');
    source = await Directory(p.join(tempDir.path, 'masters')).create();
    db = SkotiqDatabase.forTesting(
      NativeDatabase(File(p.join(tempDir.path, 'skotiq.db'))),
    );
    targets = DeliveryTargetsDao(db);
    journal = DeliveryJournalDao(db);
    peers = PeerManifestService(targets: targets, journal: journal);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<int> createPeer(String peerId, {bool enabled = true}) {
    return targets.create(
      name: peerId,
      kind: ArtifactDestinationKind.peer,
      // `rigId` is pinned so the manifest's names do not depend on whatever
      // this machine calls itself; the default-from-the-host-name path has its
      // own test in delivery_naming_test.dart.
      configJson: jsonEncode({'peerId': peerId, 'rigId': 'shed-rig'}),
      enabled: enabled,
      content: const {
        ArtifactContent.linearMasters,
        ArtifactContent.nightReport,
      },
    );
  }

  Future<DeliveryArtifactSet> publishSet(
    int jobId, {
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

  DeliveryService serviceFor() => DeliveryService(
    targets: targets,
    journal: journal,
    transportFactory: (destination, jobId) =>
        PeerPublicationTransport(destination: destination, jobId: jobId),
  );

  test(
    'publishing writes journal rows the manifest is then built from',
    () async {
      final jobId = await DarkroomJobsDao(db).enqueue();
      await createPeer('office-pc');
      final set = await publishSet(jobId, names: ['a.fits', 'b.fits']);

      final report = await serviceFor().deliverJobArtifacts(set);
      final manifest = await peers.buildManifest(
        jobId: jobId,
        peerId: 'office-pc',
      );

      expect(report.awaitingPull, 2);
      expect(manifest.jobId, jobId);
      expect(manifest.peerId, 'office-pc');
      expect(manifest.entries.length, 2);
      expect(
        manifest.totalBytes,
        set.artifacts.fold<int>(0, (s, a) => s + a.bytes),
      );
      for (final entry in manifest.entries) {
        // Joined on the artifact id — the hash of the rig-side path — because
        // the name the desktop writes is no longer the rig's own name.
        final artifact = set.artifacts.firstWhere(
          (a) => artifactIdForPath(a.sourcePath) == entry.artifactId,
        );
        expect(entry.checksum, artifact.checksum);
        expect(entry.bytes, artifact.bytes);
        expect(
          entry.fileName,
          'shed-rig-${artifact.fileName}',
          reason:
              'the desktop writes a name that says which rig it came '
              'from, so two rigs pulling into one folder do not collide',
        );
      }
    },
  );

  test('one desktop never sees another desktop\'s night', () async {
    final jobId = await DarkroomJobsDao(db).enqueue();
    final officeId = await createPeer('office-pc');
    await createPeer('laptop');
    await serviceFor().deliverJobArtifacts(await publishSet(jobId));

    final office = await peers.buildManifest(jobId: jobId, peerId: 'office-pc');

    expect(office.entries.single.targetId, officeId);
    final laptop = await peers.buildManifest(jobId: jobId, peerId: 'laptop');
    expect(laptop.entries.single.targetId, isNot(officeId));
  });

  test(
    'an unrecognised peer is refused rather than served everything',
    () async {
      final jobId = await DarkroomJobsDao(db).enqueue();
      await createPeer('office-pc');
      await serviceFor().deliverJobArtifacts(await publishSet(jobId));

      await expectLater(
        peers.buildManifest(jobId: jobId, peerId: 'someone-elses-desktop'),
        throwsA(isA<UnknownDeliveryPeerException>()),
      );
    },
  );

  test('a disabled peer destination stops answering', () async {
    final jobId = await DarkroomJobsDao(db).enqueue();
    final id = await createPeer('office-pc');
    await serviceFor().deliverJobArtifacts(await publishSet(jobId));
    await targets.update(id, enabled: false);

    await expectLater(
      peers.buildManifest(jobId: jobId, peerId: 'office-pc'),
      throwsA(isA<UnknownDeliveryPeerException>()),
    );
  });

  test('a published file that is gone is stated as unavailable, not quietly '
      'dropped', () async {
    final jobId = await DarkroomJobsDao(db).enqueue();
    await createPeer('office-pc');
    final set = await publishSet(jobId, names: ['a.fits', 'b.fits']);
    await serviceFor().deliverJobArtifacts(set);
    await File(set.artifacts.first.sourcePath).delete();

    final manifest = await peers.buildManifest(
      jobId: jobId,
      peerId: 'office-pc',
    );

    expect(manifest.entries.length, 1);
    expect(manifest.unavailable.length, 1);
    expect(
      manifest.unavailable.single.artifactId,
      artifactIdForPath(set.artifacts.first.sourcePath),
    );
    expect(manifest.unavailable.single.reason, contains('sourceMissing'));
  });

  test('a file the sweep already recorded as lost is still named to the '
      'desktop, and is no longer offered', () async {
    // The rig's sweep now marks a published file it has lost as terminal, so
    // the two peer surfaces meet at that row. Skipping every `failed` row
    // outright would have made the file vanish from the manifest entirely the
    // moment the sweep noticed it — a desktop that pulled before the sweep and
    // one that pulled after it would report different nights.
    final jobId = await DarkroomJobsDao(db).enqueue();
    await createPeer('office-pc');
    final set = await publishSet(jobId, names: ['a.fits', 'b.fits']);
    final service = serviceFor();
    await service.deliverJobArtifacts(set);
    await File(set.artifacts.first.sourcePath).delete();
    final swept = await service.sweepDueRetries();
    expect(swept.failed, 1, reason: 'the sweep is what marks the row terminal');

    final manifest = await peers.buildManifest(
      jobId: jobId,
      peerId: 'office-pc',
    );

    expect(manifest.entries.length, 1);
    expect(
      manifest.entries.single.artifactId,
      artifactIdForPath(set.artifacts.last.sourcePath),
      reason: 'the file that is still on the rig is the one still offered',
    );
    expect(manifest.unavailable.length, 1);
    expect(
      manifest.unavailable.single.artifactId,
      artifactIdForPath(set.artifacts.first.sourcePath),
    );
    expect(
      manifest.unavailable.single.reason,
      contains('sourceMissing'),
      reason: 'the desktop reads the reason the rig recorded, not a new guess',
    );
  });

  test('a file this desktop already acknowledged is not offered again, and is '
      'still served on request', () async {
    // The manifest is what the desktop still has to pull. Every other
    // transport stops at `delivered` too, and offering an acknowledged file
    // back told the desktop it still owed a pull it had already made. The
    // download endpoint is deliberately unchanged: a desktop holding the id
    // from an earlier manifest can still fetch the bytes and acknowledge them
    // again.
    final jobId = await DarkroomJobsDao(db).enqueue();
    await createPeer('office-pc');
    final set = await publishSet(jobId, names: ['a.fits', 'b.fits']);
    await serviceFor().deliverJobArtifacts(set);
    final pulled = set.artifacts.first;

    await peers.acknowledgePull(
      jobId: jobId,
      peerId: 'office-pc',
      artifactId: artifactIdForPath(pulled.sourcePath),
      checksum: pulled.checksum,
    );

    final manifest = await peers.buildManifest(
      jobId: jobId,
      peerId: 'office-pc',
    );

    expect(manifest.entries.map((e) => e.artifactId), [
      artifactIdForPath(set.artifacts.last.sourcePath),
    ]);
    expect(
      manifest.unavailable,
      isEmpty,
      reason: 'nothing went wrong with a file the desktop has',
    );
    expect(
      await peers.resolveArtifact(
        jobId: jobId,
        peerId: 'office-pc',
        artifactId: artifactIdForPath(pulled.sourcePath),
      ),
      isNotNull,
      reason: 'the bytes are still served to a desktop that asks for them',
    );
  });

  group('resolving an id', () {
    test('finds the file the manifest named', () async {
      final jobId = await DarkroomJobsDao(db).enqueue();
      final targetId = await createPeer('office-pc');
      final set = await publishSet(jobId);
      await serviceFor().deliverJobArtifacts(set);

      final resolved = await peers.resolveArtifact(
        jobId: jobId,
        peerId: 'office-pc',
        artifactId: artifactIdForPath(set.artifacts.single.sourcePath),
      );

      expect(resolved, isNotNull);
      expect(resolved!.filePath, set.artifacts.single.sourcePath);
      expect(resolved.targetId, targetId);
      expect(resolved.jobId, jobId);
      // The download's `Content-Disposition` is built from this, and it used
      // to carry the rig's bare file name while the manifest promised the
      // namespaced one. Any puller that saves what the header says — `curl
      // -OJ`, a browser — then wrote the very name the namespacing exists to
      // keep two rigs off.
      expect(
        resolved.fileName,
        'shed-rig-${set.artifacts.single.fileName}',
        reason: 'the resolved name is the name the manifest published',
      );
    });

    test('the resolved name is exactly the manifest entry\'s name', () async {
      final jobId = await DarkroomJobsDao(db).enqueue();
      await createPeer('office-pc');
      final set = await publishSet(jobId, names: ['a.fits', 'b.fits']);
      await serviceFor().deliverJobArtifacts(set);

      final manifest = await peers.buildManifest(
        jobId: jobId,
        peerId: 'office-pc',
      );
      for (final entry in manifest.entries) {
        final resolved = await peers.resolveArtifact(
          jobId: jobId,
          peerId: 'office-pc',
          artifactId: entry.artifactId,
        );
        expect(resolved!.fileName, entry.fileName);
      }
    });

    test('refuses an id this job never published', () async {
      final jobId = await DarkroomJobsDao(db).enqueue();
      await createPeer('office-pc');
      await serviceFor().deliverJobArtifacts(await publishSet(jobId));

      expect(
        await peers.resolveArtifact(
          jobId: jobId,
          peerId: 'office-pc',
          artifactId: artifactIdForPath('/etc/passwd'),
        ),
        isNull,
      );
    });

    test('refuses an id another peer\'s row owns', () async {
      final jobId = await DarkroomJobsDao(db).enqueue();
      await createPeer('office-pc');
      final set = await publishSet(jobId);
      await serviceFor().deliverJobArtifacts(set);
      // `laptop` exists but was configured after the publication, so no row of
      // this job belongs to it.
      await createPeer('laptop');

      expect(
        await peers.resolveArtifact(
          jobId: jobId,
          peerId: 'laptop',
          artifactId: artifactIdForPath(set.artifacts.single.sourcePath),
        ),
        isNull,
      );
    });
  });

  group('acknowledging a pull', () {
    test('is what turns a published row into a delivered one', () async {
      final jobId = await DarkroomJobsDao(db).enqueue();
      await createPeer('office-pc');
      final set = await publishSet(jobId);
      await serviceFor().deliverJobArtifacts(set);
      final artifact = set.artifacts.single;

      final before = (await journal.listForJob(jobId)).single;
      expect(before.state, DeliveryAttemptState.retrying);
      expect(before.deliveredAt, isNull);

      final after = await peers.acknowledgePull(
        jobId: jobId,
        peerId: 'office-pc',
        artifactId: artifactIdForPath(artifact.sourcePath),
        checksum: artifact.checksum,
      );

      expect(after.state, DeliveryAttemptState.delivered);
      expect(after.checksum, artifact.checksum);
      expect(after.bytes, artifact.bytes);
      expect(after.deliveredAt, isNotNull);
    });

    test(
      'a desktop cannot talk the report into accepting corrupt bytes',
      () async {
        final jobId = await DarkroomJobsDao(db).enqueue();
        await createPeer('office-pc');
        final set = await publishSet(jobId);
        await serviceFor().deliverJobArtifacts(set);

        await expectLater(
          peers.acknowledgePull(
            jobId: jobId,
            peerId: 'office-pc',
            artifactId: artifactIdForPath(set.artifacts.single.sourcePath),
            checksum: 'de' * 32,
          ),
          throwsA(
            isA<DeliveryFailure>().having(
              (f) => f.kind,
              'kind',
              DeliveryFailureKind.checksumMismatch,
            ),
          ),
        );
        expect(
          (await journal.listForJob(jobId)).single.state,
          DeliveryAttemptState.retrying,
        );
      },
    );

    test('an id nothing published cannot be acknowledged', () async {
      final jobId = await DarkroomJobsDao(db).enqueue();
      await createPeer('office-pc');
      await serviceFor().deliverJobArtifacts(await publishSet(jobId));

      await expectLater(
        peers.acknowledgePull(
          jobId: jobId,
          peerId: 'office-pc',
          artifactId: artifactIdForPath('/etc/shadow'),
          checksum: 'de' * 32,
        ),
        throwsA(isA<DeliveryJournalMissingException>()),
      );
    });
  });

  group('peer configuration', () {
    test('a destination with no peerId is a configuration failure at publish '
        'time', () async {
      final jobId = await DarkroomJobsDao(db).enqueue();
      await targets.create(
        name: 'nameless',
        kind: ArtifactDestinationKind.peer,
        configJson: '{}',
        content: const {ArtifactContent.linearMasters},
      );

      final report = await serviceFor().deliverJobArtifacts(
        await publishSet(jobId),
      );

      expect(report.awaitingPull, 0);
      expect(report.failed, 1);
      expect(
        (await journal.listForJob(jobId)).single.lastError,
        contains('configurationInvalid'),
      );
    });

    test(
      'a misconfigured peer does not deny another peer its manifest',
      () async {
        final jobId = await DarkroomJobsDao(db).enqueue();
        await targets.create(
          name: 'nameless',
          kind: ArtifactDestinationKind.peer,
          configJson: '{}',
          content: const {ArtifactContent.linearMasters},
        );
        await createPeer('office-pc');
        await serviceFor().deliverJobArtifacts(await publishSet(jobId));

        final manifest = await peers.buildManifest(
          jobId: jobId,
          peerId: 'office-pc',
        );

        expect(manifest.entries.length, 1);
      },
    );
  });
}
