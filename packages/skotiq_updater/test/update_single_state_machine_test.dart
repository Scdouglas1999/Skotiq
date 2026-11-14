import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_updater/skotiq_updater.dart';

class _MockUpdateService extends Mock implements UpdateService {}

/// The window's notifier and the REST surface share one controller. Whatever
/// one of them does, the other shows.
void main() {
  late _MockUpdateService service;
  late Directory dataDir;
  late UpdateController controller;
  late UpdateNotifier notifier;
  StagedUpdate? stagedOnDisk;

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

  void offerAnUpdate() {
    when(() => service.checkForUpdates()).thenAnswer(
      (_) async => UpdateCheckResult(
        hasUpdate: true,
        currentVersion: '2.0.0',
        availableVersion: offered.version,
        manifest: offered,
        releaseNotes: 'Notes for 2.1.0',
      ),
    );
  }

  setUpAll(() => registerFallbackValue(offered));

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('skotiq_one_machine_');
    service = _MockUpdateService();
    when(
      () => service.verifyPendingInstall(),
    ).thenAnswer((_) async => const PendingInstallStatus.none());
    stagedOnDisk = null;
    when(() => service.getStagedUpdate()).thenAnswer((_) async => stagedOnDisk);
    when(() => service.readStagedManifest()).thenAnswer((_) async => null);
    when(() => service.readSkippedVersion()).thenAnswer((_) async => null);
    when(() => service.writeSkippedVersion(any())).thenAnswer((_) async {});
    when(() => service.hasUpdateSource).thenReturn(true);
    when(() => service.dispose()).thenReturn(null);

    controller = UpdateController(
      service: service,
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      stateDirectory: () async => dataDir,
      applySafetyCheck: () async {},
    );
    notifier = UpdateNotifier(
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      dataDirectory: () async => dataDir,
      controller: controller,
    );
    await notifier.checkStagedUpdate();
  });

  tearDown(() async {
    notifier.dispose();
    await controller.dispose();
    await dataDir.delete(recursive: true);
  });

  test('a check made over the API is what the window shows', () async {
    offerAnUpdate();
    expect(notifier.state.status, UpdateStatus.idle);

    await controller.checkForUpdates();

    expect(notifier.state.status, UpdateStatus.available);
    expect(notifier.state.availableUpdate?.version, '2.1.0');
    expect(notifier.state.releaseNotes, 'Notes for 2.1.0');
  });

  test('a check made in the window is what the API reports', () async {
    offerAnUpdate();

    await notifier.checkForUpdates();

    expect(controller.status.state, UpdateLifecycleState.available);
    expect(controller.status.availableVersion, '2.1.0');
    verify(() => service.checkForUpdates()).called(1);
  });

  test('a download started over the API shows its progress in the window '
      'and ends staged in both', () async {
    offerAnUpdate();
    await controller.checkForUpdates();
    final seen = <UpdateStatus>[];
    final remove = notifier.addListener((s) => seen.add(s.status));
    addTearDown(remove);
    when(
      () => service.downloadAndStage(
        any(),
        onProgress: any(named: 'onProgress'),
        onVerifying: any(named: 'onVerifying'),
      ),
    ).thenAnswer((invocation) async {
      final onProgress =
          invocation.namedArguments[#onProgress]
              as void Function(int, int, double);
      onProgress(500, 1000, 0.5);
      expect(notifier.state.downloadProgress, 0.5);
      expect(notifier.state.downloadedBytes, 500);
      stagedOnDisk = StagedUpdate(
        version: '2.1.0',
        buildNumber: 42,
        stagedAt: DateTime.utc(2026, 5, 26),
        extractPath: '/staged/2.1.0',
      );
    });

    await controller.downloadAndStage(jobId: 'job-1');

    expect(seen, contains(UpdateStatus.downloading));
    expect(notifier.state.status, UpdateStatus.staged);
    expect(notifier.state.stagingPath, '/staged/2.1.0');
    expect(controller.status.state, UpdateLifecycleState.staged);
  });

  test('a skipped version reads as up to date in the window and is not '
      'offered again; a newer one clears the skip', () async {
    offerAnUpdate();
    await notifier.checkForUpdates();
    notifier.skipUpdate();

    expect(notifier.state.status, UpdateStatus.upToDate);
    expect(notifier.state.availableUpdate, isNull);
    expect(notifier.shouldPrompt(), isFalse);
    verify(() => service.writeSkippedVersion('2.1.0')).called(1);

    await notifier.checkForUpdates();
    expect(notifier.state.status, UpdateStatus.upToDate);

    when(() => service.checkForUpdates()).thenAnswer(
      (_) async => UpdateCheckResult(
        hasUpdate: true,
        currentVersion: '2.0.0',
        availableVersion: '2.2.0',
        manifest: offered.copyWith(version: '2.2.0', buildNumber: 43),
      ),
    );
    await notifier.checkForUpdates();
    expect(notifier.state.status, UpdateStatus.available);
    expect(notifier.state.skippedVersion, isNull);
    verify(() => service.writeSkippedVersion(null)).called(1);
  });

  test('a failed check is an error in the window with the reason', () async {
    when(
      () => service.checkForUpdates(),
    ).thenThrow(UpdateException('server unreachable'));

    await notifier.checkForUpdates();

    expect(notifier.state.status, UpdateStatus.error);
    expect(notifier.state.errorMessage, contains('server unreachable'));
    expect(controller.status.state, UpdateLifecycleState.failed);
  });

  test('an update pushed over the LAN is staged in both, and a failed push '
      'is reported without changing either', () async {
    final failures = <String>[];
    final sub = notifier.lanPushFailures.listen(failures.add);
    addTearDown(sub.cancel);

    controller.lanPushFailed('signature mismatch');
    await Future<void>.delayed(Duration.zero);
    expect(failures, ['signature mismatch']);
    expect(notifier.state.status, UpdateStatus.idle);
    expect(controller.status.state, UpdateLifecycleState.idle);

    controller.lanPushReceived(offered, '/staged/pushed');
    expect(controller.status.state, UpdateLifecycleState.staged);
    expect(controller.status.stagedVersion, '2.1.0');
    expect(notifier.state.status, UpdateStatus.staged);
    expect(notifier.state.stagingPath, '/staged/pushed');
    expect(notifier.state.availableUpdate?.version, '2.1.0');
  });

  test('the environment names the update server for both', () {
    final fromEnv = UpdateController.forApp(
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      dataDirectory: () async => dataDir,
      service: service,
      environment: const {
        'SKOTIQ_UPDATE_SERVER': ' https://updates.example.invalid ',
        'SKOTIQ_UPDATE_CHANNEL': 'beta',
      },
    );
    expect(fromEnv.updateServerUrl, 'https://updates.example.invalid');
    expect(fromEnv.channel, 'beta');
    verify(
      () => service.configure(
        serverUrl: 'https://updates.example.invalid',
        channel: 'beta',
      ),
    ).called(1);

    final github = UpdateController.forApp(
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      dataDirectory: () async => dataDir,
      service: service,
      environment: const {},
    );
    expect(github.updateServerUrl, isNull);
    expect(github.updateSourceLabel, 'github-releases');
  });
}
