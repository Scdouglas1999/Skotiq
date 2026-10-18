import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:skotiq_desktop/headless_api/routes/device_routes.dart';
import 'package:skotiq_desktop/headless_api/routes/headless_route.dart';

import 'handler_test_helpers.dart';

/// POST /api/mount/home: sends the mount home without parking it, refuses a
/// parked mount with 409 rather than unparking it, and refuses a mount with no
/// home position with 400.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _HomeBackend backend;
  late DeviceHandlers handlers;

  setUp(() {
    backend = _HomeBackend();
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    handlers = DeviceHandlers(container);
  });

  Future<(int, Map<String, Object?>)> home({
    String path = '/api/mount/home',
  }) async {
    final response = await translateHandlerErrors(
      handlers.handleMountHome(
        Request(
          'POST',
          Uri.parse('http://localhost$path'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'deviceId': 'sim_mount_1'}),
        ),
      ),
    );
    final body =
        jsonDecode(await response.readAsString()) as Map<String, Object?>;
    return (response.statusCode, body);
  }

  test('200: an unparked mount that can home is sent home', () async {
    final (status, body) = await home();

    expect(status, 200);
    expect(body['status'], 'homing');
    expect(backend.findHomeCalls, ['sim_mount_1']);
    expect(backend.unparkCalls, isEmpty);
    expect(backend.parkCalls, isEmpty, reason: 'homing never parks');
  });

  test('409: a parked mount is refused and left parked', () async {
    backend.parked = true;

    final (status, body) = await home();

    expect(status, 409);
    expect(body['error'], 'mount_parked');
    expect(body['message'], contains('Unpark it before sending it home'));
    expect(backend.findHomeCalls, isEmpty);
    expect(
      backend.unparkCalls,
      isEmpty,
      reason: 'the route must never unpark the mount on its own',
    );
  });

  test('400: a mount without a home position is refused', () async {
    backend.canFindHome = false;

    final (status, body) = await home();

    expect(status, 400);
    expect(body['error'], 'capability_unsupported');
    expect(body['message'], contains('cannot find home'));
    expect(backend.findHomeCalls, isEmpty);
  });

  test('both spellings route to the same checked handler', () {
    final routes = buildDeviceRoutes(
      handlers,
    ).where((r) => r.method == HttpMethod.post).map((r) => r.path).toSet();
    expect(routes, containsAll(['/api/mount/home', '/api/mount/find-home']));
  });
}

class _HomeBackend extends DisconnectedBackend {
  bool parked = false;
  bool canFindHome = true;
  final List<String> findHomeCalls = [];
  final List<String> parkCalls = [];
  final List<String> unparkCalls = [];

  @override
  Future<MountCapabilities?> getMountCapabilities(String deviceId) async =>
      MountCapabilities(canFindHome: canFindHome, canPark: true);

  @override
  Future<MountStatus> getMountStatus(String deviceId) async => MountStatus(
    connected: true,
    tracking: true,
    slewing: false,
    parked: parked,
    atHome: false,
    sideOfPier: PierSide.west,
    rightAscension: 5.5,
    declination: 22.0,
    trackingRate: TrackingRate.sidereal,
    canPark: true,
    canSlew: true,
    canSync: true,
    canPulseGuide: true,
    canSetTrackingRate: true,
  );

  @override
  Future<void> mountFindHome(String deviceId) async {
    findHomeCalls.add(deviceId);
  }

  @override
  Future<void> mountPark(String deviceId) async {
    parkCalls.add(deviceId);
  }

  @override
  Future<void> mountUnpark(String deviceId) async {
    unparkCalls.add(deviceId);
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
