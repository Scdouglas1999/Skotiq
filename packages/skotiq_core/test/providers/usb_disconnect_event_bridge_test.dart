// Integration test for the USB disconnect event bridge.
//
// Verifies that the `usbDisconnectEventBridgeProvider` correctly
// subscribes to the backend's event stream and forwards equipment `Error`
// events into the underlying log, while ignoring commanded disconnects and
// unrelated event categories.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/usb_disconnect_log_provider.dart';
import 'package:skotiq_core/src/services/usb_disconnect_log.dart';

import '../mocks/mock_backend.dart';
import '../harness/in_memory_database.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  late MockBackend backend;
  late StreamController<SkotiqEvent> eventController;
  late ProviderContainer container;

  setUp(() {
    backend = MockBackend();
    eventController = StreamController<SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
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
    // Materialize the bridge so it begins listening.
    container.read(usbDisconnectEventBridgeProvider);
  });

  tearDown(() async {
    await eventController.close();
    container.dispose();
  });

  Future<void> emit(SkotiqEvent event) async {
    eventController.add(event);
    // Yield so the stream listener inside the bridge runs.
    await Future<void>.delayed(Duration.zero);
  }

  test('a device the operator disconnected is not a dropout', () async {
    // The native side publishes `Disconnected` only from its disconnect
    // command: the Disconnect button, a profile switch, shutdown.
    await emit(
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.equipment,
        eventType: 'Disconnected',
        data: {'device_type': 'camera', 'device_id': 'cam-1'},
      ),
    );

    final log = container.read(usbDisconnectLogProvider);
    expect(log.totalLast24h(), 0);
    expect(log.countForDevice('cam-1'), 0);
  });

  test('a device that stopped answering is one dropout', () async {
    // What the heartbeat publishes when it gives a device up: the status
    // change, then the error that carries the reason.
    await emit(
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.error,
        category: EventCategory.equipment,
        eventType: 'HeartbeatStatusChanged',
        data: {
          'device_type': 'Camera',
          'device_id': 'cam-1',
          'status': 'Disconnected',
        },
      ),
    );
    await emit(
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.error,
        category: EventCategory.equipment,
        eventType: 'Error',
        data: {
          'device_type': 'Camera',
          'device_id': 'cam-1',
          'message': 'Device unresponsive after 3 heartbeat failures: timeout',
        },
      ),
    );

    final log = container.read(usbDisconnectLogProvider);
    expect(log.countForDevice('cam-1'), 1);
    expect(log.recentEntries().first.reason, contains('unresponsive'));
  });

  test('records equipment Error events at warning+ severity', () async {
    await emit(
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.error,
        category: EventCategory.equipment,
        eventType: 'Error',
        data: {
          'device_type': 'mount',
          'device_id': 'mount-1',
          'message': 'USB device unplugged',
        },
      ),
    );

    final log = container.read(usbDisconnectLogProvider);
    expect(log.totalLast24h(), 1);
    final entries = log.recentEntries();
    expect(entries.first.reason, 'USB device unplugged');
  });

  test('ignores equipment Error events at info severity', () async {
    await emit(
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.equipment,
        eventType: 'Error',
        data: {
          'device_type': 'focuser',
          'device_id': 'foc-1',
          'message': 'transient',
        },
      ),
    );

    final log = container.read(usbDisconnectLogProvider);
    expect(
      log.totalLast24h(),
      0,
      reason: 'info-level errors should not pollute the disconnect log',
    );
  });

  test('ignores PropertyChanged equipment events', () async {
    await emit(
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.equipment,
        eventType: 'PropertyChanged',
        data: {
          'device_type': 'camera',
          'device_id': 'cam-1',
          'property': 'temperature',
          'value': '-10.0',
        },
      ),
    );

    final log = container.read(usbDisconnectLogProvider);
    expect(log.totalLast24h(), 0);
  });

  test('ignores non-equipment categories entirely', () async {
    await emit(
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.warning,
        category: EventCategory.guiding,
        eventType: 'Error',
        data: const {'device_id': 'guide-1'},
      ),
    );

    final log = container.read(usbDisconnectLogProvider);
    expect(
      log.totalLast24h(),
      0,
      reason: 'only EventCategory.equipment events feed the log',
    );
  });

  test('the usbDisconnectLogProvider override is honored', () {
    final fakeLog = UsbDisconnectLog();
    fakeLog.recordDisconnect(deviceId: 'pre-existing');
    final overridden = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        usbDisconnectLogProvider.overrideWithValue(fakeLog),
      ],
    );
    addTearDown(overridden.dispose);
    expect(
      overridden.read(usbDisconnectLogProvider).countForDevice('pre-existing'),
      1,
    );
  });
}
