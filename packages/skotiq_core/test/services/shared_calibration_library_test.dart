// Shared calibration library matching + merge.
//
// Exercises [CalibrationLibraryService] folding REMOTE candidates into the local
// ranking, download-on-accept + merge with conflict resolution, the consent
// refusal on publish, and the cross-train flat / sensor-dimension quality gates.
// A fake [RemoteCalibrationLibrary] stands in for the hub so the matcher logic
// is tested without HTTP.

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/calibration_tags_dao.dart';
import 'package:skotiq_core/src/database/daos/dark_library_dao.dart';
import 'package:skotiq_core/src/database/daos/flat_library_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/calibration/calibration_library_models.dart';
import 'package:skotiq_core/src/models/calibration/shared_calibration_models.dart';
import 'package:skotiq_core/src/models/collaboration/collaboration_models.dart';
import 'package:skotiq_core/src/services/calibration/shared_calibration_client.dart';
import 'package:skotiq_core/src/services/calibration/shared_calibration_library.dart';
import 'package:skotiq_core/src/services/calibration_library_service.dart';

/// A fake hub library: returns a fixed candidate set, serves fixed bytes, and
/// records what was downloaded / published.
class _FakeRemoteLibrary implements RemoteCalibrationLibrary {
  _FakeRemoteLibrary(this.candidates);

  List<CalibrationMasterRecord> candidates;
  final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
  int downloads = 0;
  int queries = 0;
  final List<CalibrationMasterRecord> published = [];
  final List<ContributionConsent> publishedConsents = [];
  final List<String> retracted = [];

  @override
  Future<bool> isConfigured() async => true;

  @override
  Future<List<CalibrationMasterRecord>> queryCandidates(
    LightFrameContext context,
  ) async {
    queries++;
    return candidates;
  }

  /// When set, the hub row served regardless of what was requested (models a
  /// hub answering with the wrong master).
  SharedCalibrationMaster? authorityOverride;

  /// Serves the bytes plus the HUB's own row for the requested `remoteId`,
  /// resolved from [candidates] — never from the record the caller passed in.
  /// That mirrors production: the download is the only place the accepting
  /// device learns the authoritative calibration tuple.
  @override
  Future<SharedCalibrationDownload> downloadMaster(
    CalibrationMasterRecord record,
  ) async {
    downloads++;
    if (authorityOverride != null) {
      return SharedCalibrationDownload(bytes: bytes, master: authorityOverride);
    }
    final authority = candidates
        .where((c) => c.remoteId == record.remoteId)
        .firstOrNull;
    return SharedCalibrationDownload(
      bytes: bytes,
      master: authority == null ? null : _asHubMaster(authority),
    );
  }

  /// The hub-row shape of a candidate record.
  static SharedCalibrationMaster _asHubMaster(CalibrationMasterRecord r) {
    return SharedCalibrationMaster(
      id: r.remoteId ?? '',
      accountId: r.provenance?.accountId ?? '',
      masterType: calibrationMasterTypeWireName(r.type),
      cameraModel: r.cameraId ?? '',
      sensorWidth: r.width ?? 0,
      sensorHeight: r.height ?? 0,
      gain: r.gain ?? 0,
      offset: r.offset ?? 0,
      exposureSeconds: r.exposureSeconds ?? 0,
      temperatureC: r.temperature,
      binX: r.binX,
      binY: r.binY,
      filter: r.filter,
      opticalTrain: r.opticalTrainId,
      frameCount: r.frameCount ?? 0,
      darkCurrent: r.provenance?.darkCurrent,
      license: r.license ?? ContributionLicense.private,
      provenance: r.provenance ?? const Provenance(),
      bytes: 5,
      createdAt: r.createdAt,
    );
  }

