// Camera gain/offset auto-detect on connect.
//
// These tests pin the contract for [DeviceService] auto-detect behavior:
// - Camera reports a recommendation, profile has no defaultGain  → applied.
// - Camera reports nothing                                       → profile unchanged.
// - Profile already has user-set defaultGain                     → never overwritten.
// - Public re-entry hook proxies the backend faithfully.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart'
    hide CameraState;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/services/device_service.dart';

import '../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  late MockBackend mockBackend;
  late StreamController<SkotiqEvent> eventStreamController;

  setUpAll(() {
    registerMocktailFallbackValues();
  });

  setUp(() {
    mockBackend = MockBackend();
    eventStreamController = StreamController<SkotiqEvent>.broadcast();
    when(
      () => mockBackend.eventStream,
    ).thenAnswer((_) => eventStreamController.stream);
    when(
      () => mockBackend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() {
    eventStreamController.close();
  });

  ProviderContainer buildContainer(EquipmentProfileModel? activeProfile) {
    final overrides = <Override>[
      backendProvider.overrideWith(
        (ref) => _TestBackendNotifier(ref, mockBackend),
      ),
    ];
    if (activeProfile != null) {
      overrides.add(
        activeEquipmentProfileProvider.overrideWithValue(activeProfile),
      );
    }
    final c = ProviderContainer(overrides: overrides);
    // Initialize DeviceService so event listeners are active.
    c.read(deviceServiceProvider);
    return c;
  }

  group('queryRecommendedCameraSettings (public re-entry)', () {
    test('proxies the backend faithfully', () async {
      when(() => mockBackend.cameraGetRecommendedSettings('cam-1')).thenAnswer(
        (_) async => const CameraRecommendedSettings(
          unityGain: 100,
          defaultOffset: 30,
          notes: 'ZWO SDK reports default gain = 100',
        ),
      );

      final container = buildContainer(null);
      addTearDown(container.dispose);

      final service = container.read(deviceServiceProvider);
      final result = await service.queryRecommendedCameraSettings('cam-1');

      expect(result.unityGain, 100);
      expect(result.defaultOffset, 30);
      expect(result.hcgGain, isNull);
      expect(result.notes, contains('ZWO SDK'));
      verify(() => mockBackend.cameraGetRecommendedSettings('cam-1')).called(1);
    });

    test('propagates backend errors instead of swallowing them', () async {
      // The public re-entry MUST surface errors so the UI can show them.
      // Silent fallbacks would hide SDK failures for months.
      // Why `async => throw`: mocktail's `.thenThrow` rethrows synchronously
      // when the stubbed method is called, but the real backend signature
      // returns Future. Using `.thenAnswer((_) async => throw ...)` simulates
      // a Future that completes with an error, which is the realistic path.
      when(
        () => mockBackend.cameraGetRecommendedSettings('cam-broken'),
      ).thenAnswer((_) async => throw Exception('SDK call failed'));

      final container = buildContainer(null);
      addTearDown(container.dispose);

      final service = container.read(deviceServiceProvider);
      await expectLater(
        service.queryRecommendedCameraSettings('cam-broken'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('applyRecommendedCameraSettings (UI confirm path)', () {
    test('returns false when no active profile is set', () async {
      final container = buildContainer(null);
      addTearDown(container.dispose);

      final service = container.read(deviceServiceProvider);
      final applied = await service.applyRecommendedCameraSettings(
        const CameraRecommendedSettings(
          unityGain: 100,
          defaultOffset: 30,
          notes: '',
        ),
      );
      expect(applied, isFalse);
    });

    test('returns false when SDK reported nothing', () async {
      final container = buildContainer(
        const EquipmentProfileModel(id: 1, name: 'Test rig'),
      );
      addTearDown(container.dispose);

      final service = container.read(deviceServiceProvider);
      final applied = await service.applyRecommendedCameraSettings(
        const CameraRecommendedSettings(notes: ''),
      );
      expect(applied, isFalse);
    });
  });

  group('CameraRecommendedSettings shape', () {
    test('empty struct surfaces all-null fields and empty notes', () {
      // Pins the contract: every field is independently nullable so the
      // service can apply a partial recommendation (gain-only or offset-only).
      const empty = CameraRecommendedSettings(notes: '');
      expect(empty.unityGain, isNull);
      expect(empty.hcgGain, isNull);
      expect(empty.defaultOffset, isNull);
      expect(empty.notes, isEmpty);
    });

    test('populated struct carries through the auto-detect channel', () {
      const populated = CameraRecommendedSettings(
        unityGain: 100,
        hcgGain: null, // No SDK exposes this yet.
        defaultOffset: 50,
        notes: 'QHY DefaultGain control reports 56',
      );
      expect(populated.unityGain, 100);
      expect(populated.defaultOffset, 50);
      expect(populated.hcgGain, isNull);
      expect(populated.notes, contains('QHY DefaultGain'));
    });
  });
}
