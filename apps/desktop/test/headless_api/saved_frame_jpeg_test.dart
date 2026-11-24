// GET /api/images/<id>/jpeg: a saved frame drawn on the host for a device that
// cannot decode a FITS (a phone), with the frame's own size in x-image-meta.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_desktop/headless_api/display_buffer_jpeg.dart';
import 'package:skotiq_desktop/headless_api/handlers/session_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockImagingBackend extends Mock implements ImagingBackend {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ProviderContainer container;
  late SessionHandlers handlers;
  late _MockImagingBackend imaging;
  late Directory dir;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imaging = _MockImagingBackend();
    dir = Directory.systemTemp.createTempSync('saved-frame-jpeg');
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        imagingBackendProvider.overrideWithValue(imaging),
      ],
    );
    handlers = SessionHandlers(container);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<int> createImage(String path) async {
    final response = await translateHandlerErrors(
      handlers.handleCreateImage(
        Request(
          'POST',
          Uri.parse('http://localhost/api/images'),
          body: jsonEncode({
            'filePath': path,
            'fileName': 'frame.fits',
            'frameType': 'light',
            'exposureDuration': 0.005,
            'capturedAt': DateTime.utc(2026, 11, 24).toIso8601String(),
          }),
        ),
      ),
    );
    return (jsonDecode(await response.readAsString()) as Map)['id'] as int;
  }

  Future<Response> getJpeg(int id) => translateHandlerErrors(
    handlers.handleGetImageJpeg(
      Request('GET', Uri.parse('http://localhost/api/images/$id/jpeg')),
      '$id',
    ),
  );

  test('draws the frame and names its size', () async {
    final file = File('${dir.path}/frame.fits')..writeAsBytesSync([0]);
    when(() => imaging.readFitsFile(filePath: file.path)).thenAnswer(
      (_) async => bridge.FitsReadResult(
        width: 4,
        height: 2,
        bitpix: 16,
        displayData: Uint8List(4 * 2 * 4),
        histogram: Uint32List(256),
        stats: const bridge.ImageStatsResult(
          min: 0,
          max: 1,
          mean: 0,
          median: 0,
          stdDev: 0,
          starCount: 0,
        ),
      ),
    );
    final id = await createImage(file.path);

    final response = await getJpeg(id);

    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers['content-type'], 'image/jpeg');
    final meta = decodeImageMetaHeader(response.headers['x-image-meta']!);
    expect((meta['width'], meta['height']), (4, 2));
  });

  test('a frame whose file is gone is not found', () async {
    final id = await createImage('${dir.path}/missing.fits');
    final response = await getJpeg(id);
    expect(response.statusCode, HttpStatus.notFound);
    verifyNever(() => imaging.readFitsFile(filePath: any(named: 'filePath')));
  });
}