  @override
  Future<SharedCalibrationMaster> publish({
    required CalibrationMasterRecord record,
    required ContributionConsent consent,
    Provenance provenance = const Provenance(),
  }) async {
    published.add(record);
    publishedConsents.add(consent);
    return SharedCalibrationMaster(
      id: 'published-1',
      accountId: 'me',
      masterType: calibrationMasterTypeWireName(record.type),
      cameraModel: record.cameraId ?? '',
      sensorWidth: record.width ?? 0,
      sensorHeight: record.height ?? 0,
      gain: record.gain ?? 0,
      offset: record.offset ?? 0,
      exposureSeconds: record.exposureSeconds ?? 0,
      temperatureC: record.temperature,
      binX: record.binX,
      binY: record.binY,
      filter: record.filter,
      opticalTrain: record.opticalTrainId,
      frameCount: record.frameCount ?? 0,
      license: consent.license,
      provenance: provenance,
      bytes: 5,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> retract(String remoteId) async {
    retracted.add(remoteId);
  }
}

void main() {
  final now = DateTime.utc(2026, 6, 20, 22);

  late SkotiqDatabase db;
  late DarkLibraryDao darkDao;
  late FlatLibraryDao flatDao;
  late CalibrationTagsDao tagsDao;
  late Directory tmp;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    darkDao = DarkLibraryDao(db);
    flatDao = FlatLibraryDao(db);
    tagsDao = CalibrationTagsDao(db);
    tmp = Directory.systemTemp.createTempSync('ns_shared_cal_');
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  CalibrationLibraryService buildService(_FakeRemoteLibrary remote) {
    return CalibrationLibraryService(
      db: db,
      flatLibraryDao: flatDao,
      tagsDao: tagsDao,
      remoteLibrary: remote,
      sharedMasterDirResolver: () async => tmp.path,
      now: () => now,
    );
  }

  CalibrationMasterRecord remoteDark({
    String id = 'r-dark',
    int gain = 100,
    int offset = 50,
    double exposure = 300,
    double? temperature = -10,
    int? width = 6248,
    int? height = 4176,
    String camera = 'ASI2600MM',
    ContributionLicense license = ContributionLicense.ccBy,
    int frames = 40,
    double darkCurrent = 0.018,
    int binX = 1,
    int binY = 1,
  }) {
    return CalibrationMasterRecord(
      type: CalibrationMasterType.dark,
      id: 0,
      filePath: null,
      isMaster: true,
      frameCount: frames,
      exposureSeconds: exposure,
      temperature: temperature,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      width: width,
      height: height,
      cameraId: camera,
      createdAt: now,
      remoteId: id,
      sourceHubKey: 'http://hub.test',
      provenance: Provenance(
        displayName: 'Alice',
        accountId: 'acct-alice',
        frameCount: frames,
        darkCurrent: darkCurrent,
        sensorWidth: width,
        sensorHeight: height,
      ),
      license: license,
      sharedBy: 'Alice',
    );
  }

  CalibrationMasterRecord remoteFlat({
    String id = 'r-flat',
    String filter = 'L',
    String? opticalTrain = 'trainA',
    int? width = 6248,
    int? height = 4176,
    ContributionLicense license = ContributionLicense.ccBy,
  }) {
    return CalibrationMasterRecord(
      type: CalibrationMasterType.flat,
      id: 0,
      filePath: null,
      isMaster: true,
      frameCount: 25,
      gain: 100,
      offset: 50,
      filter: filter,
      flatKind: 'sky',
      width: width,
      height: height,
      cameraId: 'ASI2600MM',
      opticalTrainId: opticalTrain,
      createdAt: now,
      remoteId: id,
      sourceHubKey: 'http://hub.test',
      provenance: const Provenance(displayName: 'Bob'),
      license: license,
      sharedBy: 'Bob',
    );
  }

  const darkContext = LightFrameContext(
    cameraId: 'ASI2600MM',
    gain: 100,
    offset: 50,
    exposureSeconds: 300,
    temperature: -10,
    sensorWidth: 6248,
    sensorHeight: 4176,
  );

  group('no configured hub', () {
    CalibrationLibraryService serviceWithNoHub() => CalibrationLibraryService(
      db: db,
      flatLibraryDao: flatDao,
      tagsDao: tagsDao,
      remoteLibrary: HubCalibrationLibrary(
        credentialsResolver: () async => null,
      ),
      sharedMasterDirResolver: () async => tmp.path,
      now: () => now,
    );

    test('match warns that shared masters were not consulted', () async {
      final result = await serviceWithNoHub().match(darkContext);

      expect(
        result.warnings.any((w) => w.contains('not consulted')),
        isTrue,
        reason: 'signed out must be distinguishable from "the hub had nothing"',
      );
    });

    test('a reachable hub with no candidates does NOT warn', () async {
      final result = await buildService(
        _FakeRemoteLibrary([]),
      ).match(darkContext);

      expect(
        result.warnings.any((w) => w.contains('not consulted')),
        isFalse,
        reason: 'the hub WAS consulted — it simply had nothing to offer',
      );
    });
  });

  group('match folding', () {
    test('folds a remote dark into the ranking with provenance', () async {
      final remote = _FakeRemoteLibrary([remoteDark()]);
      final service = buildService(remote);

      final result = await service.match(darkContext);

      expect(remote.queries, 1);
      expect(result.dark, isNotNull);
      expect(result.dark!.record.isRemote, isTrue);
      expect(result.dark!.record.remoteId, 'r-dark');
      // Provenance is surfaced so the user can trust what they pull.
      final reasonText = result.dark!.reasons.join(' ');
      expect(reasonText, contains('Shared master from Alice'));
      expect(reasonText, contains('40 frames'));
      expect(reasonText, contains('dark current'));
      expect(
        result.dark!.warnings.any((w) => w.contains('SHARED master')),
        isTrue,
      );
    });

    test(
      'prefers a LOCAL master over a remote one on an exact tuple tie',
      () async {
        await darkDao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/local/dark.fits',
            exposureTime: 300,
            gain: const Value(100),
            offset: const Value(50),
            temperature: const Value(-10),
            masterDarkPath: const Value('/local/master_dark.fits'),
            masterFrameCount: const Value(30),
            createdAt: Value(now),
          ),
        );
        final remote = _FakeRemoteLibrary([remoteDark()]);
        final service = buildService(remote);

        final result = await service.match(darkContext);

        expect(result.dark, isNotNull);
        expect(
          result.dark!.record.isRemote,
          isFalse,
          reason: 'a local exact-tuple master wins the tie',
        );
      },
    );

    test('includeRemote:false skips the hub entirely', () async {
      final remote = _FakeRemoteLibrary([remoteDark()]);
      final service = buildService(remote);

      final result = await service.match(darkContext, includeRemote: false);

      expect(remote.queries, 0);
      expect(result.dark, isNull);
    });
  });

