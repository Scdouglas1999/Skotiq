import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_updater/src/services/update_downloader.dart';

class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this._scripts);

  final List<http.StreamedResponse Function(http.BaseRequest request)> _scripts;
  final requests = <http.BaseRequest>[];
  var _index = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return _scripts[_index++](request);
  }
}

http.StreamedResponse _bytes(
  int status,
  List<int> body, {
  Map<String, String>? headers,
}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(body),
    status,
    contentLength: headers == null ? body.length : null,
    headers: headers ?? const {},
  );
}

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

  test('HTTP 416 deletes the partial and restarts from byte 0', () async {
    final tempDir = await Directory.systemTemp.createTemp('skotiq_dl_416_');
    final destination = File('${tempDir.path}/update.bin');
    await destination.writeAsBytes([1, 2, 3, 4, 5]);
    final client = _ScriptedClient([
      (_) => http.StreamedResponse(const Stream<List<int>>.empty(), 416),
      (_) => _bytes(200, [9, 8, 7, 6]),
    ]);
    final downloader = UpdateDownloader(client: client);
    addTearDown(() async {
      downloader.dispose();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final file = await downloader.download(
      'https://updates.example.invalid/update.bin',
      destination.path,
    );

    expect(await file.readAsBytes(), [9, 8, 7, 6]);
    expect(client.requests, hasLength(2));
    expect(client.requests.first.headers['range'], 'bytes=5-');
    expect(client.requests.last.headers.containsKey('range'), isFalse);
  });

  test(
    'a Content-Range start that misses the local offset deletes the partial',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('skotiq_dl_range_');
      final destination = File('${tempDir.path}/update.bin');
      await destination.writeAsBytes([4, 4, 4, 4]);
      final client = _ScriptedClient([
        (_) => _bytes(
          206,
          [1, 2, 3, 4, 5, 6, 7, 8],
          headers: {'content-range': 'bytes 0-7/8'},
        ),
        (_) => _bytes(200, [9, 9, 9, 9]),
      ]);
      final downloader = UpdateDownloader(client: client);
      addTearDown(() async {
        downloader.dispose();
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final file = await downloader.download(
        'https://updates.example.invalid/update.bin',
        destination.path,
      );

      expect(await file.readAsBytes(), [9, 9, 9, 9]);
      expect(client.requests, hasLength(2));
      expect(client.requests.first.headers['range'], 'bytes=4-');
      expect(client.requests.last.headers.containsKey('range'), isFalse);
    },
  );

  test(
    'a 206 without Content-Range or contentLength still writes the body',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('skotiq_dl_len_');
      final destination = File('${tempDir.path}/update.bin');
      final client = _ScriptedClient([
        (_) =>
            http.StreamedResponse(Stream<List<int>>.value([1, 2, 3, 4]), 206),
      ]);
      final downloader = UpdateDownloader(client: client);
      addTearDown(() async {
        downloader.dispose();
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final file = await downloader.download(
        'https://updates.example.invalid/update.bin',
        destination.path,
      );

      expect(await file.readAsBytes(), [1, 2, 3, 4]);
    },
  );
}
