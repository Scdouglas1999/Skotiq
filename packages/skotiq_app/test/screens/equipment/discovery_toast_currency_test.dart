// The last toast on screen must not contradict the live state.
//
// Clicking Connect / Disconnect on a device row eight times as fast as the
// mouse allows leaves the snackbars replaying one at a time long after the
// clicks stop: the status bar carries "Disconnected camera" while the same
// frame shows `1 connected`, the row reading Disconnect, and a live sensor
// temperature of 20.0 C. Snackbars queue; device state does not. Only the
// newest statement about a device can be true.
//
// The copy also has to be symmetric — "Connected to Simulated Camera" (device
// name, title case) against "Disconnected camera" (generic, lowercase).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/discovery_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_backend.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _deviceName = 'ASCOM Camera Simulator';
const _deviceId = 'ascom:ASCOM.Simulator.Camera';

UnifiedDevice _camera() => UnifiedDevice(
      canonicalName: 'ascom camera',
      displayName: _deviceName,
      type: DeviceType.camera,
      availableBackends: {
        DriverType.ascom: DeviceInfo(
          id: _deviceId,
          name: _deviceName,
          deviceType: DeviceType.camera,
          driverType: DriverType.ascom,
          description: '',
          driverVersion: '',
        ),
      },
    );

class _SeededDiscoveryNotifier extends UnifiedDiscoveryNotifier {
  _SeededDiscoveryNotifier(super.ref, UnifiedDiscoveryState seed) {
    state = seed;
  }
}

class _FakeCameraNotifier extends StateNotifier<CameraStateSnapshot>
    implements CameraStateNotifier {
  _FakeCameraNotifier() : super(const CameraStateSnapshot());

  void _apply({required bool connected}) {
    state = CameraStateSnapshot(
      connectionState: connected
          ? DeviceConnectionState.connected
          : DeviceConnectionState.disconnected,
      deviceId: connected ? _deviceId : null,
      deviceName: connected ? _deviceName : null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Drives the fake camera state the way the real service would, without a rig.
class _FakeDeviceService extends DeviceService {
  _FakeDeviceService(super.ref, super.backend, this.camera);

  final _FakeCameraNotifier camera;

  @override
  Future<void> connectCamera(String deviceId) async =>
      camera._apply(connected: true);

  @override
  Future<void> disconnectCamera() async => camera._apply(connected: false);
}

/// `SkotiqIconButton` carries its tooltip through `Semantics` and
/// `SkotiqTooltip`, not a Material `Tooltip`, so `find.byTooltip` misses it.
Finder _iconButton(String tooltip) => find.byWidgetPredicate(
      (w) => w is SkotiqIconButton && w.tooltip == tooltip,
    );

void main() {
  testWidgets(
      'the newest device toast replaces the previous one, and both '
      'name the device', (tester) async {
    final backend = mockBackend();
    addTearDown(backend.dispose);
    final camera = _FakeCameraNotifier();

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        cameraStateProvider.overrideWith((ref) => camera),
        deviceServiceProvider.overrideWith(
          (ref) => _FakeDeviceService(ref, backend, camera),
        ),
        unifiedDiscoveryProvider.overrideWith(
          (ref) => _SeededDiscoveryNotifier(
            ref,
            UnifiedDiscoveryState(groupedDevices: [_camera()]),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SingleChildScrollView(child: DiscoveryPanel()),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(_iconButton('Expand'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SkotiqButton, 'Connect').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Connected to $_deviceName'), findsOneWidget);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Disconnect').first);
    await tester.pump();
    // Long enough for the superseded snackbar's exit animation to finish and
    // the replacement to come up — well short of a full four-second dwell.
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      find.text('Disconnected $_deviceName'),
      findsOneWidget,
      reason: 'the disconnect toast names the device, like the connect one',
    );
    expect(
      find.text('Connected to $_deviceName'),
      findsNothing,
      reason: 'a superseded claim about a device must leave the screen',
    );
  });
}