  group('quality gate', () {
    test('refuses a remote master whose sensor dimensions differ', () async {
      final remote = _FakeRemoteLibrary([
        remoteDark(width: 9576, height: 6388), // different sensor geometry
      ]);
      final service = buildService(remote);

      final result = await service.match(darkContext);

      expect(
        result.dark,
        isNull,
        reason:
            'a master from a different sensor can never calibrate this frame',
      );
    });

    test('fails closed: refuses a remote master when the context names no '
        'camera', () async {
      final remote = _FakeRemoteLibrary([remoteDark()]);
      final service = buildService(remote);

      final result = await service.match(
        const LightFrameContext(
          gain: 100,
          offset: 50,
          exposureSeconds: 300,
          temperature: -10,
          sensorWidth: 6248,
          sensorHeight: 4176,
        ),
      );

      expect(
        result.dark,
        isNull,
        reason:
            'an unknown-camera context can never prove sensor compatibility',
      );
    });

    test('fails closed: refuses a remote candidate that advertises no sensor '
        'dimensions', () async {
      final remote = _FakeRemoteLibrary([
        remoteDark(width: null, height: null),
      ]);
      final service = buildService(remote);

      final result = await service.match(darkContext);

      expect(
        result.dark,
        isNull,
        reason:
            'a candidate with no recorded geometry cannot be proven matched',
      );
    });

    test('refuses a remote master shot on a different camera model', () async {
      final remote = _FakeRemoteLibrary([remoteDark(camera: 'ASI6200MM')]);
      final service = buildService(remote);

      final result = await service.match(darkContext);

      expect(result.dark, isNull);
    });

    test('refuses a remote flat across optical trains', () async {
      final remote = _FakeRemoteLibrary([remoteFlat(opticalTrain: 'trainB')]);
      final service = buildService(remote);

      final result = await service.match(
        const LightFrameContext(
          cameraId: 'ASI2600MM',
          gain: 100,
          offset: 50,
          exposureSeconds: 120,
          filter: 'L',
          opticalTrainId: 'trainA',
          sensorWidth: 6248,
          sensorHeight: 4176,
        ),
      );

      expect(result.flat, isNull, reason: 'flats never cross optical trains');
    });

    test('refuses a remote flat with no optical-train tag', () async {
      final remote = _FakeRemoteLibrary([remoteFlat(opticalTrain: null)]);
      final service = buildService(remote);

      final result = await service.match(
        const LightFrameContext(
          cameraId: 'ASI2600MM',
          gain: 100,
          offset: 50,
          exposureSeconds: 120,
          filter: 'L',
          opticalTrainId: 'trainA',
          sensorWidth: 6248,
          sensorHeight: 4176,
        ),
      );

      expect(result.flat, isNull);
    });

    test('accepts a remote flat on an EXACT optical-train match', () async {
      final remote = _FakeRemoteLibrary([remoteFlat(opticalTrain: 'trainA')]);
      final service = buildService(remote);

      final result = await service.match(
        const LightFrameContext(
          cameraId: 'ASI2600MM',
          gain: 100,
          offset: 50,
          exposureSeconds: 120,
          filter: 'L',
          opticalTrainId: 'trainA',
          sensorWidth: 6248,
          sensorHeight: 4176,
        ),
      );

      expect(result.flat, isNotNull);
      expect(result.flat!.record.isRemote, isTrue);
    });

    test(
      'does not fold a remote master shared under a private license',
      () async {
        final remote = _FakeRemoteLibrary([
          remoteDark(license: ContributionLicense.private),
        ]);
        final service = buildService(remote);

        final result = await service.match(darkContext);

        expect(result.dark, isNull);
      },
    );
  });

