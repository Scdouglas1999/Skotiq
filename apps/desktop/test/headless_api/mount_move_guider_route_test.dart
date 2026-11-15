import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/framing_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/planetarium_handlers.dart';

import 'handler_test_helpers.dart';

/// Every route that moves the mount goes through the host's mount commands,
/// which stop the guider first, and answers with what the guider did. A GoTo
/// the guider's silence refused is a 409 `guider_not_answering` until the
/// caller sends `guiderSilentOk`; a park and a home go ahead with a notice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MoveBackend backend;
  late ProviderContainer container;

  setUp(() {
    backend = _MoveBackend();
    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<(int, Map<String, Object?>)> post(
    Future<Response> Function(Request) handler,
    Map<String, Object?> body,
  ) async {
    final response = await translateHandlerErrors(
      handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/test'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(body),
        ),
      ),
    );
    return (
      response.statusCode,
      jsonDecode(await response.readAsString()) as Map<String, Object?>,
    );
  }

  const target = {'ra': 5.5, 'dec': 22.0};
  const mountTarget = {'deviceId': 'sim_mount_1', ...target};

  Map<String, Future<Response> Function(Request)> goToRoutes() => {
    'mount slew': DeviceHandlers(container).handleMountSlew,
    'framing slew': FramingHandlers(container).handleSlewToTarget,
    'planetarium slew': PlanetariumHandlers(container).handleSlewTo,
  };

  test('a GoTo says the guider was stopped for it', () async {
    backend.guider = GuiderForMove.stopped;
    for (final MapEntry(key: name, value: route) in goToRoutes().entries) {
      final (status, body) = await post(route, mountTarget);
      expect(status, 200, reason: name);
      expect(body['guider'], 'stopped', reason: name);
      expect(body.containsKey('notice'), isFalse, reason: name);
    }
    expect(backend.slews, [false, false, false]);
  });

  test('a GoTo with the guider not answering is a typed refusal', () async {
    backend.guider = GuiderForMove.unanswered;
    for (final MapEntry(key: name, value: route) in goToRoutes().entries) {
      final (status, body) = await post(route, mountTarget);
      expect(status, 409, reason: name);
      expect(body['error'], 'guider_not_answering', reason: name);
      expect(body['message'], contains('guiderSilentOk'), reason: name);
    }
  });

  test(
    'a GoTo that accepts a silent guider moves and carries the notice',
    () async {
      backend.guider = GuiderForMove.unanswered;
      for (final MapEntry(key: name, value: route) in goToRoutes().entries) {
        final (status, body) = await post(route, {
          ...mountTarget,
          'guiderSilentOk': true,
        });
        expect(status, 200, reason: name);
        expect(body['guider'], 'not_answering', reason: name);
        expect(body['notice'], contains('did not answer'), reason: name);
      }
      expect(backend.slews, [true, true, true]);
    },
  );

  test('a park and a home go ahead with the guider not answering', () async {
    backend.guider = GuiderForMove.unanswered;
    final device = DeviceHandlers(container);
    final routes = {
      'mount park': device.handleMountPark,
      'framing park': FramingHandlers(container).handleParkMount,
      'mount home': device.handleMountHome,
    };
    for (final MapEntry(key: name, value: route) in routes.entries) {
      final (status, body) = await post(route, {'deviceId': 'sim_mount_1'});
      expect(status, 200, reason: name);
      expect(body['guider'], 'not_answering', reason: name);
      expect(body['notice'], contains('did not answer'), reason: name);
    }
    expect(backend.parks, 2);
    expect(backend.homes, 1);
  });
}

/// A host whose guider is in one condition. A GoTo is refused for a silent
/// guider unless the caller accepted it, as the native command does.
class _MoveBackend extends DisconnectedBackend {
  GuiderForMove guider = GuiderForMove.idle;
  final List<bool> slews = [];
  int parks = 0;
  int homes = 0;

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async => const [
    DeviceInfo(
      id: 'sim_mount_1',
      name: 'Simulated Mount',
      deviceType: DeviceType.mount,
      driverType: DriverType.simulator,
      description: '',
      driverVersion: '',
    ),
  ];

  @override
  Future<MountCapabilities?> getMountCapabilities(String deviceId) async =>
      const MountCapabilities(canFindHome: true, canPark: true);

  @override
  Future<MountStatus> getMountStatus(String deviceId) async =>
      const MountStatus(
        connected: true,
        tracking: true,
        slewing: false,
        parked: false,
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
  Future<GuiderForMove> mountSlewToCoordinates(
    String deviceId,
    double ra,
    double dec, {
    bool guiderSilentOk = false,
  }) async {
    if (guider == GuiderForMove.unanswered && !guiderSilentOk) {
      throw const GuiderNotAnsweringException('PHD2 timed out');
    }
    slews.add(guiderSilentOk);
    return guider;
  }

  @override
  Future<GuiderForMove> mountPark(
    String deviceId, {
    bool forSafety = false,
  }) async {
    parks++;
    return guider;
  }

  @override
  Future<GuiderForMove> mountFindHome(String deviceId) async {
    homes++;
    return guider;
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
