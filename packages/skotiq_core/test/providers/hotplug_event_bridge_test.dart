// Hot-plug device-detection event bridge test.
//
// Verifies that when the backend event stream emits a Rust
// `EquipmentEvent::DeviceDiscovered` (mapped to the 'DeviceDiscovered' event
// type) the equipment discovery providers are invalidated so a subsequent
// read re-runs the scan. This is the load-bearing assertion of
// without invalidation the equipment screen would serve a stale list
// from the FutureProvider cache and a freshly-plugged camera would
// never appear without a manual pull-to-refresh.

// Note: backup_service.dart in this branch has an unrelated drift type
// inference compile error that blocks loading `package:skotiq_core/skotiq_core.dart`
// in test compilation. We import only the source files we need directly
// from `src/` so the test still builds. The drift issue is tracked
// separately and is not part of this change.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/ffi_backend.dart';
// `skotiq_backend.dart` re-exports `backend_types.dart` which in turn
// re-exports `device_info.dart` and `event_types.dart`, so a single
// import covers `DeviceInfo`, `SkotiqEvent`, `EventCategory`,
// `EventSeverity`, `deviceDiscoveredEventType`, and
// `deviceLostEventType`.
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/hotplug_event_bridge_provider.dart';
import 'package:skotiq_core/src/services/device_service.dart';
import '../harness/in_memory_database.dart';

class _MockFfiBackend extends Mock implements FfiBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

SkotiqEvent _hotplugEvent({
  required String eventType,
  String deviceClass = 'camera',
  String deviceId = 'native:zwo:0',
}) {
  return SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: EventSeverity.info,
    category: EventCategory.equipment,
    eventType: eventType,
    data: {
      'device_class': deviceClass,
      'driver': 'native',
      'id': deviceId,
      if (eventType == deviceDiscoveredEventType) ...{
        'name': 'ZWO ASI 533',
        'display_name': 'ZWO ASI 533',
      },
    },
  );
}

void main() {
  test('hotplugEventBridgeProvider invalidates discovery providers on '
      'device_discovered events', () async {
    final controller = StreamController<SkotiqEvent>.broadcast();
    addTearDown(controller.close);

    final backend = _MockFfiBackend();
    when(() => backend.eventStream).thenAnswer((_) => controller.stream);

    var cameraScans = 0;
    var mountScans = 0;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        availableCamerasProvider.overrideWith((ref) {
          cameraScans += 1;
          return <DeviceInfo>[];
        }),
        availableMountsProvider.overrideWith((ref) {
          mountScans += 1;
          return <DeviceInfo>[];
        }),
      ],
    );
    addTearDown(container.dispose);

    // Bring the bridge online and seed the FutureProviders so we have
    // baseline scan counts to diff against.
    container.read(hotplugEventBridgeProvider);
    await container.read(availableCamerasProvider.future);
    await container.read(availableMountsProvider.future);
    final cameraBaseline = cameraScans;
    final mountBaseline = mountScans;

    // Emit a hot-plug arrival. The bridge debounces invalidation, so we wait
    // past the coalesce window before the next read re-runs the FutureProvider.
    controller.add(_hotplugEvent(eventType: deviceDiscoveredEventType));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    await container.read(availableCamerasProvider.future);
    await container.read(availableMountsProvider.future);

    expect(cameraScans, greaterThan(cameraBaseline));
    expect(mountScans, greaterThan(mountBaseline));
  });

  test('hotplugEventBridgeProvider coalesces a burst into a single '
      'invalidation round', () async {
    final controller = StreamController<SkotiqEvent>.broadcast();
    addTearDown(controller.close);

    final backend = _MockFfiBackend();
    when(() => backend.eventStream).thenAnswer((_) => controller.stream);

    var cameraScans = 0;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        availableCamerasProvider.overrideWith((ref) {
          cameraScans += 1;
          return <DeviceInfo>[];
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(hotplugEventBridgeProvider);
    await container.read(availableCamerasProvider.future);
    final baseline = cameraScans;

    // A powered-hub plug-in: many arrivals back-to-back inside one window.
    for (var i = 0; i < 25; i++) {
      controller.add(
        _hotplugEvent(
          eventType: deviceDiscoveredEventType,
          deviceId: 'native:zwo:$i',
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));

    await container.read(availableCamerasProvider.future);

    // 25 events must NOT cause 25 rescans — the debounce collapses them to a
    // single invalidation round, so exactly one extra scan beyond baseline.
    expect(cameraScans, equals(baseline + 1));
  });

  test('hotplugEventBridgeProvider invalidates discovery providers on '
      'device_lost events', () async {
    final controller = StreamController<SkotiqEvent>.broadcast();
    addTearDown(controller.close);

    final backend = _MockFfiBackend();
    when(() => backend.eventStream).thenAnswer((_) => controller.stream);

    var scans = 0;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        availableFocusersProvider.overrideWith((ref) {
          scans += 1;
          return <DeviceInfo>[];
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(hotplugEventBridgeProvider);
    await container.read(availableFocusersProvider.future);
    final baseline = scans;

    controller.add(
      _hotplugEvent(
        eventType: deviceLostEventType,
        deviceClass: 'focuser',
        deviceId: 'native:zwo:0',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    await container.read(availableFocusersProvider.future);
    expect(scans, greaterThan(baseline));
  });

  test(
    'hotplugEventBridgeProvider ignores unrelated PropertyChanged events',
    () async {
      final controller = StreamController<SkotiqEvent>.broadcast();
      addTearDown(controller.close);

      final backend = _MockFfiBackend();
      when(() => backend.eventStream).thenAnswer((_) => controller.stream);

      var scans = 0;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          availableCamerasProvider.overrideWith((ref) {
            scans += 1;
            return <DeviceInfo>[];
          }),
        ],
      );
      addTearDown(container.dispose);

      container.read(hotplugEventBridgeProvider);
      await container.read(availableCamerasProvider.future);
      final baseline = scans;

      // A non-hot-plug PropertyChanged (mount tracking, camera temp, etc.)
      // must NOT invalidate the discovery providers — that would cause a
      // rescan storm during normal operation.
      controller.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'PropertyChanged',
          data: const {
            'device_type': 'mount',
            'device_id': 'ascom:sw.eqmod',
            'property': 'tracking_state',
            'value': 'true',
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // No re-read because the future provider was not invalidated.
      expect(scans, equals(baseline));
    },
  );
}
