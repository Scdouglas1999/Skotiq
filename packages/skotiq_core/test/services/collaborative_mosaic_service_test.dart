// Client-side collaborative-mosaic orchestration.
//
// Exercises [CollaborativeMosaicService] over a `package:http/testing` MockClient
// (no network) + a real in-memory DB with the real v45/v56 mosaic DAOs and the
// real [MosaicProjectService] (with a fake seam so assembly reuses the genuine
// stitchProject WCS + >= 2-panel gates without the native stitcher):
//
//   * publishProject persists hub_mosaic_id + collab_role=owner;
//   * claimPanels persists claim_token + assigned account/rig provenance;
//   * uploadPanelMaster resolves the integrated master FITS + persists the
//     uploaded master id (and refuses a non-plate-solved panel);
//   * assembleMosaic pulls panel masters, invokes the (faked) seam.stitchMosaic
//     via the existing stitchProject, then pushes the output.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A minimal FITS primary header carrying a WCS solution so the service's
/// `_fitsHeaderHasWcs` probe (and stitchProject's gate) accept the panel.
Uint8List fitsWithWcs() {
  String card(String key, String value) =>
      '${key.padRight(8)}= ${value.padLeft(20)}'.padRight(80);
  final cards = <String>[
    card('SIMPLE', 'T'),
    card('BITPIX', '16'),
    card('NAXIS', '2'),
    card('NAXIS1', '100'),
    card('NAXIS2', '80'),
    "CTYPE1  = 'RA---TAN'".padRight(80),
    "CTYPE2  = 'DEC--TAN'".padRight(80),
    card('CRVAL1', '300.0'),
    card('CRVAL2', '30.0'),
    card('CRPIX1', '50.0'),
    card('CRPIX2', '40.0'),
    card('CD1_1', '-0.0002'),
    card('CD1_2', '0.0'),
    card('CD2_1', '0.0'),
    card('CD2_2', '0.0002'),
    'END'.padRight(80),
  ];
  final header = cards.join();
  const block = 2880;
  final padded = header.padRight(
    ((header.length + block - 1) ~/ block) * block,
  );
  return Uint8List.fromList(padded.codeUnits);
}

/// A valid minimal FITS primary header (END card present) that carries NO WCS,
/// modelling a master whose plate-solve was persisted DB-only.
Uint8List fitsNoWcs() {
  String card(String key, String value) =>
      '${key.padRight(8)}= ${value.padLeft(20)}'.padRight(80);
  final cards = <String>[
    card('SIMPLE', 'T'),
    card('BITPIX', '16'),
    card('NAXIS', '2'),
    card('NAXIS1', '100'),
    card('NAXIS2', '80'),
    'END'.padRight(80),
  ];
  final header = cards.join();
  const block = 2880;
  final padded = header.padRight(
    ((header.length + block - 1) ~/ block) * block,
  );
  return Uint8List.fromList(padded.codeUnits);
}

/// A fake seam: `stitchMosaic` writes the requested output FITS so the service's
/// pushMosaicOutput finds a real file, and returns a canned stitch result.
class _FakeSeam implements PostSessionSeam {
  int stitchCalls = 0;