  group('accept + merge', () {
    test('downloads + merges a remote master, stamping provenance', () async {
      final remote = _FakeRemoteLibrary([remoteDark()]);
      final service = buildService(remote);

      final match = await service.match(darkContext);
      final outcome = await service.acceptRemoteMaster(match.dark!.record);

      expect(outcome.kind, RemoteMasterAcceptanceKind.merged);
      expect(remote.downloads, 1);
      expect(outcome.mergedId, isNotNull);
      expect(File(outcome.filePath!).existsSync(), isTrue);

      // The merged master now lists as a LOCAL record carrying its provenance.
      final listed = await service.listMasters(enrichFromHeaders: false);
      final merged = listed.firstWhere((r) => r.id == outcome.mergedId);
      expect(merged.isRemote, isFalse);
      expect(merged.sharedBy, 'Alice');
      expect(merged.license, ContributionLicense.ccBy);
      expect(merged.provenance?.darkCurrent, closeTo(0.018, 1e-9));
    });

    test(
      'conflict resolution: prefers a local exact-tuple master, no download',
      () async {
        final localId = await darkDao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/local/dark.fits',
            exposureTime: 300,
            gain: const Value(100),
            offset: const Value(50),
            temperature: const Value(-10),
            binX: const Value(1),
            binY: const Value(1),
            width: const Value(6248),
            height: const Value(4176),
            masterDarkPath: const Value('/local/master_dark.fits'),
            masterFrameCount: const Value(30),
            createdAt: Value(now),
          ),
        );
        // Cache the camera id so the exact-tuple duplicate check can match it.
        await tagsDao.upsert(
          CalibrationMasterType.dark,
          localId,
          cameraId: 'ASI2600MM',
        );
        final remote = _FakeRemoteLibrary([remoteDark()]);
        final service = buildService(remote);

        final outcome = await service.acceptRemoteMaster(remoteDark());

        expect(outcome.kind, RemoteMasterAcceptanceKind.preferredLocal);
        expect(outcome.existing!.id, localId);
        expect(
          remote.downloads,
          0,
          reason: 'no download when a local copy wins',
        );
      },
    );

    test(
      'keeps both when the tuple differs (no exact local duplicate)',
      () async {
        await darkDao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/local/dark.fits',
            exposureTime: 120, // different exposure → not a duplicate
            gain: const Value(100),
            offset: const Value(50),
            masterDarkPath: const Value('/local/master_dark.fits'),
            masterFrameCount: const Value(30),
            createdAt: Value(now),
          ),
        );
        final remote = _FakeRemoteLibrary([remoteDark()]);
        final service = buildService(remote);

