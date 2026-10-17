// `FfiBackend.getImageThumbnail` reads the sidecar cache the capture pipeline
// writes, instead of decoding the frame again on every request.
//
// `ThumbnailSidecarService` has always written a `.thumb.jpg` beside every
// captured FITS, and the remote-mode HTTP handler has always read it first.
// The desktop FFI backend went straight to the Rust full-frame decode every
// single time — so a night's worth of frames cost one 32.8 MB FITS read, u16
// conversion, auto-stretch and JPEG encode PER FRAME PER NAVIGATION, with the
// answer already sitting on disk. That is what the owner saw when the
// Dashboard and Imaging frame strips came up empty.
//
// These tests drive the real `FfiBackend` against an in-memory database, with
// the sidecar service's generator stubbed so no Rust runtime is needed.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

/// Stands in for `apiGenerateFitsThumbnail`. Counts calls so a test can prove
/// a request was answered from disk rather than by decoding again.
class _CountingGenerator {
  int calls = 0;
  final List<String> paths = <String>[];
  Uint8List bytes;
  Object? throwOnCall;

  /// Stands in for the real generation's duration, so a test can hold several
  /// requests inside one generation the way a 35-500 ms FITS decode does.
  Future<void>? holdUntil;

  _CountingGenerator({Uint8List? bytes})
    : bytes = bytes ?? Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]);

  Future<Uint8List> call({
    required String filePath,
    required int maxSize,
  }) async {
    calls++;
    paths.add(filePath);
    final hold = holdUntil;
    if (hold != null) await hold;
    final failure = throwOnCall;
    if (failure != null) {
      throwOnCall = null;
      throw failure;
    }
    return bytes;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late SkotiqDatabase db;
  late ImagesDao imagesDao;
  late _CountingGenerator generator;
  late FfiBackend backend;

  /// Writes a stand-in FITS on disk and the row that points at it.
  Future<(int, String)> seedFrame([String name = 'L_0001.fits']) async {
    final path = '${temp.path}/$name';
    await File(path).writeAsBytes(Uint8List(2880));
    final id = await imagesDao.insertSequenceFrame(
      filePath: path,
      fileName: name,
      fileFormat: 'fits',
      exposureDuration: 300.0,
      capturedAt: DateTime.utc(2026, 9, 14, 1, 0, 0),
      isAccepted: true,
      producingNodeId: 'node-1',
      runtimeGrade: 'pass',
      filter: 'L',
    );
    return (id, path);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sk-thumb-sidecar');
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = ImagesDao(db);
    generator = _CountingGenerator();
    backend = FfiBackend(
      database: db,
      thumbnailSidecars: ThumbnailSidecarService(generator: generator.call),
    );
  });

  tearDown(() async {
    backend.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });

  /// The service writes sidecars without awaiting, so give the microtask and
  /// the file write a chance to land before asserting on disk.
  Future<void> settle() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('a sidecar on disk is served without decoding the frame', () async {
    final (id, path) = await seedFrame();
    final cached = Uint8List.fromList(<int>[9, 9, 9, 9]);
    await File(sidecarPathForFits(path)).writeAsBytes(cached, flush: true);

    final bytes = await backend.getImageThumbnail(id);

    expect(bytes, cached, reason: 'the sidecar bytes must be what is returned');
    expect(
      generator.calls,
      0,
      reason: 'the frame was decoded even though its sidecar was on disk',
    );
  });

  test(
    'a stamped sidecar path outside the canonical location is found',
    () async {
      final (id, _) = await seedFrame();
      final stamped = '${temp.path}/elsewhere/cached.jpg';
      await File(stamped).create(recursive: true);
      final cached = Uint8List.fromList(<int>[4, 4, 4]);
      await File(stamped).writeAsBytes(cached, flush: true);
      await imagesDao.setThumbnailPath(id, stamped);

      final bytes = await backend.getImageThumbnail(id);

      expect(bytes, cached);
      expect(generator.calls, 0);
    },
  );

  test('a cold frame is decoded once and then cached for next time', () async {
    final (id, path) = await seedFrame();

    final first = await backend.getImageThumbnail(id);
    expect(first, generator.bytes);
    expect(generator.calls, 1, reason: 'the cold path must generate');
    await settle();

    // The sidecar is now on disk and the row is stamped, so the second request
    // is a file read. This is the self-heal for frames captured before
    // sidecars existed.
    final sidecar = File(sidecarPathForFits(path));
    expect(await sidecar.exists(), isTrue, reason: 'sidecar not written');
    expect(await sidecar.readAsBytes(), generator.bytes);

    final second = await backend.getImageThumbnail(id);
    expect(second, generator.bytes);
    expect(
      generator.calls,
      1,
      reason: 'the second request decoded again instead of reading the sidecar',
    );
  });

  test('simultaneous requests for one frame decode it once', () async {
    final (id, _) = await seedFrame();
    // Real generation takes tens to hundreds of milliseconds, which is what
    // makes the overlap possible. The gate is held open explicitly so the test
    // measures the coalescing and not the stub's speed.
    final gate = Completer<void>();
    generator.holdUntil = gate.future;

    // The cockpit strip, the run dashboard's history rail and the Tonight
    // panel all ask for the newest frame at the same moment.
    final requests = <Future<Uint8List>>[
      backend.getImageThumbnail(id),
      backend.getImageThumbnail(id),
      backend.getImageThumbnail(id),
    ];
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    gate.complete();
    final results = await Future.wait(requests);

    expect(results.every((bytes) => bytes == generator.bytes), isTrue);
    expect(generator.calls, 1, reason: 'one frame, three full-frame decodes');
  });

  test('a request after a generation finished decodes again', () async {
    // The coalescing window is exactly the generation, not a second cache of
    // its own: once it ends the sidecar is the cache, so a frame whose sidecar
    // has gone is decoded again rather than answered from a stale entry.
    final (id, path) = await seedFrame();
    await backend.getImageThumbnail(id);
    await settle();
    await File(sidecarPathForFits(path)).delete();

    await backend.getImageThumbnail(id);

    expect(generator.calls, 2);
  });

  test(
    'an empty sidecar is treated as a miss, not served as a frame',
    () async {
      final (id, path) = await seedFrame();
      // What a write cut short by a pulled SD card leaves behind. Serving it
      // would show a broken-image glyph for this frame for good.
      await File(
        sidecarPathForFits(path),
      ).writeAsBytes(Uint8List(0), flush: true);

      final bytes = await backend.getImageThumbnail(id);

      expect(bytes, generator.bytes);
      expect(generator.calls, 1);
    },
  );

  test(
    'a sidecar that cannot be written does not deny the caller its bytes',
    () async {
      // A read-only frame directory — a mounted archive, or a share the
      // operator only has read rights on. The decode succeeded; the caller
      // must get its thumbnail regardless of whether the cache write lands.
      final readOnly = await Directory(
        '${temp.path}/read-only',
      ).create(recursive: true);
      final name = 'L_0009.fits';
      final framePath = '${readOnly.path}/$name';
      await File(framePath).writeAsBytes(Uint8List(2880));
      final id = await imagesDao.insertSequenceFrame(
        filePath: framePath,
        fileName: name,
        fileFormat: 'fits',
        exposureDuration: 300.0,
        capturedAt: DateTime.utc(2026, 9, 14, 2, 0, 0),
        isAccepted: true,
        producingNodeId: 'node-ro',
        runtimeGrade: 'pass',
        filter: 'L',
      );
      await Process.run('chmod', <String>['a-w', readOnly.path]);
      addTearDown(() => Process.run('chmod', <String>['u+w', readOnly.path]));

      final bytes = await backend.getImageThumbnail(id);

      expect(bytes, generator.bytes);
      await settle();
      expect(
        await File(sidecarPathForFits(framePath)).exists(),
        isFalse,
        reason:
            'the write was supposed to be impossible, or this test proves '
            'nothing',
      );
      // The row's `thumbnail_path` is pre-populated at insert with the
      // predicted sidecar location (see `ImagesDao.insertSequenceFrame`), so a
      // stamp is never evidence that bytes exist — which is exactly why
      // `readSidecar` stats the stamped path and falls through when it is not
      // there. Asking again proves the frame still resolves rather than being
      // pinned to a path that will never have a file.
      expect(
        await imagesDao.getThumbnailPath(id),
        sidecarPathForFits(framePath),
      );
      expect(await backend.getImageThumbnail(id), generator.bytes);
    },
  );

  test('a missing source frame is reported, not silently blank', () async {
    final (id, path) = await seedFrame();
    await File(path).delete();

    await expectLater(
      backend.getImageThumbnail(id),
      throwsA(isA<SkotiqError>()),
    );
    expect(generator.calls, 0);
  });

  test('an unknown image id is reported', () async {
    await expectLater(
      backend.getImageThumbnail(4242),
      throwsA(isA<SkotiqError>()),
    );
  });

  test(
    'a generator failure surfaces instead of returning empty bytes',
    () async {
      final (id, _) = await seedFrame();
      generator.throwOnCall = StateError('native decode failed');

      await expectLater(
        backend.getImageThumbnail(id),
        throwsA(isA<SkotiqError>()),
      );
    },
  );
}
