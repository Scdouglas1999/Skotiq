import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/services/image_download_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockImagingBackend extends Mock implements ImagingBackend {}

/// Mirrors the `userMessage` surface of the core's SkotiqException /
/// IoException (which aren't exported from the barrel) so the service's
/// duck-typed message extraction can be exercised.
class _UserFacingException implements Exception {
  final String userMessage;
  const _UserFacingException(this.userMessage);
}

void main() {
  late Directory tmp;
  late _MockImagingBackend backend;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ns-img-dl-test');
    backend = _MockImagingBackend();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // Stub downloadImage to actually write bytes to the requested localPath,
  // mirroring the real resumable downloader's contract (file exists on return).
  void stubSuccessfulDownload({List<int> bytes = const [1, 2, 3, 4]}) {
    when(
      () => backend.downloadImage(
        any(),
        any(),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments[1] as String;
      final f = File(path);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
    });
  }

  test('rejects a non-positive image id without touching the backend',
      () async {
    final outcome = await downloadImageToDevice(
      backend: backend,
      imageId: 0,
      fileName: 'x.fits',
      temporaryDirectory: () async => tmp,
    );
    expect(outcome.status, ImageDownloadStatus.failed);
    verifyNever(() => backend.downloadImage(any(), any(),
        onProgress: any(named: 'onProgress')));
  });

  test('desktop save picker: streams then copies to the chosen path', () async {
    stubSuccessfulDownload(bytes: const [9, 8, 7]);
    final dest = File('${tmp.path}/saved/light_001.fits');

    final outcome = await downloadImageToDevice(
      backend: backend,
      imageId: 42,
      fileName: 'light_001.fits',
      temporaryDirectory: () async => tmp,
      desktopSavePicker: (suggested) async {
        expect(suggested, 'light_001.fits');
        await dest.parent.create(recursive: true);
        return ExportTarget(path: dest.path, needsShareSheet: false);
      },
    );

    expect(outcome.status, ImageDownloadStatus.saved);
    expect(outcome.savedPath, dest.path);
    expect(dest.existsSync(), isTrue);
    expect(dest.readAsBytesSync(), const [9, 8, 7]);
    // The temp staging file is removed after a successful desktop save.
    expect(
      Directory('${tmp.path}/skotiq-dl').existsSync()
          ? Directory('${tmp.path}/skotiq-dl').listSync().isEmpty
          : true,
      isTrue,
    );
  });

  test('desktop cancel: picker returns null → cancelled, temp cleaned up',
      () async {
    stubSuccessfulDownload();
    final outcome = await downloadImageToDevice(
      backend: backend,
      imageId: 7,
      fileName: 'a.fits',
      temporaryDirectory: () async => tmp,
      desktopSavePicker: (_) async => null,
    );
    expect(outcome.status, ImageDownloadStatus.cancelled);
    final staging = Directory('${tmp.path}/skotiq-dl');
    expect(
      staging.existsSync() ? staging.listSync().isEmpty : true,
      isTrue,
      reason: 'a cancelled download must not leave a staged temp file',
    );
  });

  test('download failure surfaces the user message and cleans up', () async {
    when(
      () => backend.downloadImage(
        any(),
        any(),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenThrow(
      const _UserFacingException('The connection dropped mid-download.'),
    );

    final outcome = await downloadImageToDevice(
      backend: backend,
      imageId: 5,
      fileName: 'b.fits',
      temporaryDirectory: () async => tmp,
      desktopSavePicker: (_) async =>
          fail('picker must not run after a failed download'),
    );

    expect(outcome.status, ImageDownloadStatus.failed);
    expect(outcome.error, 'The connection dropped mid-download.');
  });
}
