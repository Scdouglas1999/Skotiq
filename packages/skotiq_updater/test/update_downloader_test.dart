import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_updater/src/services/update_downloader.dart';

class _StalledClient extends http.BaseClient {
  final stream = StreamController<List<int>>();
  final requestStarted = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!requestStarted.isCompleted) requestStarted.complete();
    return http.StreamedResponse(stream.stream, 200, contentLength: 1024);
  }
}

void main() {
  test(
    'cancellation interrupts a stalled response and removes partial data',
    () async {
      final client = _StalledClient();
      final downloader = UpdateDownloader(client: client);
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_downloader_cancel_',
      );
      final destination = File('${tempDir.path}/update.zip');
      final token = CancelToken();
      addTearDown(() async {
        downloader.dispose();
        // The deliberately stalled subscription may keep StreamController's
        // close future pending even after cancellation. It does not own an OS
        // resource, so do not make test cleanup wait for that adversarial
        // stream to acknowledge shutdown.
        unawaited(client.stream.close());
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final download = downloader.download(
        'https://updates.example.invalid/update.zip',
        destination.path,
        cancelToken: token,
        expectedSize: 1024,
      );
      await client.requestStarted.future;

      token.cancel();

      await expectLater(
        download.timeout(const Duration(seconds: 1)),
        throwsA(isA<DownloadCancelledException>()),
      );
      expect(await destination.exists(), isFalse);
    },
  );
}
