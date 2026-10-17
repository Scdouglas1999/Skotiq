// C8: camera gain/offset presets seeded from CameraRecommendedSettings.
//
// These tests pin the contract for [CameraPresetsNotifier.seedFromRecommended]
// and the dirty-flag side effect of [CameraPresetsNotifier.applyPreset]:
//   1. A recommended unity gain above the camera's gainMax is clamped down.
//   2. A null recommended unity gain leaves the published default (139).
//   3. A user-renamed / re-tuned unity preset is never clobbered.
//   4. Applying a preset flips exposureSettingsUserDirtyProvider so the
//      profile / Smart Night auto-seed cannot immediately overwrite it.
//
// We back the notifier with a real in-memory Drift database (the production
// settings schema, no mocks) so the seed round-trips through persistence.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart'
    show CameraRecommendedSettings, SkotiqBackend;
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/backend/device_capabilities.dart';
import 'package:skotiq_core/src/models/imaging/camera_preset.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/camera_presets_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/imaging_provider.dart';

import '../mocks/mock_backend.dart';

/// Injects a mock backend into [backendProvider] for the connect-edge tests.
class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Reads the preset notifier after its initial async load completes so the
  /// factory defaults (including the pristine unity_gain preset) are present.
  Future<CameraPresetsNotifier> loadedNotifier() async {
    final notifier = container.read(cameraPresetsProvider.notifier);
    // The constructor kicks off _loadPresets(); pump until data lands.
    while (container.read(cameraPresetsProvider).valueOrNull == null) {
      await Future<void>.delayed(Duration.zero);
    }
    return notifier;
  }

  CameraPreset unityPresetOf(ProviderContainer c) {
    return c
        .read(cameraPresetsProvider)
        .value!
        .firstWhere((p) => p.id == kUnityGainPresetId);
  }

  test('clamps recommended unity gain to gainMax (200 -> 180)', () async {
    final notifier = await loadedNotifier();

    await notifier.seedFromRecommended(
      const CameraRecommendedSettings(
        unityGain: 200,
        defaultOffset: 25,
        notes: 'ZWO ASI2600MC',
      ),
      gainMin: 0,
      gainMax: 180,
    );

    final unity = unityPresetOf(container);
    expect(unity.gain, 180, reason: 'gain 200 must clamp to gainMax 180');
    expect(unity.offset, 25, reason: 'recommended defaultOffset should apply');
    expect(
      unity.updatedAt,
      isNotNull,
      reason: 'seeded preset should record an update timestamp',
    );

    // Persisted, not just in-memory: a fresh container hydrating the same DB
    // must see the seeded value.
    final fresh = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(fresh.dispose);
    while (fresh.read(cameraPresetsProvider).valueOrNull == null) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      unityPresetOf(fresh).gain,
      180,
      reason: 'seed must round-trip through persistence',
    );
  });

  test(
    'null recommended unity gain leaves the published default (139)',
    () async {
      final notifier = await loadedNotifier();

      final before = unityPresetOf(container);
      expect(
        before.gain,
        kDefaultUnityGain,
        reason: 'sanity: factory default is 139',
      );
      expect(before.offset, kDefaultUnityOffset);

      await notifier.seedFromRecommended(
        const CameraRecommendedSettings(
          unityGain: null,
          defaultOffset: 64,
          notes: 'ASCOM camera — no unity gain published',
        ),
        gainMin: 0,
        gainMax: 600,
      );

      final after = unityPresetOf(container);
      expect(
        after.gain,
        kDefaultUnityGain,
        reason: 'null unityGain must leave the literal default untouched',
      );
      expect(
        after.offset,
        kDefaultUnityOffset,
        reason: 'offset must not move when there is no recommended gain',
      );
      expect(
        after.updatedAt,
        isNull,
        reason: 'no seed occurred, so no update timestamp',
      );
    },
  );

  test('does not modify a user-customized unity preset', () async {
    final notifier = await loadedNotifier();

    // User re-tunes their unity preset to a personal value.
    await notifier.updatePreset(
      kUnityGainPresetId,
      unityPresetOf(container).copyWith(gain: 111, offset: 17),
    );
    expect(unityPresetOf(container).gain, 111);

    await notifier.seedFromRecommended(
      const CameraRecommendedSettings(
        unityGain: 139,
        defaultOffset: 30,
        notes: 'recommendation should be ignored — preset is customized',
      ),
      gainMin: 0,
      gainMax: 600,
    );

    final unity = unityPresetOf(container);
    expect(unity.gain, 111, reason: 'user-tuned gain must survive seeding');
    expect(unity.offset, 17, reason: 'user-tuned offset must survive seeding');
  });

  test('does not modify a user-renamed unity preset', () async {
    final notifier = await loadedNotifier();

    // User renames the factory preset but keeps the literal numbers.
    await notifier.updatePreset(
      kUnityGainPresetId,
      unityPresetOf(container).copyWith(name: 'My Unity'),
    );

    await notifier.seedFromRecommended(
      const CameraRecommendedSettings(
        unityGain: 200,
        defaultOffset: 50,
        notes: 'renamed preset is no longer the factory default',
      ),
      gainMin: 0,
      gainMax: 600,
    );

    final unity = unityPresetOf(container);
    expect(
      unity.gain,
      kDefaultUnityGain,
      reason: 'renamed preset is not pristine, so it must not be seeded',
    );
    expect(unity.name, 'My Unity');
  });

  test('applyPreset sets the exposure-settings dirty flag', () async {
    final notifier = await loadedNotifier();

    expect(
      container.read(exposureSettingsUserDirtyProvider),
      isFalse,
      reason: 'dirty flag defaults to false',
    );

    notifier.applyPreset(kUnityGainPresetId);

    expect(
      container.read(exposureSettingsUserDirtyProvider),
      isTrue,
      reason: 'applying a preset is a deliberate user gain/offset choice',
    );

    final settings = container.read(exposureSettingsProvider);
    expect(
      settings.gain,
      kDefaultUnityGain,
      reason: 'applyPreset should push the preset gain into exposure settings',
    );
    expect(settings.offset, kDefaultUnityOffset);
    expect(container.read(selectedPresetIdProvider), kUnityGainPresetId);
  });

  // Connect-edge wiring: the production runtime behaviour is the
  // `cameraPresetsSeedOnConnectProvider` listener, NOT a direct call to
  // seedFromRecommended. These tests drive a disconnected -> connected
  // transition through cameraStateProvider with that provider read (exactly as
  // the desktop bootstrap does) and assert the unity preset is seeded. Without
  // the bootstrap `container.read(cameraPresetsSeedOnConnectProvider)` the
  // listener never attaches and nothing is seeded.
  group('cameraPresetsSeedOnConnectProvider connect-edge', () {
    setUpAll(registerMocktailFallbackValues);

    late MockBackend mockBackend;
    late ProviderContainer connectContainer;

    setUp(() {
      mockBackend = MockBackend();
      when(
        () => mockBackend.eventStream,
      ).thenAnswer((_) => const Stream.empty());
      when(
        () => mockBackend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
    });

    tearDown(() {
      connectContainer.dispose();
    });

    ProviderContainer buildContainer() {
      return ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, mockBackend),
          ),
        ],
      );
    }

    /// Load the preset notifier so the factory defaults (pristine unity_gain)
    /// are present before the connect edge fires.
    Future<void> waitForPresets(ProviderContainer c) async {
      c.read(cameraPresetsProvider.notifier);
      while (c.read(cameraPresetsProvider).valueOrNull == null) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    Future<void> pumpUntilUnitySeeded(
      ProviderContainer c, {
      required int expectedGain,
    }) async {
      // The seed runs off the listener callback as an unawaited future, so
      // poll until it lands (or give up after a bounded number of pumps).
      for (var i = 0; i < 200; i++) {
        final unity = c
            .read(cameraPresetsProvider)
            .value!
            .firstWhere((p) => p.id == kUnityGainPresetId);
        if (unity.gain == expectedGain) return;
        await Future<void>.delayed(Duration.zero);
      }
    }

    test(
      'seeds unity preset from CameraRecommendedSettings on connect',
      () async {
        when(() => mockBackend.cameraGetRecommendedSettings(any())).thenAnswer(
          (_) async => const CameraRecommendedSettings(
            unityGain: 100,
            defaultOffset: 40,
            notes: 'ZWO ASI2600MM',
          ),
        );
        when(() => mockBackend.getCameraCapabilities(any())).thenAnswer(
          (_) async => const CameraCapabilities(
            maxWidth: 6248,
            maxHeight: 4176,
            bitDepth: 16,
            gainMin: 0,
            gainMax: 600,
          ),
        );

        connectContainer = buildContainer();
        await waitForPresets(connectContainer);

        // Attach the connect-edge listener exactly as app bootstrap does.
        connectContainer.read(cameraPresetsSeedOnConnectProvider);

        // Drive disconnected -> connecting -> connected.
        final cameraNotifier = connectContainer.read(
          cameraStateProvider.notifier,
        );
        cameraNotifier.setConnecting('simulator:test-camera-1', 'ASI2600MM');
        cameraNotifier.setConnected();

        await pumpUntilUnitySeeded(connectContainer, expectedGain: 100);

        final unity = connectContainer
            .read(cameraPresetsProvider)
            .value!
            .firstWhere((p) => p.id == kUnityGainPresetId);
        expect(
          unity.gain,
          100,
          reason: 'connect edge must seed gain from the recommendation',
        );
        expect(
          unity.offset,
          40,
          reason: 'connect edge must seed offset from the recommendation',
        );

        verify(
          () => mockBackend.cameraGetRecommendedSettings(
            'simulator:test-camera-1',
          ),
        ).called(1);
      },
    );

    test(
      'clamps the recommended gain to the reported gainMax on connect',
      () async {
        when(() => mockBackend.cameraGetRecommendedSettings(any())).thenAnswer(
          (_) async => const CameraRecommendedSettings(
            unityGain: 500,
            defaultOffset: 30,
            notes: 'recommendation above gainMax',
          ),
        );
        when(() => mockBackend.getCameraCapabilities(any())).thenAnswer(
          (_) async => const CameraCapabilities(
            maxWidth: 100,
            maxHeight: 100,
            bitDepth: 16,
            gainMin: 0,
            gainMax: 180,
          ),
        );

        connectContainer = buildContainer();
        await waitForPresets(connectContainer);
        connectContainer.read(cameraPresetsSeedOnConnectProvider);

        final cameraNotifier = connectContainer.read(
          cameraStateProvider.notifier,
        );
        cameraNotifier.setConnecting('simulator:test-camera-1', 'Cam');
        cameraNotifier.setConnected();

        await pumpUntilUnitySeeded(connectContainer, expectedGain: 180);

        final unity = connectContainer
            .read(cameraPresetsProvider)
            .value!
            .firstWhere((p) => p.id == kUnityGainPresetId);
        expect(unity.gain, 180, reason: 'gain 500 must clamp to gainMax 180');
      },
    );

    test('does not re-seed on status ticks after the first connect', () async {
      when(() => mockBackend.cameraGetRecommendedSettings(any())).thenAnswer(
        (_) async => const CameraRecommendedSettings(
          unityGain: 100,
          defaultOffset: 40,
          notes: 'ZWO ASI2600MM',
        ),
      );
      when(() => mockBackend.getCameraCapabilities(any())).thenAnswer(
        (_) async => const CameraCapabilities(
          maxWidth: 100,
          maxHeight: 100,
          bitDepth: 16,
          gainMin: 0,
          gainMax: 600,
        ),
      );

      connectContainer = buildContainer();
      await waitForPresets(connectContainer);
      connectContainer.read(cameraPresetsSeedOnConnectProvider);

      final cameraNotifier = connectContainer.read(
        cameraStateProvider.notifier,
      );
      cameraNotifier.setConnecting('simulator:test-camera-1', 'Cam');
      cameraNotifier.setConnected();
      await pumpUntilUnitySeeded(connectContainer, expectedGain: 100);

      // A subsequent status tick re-emits the connected snapshot (temperature
      // update). The listener must NOT treat connected -> connected as a new
      // connect edge and re-query the recommendation.
      cameraNotifier.updateTemperature(-9.5, 42.0);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      verify(() => mockBackend.cameraGetRecommendedSettings(any())).called(1);
    });

    test('discards a late recommendation from the previous camera', () async {
      final cameraAGate = Completer<CameraRecommendedSettings>();
      final cameraBGate = Completer<CameraRecommendedSettings>();
      when(
        () => mockBackend.cameraGetRecommendedSettings('camera-a'),
      ).thenAnswer((_) => cameraAGate.future);
      when(
        () => mockBackend.cameraGetRecommendedSettings('camera-b'),
      ).thenAnswer((_) => cameraBGate.future);
      when(() => mockBackend.getCameraCapabilities(any())).thenAnswer(
        (_) async => const CameraCapabilities(
          maxWidth: 100,
          maxHeight: 100,
          bitDepth: 16,
          gainMin: 0,
          gainMax: 600,
        ),
      );

      connectContainer = buildContainer();
      await waitForPresets(connectContainer);
      connectContainer.read(cameraPresetsSeedOnConnectProvider);
      final cameraNotifier = connectContainer.read(
        cameraStateProvider.notifier,
      );

      cameraNotifier.setConnecting('camera-a', 'Camera A');
      cameraNotifier.setConnected();
      await Future<void>.delayed(Duration.zero);
      cameraNotifier.setDisconnected();
      cameraNotifier.setConnecting('camera-b', 'Camera B');
      cameraNotifier.setConnected();
      await Future<void>.delayed(Duration.zero);

      cameraAGate.complete(
        const CameraRecommendedSettings(
          unityGain: 200,
          defaultOffset: 20,
          notes: 'stale camera A',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        unityPresetOf(connectContainer).gain,
        kDefaultUnityGain,
        reason: 'camera A is no longer authorized to seed the preset',
      );

      cameraBGate.complete(
        const CameraRecommendedSettings(
          unityGain: 90,
          defaultOffset: 15,
          notes: 'current camera B',
        ),
      );
      await pumpUntilUnitySeeded(connectContainer, expectedGain: 90);

      final unity = unityPresetOf(connectContainer);
      expect(unity.gain, 90);
      expect(unity.offset, 15);
      verifyNever(() => mockBackend.getCameraCapabilities('camera-a'));
      verify(() => mockBackend.getCameraCapabilities('camera-b')).called(1);
    });
  });
}
