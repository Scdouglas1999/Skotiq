// The INDI "Test Connection" button must not report a green "Connected. Found 0
// devices." against an address where nothing is listening — a dead
// localhost:7624 or 192.0.2.77 (RFC 5737 TEST-NET-1, guaranteed unroutable).
//
// The FFI backend catches a refused/timed-out INDI socket and returns an empty
// device list rather than rethrowing (see
// skotiq_core .../ffi_backend/discovery_camera_operations.dart
// `_discoverAddressDevices`), so "server up, no drivers loaded" and "nothing is
// listening" reach this dialog as the identical value. Inferring a successful
// connection from that is a claim the dialog has no evidence for, and it is the
// worst possible failure mode for the test button: a user who typos their
// Raspberry Pi's address gets a green tick and hunts the wrong problem.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/dialogs/indi_server_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_backend.dart';
import '../../harness/mock_database.dart';

/// A [DeviceService] whose INDI address probe returns a fixed device list (or
/// throws), standing in for the backend's response to an address that may or
/// may not have an indiserver behind it.
class _StubIndiDeviceService extends DeviceService {
  _StubIndiDeviceService(super.ref, super.backend,
      {this.devices = const <DeviceInfo>[], this.error});

  final List<DeviceInfo> devices;
  final Object? error;

  @override
  Future<List<DeviceInfo>> discoverIndiAtAddress(String host, int port) async {
    final failure = error;
    if (failure != null) throw failure;
    return devices;
  }
}

DeviceInfo _indiCamera() => const DeviceInfo(
      id: 'indi:CCD Simulator',
      name: 'CCD Simulator',
      deviceType: DeviceType.camera,
      driverType: DriverType.indi,
      description: '',
      driverVersion: '1.0',
    );

Future<void> _openDialog(
  WidgetTester tester, {
  required SkotiqDatabase db,
  required DeviceService Function(Ref ref) service,
}) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        deviceServiceProvider.overrideWith(service),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: IndiServerDialog()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'an address that enumerates no devices is not reported as '
      'connected', (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);
    final backend = mockBackend();
    addTearDown(backend.dispose);

    await _openDialog(
      tester,
      db: db,
      service: (ref) => _StubIndiDeviceService(ref, backend),
    );

    await tester.enterText(
      find.byKey(const ValueKey('indi-host-field')),
      '192.0.2.77',
    );
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Connected.'), findsNothing,
        reason: 'an empty device list is not evidence of a connection');
    expect(find.textContaining('No INDI devices at 192.0.2.77:7624'),
        findsOneWidget);
    // The result banner must use the failure icon, not the green success tick.
    expect(find.byIcon(SkotiqIcons.success), findsNothing);
    expect(find.byIcon(SkotiqIcons.error), findsOneWidget);
  });

  testWidgets('an address that enumerates a device is reported as connected',
      (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);
    final backend = mockBackend();
    addTearDown(backend.dispose);

    await _openDialog(
      tester,
      db: db,
      service: (ref) =>
          _StubIndiDeviceService(ref, backend, devices: [_indiCamera()]),
    );

    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Connected. Found 1 device.'), findsOneWidget);
    expect(find.byIcon(SkotiqIcons.success), findsOneWidget);
  });

  testWidgets('a thrown probe names the endpoint it failed on', (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);
    final backend = mockBackend();
    addTearDown(backend.dispose);

    await _openDialog(
      tester,
      db: db,
      service: (ref) => _StubIndiDeviceService(ref, backend,
          error: Exception('Connection refused')),
    );

    await tester.enterText(
      find.byKey(const ValueKey('indi-port-field')),
      '7777',
    );
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(
        find.textContaining('No response on localhost:7777'), findsOneWidget);
    expect(find.byIcon(SkotiqIcons.error), findsOneWidget);
  });
}
