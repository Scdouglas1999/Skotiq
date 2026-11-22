import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/ffi_backend.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/device_heartbeat_health_provider.dart';
import 'package:skotiq_core/src/providers/device_service_providers.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/linked_host.dart';
import 'package:skotiq_core/src/providers/sequence/run_record.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';

import '../harness/in_memory_database.dart';
import '../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _MockHostDevices extends Mock implements HostDeviceControl {}

/// Who brings a lost device back, per backend the app runs on.
///
/// The imaging host (the desktop window and the headless daemon both start
/// an FfiBackend) leaves every device type to the native reconnection loop:
/// the app makes no connect of its own and only shows "Reconnecting". A
/// linked client (desktop or phone, a NetworkBackend) leaves the host's
/// devices to the host. A DisconnectedBackend, or an FfiBackend without the
/// native library, has no device events to react to.
void main() {
  setUpAll(registerMocktailFallbackValues);

  SkotiqEvent disconnected(DeviceType type, String deviceId) => SkotiqEvent(
    timestamp: 0,
    severity: EventSeverity.warning,
    category: EventCategory.equipment,
    eventType: 'Disconnected',
    data: {'device_type': type.slot.wireNames.first, 'device_id': deviceId},
  );

  String idFor(DeviceType type) => 'ascom:ASCOM.Test.${type.name}';

  /// Loses one device of every type with each slot connected, then lets
  /// well over the old 5/10/20 s retry schedule pass.
  ({MockBackend backend, ProviderContainer container}) loseEveryDevice(
    FakeAsync async, {
    required Set<DeviceType> nativeTypes,
    HostDeviceControl? hostDevices,
  }) {
    final backend = MockBackend();
    final events = StreamController<SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => backend.nativeReconnectedDeviceTypes).thenReturn(nativeTypes);
    when(() => backend.connectDevice(any(), any())).thenAnswer((_) async {});
    when(() => backend.saveCheckpoint()).thenAnswer((_) async {});
    when(() => backend.sequencerPause()).thenAnswer((_) async {});
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        linkedHostDevicesProvider.overrideWithValue(hostDevices),
        inMemoryDatabaseOverride(),
      ],
    );
    container.read(deviceServiceProvider);
    container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.running);
    for (final type in DeviceType.values) {
      readDeviceConnectionNotifier(container, type)
        ..setConnecting(idFor(type), type.displayName)
        ..setConnected();
    }
    async.flushMicrotasks();
    for (final type in DeviceType.values) {
      events.add(disconnected(type, idFor(type)));
    }
    async.elapse(const Duration(minutes: 5));
    return (backend: backend, container: container);
  }

  test('on the imaging host every lost device is left to the native '
      'reconnection loop and shows as reconnecting', () {
    fakeAsync((async) {
      final rig = loseEveryDevice(
        async,
        nativeTypes: DeviceType.values.toSet(),
      );
      verifyNever(() => rig.backend.connectDevice(any(), any()));
      // The run is still protected: the lost camera and mount each take a
      // checkpoint and pause it.
      verify(() => rig.backend.saveCheckpoint()).called(2);
      verify(() => rig.backend.sequencerPause()).called(2);
      final health = rig.container.read(deviceHeartbeatHealthProvider.notifier);
      for (final type in DeviceType.values) {
        expect(
          health.forDevice(idFor(type)).health,
          HeartbeatHealth.reconnecting,
          reason: type.name,
        );
      }
      rig.container.dispose();
      async.flushTimers();
    });
  });

  test('on a linked client the app reconnects nothing, takes no checkpoint '
      'and pauses nothing', () {
    fakeAsync((async) {
      final rig = loseEveryDevice(
        async,
        nativeTypes: const {},
        hostDevices: _MockHostDevices(),
      );
      verifyNever(() => rig.backend.connectDevice(any(), any()));
      verifyNever(() => rig.backend.saveCheckpoint());
      verifyNever(() => rig.backend.sequencerPause());
      rig.container.dispose();
      async.flushTimers();
    });
  });

  test('a DisconnectedBackend has no device events and no native types', () {
    final backend = DisconnectedBackend();
    addTearDown(backend.dispose);
    expect(backend.nativeReconnectedDeviceTypes, isEmpty);
    fakeAsync((async) {
      var events = 0;
      final sub = backend.eventStream.listen((_) => events++);
      async.elapse(const Duration(minutes: 5));
      expect(events, 0);
      sub.cancel();
    });
  });

  test('an FfiBackend without the native library emits no device events', () {
    fakeAsync((async) {
      final backend = FfiBackend();
      expect(backend.nativeReconnectedDeviceTypes, isEmpty);
      var events = 0;
      final sub = backend.eventStream.listen((_) => events++);
      async.elapse(const Duration(minutes: 5));
      expect(events, 0);
      sub.cancel();
      backend.dispose();
      async.flushTimers();
    });
  });
}