        final outcome = await service.acceptRemoteMaster(remoteDark());

        expect(outcome.kind, RemoteMasterAcceptanceKind.merged);
        expect(remote.downloads, 1);
      },
    );

    test('refuses to accept a non-shareable (private) master', () async {
      final remote = _FakeRemoteLibrary([]);
      final service = buildService(remote);

      final outcome = await service.acceptRemoteMaster(
        remoteDark(license: ContributionLicense.private),
      );

      expect(outcome.kind, RemoteMasterAcceptanceKind.refused);
      expect(remote.downloads, 0);
    });

    test('refuses to accept a flat with no optical-train tag', () async {
      final remote = _FakeRemoteLibrary([remoteFlat(opticalTrain: null)]);
      final service = buildService(remote);

      final outcome = await service.acceptRemoteMaster(
        remoteFlat(opticalTrain: null),
      );

      expect(outcome.kind, RemoteMasterAcceptanceKind.refused);
    });

    test(
      'files the HUB tuple, not a caller-supplied one, when they disagree',
      () async {
        // The hub's row: gain 100 / offset 50 / 300 s / -10 C / bin 1x1.
        final remote = _FakeRemoteLibrary([remoteDark()]);
        final service = buildService(remote);

        // The record reaching accept() has been mutated in transit — same
        // remoteId (so the same bytes are fetched) but a wholly different
        // calibration tuple. Filing THIS would register a 300 s gain-100 dark
        // as a 60 s gain-200 one, and the matcher would then subtract it from
        // lights it was never shot for.
        final forged = remoteDark(
          gain: 200,
          offset: 99,
          exposure: 60,
          temperature: -25,
          binX: 2,
          binY: 2,
          frames: 999,
        );

        final outcome = await service.acceptRemoteMaster(forged);
        expect(outcome.kind, RemoteMasterAcceptanceKind.merged);

        final listed = await service.listMasters(enrichFromHeaders: false);
        final merged = listed.firstWhere((r) => r.id == outcome.mergedId);
        expect(merged.gain, 100, reason: 'hub gain wins over the caller');
        expect(merged.offset, 50);
        expect(merged.exposureSeconds, 300);
        expect(merged.temperature, -10);
        expect(merged.binX, 1);
        expect(merged.binY, 1);
        expect(merged.frameCount, 40);
      },
    );

    test(
      'refuses when the hub returns no authoritative record for the master',
      () async {
        // Candidates are empty, so the fake serves bytes with no hub row — the
        // tuple the master would be filed under cannot be verified.
        final remote = _FakeRemoteLibrary([]);
        final service = buildService(remote);

        final outcome = await service.acceptRemoteMaster(remoteDark());

        expect(outcome.kind, RemoteMasterAcceptanceKind.refused);
        expect(outcome.reason, contains('authoritative'));
        expect(
          remote.downloads,
          1,
          reason: 'the refusal is only knowable after the hub answers',
        );
      },
    );

    test(
      'refuses a hub row whose id does not match the requested master',
      () async {
        // The hub answers with a DIFFERENT master's row: filing it would attach
        // one master's identity to another master's bytes.
        final remote = _FakeRemoteLibrary([remoteDark(id: 'r-other')]);
        remote.authorityOverride = _FakeRemoteLibrary._asHubMaster(
          remoteDark(id: 'r-other'),
        );
        final service = buildService(remote);

        final outcome = await service.acceptRemoteMaster(remoteDark());

        expect(outcome.kind, RemoteMasterAcceptanceKind.refused);
        expect(outcome.reason, contains('r-other'));
      },
    );
  });

  group('publish (consent gate)', () {
    test('refuses to publish without sharing consent', () async {
      final remote = _FakeRemoteLibrary([]);
      final service = buildService(remote);
      final localId = await darkDao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/local/dark.fits',
          exposureTime: 300,
          masterDarkPath: const Value('/local/master_dark.fits'),
          createdAt: Value(now),
        ),
      );
      final record = (await service.getRecord(
        CalibrationMasterType.dark,
        localId,
      ))!;

      expect(
        () => service.publishMaster(
          record,
          consent: ContributionConsent.denied, // license private
        ),
        throwsA(isA<StateError>()),
      );
      expect(remote.published, isEmpty);
    });

    test('refuses to publish a flat without an optical-train tag', () async {
      final remote = _FakeRemoteLibrary([]);
      final service = buildService(remote);
      final flatId = await flatDao.addEntry(
        filePath: '/local/flat.fits',
        filter: 'L',
        gain: 100,
        offset: 50,
        masterFrameCount: 25,
        createdAt: now,
      );
      final record = (await service.getRecord(
        CalibrationMasterType.flat,
        flatId,
      ))!;

      expect(
        () => service.publishMaster(
          record,
          consent: const ContributionConsent(license: ContributionLicense.ccBy),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('publishes a consented dark to the hub', () async {
      final remote = _FakeRemoteLibrary([]);
      final service = buildService(remote);
      final localId = await darkDao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/local/dark.fits',
          exposureTime: 300,
          gain: const Value(100),
          offset: const Value(50),
          masterDarkPath: const Value('/local/master_dark.fits'),
          masterFrameCount: const Value(30),
          createdAt: Value(now),
        ),
      );
      final record = (await service.getRecord(
        CalibrationMasterType.dark,
        localId,
      ))!;

      final published = await service.publishMaster(
        record,
        consent: const ContributionConsent(license: ContributionLicense.ccBy),
      );

      expect(published.license, ContributionLicense.ccBy);
      expect(remote.published, hasLength(1));
      expect(remote.publishedConsents.single.license, ContributionLicense.ccBy);
    });

    test('publishing records the retract handle on the local master', () async {
      final remote = _FakeRemoteLibrary([]);
      final service = buildService(remote);
      final localId = await darkDao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/local/dark.fits',
          exposureTime: 300,
          gain: const Value(100),
          offset: const Value(50),
          masterDarkPath: const Value('/local/master_dark.fits'),
          masterFrameCount: const Value(30),
          createdAt: Value(now),
        ),
      );
      final record = (await service.getRecord(
        CalibrationMasterType.dark,
        localId,
      ))!;
      expect(record.isPublished, isFalse);

      await service.publishMaster(
        record,
        consent: const ContributionConsent(license: ContributionLicense.ccBy),
      );

      final after = (await service.getRecord(
        CalibrationMasterType.dark,
        localId,
      ))!;
      expect(after.isPublished, isTrue);
      expect(after.publishedRemoteId, 'published-1');
    });
  });

  group('retract (un-share)', () {
    test('retracts a published master and clears the local handle', () async {
      final remote = _FakeRemoteLibrary([]);
      final service = buildService(remote);
      final localId = await darkDao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/local/dark.fits',
          exposureTime: 300,
          gain: const Value(100),
          offset: const Value(50),
          masterDarkPath: const Value('/local/master_dark.fits'),
          masterFrameCount: const Value(30),
          createdAt: Value(now),
        ),
      );
      final record = (await service.getRecord(
        CalibrationMasterType.dark,
        localId,
      ))!;
      await service.publishMaster(
        record,
        consent: const ContributionConsent(license: ContributionLicense.ccBy),
      );
      final published = (await service.getRecord(
        CalibrationMasterType.dark,
        localId,
      ))!;

      await service.retractPublishedMaster(published);

      expect(remote.retracted, ['published-1']);
      final after = (await service.getRecord(
        CalibrationMasterType.dark,
        localId,
      ))!;
      expect(after.isPublished, isFalse);
      expect(after.publishedRemoteId, isNull);
    });

    test('retracting a never-published master throws', () async {
      final remote = _FakeRemoteLibrary([]);
      final service = buildService(remote);
      final localId = await darkDao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/local/dark.fits',
          exposureTime: 300,
          gain: const Value(100),
          offset: const Value(50),
          masterDarkPath: const Value('/local/master_dark.fits'),
          masterFrameCount: const Value(30),
          createdAt: Value(now),
        ),
      );
      final record = (await service.getRecord(
        CalibrationMasterType.dark,
        localId,
      ))!;

      await expectLater(
        () => service.retractPublishedMaster(record),
        throwsStateError,
      );
      expect(remote.retracted, isEmpty);
    });
  });
}
