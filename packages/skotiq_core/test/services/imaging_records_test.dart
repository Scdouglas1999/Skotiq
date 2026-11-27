import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/daos/sessions_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/services/local_imaging_records.dart';
import 'package:skotiq_core/src/services/restored_frame_path.dart';

import '../fakes/fake_network_client.dart';
import 'package:skotiq_core/src/backend/network_backend/host_data/remote_host_records.dart';
import 'package:skotiq_core/src/backend/network_backend/host_data/remote_imaging_records.dart';
import 'package:skotiq_core/src/backend/roles/host_data/imaging_records.dart';

Map<String, Object?> _imageRow(int id) => {
  'id': id,
  'filePath': '/host/frame-$id.fits',
  'fileName': 'frame-$id.fits',
  'fileFormat': 'fits',
  'frameType': 'light',
  'exposureDuration': 120,
  'binX': 1,
  'binY': 1,
  'capturedAt': 1700000000000 + id,
  'createdAt': 1700000000000 + id,
  'isAccepted': true,
  'isPlateSolved': false,
};

Future<void> _waitUntil(
  bool Function() condition, {
  String Function()? describe,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'Timed out waiting for repository polling'
        '${describe == null ? '' : ': ${describe()}'}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  group('LocalImagingRecords', () {
    late SkotiqDatabase db;
    late SessionsDao sessionsDao;
    late ImagesDao imagesDao;
    late ImagingRecords repository;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      sessionsDao = SessionsDao(db);
      imagesDao = ImagesDao(db);
      repository = LocalImagingRecords(
        sessionsDao: sessionsDao,
        imagesDao: imagesDao,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('the solved-frame hook runs once per frame however often it is '
        'solved or its stored solve reused', () async {
      final fired = <int>[];
      final hooked = LocalImagingRecords(
        sessionsDao: sessionsDao,
        imagesDao: imagesDao,
        onSolvedFrameFold: (id) async => fired.add(id),
      );
      final id = await imagesDao.insertSequenceFrame(
        filePath: '/lights/NGC0891_L_0001.fits',
        fileName: 'NGC0891_L_0001.fits',
        fileFormat: 'fits',
        exposureDuration: 120,
        capturedAt: DateTime.utc(2026, 10, 21, 3),
        isAccepted: true,
        producingNodeId: 'lights',
      );
      Future<void> solve() => hooked.updatePlateSolveResult(
        id,
        solvedRa: 2.3755,
        solvedDec: 42.349,
        solvedRotation: -21.37,
        solvedPixelScale: 0.788,
        solvedCd1_1: 2.0379e-4,
        solvedCd1_2: 7.981e-5,
        solvedCd2_1: -7.976e-5,
        solvedCd2_2: 2.0386e-4,
      );
      // The science step solves the frame, a later step reuses the stored
      // solve, and an annotation run solves it again.
      await solve();
      expect(
        fired,
        isEmpty,
        reason: 'A solve must not publish an ungraded frame',
      );
      hooked.notifyGradedFrame(id);
      await solve();
      await Future<void>.delayed(Duration.zero);
      expect(fired, [id]);
    });

    test('startSession and getSessionById round-trip', () async {
      final id = await repository.startSession(name: 'Night 1');
      final session = await repository.getSessionById(id);
      expect(session, isNotNull);
      expect(session!.name, 'Night 1');
      expect(session.status, 'active');
    });

    test('createImage and rejectImage update row', () async {
      final sessionId = await repository.startSession();
      final imageId = await repository.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/data/light.fits',
          fileName: 'light.fits',
          sessionId: Value(sessionId),
          frameType: const Value('light'),
          exposureDuration: 300,
          capturedAt: DateTime.utc(2025, 1, 1),
        ),
      );

      await repository.rejectImage(imageId, 'HFR too high');
      final row = await repository.getImageById(imageId);
      expect(row, isNotNull);
      expect(row!.isAccepted, isFalse);
      expect(row.rejectionReason, 'HFR too high');
    });
  });

  group('restoring a rejected frame', () {
    test('restoredFramePath walks out of the reject folder', () {
      expect(restoredFramePath('/c/M42/L/Reject/f.fits'), '/c/M42/L/f.fits');
      expect(
        restoredFramePath('/c/M42/Bad/f.fits', rejectFolder: 'Bad'),
        '/c/M42/f.fits',
      );
      expect(restoredFramePath('/c/M42/L/f.fits'), isNull);
      expect(
        restoredFramePath('/rejects/f.fits', rejectFolder: '/rejects'),
        isNull,
      );
      // An absolute folder outside the frame's: the sequencer used Reject/.
      expect(
        restoredFramePath('/c/M42/L/Reject/f.fits', rejectFolder: '/rejects'),
        '/c/M42/L/f.fits',
      );
    });

    test(
      'the frame and its thumbnail move back, and the row follows',
      () async {
        final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final imagesDao = ImagesDao(db);
        final repository = LocalImagingRecords(
          sessionsDao: SessionsDao(db),
          imagesDao: imagesDao,
        );
        final root = await Directory.systemTemp.createTemp('restore_');
        addTearDown(() => root.delete(recursive: true));
        final reject = await Directory('${root.path}/Reject').create();
        final frame = await File('${reject.path}/f.fits').writeAsString('x');
        final thumb = await File('${frame.path}.thumb.jpg').writeAsString('t');
        final id = await repository.createImage(
          CapturedImagesCompanion.insert(
            filePath: frame.path,
            fileName: 'f.fits',
            frameType: const Value('light'),
            exposureDuration: 120,
            capturedAt: DateTime.utc(2025, 1, 1),
          ),
        );
        await imagesDao.setThumbnailPath(id, thumb.path);
        await repository.rejectImage(id, 'HFR too high');

        await repository.acceptImage(id);

        final row = (await repository.getImageById(id))!;
        expect(row.isAccepted, isTrue);
        expect(row.filePath, '${root.path}/f.fits');
        expect(File(row.filePath).existsSync(), isTrue);
        expect(frame.existsSync(), isFalse);
        expect(row.thumbnailPath, '${root.path}/f.fits.thumb.jpg');
        expect(File(row.thumbnailPath!).existsSync(), isTrue);
      },
    );
  });

  group('RemoteImagingRecords', () {
    late FakeNetworkClient fake;
    late NetworkBackend backend;
    late ImagingRecords repository;

    setUp(() {
      fake = FakeNetworkClient();
      backend = NetworkBackend(
        serverHost: '127.0.0.1',
        serverPort: 8080,
        httpClient: fake,
        autoConnectWebSocket: false,
      );
      repository = RemoteImagingRecords(backend);
    });

    tearDown(() => backend.dispose());

    test('startSession posts to host API', () async {
      fake.setResponse('/api/sessions', method: 'POST', body: '{"id": 42}');

      final id = await repository.startSession(name: 'Remote night');
      expect(id, 42);
      expect(fake.requests.single.method, 'POST');
      expect(fake.requests.single.path, '/api/sessions');
    });

    test('createImage posts metadata to host API', () async {
      fake.setResponse('/api/images', method: 'POST', body: '{"id": 7}');

      final imageId = await repository.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/host/light.fits',
          fileName: 'light.fits',
          frameType: const Value('light'),
          exposureDuration: 120,
          capturedAt: DateTime.utc(2025, 6, 1, 12),
        ),
      );

      expect(imageId, 7);
      expect(fake.requests.single.path, '/api/images');
      final body = fake.requests.single.body!;
      expect(body, contains('filePath'));
      expect(body, contains('/host/light.fits'));
    });

    test('a solved host image keeps its CD matrix and SIP', () async {
      const cd11 = -0.00020379;
      const cd12 = 0.00007981;
      const cd21 = -0.00007976;
      const cd22 = 0.00020386;
      const sip = '{"a_order":2,"a":[0,1]}';
      fake.setResponse(
        '/api/images/9',
        body: jsonEncode({
          'image': {
            ..._imageRow(9),
            'isPlateSolved': true,
            'solvedRa': 5.5,
            'solvedDec': 24.1,
            'solvedCd1_1': cd11,
            'solvedCd1_2': cd12,
            'solvedCd2_1': cd21,
            'solvedCd2_2': cd22,
            'solvedSip': sip,
          },
        }),
      );
      fake.setResponse(
        '/api/images/10',
        body: jsonEncode({
          'image': {..._imageRow(10), 'isPlateSolved': false, 'solvedRa': 1.25},
        }),
      );
      final container = ProviderContainer(
        overrides: [imagingRecordsProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      final solved = await container.read(capturedImageWcsProvider(9).future);
      expect(solved, isNotNull);
      expect(solved!.cd1_1, cd11);
      expect(solved.cd1_2, cd12);
      expect(solved.cd2_1, cd21);
      expect(solved.cd2_2, cd22);
      expect(solved.sip, sip);
      expect(solved.solvedRaHours, 5.5);
      expect(solved.solvedDecDegrees, 24.1);

      final unsolved = await container.read(
        capturedImageWcsProvider(10).future,
      );
      expect(unsolved, isNotNull);
      expect(unsolved!.solvedRaHours, 1.25);
      expect(unsolved.cd1_1, isNull);
      expect(unsolved.cd1_2, isNull);
      expect(unsolved.cd2_1, isNull);
      expect(unsolved.cd2_2, isNull);
      expect(unsolved.sip, isNull);

      fake.setResponse(
        '/api/images/11',
        status: 404,
        body: '{"error":"missing"}',
      );
      expect(await repository.getStoredWcsDistortion(11), isNull);
    });

    test('rejectImage patches host row', () async {
      fake.setResponse(
        '/api/images/3',
        method: 'PUT',
        body: '{"status":"updated"}',
      );

      await repository.rejectImage(3, 'clouds');
      expect(fake.requests.single.method, 'PUT');
      expect(fake.requests.single.path, '/api/images/3');
      expect(fake.requests.single.body, contains('isAccepted'));
    });

    test('the run history follows every host page', () async {
      fake.setResponseSequence(
        '/api/sequence-runs',
        responses: [
          (
            status: 200,
            body: '''
              {"items":[
                {"id":3,"sequenceId":9,"sequenceName":"Galaxy","startedAt":"2025-06-03T00:00:00Z","status":"completed"},
                {"id":2,"sequenceId":9,"sequenceName":"Galaxy","startedAt":"2025-06-02T00:00:00Z","status":"failed"}
              ],"total":3}
            ''',
            headers: null,
          ),
          (
            status: 200,
            body: '''
              {"items":[
                {"id":1,"sequenceId":9,"sequenceName":"Galaxy","startedAt":"2025-06-01T00:00:00Z","status":"completed"}
              ],"total":3}
            ''',
            headers: null,
          ),
        ],
      );

      final runs = await RemoteHostRecords(backend).getAllRuns();

      expect(runs.map((run) => run.id), [3, 2, 1]);
      final requests = fake.requestsFor('/api/sequence-runs');
      expect(requests, hasLength(2));
      expect(requests[0].url.queryParameters, {'limit': '1000', 'offset': '0'});
      expect(requests[1].url.queryParameters, {'limit': '1000', 'offset': '2'});
    });

    test(
      'image watch suppresses duplicates and recovers after a host blip',
      () async {
        fake.setResponseSequence(
          '/api/sessions/6/images',
          responses: [
            (
              status: 200,
              body: jsonEncode({
                'images': [_imageRow(1)],
              }),
              headers: null,
            ),
            (
              status: 200,
              body: jsonEncode({
                'images': [_imageRow(1)],
              }),
              headers: null,
            ),
            (status: 400, body: '{"error":"temporary"}', headers: null),
            (
              status: 200,
              body: jsonEncode({
                'images': [_imageRow(2)],
              }),
              headers: null,
            ),
          ],
        );
        final pollingRepository = RemoteImagingRecords(
          backend,
          pollInterval: const Duration(milliseconds: 5),
        );
        final values = <List<DbCapturedImage>>[];
        final errors = <Object>[];
        final subscription = pollingRepository
            .watchImagesForSession(6)
            .listen(values.add, onError: errors.add);

        await _waitUntil(
          () =>
              fake.requestsFor('/api/sessions/6/images').length >= 5 &&
              values.length >= 2,
          describe: () =>
              '${fake.requestsFor('/api/sessions/6/images').length} requests, '
              '${values.length} values, ${errors.length} errors',
        );

        expect(values.map((rows) => rows.single.id), [1, 2]);
        expect(errors, isEmpty);
        await subscription.cancel().timeout(const Duration(seconds: 1));
      },
    );
  });
}
