// sidecar JPEG thumbnail caching for GET /api/images/{id}/thumbnail.
//
// Strategy: spin up an in-memory Drift DB, write a fake "FITS" file to a
// temp directory, override `fitsThumbnailBytesGeneratorProvider` with a
// deterministic stub that returns canned JPEG bytes. We then exercise the
// handler end-to-end via the existing `translateHandlerErrors` wrapper
// and assert on response codes, headers, and the on-disk sidecar.
//
// The stub is reused everywhere the production code would call
// `bridge_api.apiGenerateFitsThumbnail` so we never need the Rust runtime
// during tests.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/session_handlers.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// Canned JPEG-ish bytes our stubbed FFI returns. We don't decode them so
/// the exact magic numbers don't matter; the bytes are unique-enough to
/// spot-check that the sidecar file matches what the FFI produced.
final Uint8List _cannedJpeg = Uint8List.fromList(
  List<int>.generate(64, (i) => (i * 7 + 13) & 0xFF),
);

/// Configurable thumbnail-generator stub. Tests mutate the captured count
/// and override the return bytes between cases.
class _StubGenerator {
  int callCount = 0;
  Uint8List bytes;
  Object? throwOnNext;

  _StubGenerator({Uint8List? bytes}) : bytes = bytes ?? _cannedJpeg;

  Future<Uint8List> call({
    required String filePath,
    required int maxSize,
  }) async {
    callCount++;
    if (throwOnNext != null) {
      final err = throwOnNext!;
      throwOnNext = null;
      throw err;
    }
    return bytes;
  }
}

