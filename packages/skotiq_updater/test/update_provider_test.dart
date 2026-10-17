import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/models/update_state.dart';
import 'package:skotiq_updater/src/providers/update_provider.dart';
import 'package:skotiq_updater/src/services/android_installer.dart';
import 'package:skotiq_updater/src/services/update_controller.dart';
import 'package:skotiq_updater/src/services/update_service.dart';

class MockUpdateService extends Mock implements UpdateService {}

class MockSkotiqBackend extends Mock implements SkotiqBackend {}

class TestBackendNotifier extends BackendNotifier {
  TestBackendNotifier(super.ref, SkotiqBackend initial) {
    state = initial;
  }
}

final updateSafetyProbeProvider = FutureProvider<void>((ref) {
  return defaultUpdateApplySafetyCheck(ref);
});

void main() {
  late MockUpdateService updateService;

  setUp(() {
    updateService = MockUpdateService();
    when(
      () => updateService.verifyPendingInstall(),
    ).thenAnswer((_) async => const PendingInstallStatus.none());
    when(() => updateService.getStagedUpdate()).thenAnswer((_) async => null);
    when(
      () => updateService.readSkippedVersion(),
    ).thenAnswer((_) async => null);
    when(
      () => updateService.writeSkippedVersion(any()),
    ).thenAnswer((_) async {});
    when(() => updateService.dispose()).thenReturn(null);
  });

  UpdateManifest manifest() => UpdateManifest(
    version: '2.1.0',
    buildNumber: 42,
    releaseDate: DateTime.utc(2026, 5, 25),
    platform: 'windows',
    arch: 'x64',
    files: const {},
    totalSize: 0,
    compressedSize: 0,
    downloadUrl: 'https://example.invalid/skotiq.zip',
  );

  Future<UpdateNotifier> stagedNotifier({
    required UpdateApplySafetyCheck safetyCheck,
  }) async {
    final notifier = UpdateNotifier(
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      updateService: updateService,
      applySafetyCheck: safetyCheck,
    );

    await Future<void>.delayed(Duration.zero);
    notifier.setStagedFromLanPush(manifest(), r'C:\staged');
    return notifier;
  }

  test('applyUpdate refuses staged update when safety check blocks', () async {
    final notifier = await stagedNotifier(
      safetyCheck: () async {
        throw UpdateException('active sequence must stop first');
      },
    );

    await notifier.applyUpdate();

    expect(notifier.state.status, UpdateStatus.error);
    expect(notifier.state.errorMessage, contains('active sequence'));
    verifyNever(() => updateService.applyUpdate());

    notifier.dispose();
  });

  test('applyUpdate refuses when no safety check is wired', () async {
    final notifier = UpdateNotifier(
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      updateService: updateService,
    );
    await Future<void>.delayed(Duration.zero);
    notifier.setStagedFromLanPush(manifest(), r'C:\staged');

    await notifier.applyUpdate();

    expect(notifier.state.status, UpdateStatus.error);
    expect(notifier.state.errorMessage, contains('no safety check'));
    verifyNever(() => updateService.applyUpdate());

    notifier.dispose();
  });

  test('applyUpdate runs safety check before spawning updater', () async {
    final calls = <String>[];
    when(() => updateService.applyUpdate()).thenAnswer((_) async {
      calls.add('apply');
      // The desktop path exits inside applyUpdate; a mock has to return
      // something, and processExiting is what that path reports.
      return UpdateApplyOutcome.processExiting;
    });

    final notifier = await stagedNotifier(
      safetyCheck: () async {
        calls.add('safety');
      },
    );

    await notifier.applyUpdate();

    expect(calls, ['safety', 'apply']);
    verify(() => updateService.applyUpdate()).called(1);

    notifier.dispose();
  });

  test('headless controller with no wired gate refuses apply', () async {
    final staged = StagedUpdate(
      version: '2.1.0',
      buildNumber: 42,
      stagedAt: DateTime.utc(2026, 7, 12),
      extractPath: r'C:\staged',
    );
    when(() => updateService.getStagedUpdate()).thenAnswer((_) async => staged);
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_update_unwired_',
    );
    final controller = UpdateController(
      service: updateService,
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      stateDirectory: tempDir,
    );
    addTearDown(() async {
      await controller.dispose();
      await tempDir.delete(recursive: true);
    });

    await expectLater(
      controller.applyStagedUpdate(jobId: 'apply-1'),
      throwsA(isA<StateError>()),
    );
    verifyNever(() => updateService.applyUpdate());
  });

  test(
    'headless controller blocks apply before entering install state',
    () async {
      final staged = StagedUpdate(
        version: '2.1.0',
        buildNumber: 42,
        stagedAt: DateTime.utc(2026, 7, 12),
        extractPath: r'C:\staged',
      );
      when(
        () => updateService.getStagedUpdate(),
      ).thenAnswer((_) async => staged);
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_update_safety_',
      );
      final controller = UpdateController(
        service: updateService,
        currentVersion: '2.0.0',
        currentBuildNumber: 41,
        stateDirectory: tempDir,
        applySafetyCheck: () async {
          throw UpdateException('camera is exposing');
        },
      );
      addTearDown(() async {
        await controller.dispose();
        await tempDir.delete(recursive: true);
      });
      final events = <UpdateEvent>[];
      final subscription = controller.events.listen(events.add);
      addTearDown(subscription.cancel);

      await expectLater(
        controller.applyStagedUpdate(jobId: 'apply-1'),
        throwsA(isA<UpdateException>()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.status.state, UpdateLifecycleState.staged);
      expect(controller.status.lastError, contains('camera is exposing'));
      verifyNever(() => updateService.applyUpdate());
      expect(events.whereType<UpdateApplyStartedEvent>(), isEmpty);
      expect(events.whereType<UpdateFailedEvent>().single.phase, 'safety');
    },
  );

  test(
    'headless apply is not reported successful before handoff returns',
    () async {
      final staged = StagedUpdate(
        version: '2.1.0',
        buildNumber: 42,
        stagedAt: DateTime.utc(2026, 7, 12),
        extractPath: r'C:\staged',
      );
      final applyGate = Completer<UpdateApplyOutcome>();
      when(
        () => updateService.getStagedUpdate(),
      ).thenAnswer((_) async => staged);
      when(
        () => updateService.applyUpdate(),
      ).thenAnswer((_) => applyGate.future);
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_update_truth_',
      );
      final controller = UpdateController(
        service: updateService,
        currentVersion: '2.0.0',
        currentBuildNumber: 41,
        stateDirectory: tempDir,
        // This test is about the handoff, so the host gate is explicitly
        // permissive; without one the controller refuses every apply.
        applySafetyCheck: () async {},
      );
      addTearDown(() async {
        await controller.dispose();
        await tempDir.delete(recursive: true);
      });
      final events = <UpdateEvent>[];
      final subscription = controller.events.listen(events.add);
      addTearDown(subscription.cancel);

      final apply = controller.applyStagedUpdate(jobId: 'apply-1');
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<UpdateApplyStartedEvent>(), hasLength(1));
      expect(events.whereType<UpdateAppliedEvent>(), isEmpty);
      expect(controller.lastUpdateApplied, isNull);

      applyGate.complete(UpdateApplyOutcome.processExiting);
      await apply;
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<UpdateAppliedEvent>(), hasLength(1));
      expect(controller.lastUpdateApplied, isNull);
    },
  );

  test(
    'headless bootstrap records only a verified completed install',
    () async {
      when(() => updateService.verifyPendingInstall()).thenAnswer(
        (_) async => const PendingInstallStatus.verified('Build verified.'),
      );
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_update_bootstrap_',
      );
      final verifiedAt = DateTime.utc(2026, 7, 14, 4, 10);
      final controller = UpdateController(
        service: updateService,
        currentVersion: '2.1.0',
        currentBuildNumber: 42,
        stateDirectory: tempDir,
        now: () => verifiedAt,
      );
      addTearDown(() async {
        await controller.dispose();
        await tempDir.delete(recursive: true);
      });

      await controller.bootstrap();

      expect(controller.lastUpdateApplied, verifiedAt);
      expect(
        await File('${tempDir.path}/last_update_applied.txt').readAsString(),
        verifiedAt.toIso8601String(),
      );
    },
  );

  test('headless bootstrap keeps an unverifiable handoff visible', () async {
    when(() => updateService.verifyPendingInstall()).thenAnswer(
      (_) async => const PendingInstallStatus.requiresAttention(
        'Target build does not match the pending marker.',
      ),
    );
    when(() => updateService.getStagedUpdate()).thenAnswer(
      (_) async => StagedUpdate(
        version: '2.1.0',
        buildNumber: 42,
        stagedAt: DateTime.utc(2026, 7, 12),
        extractPath: r'C:\staged',
      ),
    );
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_update_attention_',
    );
    final controller = UpdateController(
      service: updateService,
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      stateDirectory: tempDir,
    );
    addTearDown(() async {
      await controller.dispose();
      await tempDir.delete(recursive: true);
    });

    await controller.bootstrap();

    expect(controller.status.state, UpdateLifecycleState.failed);
    expect(controller.status.lastError, contains('does not match'));
    expect(controller.status.stagedVersion, '2.1.0');
    expect(controller.lastUpdateApplied, isNull);
  });

  test('headless check exposes a real downloadable available state', () async {
    final offered = manifest();
    when(() => updateService.checkForUpdates()).thenAnswer(
      (_) async => UpdateCheckResult(
        hasUpdate: true,
        currentVersion: '2.0.0',
        availableVersion: offered.version,
        manifest: offered,
      ),
    );
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_update_available_',
    );
    final controller = UpdateController(
      service: updateService,
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      stateDirectory: tempDir,
      serverUrl: 'https://updates.example.invalid',
    );
    addTearDown(() async {
      await controller.dispose();
      await tempDir.delete(recursive: true);
    });

    final outcome = await controller.checkForUpdates();

    expect(outcome.available, isTrue);
    expect(controller.status.state, UpdateLifecycleState.available);
    expect(controller.status.availableVersion, offered.version);
    expect(controller.status.availableBuildNumber, offered.buildNumber);
  });

  test('manual-upgrade offer cannot enter the OTA download path', () async {
    final offered = manifest();
    when(() => updateService.checkForUpdates()).thenAnswer(
      (_) async => UpdateCheckResult(
        hasUpdate: true,
        currentVersion: '2.0.0',
        availableVersion: offered.version,
        manifest: offered,
        requiresManualUpgrade: true,
      ),
    );
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_update_manual_',
    );
    final controller = UpdateController(
      service: updateService,
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      stateDirectory: tempDir,
      serverUrl: 'https://updates.example.invalid',
    );
    addTearDown(() async {
      await controller.dispose();
      await tempDir.delete(recursive: true);
    });

    await controller.checkForUpdates();

    expect(controller.status.requiresManualUpgrade, isTrue);
    await expectLater(
      controller.downloadAndStage(jobId: 'download-1'),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('one-off check channel is restored after the request', () async {
    when(() => updateService.checkForUpdates()).thenAnswer(
      (_) async => UpdateCheckResult(hasUpdate: false, currentVersion: '2.0.0'),
    );
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_update_channel_',
    );
    final controller = UpdateController(
      service: updateService,
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      stateDirectory: tempDir,
      channel: 'stable',
      serverUrl: 'https://updates.example.invalid',
    );
    addTearDown(() async {
      await controller.dispose();
      await tempDir.delete(recursive: true);
    });

    await controller.checkForUpdates(channelOverride: 'beta');

    // The override changes the channel only. It used to go through
    // configure(), which re-derives the update source as a side effect — and
    // would now silently drop a GitHub source on every `?channel=` request.
    verifyInOrder([
      () => updateService.setChannel('beta'),
      () => updateService.checkForUpdates(),
      () => updateService.setChannel('stable'),
    ]);
    verifyNever(
      () => updateService.configure(
        serverUrl: any(named: 'serverUrl'),
        channel: any(named: 'channel'),
      ),
    );
  });

  test('aborted check cannot publish a late available result', () async {
    final gate = Completer<UpdateCheckResult>();
    when(() => updateService.checkForUpdates()).thenAnswer((_) => gate.future);
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_update_abort_',
    );
    final controller = UpdateController(
      service: updateService,
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      stateDirectory: tempDir,
      serverUrl: 'https://updates.example.invalid',
    );
    addTearDown(() async {
      await controller.dispose();
      await tempDir.delete(recursive: true);
    });
    final events = <UpdateEvent>[];
    final subscription = controller.events.listen(events.add);
    addTearDown(subscription.cancel);

    final check = controller.checkForUpdates();
    expect(controller.status.state, UpdateLifecycleState.checking);
    controller.abortInFlight();
    expect(controller.status.state, UpdateLifecycleState.cancelling);
    await expectLater(controller.checkForUpdates(), throwsA(isA<StateError>()));
    gate.complete(
      UpdateCheckResult(
        hasUpdate: true,
        currentVersion: '2.0.0',
        availableVersion: manifest().version,
        manifest: manifest(),
      ),
    );

    final outcome = await check;
    await Future<void>.delayed(Duration.zero);

    expect(outcome.available, isFalse);
    expect(controller.status.state, UpdateLifecycleState.idle);
    expect(controller.lastUpdateCheck, isNull);
    expect(events.whereType<UpdateAvailableEvent>(), isEmpty);
  });

  test('headless controller rejects overlapping update operations', () async {
    final gate = Completer<UpdateCheckResult>();
    when(() => updateService.checkForUpdates()).thenAnswer((_) => gate.future);
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_update_single_flight_',
    );
    final controller = UpdateController(
      service: updateService,
      currentVersion: '2.0.0',
      currentBuildNumber: 41,
      stateDirectory: tempDir,
      serverUrl: 'https://updates.example.invalid',
    );
    addTearDown(() async {
      await controller.dispose();
      await tempDir.delete(recursive: true);
    });

    final first = controller.checkForUpdates();
    expect(controller.hasActiveOperation, isTrue);
    await expectLater(
      controller.checkForUpdates(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('still in progress'),
        ),
      ),
    );
    verify(() => updateService.checkForUpdates()).called(1);

    gate.complete(UpdateCheckResult(hasUpdate: false, currentVersion: '2.0.0'));
    await first;
    expect(controller.hasActiveOperation, isFalse);
  });

  test(
    'default safety check checkpoints then blocks active sequence',
    () async {
      final backend = MockSkotiqBackend();
      when(() => backend.saveCheckpoint()).thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;

      await expectLater(
        container.read(updateSafetyProbeProvider.future),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('running'),
          ),
        ),
      );
      verify(() => backend.saveCheckpoint()).called(1);
    },
  );

  test('default safety check blocks active camera cooler', () async {
    final backend = MockSkotiqBackend();

    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final camera = container.read(cameraStateProvider.notifier);
    camera.setConnecting('cam1', 'Camera');
    camera.setConnected();
    camera.setCooling(true);

    await expectLater(
      container.read(updateSafetyProbeProvider.future),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('cooler'),
        ),
      ),
    );
    verifyNever(() => backend.saveCheckpoint());
  });

  test('default safety check blocks unparked mount', () async {
    final backend = MockSkotiqBackend();

    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final mount = container.read(mountStateProvider.notifier);
    mount.setConnecting('mount1');
    mount.setConnected();
    mount.setParked(false);

    await expectLater(
      container.read(updateSafetyProbeProvider.future),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('parked'),
        ),
      ),
    );
    verifyNever(() => backend.saveCheckpoint());
  });

  test('an Android install refused for missing permission opens the grant '
      'screen and stays installable', () async {
    // Android 8+ keeps "install unknown apps" off for every app until the
    // user turns it on, so the first OTA install on every phone meets this.
    // It used to end as a bare error: the permission screen was never
    // opened, and leaving the staged state meant the verified APK could
    // only be reached again by downloading it a second time.
    TestWidgetsFlutterBinding.ensureInitialized();
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidInstallerChannel, (call) async {
          calls.add(call.method);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(androidInstallerChannel, null),
    );
    when(() => updateService.applyUpdate()).thenThrow(
      AndroidInstallException(
        code: 'install_permission_denied',
        message: 'Skotiq is not allowed to install apps yet.',
      ),
    );

    final notifier = await stagedNotifier(safetyCheck: () async {});
    addTearDown(notifier.dispose);
    await notifier.applyUpdate();

    expect(calls, contains('openInstallPermissionSettings'));
    expect(notifier.state.status, UpdateStatus.staged);
    expect(notifier.state.errorMessage, contains('Allow'));
  });
}
