import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/stacking_handlers.dart';
import 'package:skotiq_desktop/headless_api/validation.dart';
import 'package:shelf/shelf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late SkotiqDatabase database;
  late ProviderContainer container;
  late StackedResultsDao dao;
  late StackingHandlers handlers;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ns_saved_stack_test_');
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    dao = container.read(stackedResultsDaoProvider);
    handlers = StackingHandlers(
      container,
      savedPreviewPathResolver: (id) async =>
          '${tempDir.path}/canonical/result_$id.png',
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    await tempDir.delete(recursive: true);
  });

  Future<int> insertResult({String? previewPath}) {
    return dao.insertResult(
      StackAndShareResult(
        sessionId: 3,
        targetName: 'M81',
        width: 2,
        height: 1,
        framesStacked: 5,
        framesAttempted: 6,
        integrationSecs: 300,
        avgAlignmentResidual: 0.3,
        isColor: true,
        channels: 3,
        createdAt: DateTime.utc(2026, 7, 14, 1, 2, 3),
        exportedImagePath: previewPath,
      ),
    );
  }

  Request get(String path) =>
      Request('GET', Uri.parse('http://localhost$path'));

  test(
    'detail sanitizes the host path and reports preview availability',
    () async {
      final preview = File('${tempDir.path}/secret-host-preview.jpg');
      await preview.writeAsBytes(const [1, 2, 3], flush: true);
      final id = await insertResult(previewPath: preview.path);

      final response = await handlers.handleSavedResult(
        get('/api/stacking/results/$id'),
        '$id',
      );
      final rawBody = await response.readAsString();
      final body = jsonDecode(rawBody) as Map<String, dynamic>;
      final result = body['result'] as Map<String, dynamic>;

      expect(response.statusCode, 200);
      expect(result['id'], id);
      expect(result['previewAvailable'], isTrue);
      expect(result.containsKey('exportedImagePath'), isFalse);
      expect(rawBody, isNot(contains(tempDir.path)));
    },
  );

  test(
    'preview streams the recorded bytes with the correct media type',
    () async {
      final preview = File('${tempDir.path}/result.jpg');
      await preview.writeAsBytes(const [10, 20, 30, 40], flush: true);
      final id = await insertResult(previewPath: preview.path);

      final response = await handlers.handleSavedResultPreview(
        get('/api/stacking/results/$id/preview'),
        '$id',
      );

      expect(response.statusCode, 200);
      expect(response.headers[HttpHeaders.contentTypeHeader], 'image/jpeg');
      expect(await response.read().expand((chunk) => chunk).toList(), [
        10,
        20,
        30,
        40,
      ]);
    },
  );

  test('legacy row without pixels returns an exact unavailable code', () async {
    final id = await insertResult();

    final response = await handlers.handleSavedResultPreview(
      get('/api/stacking/results/$id/preview'),
      '$id',
    );
    final body =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(response.statusCode, 404);
    expect(body['code'], 'stack_result_preview_unavailable');
  });

  test('list validates its limit before querying history', () async {
    await expectLater(
      handlers.handleSavedResults(
        get('/api/stacking/results?limit=not-a-number'),
      ),
      throwsA(isA<BadRequestError>()),
    );
  });

  test('detail rejects non-positive path ids', () async {
    await expectLater(
      handlers.handleSavedResult(get('/api/stacking/results/0'), '0'),
      throwsA(isA<BadRequestError>()),
    );
  });
}