Future<void> _pumpUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'pumpUntil predicate did not become true within $timeout',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('thumbnail sidecar caching', () {
    late ProviderContainer container;
    late SessionHandlers handlers;
    late SkotiqDatabase db;
    late Directory tempDir;
    late File fitsFile;
    late int imageId;
    late _StubGenerator stubGenerator;
    late JobManager jobManager;

    setUp(() async {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      stubGenerator = _StubGenerator();
      jobManager = JobManager(emitEvent: (_) {});

      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          // Replace the FFI with the deterministic stub. The
          // ThumbnailSidecarService picks this up via Riverpod, so both
          // the capture-time fire-and-forget path and the GET cold-read
          // fallback share the same stub.
          fitsThumbnailBytesGeneratorProvider.overrideWithValue(
            stubGenerator.call,
          ),
        ],
      );
      handlers = SessionHandlers(container, jobManager: jobManager);

      tempDir = await Directory.systemTemp.createTemp('skotiq_thumb_sidecar_');
      fitsFile = File('${tempDir.path}${Platform.pathSeparator}test.fits');
      // Real FITS content not needed — the FFI stub doesn't read it. The
      // file just has to exist for the existence-check branches.
      await fitsFile.writeAsBytes(List<int>.filled(2880, 0));

      imageId = await db.imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: fitsFile.path,
          fileName: 'test.fits',
          fileFormat: const Value('fits'),
          frameType: const Value('light'),
          exposureDuration: 30.0,
          hfr: const Value(2.5),
          starCount: const Value(312),
          isAccepted: const Value(true),
          capturedAt: DateTime.utc(2026, 1, 1),
        ),
      );
    });

    tearDown(() async {
      await jobManager.dispose();
      container.dispose();
      await db.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup.
      }
    });

    Future<Response> hitThumbnail({Map<String, String>? headers}) {
      return translateHandlerErrors(
        handlers.handleGetImageThumbnail(
          Request(
            'GET',
            Uri.parse('http://localhost/api/images/$imageId/thumbnail'),
            headers: headers,
          ),
          imageId.toString(),
        ),
      );
    }

    test('POST creates a new image, sidecar file is written', () async {
      final newFits = File('${tempDir.path}${Platform.pathSeparator}new.fits');
      await newFits.writeAsBytes(List<int>.filled(2880, 0));

      final response = await translateHandlerErrors(
        handlers.handleCreateImage(
          Request(
            'POST',
            Uri.parse('http://localhost/api/images'),
            body: jsonEncode({
              'filePath': newFits.path,
              'fileName': 'new.fits',
              'frameType': 'light',
              'exposureDuration': 45.0,
              'capturedAt': DateTime.utc(2026, 1, 2).millisecondsSinceEpoch,
            }),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);

      // The handler schedules the sidecar via unawaited(...). Pump until
      // it lands on disk; if the stub blew up, the file simply never
      // appears and the timeout will surface that.
      final sidecar = File('${newFits.path}.thumb.jpg');
      await _pumpUntil(() => sidecar.existsSync());
      expect(await sidecar.readAsBytes(), _cannedJpeg);
      expect(stubGenerator.callCount, greaterThanOrEqualTo(1));
    });

    test('GET serves sidecar when present, returns ETag', () async {
      // Pre-write the sidecar so we hit the fast path (no FFI call).
      final sidecar = File('${fitsFile.path}.thumb.jpg');
      await sidecar.writeAsBytes(_cannedJpeg);
      await db.imagesDao.setThumbnailPath(imageId, sidecar.path);

      final priorCount = stubGenerator.callCount;
      final response = await hitThumbnail();

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'image/jpeg');
      expect(response.headers['etag'], isNotNull);
      expect(response.headers['etag']!, startsWith('"$imageId-'));
      expect(
        response.headers['cache-control'],
        'private, max-age=86400, immutable',
      );
      expect(response.headers['x-image-meta'], isNotNull);
      // No FFI call should have happened — bytes came from the on-disk
      // sidecar.
      expect(stubGenerator.callCount, priorCount);
      final body = await response.read().expand((c) => c).toList();
      expect(body, _cannedJpeg);
    });

    test('GET with matching If-None-Match returns 304', () async {
      final sidecar = File('${fitsFile.path}.thumb.jpg');
      await sidecar.writeAsBytes(_cannedJpeg);
      await db.imagesDao.setThumbnailPath(imageId, sidecar.path);

      final first = await hitThumbnail();
      final etag = first.headers['etag']!;
      await first.read().drain();

      final second = await hitThumbnail(headers: {'if-none-match': etag});
      expect(second.statusCode, HttpStatus.notModified);
      // 304 must not carry a body.
      final bytes = await second.read().expand((c) => c).toList();
      expect(bytes, isEmpty);
      expect(second.headers['etag'], etag);
    });

    test(
      'GET with missing sidecar falls back to cold read + self-heals',
      () async {
        // Sidecar not written; DB stamp is null. Handler should call the
        // stub, persist the result, and stamp the row.
        final sidecar = File('${fitsFile.path}.thumb.jpg');
        expect(sidecar.existsSync(), isFalse);

        final response = await hitThumbnail();
        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers['content-type'], 'image/jpeg');
        expect(response.headers['etag'], isNotNull);
        final body = await response.read().expand((c) => c).toList();
        expect(body, _cannedJpeg);

        // FFI was invoked exactly once.
        expect(stubGenerator.callCount, 1);
        // Sidecar is now on disk and the DB stamp reflects the new path.
        expect(sidecar.existsSync(), isTrue);
        expect(await sidecar.readAsBytes(), _cannedJpeg);
        expect(await db.imagesDao.getThumbnailPath(imageId), sidecar.path);

        // Second call should NOT re-invoke the FFI (warm hit).
        final second = await hitThumbnail();
        expect(second.statusCode, HttpStatus.ok);
        await second.read().drain();
        expect(stubGenerator.callCount, 1);
      },
    );

    test('GET returns 404 when FITS source file is missing', () async {
      await fitsFile.delete();
      final response = await hitThumbnail();
      expect(response.statusCode, HttpStatus.notFound);
      expect(stubGenerator.callCount, 0);
    });

    test(
      'POST regenerate-thumbnail rewrites sidecar with fresh mtime',
      () async {
        // Initial sidecar with old bytes.
        final sidecar = File('${fitsFile.path}.thumb.jpg');
        final originalBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
        await sidecar.writeAsBytes(originalBytes);
        await db.imagesDao.setThumbnailPath(imageId, sidecar.path);
        final originalMtime = await sidecar.lastModified();

        // Force a measurable mtime advance. Windows NTFS quantises file
        // mtime to ~10ms (sometimes 1s on FAT-style mounts); we wait 1.2s
        // to guarantee the post-regenerate stat strictly exceeds the
        // original. Bare-mtime assertion plus the byte-content check below
        // catches the cache invalidation case without depending on sub-
        // second filesystem resolution.
        await Future<void>.delayed(const Duration(milliseconds: 1200));

        // Swap the canned bytes so the regenerate produces a visibly
        // different result.
        final freshBytes = Uint8List.fromList(
          List<int>.generate(32, (i) => (i * 11 + 3) & 0xFF),
        );
        stubGenerator.bytes = freshBytes;

        final response = await translateHandlerErrors(
          handlers.handleRegenerateImageThumbnail(
            Request(
              'POST',
              Uri.parse(
                'http://localhost/api/images/$imageId/regenerate-thumbnail',
              ),
            ),
            imageId.toString(),
          ),
        );
        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['status'], 'regenerated');

        final newBytes = await sidecar.readAsBytes();
        expect(newBytes, freshBytes);
        final newMtime = await sidecar.lastModified();
        expect(newMtime.isAfter(originalMtime), isTrue);
      },
    );

    test(
      'POST backfill-thumbnails returns jobId, job processes rows',
      () async {
        // Add a few extra rows: one with no sidecar, one whose source FITS
        // is missing, and one that already has a sidecar on disk.
        final fitsA = File('${tempDir.path}${Platform.pathSeparator}a.fits');
        await fitsA.writeAsBytes(List<int>.filled(2880, 0));
        await db.imagesDao.createImage(
          CapturedImagesCompanion.insert(
            filePath: fitsA.path,
            fileName: 'a.fits',
            fileFormat: const Value('fits'),
            frameType: const Value('light'),
            exposureDuration: 10.0,
            capturedAt: DateTime.utc(2026, 1, 3),
          ),
        );

        final missingPath =
            '${tempDir.path}${Platform.pathSeparator}missing.fits';
        final idMissing = await db.imagesDao.createImage(
          CapturedImagesCompanion.insert(
            filePath: missingPath,
            fileName: 'missing.fits',
            fileFormat: const Value('fits'),
            frameType: const Value('light'),
            exposureDuration: 10.0,
            capturedAt: DateTime.utc(2026, 1, 4),
          ),
        );

        final fitsB = File('${tempDir.path}${Platform.pathSeparator}b.fits');
        await fitsB.writeAsBytes(List<int>.filled(2880, 0));
        final preExistingSidecar = File('${fitsB.path}.thumb.jpg');
        await preExistingSidecar.writeAsBytes(_cannedJpeg);
        final idB = await db.imagesDao.createImage(
          CapturedImagesCompanion.insert(
            filePath: fitsB.path,
            fileName: 'b.fits',
            fileFormat: const Value('fits'),
            frameType: const Value('light'),
            exposureDuration: 10.0,
            capturedAt: DateTime.utc(2026, 1, 5),
          ),
        );

        final response = await translateHandlerErrors(
          handlers.handleBackfillThumbnails(
            Request(
              'POST',
              Uri.parse('http://localhost/api/images/backfill-thumbnails'),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        final jobId = body['jobId'] as String;
        expect(body['operation'], 'image.backfill-thumbnails');
        expect(body['status'], anyOf('queued', 'running'));

        await _pumpUntil(
          () => jobManager.get(jobId)?.state.isTerminal ?? false,
          timeout: const Duration(seconds: 5),
        );

        final terminal = jobManager.get(jobId)!;
        expect(terminal.state, JobState.succeeded);
        final result = terminal.result!;
        // Three new rows + the setUp row = 4 total. Of those:
        //   - imageId (setUp): processed → written (no sidecar yet).
        //   - idA: processed → written.
        //   - idMissing: source FITS missing → skipped.
        //   - idB: sidecar already present → alreadyPresent.
        expect(result['total'], 4);
        expect(result['skipped'], 1);
        expect(result['alreadyPresent'], 1);
        expect(result['written'], 2);
        expect(result['failed'], 0);

        // Verify the on-disk state matches the counts.
        expect(File('${fitsFile.path}.thumb.jpg').existsSync(), isTrue);
        expect(File('${fitsA.path}.thumb.jpg').existsSync(), isTrue);
        expect(File('$missingPath.thumb.jpg').existsSync(), isFalse);
        // Skipped-missing should also have cleared the DB stamp.
        expect(await db.imagesDao.getThumbnailPath(idMissing), isNull);

        // Stamp on the pre-existing sidecar row should now be set so
        // GETs hit it without an FS probe.
        expect(
          await db.imagesDao.getThumbnailPath(idB),
          preExistingSidecar.path,
        );
      },
    );

    test('GET 404 when image row missing', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetImageThumbnail(
          Request(
            'GET',
            Uri.parse('http://localhost/api/images/999999/thumbnail'),
          ),
          '999999',
        ),
      );
      expect(response.statusCode, HttpStatus.notFound);
    });
  });

  group('thumbnail sidecar service unit', () {
    late Directory tempDir;
    late File fitsFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'skotiq_thumb_sidecar_unit_',
      );
      fitsFile = File('${tempDir.path}${Platform.pathSeparator}u.fits');
      await fitsFile.writeAsBytes(List<int>.filled(2880, 0));
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('writeSidecar produces SidecarWritten on success', () async {
      final stub = _StubGenerator();
      final service = ThumbnailSidecarService(generator: stub.call);
      final result = await service.writeSidecar(fitsFile.path);
      expect(result, isA<SidecarWritten>());
      final written = result as SidecarWritten;
      expect(written.byteCount, _cannedJpeg.length);
      expect(written.sidecarFile.path, '${fitsFile.path}.thumb.jpg');
      expect(await written.sidecarFile.readAsBytes(), _cannedJpeg);
    });

    test('writeSidecar returns SidecarSkipped for missing source', () async {
      final stub = _StubGenerator();
      final service = ThumbnailSidecarService(generator: stub.call);
      final result = await service.writeSidecar(
        '${tempDir.path}${Platform.pathSeparator}nope.fits',
      );
      expect(result, isA<SidecarSkipped>());
      expect((result as SidecarSkipped).reason, 'missing_source');
      expect(stub.callCount, 0);
    });

    test('writeSidecar returns SidecarFailed when FFI throws', () async {
      final stub = _StubGenerator()..throwOnNext = StateError('ffi boom');
      final service = ThumbnailSidecarService(generator: stub.call);
      final result = await service.writeSidecar(fitsFile.path);
      expect(result, isA<SidecarFailed>());
      expect((result as SidecarFailed).error, isA<StateError>());
    });
  });
}