  @override
  Future<MosaicStitchResult> stitchMosaic(Map<String, dynamic> args) async {
    stitchCalls++;
    final output = args['output'] as Map<String, dynamic>;
    final outPath = output['mosaicFitsPath'] as String;
    final previewPath = output['previewPngPath'] as String;
    File(outPath)
      ..createSync(recursive: true)
      ..writeAsBytesSync(fitsWithWcs());
    File(previewPath).writeAsBytesSync(<int>[0]);
    return MosaicStitchResult(
      outputPath: outPath,
      previewPath: previewPath,
      outWidth: 200,
      outHeight: 80,
      overlapPairs: 1,
      meanPanelGain: 1.0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used in test');
}

void main() {
  late SkotiqDatabase db;
  late MosaicProjectsDao projectsDao;
  late MosaicPanelsDao panelsDao;
  late IntegratedMastersDao mastersDao;
  late MosaicProjectService projectService;
  late _FakeSeam seam;
  late Directory tmp;
  final hub = Uri.parse('https://hub.example.org');

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    projectsDao = MosaicProjectsDao(db);
    panelsDao = MosaicPanelsDao(db);
    mastersDao = IntegratedMastersDao(db);
    seam = _FakeSeam();
    projectService = MosaicProjectService(
      db: db,
      projectsDao: projectsDao,
      panelsDao: panelsDao,
      targetsDao: TargetsDao(db),
      imagesDao: ImagesDao(db),
      mastersDao: mastersDao,
      integrationService: PostSessionIntegrationService(
        mastersDao: mastersDao,
        calibrationLibrary: CalibrationLibraryService(
          db: db,

          flatLibraryDao: FlatLibraryDao(db),

          tagsDao: CalibrationTagsDao(db),
        ),
        seam: seam,
      ),
      seam: seam,
    );
    tmp = Directory.systemTemp.createTempSync('collab_mosaic_');
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  CollaborativeMosaicService serviceWith(MockClient mock) =>
      CollaborativeMosaicService(
        credentialsResolver: () async =>
            ConstellationCredentials(hubBaseUrl: hub, bearerToken: 'tok'),
        accountIdResolver: () async => 'acct-1',
        rigIdResolver: () => 'rig-1',
        projectsDao: projectsDao,
        panelsDao: panelsDao,
        mastersDao: mastersDao,
        projectService: projectService,
        logger: LoggingService(),
        assemblyDirResolver: (mosaicId) async => '${tmp.path}/$mosaicId',
        clientFactory: (c) => ConstellationClient(
          hubBaseUrl: c.hubBaseUrl,
          bearerToken: c.bearerToken,
          client: mock,
        ),
      );

  Future<int> seedProject({int cols = 2}) async {
    final projectId = await projectsDao.create(
      name: 'Veil',
      rows: 1,
      cols: cols,
    );
    for (var i = 0; i < cols; i++) {
      await panelsDao.upsert(
        projectId: projectId,
        panelIndex: i,
        centerRa: 20.0 + i * 0.1,
        centerDec: 30.0,
      );
    }
    return projectId;
  }

  test('publishProject persists hub_mosaic_id + collab_role=owner', () async {
    final projectId = await seedProject();
    Map<String, dynamic>? body;
    final mock = MockClient((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'mosaicId': 'mos-1',
          'ownerAccountId': 'acct-1',
          'name': 'Veil',
          'rows': 1,
          'cols': 2,
          'overlapPct': 15.0,
          'positionAngleDeg': 0.0,
          'centerRaDeg': 300.0,
          'centerDecDeg': 30.0,
          'status': 'open',
          'outputPresent': false,
          'panels': [],
        }),
        201,
      );
    });

    final mosaic = await serviceWith(mock).publishProject(projectId);

    expect(mosaic.mosaicId, 'mos-1');
    // RA hours -> degrees at the boundary.
    expect((body!['panels'] as List), hasLength(2));
    expect((body!['centerRaDeg'] as num) > 0, isTrue);
    final project = await projectsDao.getById(projectId);
    expect(project!.hubMosaicId, 'mos-1');
    expect(project.collabRole, 'owner');
    expect(project.collabStatus, 'published');
  });

  // Wave-1 COL-7: a mosaic straddling RA 0h was published with a centre 144
  // degrees away, because the centre was the arithmetic mean of panel RAs that
  // wrap (358.595 / 359.298 / 0 / 0.702 / 1.405 averages to 144.0). The centre
  // must be the circular mean, i.e. inside the grid the panels describe.
  test('publishProject centres a mosaic that straddles RA 0h', () async {
    final projectId = await projectsDao.create(name: 'Seam', rows: 1, cols: 5);
    // Panel RAs in HOURS: 23.9063, 23.9532, 0.0, 0.0468, 0.0937
    // (= 358.595 / 359.298 / 0 / 0.702 / 1.405 degrees).
    const raHours = [23.90633, 23.95320, 0.0, 0.04680, 0.09367];
    for (var i = 0; i < raHours.length; i++) {
      await panelsDao.upsert(
        projectId: projectId,
        panelIndex: i,
        centerRa: raHours[i],
        centerDec: 30.0,
      );
    }

    Map<String, dynamic>? body;
    final mock = MockClient((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'mosaicId': 'mos-seam',
          'ownerAccountId': 'acct-1',
          'name': 'Seam',
          'rows': 1,
          'cols': 5,
          'overlapPct': 15.0,
          'positionAngleDeg': 0.0,
          'centerRaDeg': 0.0,
          'centerDecDeg': 30.0,
          'status': 'open',
          'outputPresent': false,
          'panels': [],
        }),
        201,
      );
    });

    await serviceWith(mock).publishProject(projectId);

    final centerRaDeg = (body!['centerRaDeg'] as num).toDouble();
    // The true centre is 0 degrees; accept either side of the seam.
    final offset = (centerRaDeg + 180.0) % 360.0 - 180.0;
    expect(offset.abs(), lessThan(0.01), reason: 'published $centerRaDeg');
  });

  test('claimPanels persists claim_token + assigned account/rig', () async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
    final mock = MockClient((request) async {
      expect(request.url.path, '/v1/mosaics/mos-1/panels/0/claim');
      return http.Response(
        jsonEncode({
          'mosaicId': 'mos-1',
          'panelIndex': 0,
          'claimToken': 'baton-0',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(hours: 12))
              .toIso8601String(),
        }),
        200,
      );
    });

    final claims = await serviceWith(mock).claimPanels(projectId, [0]);

    expect(claims, hasLength(1));
    final panel = await panelsDao.getByIndex(projectId, 0);
    expect(panel!.claimToken, 'baton-0');
    expect(panel.assignedUserId, 'acct-1');
    expect(panel.assignedRigId, 'rig-1');
  });

  test('claimPanels skips a panel held by another rig (409)', () async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
    final mock = MockClient((request) async => http.Response('held', 409));
    final claims = await serviceWith(mock).claimPanels(projectId, [0]);
    expect(claims, isEmpty);
    final panel = await panelsDao.getByIndex(projectId, 0);
    expect(panel!.claimToken, isNull);
  });

  test('forceReleasePanel POSTs the owner/admin eviction path', () async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
    String? seenPath;
    final mock = MockClient((request) async {
      seenPath = request.url.path;
      expect(request.method, 'POST');
      return http.Response(jsonEncode({'released': true}), 200);
    });

    final released = await serviceWith(mock).forceReleasePanel(projectId, 0);

    expect(released, isTrue);
    expect(seenPath, '/v1/mosaics/mos-1/panels/0/force-release');
  });

  test(
    'forceReleasePanel surfaces a hub forbidden (403) as an exception',
    () async {
      final projectId = await seedProject();
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
      final mock = MockClient(
        (request) async => http.Response('only the owner may evict', 403),
      );
      await expectLater(
        serviceWith(mock).forceReleasePanel(projectId, 0),
        throwsA(isA<ConstellationException>()),
      );
    },
  );

  test(
    'uploadPanelMaster resolves the master FITS + persists uploaded id',
    () async {
      final projectId = await seedProject();
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
      // A plate-solved panel master on disk.
      final fits = File('${tmp.path}/panel0.fits')
        ..writeAsBytesSync(fitsWithWcs());
      final masterId = await mastersDao.insertMaster(
        name: 'Panel 0',
        masterFitsPath: fits.path,
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.batch,
      );
      final panel = await panelsDao.getByIndex(projectId, 0);
      await panelsDao.setMaster(panel!.id!, masterId);

      final mock = MockClient((request) async {
        expect(request.url.path, '/v1/mosaics/mos-1/panels/0/master');
        return http.Response(
          jsonEncode({'panelIndex': 0, 'status': 'uploaded', 'uploaded': true}),
          200,
        );
      });

      final uploaded = await serviceWith(mock).uploadPanelMaster(
        projectId,
        0,
        license: ContributionLicense.ccBy,
        attributionConsent: true,
      );

      expect(uploaded.uploaded, isTrue);
      final reread = await panelsDao.getByIndex(projectId, 0);
      expect(reread!.uploadedMasterId, masterId);
    },
  );

  test('uploadPanelMaster refuses a non-plate-solved panel (no WCS)', () async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
    final fits = File('${tmp.path}/nowcs.fits')
      ..writeAsBytesSync(Uint8List.fromList(List.filled(2880, 32)));
    final masterId = await mastersDao.insertMaster(
      name: 'Panel 0',
      masterFitsPath: fits.path,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
    );
    final panel = await panelsDao.getByIndex(projectId, 0);
    await panelsDao.setMaster(panel!.id!, masterId);

    final mock = MockClient((request) async => http.Response('{}', 200));
    expect(
      () => serviceWith(mock).uploadPanelMaster(
        projectId,
        0,
        license: ContributionLicense.ccBy,
        attributionConsent: true,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'uploadPanelMaster fails closed when no consent is given or recorded',
    () async {
      final projectId = await seedProject();
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
      // No explicit license/attribution and no resolver wired → the consent
      // gate refuses the upload BEFORE any bytes leave the device.
      final mock = MockClient((request) async => http.Response('{}', 200));
      await expectLater(
        () => serviceWith(mock).uploadPanelMaster(projectId, 0),
        throwsA(isA<ConstellationException>()),
      );
    },
  );

  test('uploadPanelMaster honors the persisted consent record when none is '
      'passed explicitly', () async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
    final fits = File('${tmp.path}/panel_consent.fits')
      ..writeAsBytesSync(fitsWithWcs());
    final masterId = await mastersDao.insertMaster(
      name: 'Panel 0',
      masterFitsPath: fits.path,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
    );
    final panel = await panelsDao.getByIndex(projectId, 0);
    await panelsDao.setMaster(panel!.id!, masterId);

    final mock = MockClient((request) async {
      return http.Response(
        jsonEncode({'panelIndex': 0, 'status': 'uploaded', 'uploaded': true}),
        200,
      );
    });
    final service = CollaborativeMosaicService(
      credentialsResolver: () async =>
          ConstellationCredentials(hubBaseUrl: hub, bearerToken: 'tok'),
      accountIdResolver: () async => 'acct-1',
      rigIdResolver: () => 'rig-1',
      uploadConsentResolver: () async => const MosaicUploadConsent(
        license: ContributionLicense.cc0,
        attributionConsent: false,
      ),
      projectsDao: projectsDao,
      panelsDao: panelsDao,
      mastersDao: mastersDao,
      projectService: projectService,
      logger: LoggingService(),
      assemblyDirResolver: (mosaicId) async => '${tmp.path}/$mosaicId',
      clientFactory: (c) => ConstellationClient(
        hubBaseUrl: c.hubBaseUrl,
        bearerToken: c.bearerToken,
        client: mock,
      ),
    );

    // No explicit license/attribution passed → the persisted (cc0, anonymous)
    // consent the resolver supplies drives the upload rather than a hardcoded
    // ccBy default, and the upload proceeds.
    final uploaded = await service.uploadPanelMaster(projectId, 0);
    expect(uploaded.uploaded, isTrue);
    final reread = await panelsDao.getByIndex(projectId, 0);
    expect(reread!.uploadedMasterId, masterId);
  });

  test('uploadPanelMaster stamps a DB-only persisted WCS into the FITS header '
      'before upload (the DB never travels to the hub)', () async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
    // A master whose FITS header carries NO WCS, but whose CD-matrix WCS is
    // persisted DB-only (exactly what PostSessionIntegrationService does via
    // IntegratedMastersDao.updateWcs after a post-hoc plate-solve).
    final fits = File('${tmp.path}/dbonly.fits')..writeAsBytesSync(fitsNoWcs());
    final masterId = await mastersDao.insertMaster(
      name: 'Panel 0',
      masterFitsPath: fits.path,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      width: 100,
      height: 80,
    );
    await mastersDao.updateWcs(
      masterId,
      crval1: 300.0,
      crval2: 30.0,
      crpix1: 50.0,
      crpix2: 40.0,
      cd1_1: -0.0002,
      cd1_2: 0.0,
      cd2_1: 0.0,
      cd2_2: 0.0002,
    );
    final panel = await panelsDao.getByIndex(projectId, 0);
    await panelsDao.setMaster(panel!.id!, masterId);

    Uint8List? pushedBytes;
    final mock = MockClient((request) async {
      pushedBytes = request.bodyBytes;
      return http.Response(
        jsonEncode({'panelIndex': 0, 'status': 'uploaded', 'uploaded': true}),
        200,
      );
    });

    final uploaded = await serviceWith(mock).uploadPanelMaster(
      projectId,
      0,
      license: ContributionLicense.ccBy,
      attributionConsent: true,
    );
    expect(uploaded.uploaded, isTrue);

    // The bytes that reached the hub now self-describe their WCS in the header.
    final pushedText = String.fromCharCodes(pushedBytes!);
    expect(pushedText.contains('CRVAL1'), isTrue);
    expect(pushedText.contains('CD1_1'), isTrue);
    expect(pushedText.contains('RA---TAN'), isTrue);
    // And the on-disk master FITS was reconciled too (header now matches the DB).
    final reread = await File(fits.path).readAsString();
    expect(reread.contains('CRVAL1'), isTrue);
  });

  test(
    'assembleMosaic refuses to assemble until the hub mosaic is assembling',
    () async {
      final projectId = await seedProject();
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
      final mock = MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.path == '/v1/mosaics/mos-1') {
          return http.Response(
            jsonEncode({
              'mosaicId': 'mos-1',
              'ownerAccountId': 'acct-1',
              'name': 'Veil',
              'rows': 1,
              'cols': 2,
              'overlapPct': 15.0,
              'positionAngleDeg': 0.0,
              'centerRaDeg': 300.0,
              'centerDecDeg': 30.0,
              // Still open — not every panel has uploaded.
              'status': 'open',
              'outputPresent': false,
              'panels': [],
            }),
            200,
          );
        }
        return http.Response(
          'unexpected ${request.method} ${request.url.path}',
          500,
        );
      });
      expect(
        () => serviceWith(mock).assembleMosaic(projectId),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'assembleMosaic pulls panels, stitches via the seam, pushes output',
    () async {
      final projectId = await seedProject(cols: 2);
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');

      var pushedOutput = false;
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/v1/mosaics/mos-1') {
          // The assembler refreshes hub state first and only proceeds when the
          // mosaic is `assembling` (all panels uploaded).
          return http.Response(
            jsonEncode({
              'mosaicId': 'mos-1',
              'ownerAccountId': 'acct-1',
              'name': 'Veil',
              'rows': 1,
              'cols': 2,
              'overlapPct': 15.0,
              'positionAngleDeg': 0.0,
              'centerRaDeg': 300.0,
              'centerDecDeg': 30.0,
              'status': 'assembling',
              'outputPresent': false,
              'panels': [],
            }),
            200,
          );
        }
        if (request.method == 'GET' && path.contains('/panels/')) {
          // Serve a plate-solved panel master for the assembler to pull.
          return http.Response.bytes(fitsWithWcs(), 200);
        }
        if (request.method == 'POST' && path == '/v1/mosaics/mos-1/output') {
          pushedOutput = true;
          return http.Response(
            jsonEncode({
              'mosaicId': 'mos-1',
              'ownerAccountId': 'acct-1',
              'name': 'Veil',
              'rows': 1,
              'cols': 2,
              'overlapPct': 15.0,
              'positionAngleDeg': 0.0,
              'centerRaDeg': 300.0,
              'centerDecDeg': 30.0,
              'status': 'complete',
              'outputPresent': true,
              'panels': [],
            }),
            200,
          );
        }
        return http.Response('unexpected ${request.method} $path', 500);
      });

      final outcome = await serviceWith(mock).assembleMosaic(projectId);

      // The genuine stitchProject ran (>= 2 WCS panels), the seam was invoked,
      // and the finished mosaic was pushed back to the hub.
      expect(seam.stitchCalls, 1);
      expect(outcome.panelCount, 2);
      expect(pushedOutput, isTrue);
      final project = await projectsDao.getById(projectId);
      expect(project!.collabStatus, 'complete');

      // Each pulled swarm panel is recorded with the geometry its FITS header
      // declares, not 0x0 — the owner's library has to describe the
      // contributors' panels truthfully.
      for (final panel in await panelsDao.getForProject(projectId)) {
        final master = await mastersDao.getById(panel.integratedMasterId!);
        expect(master!.width, 100, reason: 'panel ${panel.panelIndex} width');
        expect(master.height, 80, reason: 'panel ${panel.panelIndex} height');
      }
    },
  );

  test(
    'joinAsParticipant throws when the local project does not exist',
    () async {
      // The link is an UPDATE: without the rows-changed check a join against a
      // missing project silently updates nothing and still reports success, so
      // the caller is told it is a participant while no state was recorded.
      final mock = MockClient((_) async => http.Response('{}', 200));
      await expectLater(
        () => serviceWith(mock).joinAsParticipant(4242, 'mos-1'),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test(
    'releasePanel clears the local claim once the hub gives it back',
    () async {
      final projectId = await seedProject();
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
      final claimMock = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'mosaicId': 'mos-1',
            'panelIndex': 0,
            'claimToken': 'tok-0',
          }),
          200,
        ),
      );
      await serviceWith(claimMock).claimPanels(projectId, [0]);
      expect((await panelsDao.getByIndex(projectId, 0))!.claimToken, 'tok-0');

      var releasedPath = '';
      final releaseMock = MockClient((request) async {
        releasedPath = request.url.path;
        return http.Response(jsonEncode({'released': true}), 200);
      });
      final released = await serviceWith(
        releaseMock,
      ).releasePanel(projectId, 0);

      expect(released, isTrue);
      expect(releasedPath, '/v1/mosaics/mos-1/panels/0/release');
      final panel = await panelsDao.getByIndex(projectId, 0);
      expect(
        panel!.claimToken,
        isNull,
        reason:
            'a stale token would let a later upload push under a lost claim',
      );
      expect(panel.assignedUserId, isNull);
    },
  );

  test('releasePanel keeps the local claim when the hub refuses', () async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
    final claimMock = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'mosaicId': 'mos-1',
          'panelIndex': 0,
          'claimToken': 'tok-0',
        }),
        200,
      ),
    );
    await serviceWith(claimMock).claimPanels(projectId, [0]);

    final releaseMock = MockClient(
      (_) async => http.Response(jsonEncode({'released': false}), 200),
    );
    final released = await serviceWith(releaseMock).releasePanel(projectId, 0);

    expect(released, isFalse);
    expect((await panelsDao.getByIndex(projectId, 0))!.claimToken, 'tok-0');
  });

  test('assembleMosaic refuses a non-owner', () async {
    final projectId = await seedProject();
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
    final mock = MockClient((request) async => http.Response('{}', 200));
    expect(
      () => serviceWith(mock).assembleMosaic(projectId),
      throwsA(isA<StateError>()),
    );
  });

  test('downloadOutput pulls the finished mosaic + links it as the project '
      'output (participant)', () async {
    // A participant rig that JOINED a hub mosaic pulls the owner-published
    // finished mosaic — the previously-dead participant retrieval path.
    final projectId = await seedProject();
    await serviceWith(
      MockClient((_) async => http.Response('{}', 200)),
    ).joinAsParticipant(projectId, 'mos-1');
    expect((await projectsDao.getById(projectId))!.collabRole, 'participant');

    var pulledOutput = false;
    final mock = MockClient((request) async {
      if (request.method == 'GET' &&
          request.url.path == '/v1/mosaics/mos-1/output') {
        pulledOutput = true;
        return http.Response.bytes(fitsWithWcs(), 200);
      }
      return http.Response('unexpected ${request.method} ${request.url}', 500);
    });

    final path = await serviceWith(mock).downloadOutput(projectId);
    expect(pulledOutput, isTrue);
    expect(File(path).existsSync(), isTrue);
    final project = await projectsDao.getById(projectId);
    expect(project!.collabStatus, 'complete');
    expect(project.outputMasterId, isNotNull);
    final master = await mastersDao.getById(project.outputMasterId!);
    expect(master!.masterFitsPath, path);
    // The hub ships bytes, not a row, so the geometry has to be read back out
    // of the pulled FITS. A 0x0 row would report a real mosaic as having no
    // dimensions everywhere the participant looks at it.
    expect(master.width, 100);
    expect(master.height, 80);
  });

  test('downloadOutput refuses a project that is not published', () async {
    final projectId = await seedProject();
    final mock = MockClient((request) async => http.Response('{}', 200));
    expect(
      () => serviceWith(mock).downloadOutput(projectId),
      throwsA(isA<StateError>()),
    );
  });

  test('joinMosaicAsParticipant mirrors a hub mosaic into a local project + '
      'links it as participant', () async {
    // A swarm-browser CollabMosaic (panels populated, so no detail round-trip).
    const mosaic = CollabMosaic(
      mosaicId: 'mos-7',
      ownerAccountId: '',
      ownerDisplayName: 'Andromeda Club',
      name: 'Heart & Soul',
      rows: 1,
      cols: 2,
      overlapPct: 12.0,
      positionAngleDeg: 30.0,
      // Hub centres are RA DEGREES.
      centerRaDeg: 38.0,
      centerDecDeg: 61.0,
      status: 'open',
      outputPresent: false,
      panels: [
        CollabMosaicPanel(
          panelIndex: 0,
          centerRaDeg: 37.5,
          centerDecDeg: 61.0,
          status: 'pending',
          assignedAccountId: null,
          assignedRigId: null,
          uploaded: false,
        ),
        CollabMosaicPanel(
          panelIndex: 1,
          centerRaDeg: 38.5,
          centerDecDeg: 61.0,
          status: 'pending',
          assignedAccountId: null,
          assignedRigId: null,
          uploaded: false,
        ),
      ],
    );
    // No HTTP is reached (panels are already on the payload).
    final mock = MockClient((request) async => http.Response('{}', 500));

    final projectId = await serviceWith(mock).joinMosaicAsParticipant(mosaic);

    final project = await projectsDao.getById(projectId);
    expect(project!.hubMosaicId, 'mos-7');
    expect(project.collabRole, 'participant');
    expect(project.name, 'Heart & Soul');
    expect(project.cols, 2);
    final panels = await panelsDao.getForProject(projectId);
    expect(panels, hasLength(2));
    // Hub RA degrees were converted back to the local RA-hours convention.
    expect(panels.first.centerRa, closeTo(37.5 / 15.0, 1e-9));
    expect(panels.first.centerDec, closeTo(61.0, 1e-9));
  });

  test(
    'joinMosaicAsParticipant is idempotent — no duplicate local project',
    () async {
      const mosaic = CollabMosaic(
        mosaicId: 'mos-8',
        ownerAccountId: '',
        name: 'Veil',
        rows: 1,
        cols: 1,
        overlapPct: 10.0,
        positionAngleDeg: 0.0,
        centerRaDeg: 300.0,
        centerDecDeg: 30.0,
        status: 'open',
        outputPresent: false,
        panels: [
          CollabMosaicPanel(
            panelIndex: 0,
            centerRaDeg: 300.0,
            centerDecDeg: 30.0,
            status: 'pending',
            assignedAccountId: null,
            assignedRigId: null,
            uploaded: false,
          ),
        ],
      );
      final mock = MockClient((request) async => http.Response('{}', 500));
      final service = serviceWith(mock);

      final first = await service.joinMosaicAsParticipant(mosaic);
      final second = await service.joinMosaicAsParticipant(mosaic);

      expect(second, first);
      final all = await projectsDao.listAll();
      expect(all.where((p) => p.hubMosaicId == 'mos-8'), hasLength(1));
    },
  );

  test('joinMosaicAsParticipant returns an existing owner project unchanged '
      '(no role downgrade)', () async {
    // The owner browsing their own published mosaic must not be re-linked as a
    // participant nor duplicated.
    final ownerProjectId = await seedProject();
    await projectsDao.setHubMosaic(ownerProjectId, 'mos-9', 'owner');
    const mosaic = CollabMosaic(
      mosaicId: 'mos-9',
      ownerAccountId: '',
      name: 'Veil',
      rows: 1,
      cols: 2,
      overlapPct: 15.0,
      positionAngleDeg: 0.0,
      centerRaDeg: 300.0,
      centerDecDeg: 30.0,
      status: 'open',
      outputPresent: false,
    );
    final mock = MockClient((request) async => http.Response('{}', 500));

    final resolved = await serviceWith(mock).joinMosaicAsParticipant(mosaic);

    expect(resolved, ownerProjectId);
    final project = await projectsDao.getById(ownerProjectId);
    expect(project!.collabRole, 'owner');
  });
}
