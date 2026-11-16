// A saved frame is shown at full resolution from its own file: on the imaging
// host the file where it was saved, on a linked client a copy fetched through
// the host's image download. The pixels come from the native decoder, never
// from the thumbnail.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';

class _MockImagingBackend extends Mock implements ImagingBackend {}

bridge.FitsReadResult _decoded(int width, int height) => bridge.FitsReadResult(
  width: width,
  height: height,
  bitpix: 16,
  displayData: Uint8List(width * height * 4),
  histogram: Uint32List(256),
  stats: const bridge.ImageStatsResult(
    min: 200,
    max: 65000,
    mean: 610,
    median: 576,
    stdDev: 40,
    starCount: 0,
  ),
  exposureTime: 30,
  filter: 'L       ',
);

final _capturedAt = DateTime.utc(2026, 11, 16, 3, 20);

SavedFrameRef _frame({String hostPath = '/data/M31/M31_L_0004.fits'}) =>
    SavedFrameRef(imageId: 7, hostPath: hostPath, capturedAt: _capturedAt);

/// Waits until the load leaves its loading states.
Future<SavedFrameLoad> _settled(
  ProviderContainer container,
  SavedFrameRef frame,
) async {
  final done = Completer<SavedFrameLoad>();
  final sub = container.listen<SavedFrameLoad>(savedFrameProvider(frame), (
    _,
    next,
  ) {
    if ((next is SavedFrameReady || next is SavedFrameFailed) &&
        !done.isCompleted) {
      done.complete(next);
    }
  }, fireImmediately: true);
  try {
    return await done.future.timeout(const Duration(seconds: 5));
  } finally {
    sub.close();
  }
}

void main() {
  late _MockImagingBackend backend;
  late Directory cache;
  late List<String> decoded;

  setUp(() {
    backend = _MockImagingBackend();
    cache = Directory.systemTemp.createTempSync('saved-frames-test');
    decoded = <String>[];
  });

  tearDown(() => cache.deleteSync(recursive: true));

  ProviderContainer container({required bool remote}) {
    final c = ProviderContainer(
      overrides: [
        imagingBackendProvider.overrideWithValue(backend),
        isRemoteModeProvider.overrideWithValue(remote),
        savedFrameCacheDirProvider.overrideWithValue(() async => cache),
        frameFileDecoderProvider.overrideWithValue((path) async {
          decoded.add(path);
          return _decoded(4656, 3520);
        }),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('on the host the frame is decoded from its own file, '
      'not downloaded', () async {
    final c = container(remote: false);
    final frame = _frame();
    final seen = <SavedFrameLoad>[];
    c.listen(
      savedFrameProvider(frame),
      (_, next) => seen.add(next),
      fireImmediately: true,
    );

    final load = await _settled(c, frame);

    expect(seen.first, const SavedFrameDecoding());
    expect(decoded, ['/data/M31/M31_L_0004.fits']);
    verifyNever(
      () => backend.downloadImage(
        any(),
        any(),
        onProgress: any(named: 'onProgress'),
      ),
    );
    expect(load, isA<SavedFrameReady>());
    final ready = load as SavedFrameReady;
    expect(ready.localPath, '/data/M31/M31_L_0004.fits');
    expect((ready.image.width, ready.image.height), (4656, 3520));
    expect(ready.image.displayData.length, 4656 * 3520 * 4);
    expect(ready.image.capturedAt, _capturedAt);
    expect(ready.image.stats.median, 576);
    expect(ready.image.settings.filter, 'L');
  });

  test('a linked client downloads the frame from the host, then decodes '
      'its copy', () async {
    when(
      () => backend.downloadImage(
        any(),
        any(),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((invocation) async {
      final progress =
          invocation.namedArguments[#onProgress] as void Function(double)?;
      progress?.call(0.5);
      progress?.call(1);
      File(invocation.positionalArguments[1] as String).writeAsBytesSync([1]);
    });
    final c = container(remote: true);
    final frame = _frame(hostPath: r'C:\Skotiq\M31\M31_L_0004.fits');
    final seen = <SavedFrameLoad>[];
    c.listen(
      savedFrameProvider(frame),
      (_, next) => seen.add(next),
      fireImmediately: true,
    );

    final load = await _settled(c, frame);

    final copy = p.join(cache.path, '7-M31_L_0004.fits');
    verify(
      () => backend.downloadImage(
        7,
        '$copy.part',
        onProgress: any(named: 'onProgress'),
      ),
    ).called(1);
    expect(File('$copy.part').existsSync(), isFalse);
    expect(decoded, [copy]);
    expect((load as SavedFrameReady).localPath, copy);
    expect(seen.first, const SavedFrameDownloading());
    expect(seen, contains(const SavedFrameDownloading(0.5)));
    expect(seen, contains(const SavedFrameDecoding()));
  });

  test('a frame a client already fetched is decoded from the cache', () async {
    File(p.join(cache.path, '7-M31_L_0004.fits')).writeAsBytesSync([1]);
    final c = container(remote: true);

    final load = await _settled(c, _frame());

    expect(load, isA<SavedFrameReady>());
    verifyNever(
      () => backend.downloadImage(
        any(),
        any(),
        onProgress: any(named: 'onProgress'),
      ),
    );
  });

  test('the client cache keeps only the newest downloads', () async {
    for (var i = 0; i < savedFrameCacheSize + 3; i++) {
      final f = File(p.join(cache.path, '${100 + i}-old.fits'))
        ..writeAsBytesSync([1]);
      f.setLastModifiedSync(DateTime(2026, 11, 1, 0, i));
    }
    when(
      () => backend.downloadImage(
        any(),
        any(),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((invocation) async {
      File(invocation.positionalArguments[1] as String).writeAsBytesSync([1]);
    });
    final c = container(remote: true);

    await _settled(c, _frame());

    final left = cache.listSync().map((e) => p.basename(e.path)).toSet();
    expect(left, hasLength(savedFrameCacheSize));
    expect(left, contains('7-M31_L_0004.fits'));
    expect(left, isNot(contains('100-old.fits')));
  });

  test('a decode failure keeps the reason', () async {
    final c = ProviderContainer(
      overrides: [
        imagingBackendProvider.overrideWithValue(backend),
        isRemoteModeProvider.overrideWithValue(false),
        frameFileDecoderProvider.overrideWithValue(
          (path) async => throw const FileSystemException('File not found'),
        ),
      ],
    );
    addTearDown(c.dispose);

    final load = await _settled(c, _frame());

    expect(load, isA<SavedFrameFailed>());
    expect((load as SavedFrameFailed).message, contains('File not found'));
  });

  test('a frame without a saved file says so', () async {
    final c = container(remote: false);

    final load = await _settled(c, _frame(hostPath: ''));

    expect(load, const SavedFrameFailed('This frame has no saved file.'));
    expect(decoded, isEmpty);
  });

  test('host file names split on either separator', () {
    expect(hostFileName(r'C:\Skotiq\M31\a.fits'), 'a.fits');
    expect(hostFileName('/home/x/Skotiq/b.xisf'), 'b.xisf');
    expect(hostFileName('c.fits'), 'c.fits');
  });
}
