// POST /api/mount/set-park stores the mount's park position without moving
// it, and POST /api/sequencer/request-meridian-flip carries a remote client's
// "flip now" to the running sequence, answering 409 with the run's reason when
// the flip cannot run.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:skotiq_desktop/headless_api/routes/device_routes.dart';
import 'package:skotiq_desktop/headless_api/routes/headless_route.dart';
import 'package:skotiq_desktop/headless_api/routes/sequencer_routes.dart';

import 'handler_test_helpers.dart';

class _MockSequencerBackend extends Mock implements SequencerBackend {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('POST /api/mount/set-park', () {
    late _SetParkBackend backend;
    late DeviceHandlers handlers;

    setUp(() {
      backend = _SetParkBackend();
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

    Future<(int, Map<String, Object?>)> setPark() async {
      final response = await translateHandlerErrors(
        handlers.handleMountSetPark(
          Request(
            'POST',
            Uri.parse('http://localhost/api/mount/set-park'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'deviceId': 'sim_mount_1'}),
          ),
        ),
      );
      final body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      return (response.statusCode, body);
    }

    test('200: an idle mount that can set park stores it', () async {
      final (status, body) = await setPark();

      expect(status, 200);
      expect(body['status'], 'park_set');
      expect(backend.setParkCalls, ['sim_mount_1']);
      expect(backend.parkCalls, isEmpty, reason: 'setting park never parks');
    });

    test('400: a driver that cannot set park is refused', () async {
      backend.canSetPark = false;

      final (status, body) = await setPark();

      expect(status, 400);
      expect(body['error'], 'capability_unsupported');
      expect(backend.setParkCalls, isEmpty);
    });

    test('409: a moving mount is refused', () async {
      backend.slewing = true;

      final (status, body) = await setPark();

      expect(status, 409);
      expect(body['error'], 'mount_slewing');
      expect(backend.setParkCalls, isEmpty);
    });

    test('is routed', () {
      final routes = buildDeviceRoutes(
        handlers,
      ).where((r) => r.method == HttpMethod.post).map((r) => r.path);
      expect(routes, contains('/api/mount/set-park'));
    });
  });

  group('POST /api/sequencer/request-meridian-flip', () {
    late _MockSequencerBackend backend;
    late SequencerHandlers handlers;

    setUp(() {
      backend = _MockSequencerBackend();
      final container = createHeadlessTestContainer(
        overrides: [sequencerBackendProvider.overrideWithValue(backend)],
      );
      addTearDown(container.dispose);
      handlers = SequencerHandlers(container);
    });

    Future<(int, Map<String, Object?>)> request() async {
      final response = await translateHandlerErrors(
        handlers.handleSequencerRequestMeridianFlip(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/request-meridian-flip'),
          ),
        ),
      );
      final body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      return (response.statusCode, body);
    }

    test('200: the request reaches the running sequence', () async {
      when(
        () => backend.sequencerRequestMeridianFlip(),
      ).thenAnswer((_) async {});

      final (status, body) = await request();

      expect(status, 200);
      expect(body['status'], 'flip_requested');
      verify(() => backend.sequencerRequestMeridianFlip()).called(1);
    });

    test('409: a refused request carries the run\'s reason', () async {
      when(() => backend.sequencerRequestMeridianFlip()).thenThrow(
        const bridge.SkotiqError.operationFailed(
          "'M31' has not crossed the meridian yet; it transits in about 20 min.",
        ),
      );

      final (status, body) = await request();

      expect(status, 409);
      expect(body['error'], 'flip_refused');
      expect(body['message'], contains('has not crossed the meridian'));
      expect(body['message'], isNot(contains('operationFailed')));
    });

    test('is routed', () {
      final routes = buildSequencerRoutes(
        handlers,
      ).where((r) => r.method == HttpMethod.post).map((r) => r.path);
      expect(routes, contains('/api/sequencer/request-meridian-flip'));
    });
  });
}

class _SetParkBackend extends DisconnectedBackend {
  bool canSetPark = true;
  bool slewing = false;
  final List<String> setParkCalls = [];
  final List<String> parkCalls = [];

  @override
  Future<MountCapabilities?> getMountCapabilities(String deviceId) async =>
      MountCapabilities(canSetPark: canSetPark, canPark: true);

  @override
  Future<MountStatus> getMountStatus(String deviceId) async => MountStatus(
    connected: true,
    tracking: true,
    slewing: slewing,
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
  Future<void> mountSetPark(String deviceId) async {
    setParkCalls.add(deviceId);
  }

  @override
  Future<void> mountPark(String deviceId) async {
    parkCalls.add(deviceId);
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
