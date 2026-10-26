import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/daos/sessions_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/services/imaging_records_repository.dart';

import '../fakes/fake_network_client.dart';

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
  group('ImagingRecordsRepository local', () {
    late SkotiqDatabase db;
    late SessionsDao sessionsDao;
    late ImagesDao imagesDao;
    late ImagingRecordsRepository repository;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      sessionsDao = SessionsDao(db);
      imagesDao = ImagesDao(db);
      repository = ImagingRecordsRepository.local(
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
      final hooked = ImagingRecordsRepository.local(
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
      hooked.notifySolvedFrame(id);
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

  group('ImagingRecordsRepository remote', () {
    late FakeNetworkClient fake;
    late NetworkBackend backend;
    late ImagingRecordsRepository repository;

    setUp(() {
      fake = FakeNetworkClient();
      backend = NetworkBackend(
        serverHost: '127.0.0.1',
        serverPort: 8080,
        httpClient: fake,
        autoConnectWebSocket: false,
      );
      repository = ImagingRecordsRepository.remote(backend);
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

    test('getAllSequenceRunsRemote follows every host page', () async {
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

      final runs = await repository.getAllSequenceRunsRemote();

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
        final pollingRepository = ImagingRecordsRepository.remote(
          backend,
          pollInterval: const Duration(milliseconds: 5),
        );
        final values = <List<CapturedImage>>[];
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
