import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/first_light_handlers.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('FirstLightHandlers', () {
    late SkotiqDatabase db;
    late TransientDetectionsDao dao;
    late ProviderContainer container;
    late FirstLightHandlers handlers;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      dao = TransientDetectionsDao(db);
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      handlers = FirstLightHandlers(container);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<int> seed({
      int? sessionId,
      String kind = 'newSource',
      String? catalogMatch,
      double snr = 18.0,
    }) {
      return dao.insertDetection(
        TransientDetectionsCompanion.insert(
          tileId: 42,
          raDeg: 120.0,
          decDeg: 25.0,
          residualFlux: 1500.0,
          snr: snr,
          fwhm: 2.1,
          eccentricity: 0.1,
          positionAngleDeg: const Value(63.5),
          kind: kind,
          confidence: 0.8,
          sessionId: Value(sessionId),
          catalogMatch: Value(catalogMatch),
        ),
      );
    }

    test(
      'GET candidates returns the persisted detections newest-first',
      () async {
        await seed(kind: 'newSource');
        await seed(kind: 'pointBrightening', catalogMatch: 'Star V=12.3');

        final response = await translateHandlerErrors(
          handlers.handleGetCandidates(
            Request(
              'GET',
              Uri.parse('http://localhost/api/firstlight/candidates'),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        final candidates = body['candidates'] as List;
        expect(candidates, hasLength(2));
        expect(body['unnamedCount'], 1);
        // Wire shape carries the fields the client reconstructs.
        final first = candidates.first as Map<String, dynamic>;
        expect(first['tileId'], 42);
        expect(first['kind'], isA<String>());
        expect(first['raDeg'], isA<num>());
        // positionAngleDeg must survive the wire so remote clients orient the
        // residual ellipse / streak trail correctly (not silently to 0deg).
        expect(first['positionAngleDeg'], 63.5);
      },
    );

    test('GET near returns the cross-night history at a position', () async {
      // Same source over two nights at ~(120, 25), plus a far-away source that
      // must NOT group in — backs the slave light-curve detail view.
      await dao.insertDetection(
        TransientDetectionsCompanion.insert(
          tileId: 42,
          raDeg: 120.001,
          decDeg: 25.001,
          residualFlux: 1500.0,
          snr: 18.0,
          fwhm: 2.1,
          eccentricity: 0.1,
          kind: 'newSource',
          confidence: 0.8,
          detectedAt: Value(DateTime.utc(2026, 6, 1)),
        ),
      );
      await dao.insertDetection(
        TransientDetectionsCompanion.insert(
          tileId: 42,
          raDeg: 119.999,
          decDeg: 24.999,
          residualFlux: 1500.0,
          snr: 18.0,
          fwhm: 2.1,
          eccentricity: 0.1,
          kind: 'newSource',
          confidence: 0.8,
          detectedAt: Value(DateTime.utc(2026, 6, 3)),
        ),
      );
      await dao.insertDetection(
        TransientDetectionsCompanion.insert(
          tileId: 99,
          raDeg: 121.0,
          decDeg: 25.0,
          residualFlux: 1500.0,
          snr: 18.0,
          fwhm: 2.1,
          eccentricity: 0.1,
          kind: 'newSource',
          confidence: 0.8,
          detectedAt: Value(DateTime.utc(2026, 6, 2)),
        ),
      );

      final response = await translateHandlerErrors(
        handlers.handleGetNear(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/firstlight/near?ra=120&dec=25&radius=0.02',
            ),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final detections = body['detections'] as List;
      // The bounding box keeps the two near rows and excludes the 1-deg source.
      expect(detections, hasLength(2));
      expect(body['count'], 2);
    });

    test('GET near rejects a missing ra/dec', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetNear(
          Request(
            'GET',
            Uri.parse('http://localhost/api/firstlight/near?dec=25'),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
    });

    test(
      'GET near rejects malformed and non-physical coordinates/radius',
      () async {
        final cases = <String, String>{
          'ra=NaN&dec=25': 'ra',
          'ra=-0.01&dec=25': 'ra',
          'ra=360.01&dec=25': 'ra',
          'ra=120&dec=Infinity': 'dec',
          'ra=120&dec=-90.01': 'dec',
          'ra=120&dec=90.01': 'dec',
          'ra=120&dec=25&radius=nope': 'radius',
          'ra=120&dec=25&radius=NaN': 'radius',
          'ra=120&dec=25&radius=0': 'radius',
          'ra=120&dec=25&radius=-0.1': 'radius',
        };

        for (final entry in cases.entries) {
          final response = await translateHandlerErrors(
            handlers.handleGetNear(
              Request(
                'GET',
                Uri.parse('http://localhost/api/firstlight/near?${entry.key}'),
              ),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: entry.key);
          final body = jsonDecode(await response.readAsString()) as Map;
          expect(body['field'], entry.value, reason: entry.key);
        }
      },
    );

    test('GET near keeps the documented over-max radius cap', () async {
      await dao.insertDetection(
        TransientDetectionsCompanion.insert(
          tileId: 42,
          raDeg: 120.4,
          decDeg: 25.0,
          residualFlux: 1500.0,
          snr: 18.0,
          fwhm: 2.1,
          eccentricity: 0.1,
          kind: 'newSource',
          confidence: 0.8,
        ),
      );

      final response = await translateHandlerErrors(
        handlers.handleGetNear(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/firstlight/near'
              '?ra=120&dec=25&radius=5',
            ),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['count'], 1);
    });

    test('GET candidates scoped to a session filters by sessionId', () async {
      // Detections reference imaging_sessions (FKs are enforced), so seed the
      // sessions first.
      for (final sessionId in [7, 9]) {
        await db
            .into(db.imagingSessions)
            .insert(
              ImagingSessionsCompanion.insert(
                id: Value(sessionId),
                startTime: DateTime.utc(2026, 6, 19, 21),
              ),
            );
      }
      await seed(sessionId: 7);
      await seed(sessionId: 9);

      final response = await translateHandlerErrors(
        handlers.handleGetCandidates(
          Request(
            'GET',
            Uri.parse('http://localhost/api/firstlight/candidates?sessionId=7'),
          ),
        ),
      );

      final body = jsonDecode(await response.readAsString()) as Map;
      final candidates = body['candidates'] as List;
      expect(candidates, hasLength(1));
      expect((candidates.single as Map)['sessionId'], 7);
    });

    test(
      'GET candidates bounds the across-sessions feed to the default limit',
      () async {
        // A heavy multi-season log: more rows than one page. The poll must
        // return only the most-recent page, not the whole all-time history.
        for (var i = 0; i < 250; i++) {
          await dao.insertDetection(
            TransientDetectionsCompanion.insert(
              tileId: 42,
              raDeg: 120.0,
              decDeg: 25.0,
              residualFlux: 1500.0,
              snr: 18.0,
              fwhm: 2.1,
              eccentricity: 0.1,
              kind: 'newSource',
              confidence: 0.8,
              detectedAt: Value(
                DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
              ),
            ),
          );
        }

        final response = await translateHandlerErrors(
          handlers.handleGetCandidates(
            Request(
              'GET',
              Uri.parse('http://localhost/api/firstlight/candidates'),
            ),
          ),
        );

        final body = jsonDecode(await response.readAsString()) as Map;
        final candidates = body['candidates'] as List;
        // Default page size (200), not all 250 rows.
        expect(candidates, hasLength(200));
        expect(body['limit'], 200);
        expect(body['offset'], 0);
        // Newest-first: the first row is the latest detectedAt.
        final firstMs = (candidates.first as Map)['detectedAt'] as int;
        final lastMs = (candidates.last as Map)['detectedAt'] as int;
        expect(firstMs, greaterThan(lastMs));
      },
    );

    test('GET candidates honours limit + offset paging', () async {
      for (var i = 0; i < 10; i++) {
        await dao.insertDetection(
          TransientDetectionsCompanion.insert(
            tileId: 42,
            raDeg: 120.0,
            decDeg: 25.0,
            residualFlux: 1500.0,
            snr: 18.0,
            fwhm: 2.1,
            eccentricity: 0.1,
            kind: 'newSource',
            confidence: 0.8,
            detectedAt: Value(DateTime.utc(2026, 1, 1).add(Duration(hours: i))),
          ),
        );
      }

      final page = await translateHandlerErrors(
        handlers.handleGetCandidates(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/firstlight/candidates?limit=3&offset=3',
            ),
          ),
        ),
      );
      final body = jsonDecode(await page.readAsString()) as Map;
      expect((body['candidates'] as List), hasLength(3));
      expect(body['limit'], 3);
      expect(body['offset'], 3);
    });

    test('GET candidates rejects a non-integer sessionId', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetCandidates(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/firstlight/candidates?sessionId=abc',
            ),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('POST review marks a detection reviewed', () async {
      final id = await seed();

      final response = await translateHandlerErrors(
        handlers.handleReview(
          Request(
            'POST',
            Uri.parse('http://localhost/api/firstlight/$id/review'),
          ),
          '$id',
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['status'], 'reviewed');
      expect((body['detection'] as Map)['reviewed'], isTrue);

      final row = await dao.detectionById(id);
      expect(row!.reviewed, isTrue);
      expect(row.dismissed, isFalse);
    });

    test('POST dismiss flags a detection dismissed', () async {
      final id = await seed();

      final response = await translateHandlerErrors(
        handlers.handleDismiss(
          Request(
            'POST',
            Uri.parse('http://localhost/api/firstlight/$id/dismiss'),
          ),
          '$id',
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['status'], 'dismissed');

      final row = await dao.detectionById(id);
      expect(row!.dismissed, isTrue);
      expect(row.reviewed, isTrue);
    });

    test('POST review on a missing id returns 404', () async {
      final response = await translateHandlerErrors(
        handlers.handleReview(
          Request(
            'POST',
            Uri.parse('http://localhost/api/firstlight/9999/review'),
          ),
          '9999',
        ),
      );
      expect(response.statusCode, HttpStatus.notFound);
    });

    test('POST review rejects a non-integer id', () async {
      final response = await translateHandlerErrors(
        handlers.handleReview(
          Request(
            'POST',
            Uri.parse('http://localhost/api/firstlight/nope/review'),
          ),
          'nope',
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
    });
  });

  group('FirstLightHandlers crops', () {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    late Directory tempDir;
    late SkotiqDatabase db;
    late TransientDetectionsDao dao;
    late ProviderContainer container;
    late FirstLightHandlers handlers;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('first-light-crops-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              return tempDir.path;
            }
            return null;
          });
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      dao = TransientDetectionsDao(db);
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      handlers = FirstLightHandlers(container);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<int> seedDetection() => dao.insertDetection(
      TransientDetectionsCompanion.insert(
        tileId: 42,
        raDeg: 120.0,
        decDeg: 25.0,
        residualFlux: 1500.0,
        snr: 18.0,
        fwhm: 2.1,
        eccentricity: 0.1,
        kind: 'newSource',
        confidence: 0.8,
      ),
    );

    test(
      'GET crops streams the real-pixel stamp the difference pass wrote',
      () async {
        final id = await seedDetection();
        // Write the deterministically-named stamp the bridge would have produced.
        final atlasRoot = p.join(tempDir.path, 'sky_atlas');
        final cropDir = Directory(firstLightCropDir(atlasRoot));
        await cropDir.create(recursive: true);
        final name = firstLightCropName(
          tileId: 42,
          raDeg: 120.0,
          decDeg: 25.0,
          stage: 'residual',
        );
        final pngBytes = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
        await File(p.join(cropDir.path, name)).writeAsBytes(pngBytes);

        final response = await translateHandlerErrors(
          handlers.handleGetCrop(
            Request(
              'GET',
              Uri.parse('http://localhost/api/firstlight/$id/crops/residual'),
            ),
            '$id',
            'residual',
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers['content-type'], 'image/png');
        expect(await response.read().expand((b) => b).toList(), pngBytes);
      },
    );

    test('GET crops 404s when no stamp was captured', () async {
      final id = await seedDetection();
      final response = await translateHandlerErrors(
        handlers.handleGetCrop(
          Request(
            'GET',
            Uri.parse('http://localhost/api/firstlight/$id/crops/template'),
          ),
          '$id',
          'template',
        ),
      );
      expect(response.statusCode, HttpStatus.notFound);
    });

    test('GET crops rejects an unknown stage', () async {
      final id = await seedDetection();
      final response = await translateHandlerErrors(
        handlers.handleGetCrop(
          Request(
            'GET',
            Uri.parse('http://localhost/api/firstlight/$id/crops/bogus'),
          ),
          '$id',
          'bogus',
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
    });
  });
}
