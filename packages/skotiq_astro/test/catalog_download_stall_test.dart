import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_astro/skotiq_astro.dart';

/// A catalog download must not be able to hang the app.
///
/// A download path that opens a client, awaits `send` and then `await for`s the
/// body with no timeout on either cannot see a dead connection. Neither can a
/// cancellation token polled only from inside the chunk handler: when a
/// connection stalls with no further chunks no poll runs, the progress bar
/// freezes at whatever percentage it reached, and the Cancel button does
/// nothing, forever.
///
/// Every test here bounds its own wait, so a failure fails the suite instead of
/// hanging it.
void main() {
  late Directory tempDir;
  late Duration savedConnect;
  late Duration savedIdle;
  late Duration savedPoll;
  late http.Client Function() savedFactory;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_catalog_stall_');
    await CatalogManager.instance.initialize(tempDir.path);

    savedConnect = CatalogInstaller.connectTimeout;
    savedIdle = CatalogInstaller.streamIdleTimeout;
    savedPoll = CatalogInstaller.cancelPollInterval;
    savedFactory = CatalogInstaller.httpClientFactory;

    CatalogInstaller.connectTimeout = const Duration(milliseconds: 300);
    CatalogInstaller.streamIdleTimeout = const Duration(milliseconds: 300);
    CatalogInstaller.cancelPollInterval = const Duration(milliseconds: 40);
  });

  tearDown(() async {
    CatalogInstaller.connectTimeout = savedConnect;
    CatalogInstaller.streamIdleTimeout = savedIdle;
    CatalogInstaller.cancelPollInterval = savedPoll;
    CatalogInstaller.httpClientFactory = savedFactory;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Bound every download under test so a hang is a failure, not a hung suite.
  Future<T> bounded<T>(Future<T> future) =>
      future.timeout(const Duration(seconds: 20));

  group('a stalled transfer is abandoned', () {
    test('a star download gives up instead of waiting forever', () async {
      final clients = <_StallingClient>[];
      CatalogInstaller.httpClientFactory = () {
        final client = _StallingClient.afterHeaders();
        clients.add(client);
        return client;
      };

      final started = DateTime.now();
      await expectLater(
        bounded(CatalogManager.instance.install(SkyCatalog.stars)),
        throwsA(isA<CatalogDownloadStalled>()),
      );
      final elapsed = DateTime.now().difference(started);

      expect(clients, isNotEmpty, reason: 'the download must have been tried');
      expect(elapsed, lessThan(const Duration(seconds: 10)));
      expect(
        clients.every((c) => c.closed),
        isTrue,
        reason: 'a stalled candidate must not leak its connection',
      );
    });

    test(
      'a server that never sends headers hits the connect timeout',
      () async {
        CatalogInstaller.httpClientFactory = _StallingClient.beforeHeaders;

        await expectLater(
          bounded(CatalogManager.instance.install(SkyCatalog.stars)),
          throwsA(isA<CatalogDownloadStalled>()),
        );
      },
    );

    test('the annotation download gives up too', () async {
      CatalogInstaller.httpClientFactory = _StallingClient.afterHeaders;

      await expectLater(
        bounded(CatalogManager.instance.install(SkyCatalog.annotation)),
        throwsA(isA<CatalogDownloadStalled>()),
      );
    });
  });

  group('Cancel works while the transfer is stalled', () {
    for (final catalog in [SkyCatalog.stars, SkyCatalog.annotation]) {
      test('${catalog.name} download reports canceled', () async {
        // Idle timeout far beyond the test: only Cancel can end this one.
        CatalogInstaller.streamIdleTimeout = const Duration(seconds: 30);
        CatalogInstaller.httpClientFactory = _StallingClient.afterHeaders;

        var cancelRequested = false;
        final progress = <DownloadProgress>[];

        final download = CatalogManager.instance.install(
          catalog,
          onProgress: progress.add,
          isCancelled: () async => cancelRequested,
        );
        unawaited(download.then((_) {}, onError: (_) {}));

        await Future<void>.delayed(const Duration(milliseconds: 200));
        cancelRequested = true;

        await expectLater(bounded(download), throwsA(isA<CatalogCancelled>()));
        expect(
          progress.any((p) => p.cancelled),
          isTrue,
          reason: 'the UI must be told the cancel took effect',
        );
      });
    }
  });

  test('Cancel ends the wait for response headers', () async {
    // The GLADE+ query runs server-side for 20 s or more before any header.
    CatalogInstaller.connectTimeout = const Duration(seconds: 30);
    CatalogInstaller.httpClientFactory = _StallingClient.beforeHeaders;

    var cancelRequested = false;
    final download = CatalogManager.instance.install(
      SkyCatalog.annotation,
      isCancelled: () async => cancelRequested,
    );
    unawaited(download.then((_) {}, onError: (_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    cancelRequested = true;

    final started = DateTime.now();
    await expectLater(bounded(download), throwsA(isA<CatalogCancelled>()));
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 2)),
    );
  });

  test('a healthy transfer is unaffected by the guards', () async {
    final payload = <int>[for (var i = 0; i < 4096; i++) i % 256];
    CatalogInstaller.httpClientFactory = () => _ChunkedClient(payload);

    final progress = <DownloadProgress>[];
    await expectLater(
      bounded(
        CatalogManager.instance.install(
          SkyCatalog.dso,
          onProgress: progress.add,
        ),
      ),
      // The transfer completed and was rejected on content, not timing.
      throwsA(isA<CatalogHashMismatchException>()),
    );
    expect(progress.any((p) => p.error != null), isTrue);
  });
}

class _StallingClient extends http.BaseClient {
  _StallingClient._(this._sendHeaders);

  /// Accepts the request and returns 200 headers, then goes silent.
  factory _StallingClient.afterHeaders() => _StallingClient._(true);

  /// Never even returns response headers.
  factory _StallingClient.beforeHeaders() => _StallingClient._(false);

  final bool _sendHeaders;
  final List<StreamController<List<int>>> _bodies = [];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!_sendHeaders) return Completer<http.StreamedResponse>().future;
    final body = StreamController<List<int>>();
    _bodies.add(body);
    return http.StreamedResponse(
      body.stream,
      200,
      contentLength: 50 * 1024 * 1024,
      request: request,
    );
  }

  @override
  void close() {
    closed = true;
    for (final body in _bodies) {
      if (!body.isClosed) body.close();
    }
    _bodies.clear();
  }
}

/// A client that delivers a fixed payload in several chunks and completes.
class _ChunkedClient extends http.BaseClient {
  _ChunkedClient(this.payload);

  final List<int> payload;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> body() async* {
      const chunk = 512;
      for (var i = 0; i < payload.length; i += chunk) {
        yield payload.sublist(i, (i + chunk).clamp(0, payload.length));
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }

    return http.StreamedResponse(
      body(),
      200,
      contentLength: payload.length,
      request: request,
    );
  }
}
