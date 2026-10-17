// Tests for the capability-driven UI provider layer.
//
// Verifies:
//   * Provider correctly reads capabilities for a mock camera.
//   * Provider state updates after a reconnect with different capability flags.
//   * The fail-closed gate helper returns false on error / null and respects
//     the loading default.
//   * The dome capability provider can be overridden for tests (no FRB load).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart'
    hide CameraState;
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment/device_capability_provider.dart';

import '../mocks/mock_backend.dart';
import '../harness/in_memory_database.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  setUpAll(registerMocktailFallbackValues);

  group('equipmentCameraCapabilitiesProvider', () {
    late MockBackend backend;
    late ProviderContainer container;

    setUp(() {
      backend = MockBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(
        () => backend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );
    });

    tearDown(() => container.dispose());

    test('returns null when deviceId is empty', () async {
      final caps = await container.read(
        equipmentCameraCapabilitiesProvider('').future,
      );
      expect(caps, isNull);
      // Important: an empty deviceId must NOT call the backend at all.
      verifyNever(() => backend.getCameraCapabilities(any()));
    });

    test('returns capabilities from backend on success', () async {
      const deviceId = 'simulator:cam-1';
      const expected = CameraCapabilities(
        maxWidth: 4144,
        maxHeight: 2822,
        bitDepth: 16,
        canSetCcdTemperature: true,
        canSetCooler: true,
        canSetGain: true,
        gainMin: 0,
        gainMax: 600,
        canBin: true,
        maxBinX: 2,
        maxBinY: 2,
      );
      when(
        () => backend.getCameraCapabilities(deviceId),
      ).thenAnswer((_) async => expected);

      final caps = await container.read(
        equipmentCameraCapabilitiesProvider(deviceId).future,
      );

      expect(caps, isNotNull);
      expect(caps!.canSetCcdTemperature, isTrue);
      expect(caps.canSetGain, isTrue);
      expect(caps.gainMax, 600);
    });

    test('propagates backend exceptions so gate can fail closed', () async {
      const deviceId = 'simulator:broken-cam';
      when(
        () => backend.getCameraCapabilities(deviceId),
      ).thenThrow(Exception('driver crashed'));

      expect(
        container.read(equipmentCameraCapabilitiesProvider(deviceId).future),
        throwsA(isA<Exception>()),
      );
    });

    test('family key change (e.g. reconnect to a different driver) triggers '
        'a fresh capability read with the new flags', () async {
      const oldDeviceId = 'simulator:cam-old';
      const newDeviceId = 'simulator:cam-new';

      when(() => backend.getCameraCapabilities(oldDeviceId)).thenAnswer(
        (_) async => const CameraCapabilities(
          maxWidth: 1024,
          maxHeight: 768,
          bitDepth: 12,
          canSetCcdTemperature: false,
          canSetGain: false,
        ),
      );
      when(() => backend.getCameraCapabilities(newDeviceId)).thenAnswer(
        (_) async => const CameraCapabilities(
          maxWidth: 9576,
          maxHeight: 6388,
          bitDepth: 16,
          canSetCcdTemperature: true,
          canSetGain: true,
          gainMin: 0,
          gainMax: 360,
        ),
      );

      final oldCaps = await container.read(
        equipmentCameraCapabilitiesProvider(oldDeviceId).future,
      );
      expect(
        oldCaps!.canSetCcdTemperature,
        isFalse,
        reason: 'Old driver explicitly does not support cooling',
      );
      expect(oldCaps.canSetGain, isFalse);

      // Now ask about the new device. FutureProvider.family uses deviceId as
      // the cache key, so a fresh query is issued.
      final newCaps = await container.read(
        equipmentCameraCapabilitiesProvider(newDeviceId).future,
      );
      expect(
        newCaps!.canSetCcdTemperature,
        isTrue,
        reason: 'New driver upgraded to a cooled camera',
      );
      expect(newCaps.canSetGain, isTrue);
      expect(newCaps.gainMax, 360);

      verify(() => backend.getCameraCapabilities(oldDeviceId)).called(1);
      verify(() => backend.getCameraCapabilities(newDeviceId)).called(1);
    });
  });

  group('gateCapability', () {
    test('returns extracted value when data is present', () {
      const caps = CameraCapabilities(
        maxWidth: 1,
        maxHeight: 1,
        bitDepth: 16,
        canSetCcdTemperature: true,
      );
      final value = gateCapability<CameraCapabilities>(
        const AsyncValue.data(caps),
        (c) => c.canSetCcdTemperature,
      );
      expect(value, isTrue);
    });

    test('returns false when data is null (capability unknown)', () {
      final value = gateCapability<CameraCapabilities>(
        const AsyncValue<CameraCapabilities?>.data(null),
        (c) => c.canSetCcdTemperature,
      );
      expect(
        value,
        isFalse,
        reason:
            'A driver that does not report capabilities '
            'must fail closed.',
      );
    });

    test('returns false on error (driver crash) — fail closed', () {
      final value = gateCapability<CameraCapabilities>(
        AsyncValue<CameraCapabilities?>.error(
          Exception('bridge crashed'),
          StackTrace.current,
        ),
        (c) => c.canSetCcdTemperature,
      );
      expect(
        value,
        isFalse,
        reason:
            'Errors are a feature: a thrown query is the strongest '
            'possible signal to hide the control.',
      );
    });

    test('respects loadingDefault while the future is pending', () {
      final pendingTrue = gateCapability<CameraCapabilities>(
        const AsyncValue<CameraCapabilities?>.loading(),
        (c) => c.canSetCcdTemperature,
        loadingDefault: true,
      );
      final pendingFalse = gateCapability<CameraCapabilities>(
        const AsyncValue<CameraCapabilities?>.loading(),
        (c) => c.canSetCcdTemperature,
      );
      expect(
        pendingTrue,
        isTrue,
        reason: 'UI requested optimistic visibility while loading.',
      );
      expect(
        pendingFalse,
        isFalse,
        reason: 'Default loading behaviour is fail closed.',
      );
    });
  });

  group('equipmentDomeCapabilitiesProvider', () {
    test('uses the test fetcher override (no FRB load required)', () async {
      const deviceId = 'simulator:dome-1';
      const expected = DomeCapabilities(
        canSetShutter: true,
        canPark: true,
        canSetAzimuth: false,
      );

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          domeCapabilityFetcherProvider.overrideWithValue((id) async {
            expect(id, deviceId);
            return expected;
          }),
        ],
      );
      addTearDown(container.dispose);

      final caps = await container.read(
        equipmentDomeCapabilitiesProvider(deviceId).future,
      );
      expect(caps, isNotNull);
      expect(caps!.canSetShutter, isTrue);
      expect(caps.canPark, isTrue);
      expect(caps.canSetAzimuth, isFalse);
    });

    test(
      'returns null when deviceId is empty without calling the fetcher',
      () async {
        var fetcherCalls = 0;
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            domeCapabilityFetcherProvider.overrideWithValue((id) async {
              fetcherCalls++;
              return const DomeCapabilities(canSetShutter: true);
            }),
          ],
        );
        addTearDown(container.dispose);

        final caps = await container.read(
          equipmentDomeCapabilitiesProvider('').future,
        );
        expect(caps, isNull);
        expect(
          fetcherCalls,
          0,
          reason: 'Empty deviceId must short-circuit before the fetcher.',
        );
      },
    );

    test(
      'thrown fetcher errors propagate so the gate can fail closed',
      () async {
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            domeCapabilityFetcherProvider.overrideWithValue(
              (id) async => throw StateError('dome bridge crashed'),
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(
          container.read(equipmentDomeCapabilitiesProvider('dome-x').future),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('equipmentCoverCalibratorCapabilitiesProvider', () {
    test(
      'reports each optional half and its live state independently',
      () async {
        const expected = CoverCalibratorCapabilitySnapshot(
          coverPresent: false,
          calibratorPresent: true,
          calibratorStatus: CalibratorStatus.ready,
          brightness: 42,
          maxBrightness: 255,
        );
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            coverCalibratorCapabilityFetcherProvider.overrideWithValue((
              id,
            ) async {
              expect(id, 'cover-1');
              return expected;
            }),
          ],
        );
        addTearDown(container.dispose);

        final snapshot = await container.read(
          equipmentCoverCalibratorCapabilitiesProvider('cover-1').future,
        );

        expect(snapshot, isNotNull);
        expect(snapshot!.coverPresent, isFalse);
        expect(snapshot.calibratorPresent, isTrue);
        expect(snapshot.calibratorStatus, CalibratorStatus.ready);
        expect(snapshot.brightness, 42);
        expect(snapshot.maxBrightness, 255);
      },
    );

    test('empty deviceId does not query the capability source', () async {
      var fetches = 0;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          coverCalibratorCapabilityFetcherProvider.overrideWithValue((_) async {
            fetches++;
            return const CoverCalibratorCapabilitySnapshot(
              coverPresent: true,
              calibratorPresent: true,
              maxBrightness: 255,
            );
          }),
        ],
      );
      addTearDown(container.dispose);

      final snapshot = await container.read(
        equipmentCoverCalibratorCapabilitiesProvider('').future,
      );

      expect(snapshot, isNull);
      expect(fetches, 0);
    });
  });
}
