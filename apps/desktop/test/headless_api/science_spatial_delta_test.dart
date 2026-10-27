import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/science_handlers.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_desktop/headless_api/route_metadata.dart';

void main() {
  test(
    'delta reads keep view access while Science mutations require control',
    () {
      expect(
        requiredAuthScopeNameForEndpoint(
          method: 'POST',
          path: '/api/science/session/99/bundle',
        ),
        'view',
      );
      expect(
        requiredAuthScopeNameForEndpoint(
          method: 'POST',
          path: '/api/science/session/99/reprocess',
        ),
        'control',
      );
    },
  );

  test(
    'spatial polling sends only changed frames, including reprocessing and deletion',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      final sid = await db.sessionsDao.startSession(name: 'delta replay');
      final ids = <int>[];
      for (var i = 0; i < 3; i++) {
        ids.add(
          await db.imagesDao.insertSequenceFrame(
            filePath: '/frame-$i.fits',
            fileName: 'frame-$i.fits',
            fileFormat: 'fits',
            exposureDuration: 90,
            capturedAt: DateTime.utc(2026, 10, 27, 0, i),
            isAccepted: true,
            producingNodeId: 'test',
            sessionId: sid,
          ),
        );
      }
      Future<void> maps(int id, double value) async {
        await db.scienceDao.replaceTileMetricsForImage(id, [
          for (var i = 0; i < 768; i++)
            ScienceTileMetricsCompanion.insert(
              capturedImageId: Value(id),
              sessionId: Value(sid),
              layerType: 'background',
              tileRow: i ~/ 32,
              tileCol: i % 32,
              value: Value(value),
            ),
        ]);
      }

      await maps(ids[0], 1);
      await maps(ids[1], 2);
      final handlers = ScienceHandlers(container);
      Future<Map<String, dynamic>> poll([Map<String, dynamic>? prior]) async {
        final response = await handlers.handleGetSessionBundle(
          Request(
            prior == null ? 'GET' : 'POST',
            Uri.parse('http://localhost/api/science/session/$sid/bundle'),
            body: prior == null
                ? null
                : jsonEncode({'spatialVersions': prior['spatialVersions']}),
          ),
          '$sid',
        );
        expect(response.statusCode, 200);
        return jsonDecode(await response.readAsString())
            as Map<String, dynamic>;
      }

      final initial = await poll();
      expect(initial['tileMetrics'], hasLength(1536));
      final unchanged = await poll(initial);
      expect(unchanged['tileMetrics'], isEmpty);
      expect(
        jsonEncode(unchanged).length,
        lessThan(jsonEncode(initial).length ~/ 100),
      );
      await maps(ids[2], 3);
      final added = await poll(unchanged);
      expect(
        (added['tileMetrics'] as List).map((r) => r['capturedImageId']).toSet(),
        {ids[2]},
      );
      await maps(ids[0], 7);
      await db.scienceDao.replaceTileMetricsForImage(ids[1], []);
      final replaced = await poll(added);
      expect(replaced['tileMetrics'], hasLength(768));
      expect(
        (replaced['tileMetrics'] as List).every((r) => r['value'] == 7),
        isTrue,
      );
      expect(
        (replaced['spatialVersions']['tileMetrics'] as Map).keys,
        isNot(contains('${ids[1]}')),
      );
    },
  );
}
