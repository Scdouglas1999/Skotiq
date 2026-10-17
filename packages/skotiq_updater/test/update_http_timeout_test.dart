import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_updater/src/services/update_controller.dart';
import 'package:skotiq_updater/src/services/update_downloader.dart';
import 'package:skotiq_updater/src/services/update_service.dart';

/// A server that accepts the connection and then never answers. This is the
/// blackhole an update host becomes behind a dropped NAT mapping or a
/// misconfigured proxy, and it is the case that used to wedge the whole
/// update subsystem until the process restarted.
class _BlackholeClient extends http.BaseClient {
  final requestStarted = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!requestStarted.isCompleted) requestStarted.complete();
    return Completer<http.StreamedResponse>().future;
  }
}

/// A server that answers the headers and then stops sending body bytes.
class _StalledBodyClient extends http.BaseClient {
  final stream = StreamController<List<int>>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream.stream, 200, contentLength: 4096);
}

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('skotiq_updater_to_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  UpdateService serviceWith(http.Client client) => UpdateService(
    currentVersion: '2.0.0',
    currentBuildNumber: 1,
    httpClient: client,
    httpTimeout: const Duration(milliseconds: 150),
    applicationSupportDirectoryProvider: () async => tempRoot,
  );

  test('checkForUpdates fails fast when the update server never responds', () {
    final service = serviceWith(_BlackholeClient())
      ..configure(serverUrl: 'https://updates.example.invalid');

    return expectLater(
      service.checkForUpdates(),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('did not respond'),
        ),
      ),
    ).timeout(const Duration(seconds: 5));
  });

  test(
    'a blackholed check releases the controller for the next operation',
    () async {
      final service = serviceWith(_BlackholeClient());
      final controller = UpdateController(
        service: service,
        currentVersion: '2.0.0',
        currentBuildNumber: 1,
        stateDirectory: tempRoot,
        serverUrl: 'https://updates.example.invalid',
      );
      addTearDown(controller.dispose);

      await expectLater(
        controller.checkForUpdates(),
        throwsA(isA<UpdateException>()),
      ).timeout(const Duration(seconds: 5));

      expect(
        controller.hasActiveOperation,
        isFalse,
        reason: 'a timed-out check must not hold the operation slot',
      );

      // The decisive assertion: the subsystem is still usable. Before the
      // timeout this threw StateError forever.
      await expectLater(
        controller.checkForUpdates(),
        throwsA(isA<UpdateException>()),
      ).timeout(const Duration(seconds: 5));
    },
  );

  test('download aborts when the body stalls mid-transfer', () async {
    final client = _StalledBodyClient();
    final downloader = UpdateDownloader(
      client: client,
      stallTimeout: const Duration(milliseconds: 150),
    );
    final destination = File('${tempRoot.path}/update.zip');
    addTearDown(() {
      downloader.dispose();
      unawaited(client.stream.close());
    });

    await expectLater(
      downloader.download(
        'https://updates.example.invalid/update.zip',
        destination.path,
        expectedSize: 4096,
      ),
      throwsA(isA<DownloadException>()),
    ).timeout(const Duration(seconds: 5));
  });

  test('download aborts when the server never sends headers', () async {
    final downloader = UpdateDownloader(
      client: _BlackholeClient(),
      stallTimeout: const Duration(milliseconds: 150),
    );
    addTearDown(downloader.dispose);

    await expectLater(
      downloader.download(
        'https://updates.example.invalid/update.zip',
        '${tempRoot.path}/update.zip',
      ),
      throwsA(isA<DownloadException>()),
    ).timeout(const Duration(seconds: 5));
  });
}
