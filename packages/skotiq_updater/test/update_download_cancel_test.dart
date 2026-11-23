import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_updater/skotiq_updater.dart';

class _MockUpdateService extends Mock implements UpdateService {}

/// A download stops cleanly only when the operator stopped it. A failure whose
/// text happens to say "canceled" (a client dropping the link) is a failure.
void main() {
  late _MockUpdateService service;
  late Directory dataDir;
  late UpdateController controller;
  late List<UpdateEvent> events;
  late StreamSubscription<UpdateEvent> eventSub;

  final offered = UpdateManifest(
    version: '2.1.0',
    buildNumber: 42,
    releaseDate: DateTime.utc(2026, 5, 25),
    platform: 'linux',
    arch: 'x64',
    files: const {},
    totalSize: 0,
    compressedSize: 1000,
    downloadUrl: 'https://example.invalid/skotiq.zip',
  );

  void downloadAnswers(Future<void> Function() body) {
    when(
      () => service.downloadAndStage(
        any(),
        onProgress: any(named: 'onProgress'),
        onVerifying: any(named: 'onVerifying'),
      ),
    ).thenAnswer((_) => body());
  }

  setUpAll(() => registerFallbackValue(offered));

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('skotiq_download_cancel_');
    service = _MockUpdateService();
    when(
      () => service.verifyPendingInstall(),
    ).thenAnswer((_) async => const PendingInstallStatus.none());
    when(() => service.getStagedUpdate()).thenAnswer((_) async => null);
    when(() => service.readStagedManifest()).thenAnswer((_) async => null);
    when(() => service.readSkippedVersion()).thenAnswer((_) async => null);
    when(() => service.hasUpdateSource).thenReturn(true);
    when(() => service.canCancelDownload).thenReturn(true);
    when(() => service.cancelDownload()).thenReturn(null);
    when(() => service.dispose()).thenReturn(null);
    when(() => service.checkForUpdates()).thenAnswer(
      (_) async => UpdateCheckResult(
        hasUpdate: true,
        currentVersion: '2.0.0',
        availableVersion: offered.version,
        manifest: offered,
      ),
    );

    controller = UpdateController(
      service: service,
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      stateDirectory: () async => dataDir,
      applySafetyCheck: () async {},
    );
    events = [];
    eventSub = controller.events.listen(events.add);
    await controller.checkForUpdates();
  });

  tearDown(() async {
    await eventSub.cancel();
    await controller.dispose();
    await dataDir.delete(recursive: true);
  });

  test('a dropped link whose error says "canceled" is a failure', () async {
    downloadAnswers(
      () async => throw http.ClientException(
        'Connection closed before full header was received: request canceled',
      ),
    );

    await expectLater(
      controller.downloadAndStage(jobId: 'job-1'),
      throwsA(isA<http.ClientException>()),
    );
    await pumpEventQueue();

    expect(controller.status.state, UpdateLifecycleState.failed);
    expect(controller.status.lastError, contains('request canceled'));
    final failed = events.whereType<UpdateFailedEvent>().single;
    expect(failed.phase, 'download');
    expect(failed.jobId, 'job-1');
  });

  test('the downloader\'s cancellation is a clean stop', () async {
    downloadAnswers(() async => throw DownloadCancelledException());

    await controller.downloadAndStage(jobId: 'job-1');
    await pumpEventQueue();

    expect(controller.status.state, UpdateLifecycleState.available);
    expect(controller.status.message, 'Download canceled');
    expect(events.whereType<UpdateFailedEvent>(), isEmpty);
  });

  test('after the operator aborts, the error the abort causes is a clean '
      'stop', () async {
    final release = Completer<void>();
    downloadAnswers(() async {
      await release.future;
      throw http.ClientException('Connection closed while receiving data');
    });

    final download = controller.downloadAndStage(jobId: 'job-1');
    await pumpEventQueue();
    controller.abortInFlight();
    release.complete();
    await download;
    await pumpEventQueue();

    expect(controller.status.state, UpdateLifecycleState.available);
    expect(events.whereType<UpdateFailedEvent>(), isEmpty);
  });
}
