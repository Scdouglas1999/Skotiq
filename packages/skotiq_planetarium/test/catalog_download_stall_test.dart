import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Duration savedConnect;
  late Duration savedIdle;
  late Duration savedPoll;
  late http.Client Function() savedFactory;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_catalog_stall_');
    await CatalogManager.instance.initialize(tempDir.path);

    savedConnect = CatalogManager.connectTimeout;
    savedIdle = CatalogManager.streamIdleTimeout;
    savedPoll = CatalogManager.cancelPollInterval;
    savedFactory = CatalogManager.httpClientFactory;

    CatalogManager.connectTimeout = const Duration(milliseconds: 300);
    CatalogManager.streamIdleTimeout = const Duration(milliseconds: 300);
    CatalogManager.cancelPollInterval = const Duration(milliseconds: 40);
  });

  tearDown(() async {
    CatalogManager.connectTimeout = savedConnect;
    CatalogManager.streamIdleTimeout = savedIdle;
    CatalogManager.cancelPollInterval = savedPoll;
    CatalogManager.httpClientFactory = savedFactory;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Bound every download under test so a hang is a failure, not a hung suite.
  Future<T> bounded<T>(Future<T> future) =>
      future.timeout(const Duration(seconds: 20));

  group('a stalled transfer is abandoned', () {
    test('legacy star download gives up instead of waiting forever', () async {
      final clients = <_StallingClient>[];
      CatalogManager.httpClientFactory = () {
        final client = _StallingClient.afterHeaders();
        clients.add(client);
        return client;
      };

      final started = DateTime.now();
      final ok = await bounded(CatalogManager.instance.downloadStarCatalog());
      final elapsed = DateTime.now().difference(started);

      expect(ok, isFalse);
      expect(clients, isNotEmpty, reason: 'the download must have been tried');
      // Every candidate stalls, so the wall time is a small multiple of the
      // idle timeout — not unbounded.
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
        CatalogManager.httpClientFactory = _StallingClient.beforeHeaders;

        final ok = await bounded(CatalogManager.instance.downloadStarCatalog());

        expect(ok, isFalse);
      },
    );

    test('the unified install path gives up too', () async {
      CatalogManager.httpClientFactory = _StallingClient.afterHeaders;

      final available = await CatalogManager.instance.listAvailable();
      expect(available, isNotEmpty);

      await expectLater(
        bounded(
          CatalogManager.instance.downloadAndInstall(available.first.name),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('the annotation download gives up too', () async {
      CatalogManager.httpClientFactory = _StallingClient.afterHeaders;

      final ok = await bounded(
        CatalogManager.instance.downloadAnnotationCatalog(),
      );

      expect(ok, isFalse);
    });
  });

  group('Cancel works while the transfer is stalled', () {
    test('legacy star download reports cancelled', () async {
      // Long enough that a stall timeout cannot be what ends this download —
      // only the cancel poll can.
      CatalogManager.streamIdleTimeout = const Duration(seconds: 30);
      CatalogManager.httpClientFactory = _StallingClient.afterHeaders;

      var cancelRequested = false;
      final progress = <DownloadProgress>[];

      final download = CatalogManager.instance.downloadStarCatalog(
        onProgress: progress.add,
        isCancelled: () async => cancelRequested,
      );

      // The user presses Cancel after the connection has already gone quiet.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      cancelRequested = true;

      final ok = await bounded(download);

      expect(ok, isFalse);
      expect(
        progress.any((p) => p.cancelled),
        isTrue,
        reason: 'the UI must be told the cancel took effect',
      );
    });

    test('the unified install path reports cancelled', () async {
      CatalogManager.streamIdleTimeout = const Duration(seconds: 30);
      CatalogManager.httpClientFactory = _StallingClient.afterHeaders;

      var cancelRequested = false;
      final available = await CatalogManager.instance.listAvailable();

      final install = CatalogManager.instance.downloadAndInstall(
        available.first.name,
        isCancelled: () async => cancelRequested,
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));
      cancelRequested = true;

      await expectLater(bounded(install), throwsA(isA<CatalogCancelled>()));
    });

    test('the annotation download reports cancelled', () async {
      CatalogManager.streamIdleTimeout = const Duration(seconds: 30);
      CatalogManager.httpClientFactory = _StallingClient.afterHeaders;

      var cancelRequested = false;
      final progress = <DownloadProgress>[];

      final download = CatalogManager.instance.downloadAnnotationCatalog(
        onProgress: progress.add,
        isCancelled: () async => cancelRequested,
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));
      cancelRequested = true;

      final ok = await bounded(download);

      expect(ok, isFalse);
      expect(progress.any((p) => p.cancelled), isTrue);
    });
  });

  test('a healthy transfer is unaffected by the guards', () async {
    final payload = <int>[for (var i = 0; i < 4096; i++) i % 256];
    CatalogManager.httpClientFactory = () => _ChunkedClient(payload);

    // The hash will not match the real catalog's, so the download still fails —
    // but it must fail on the hash, having read every byte, rather than stall.
    final progress = <DownloadProgress>[];
    await bounded(
      CatalogManager.instance.downloadDsoCatalog(onProgress: progress.add),
    );

    expect(
      progress.any((p) => p.error != null),
      isTrue,
      reason: 'the transfer completed and was rejected on content, not timing',
    );
  });
}

/// A client whose responses never deliver a body.
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
