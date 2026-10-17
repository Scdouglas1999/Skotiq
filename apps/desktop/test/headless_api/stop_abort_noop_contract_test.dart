import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/framing_handlers.dart';
import 'package:skotiq_desktop/headless_api/response_helpers.dart';
import 'package:shelf/shelf.dart';

/// Pins the shared stop/abort no-op contract (see [kWasRunningField]).
///
/// Every stop/abort endpoint answers 200 whether or not anything was running,
/// so the ONLY way a client can tell "I stopped something" from "there was
/// nothing to stop" is the `wasRunning` flag. Observed live before this
/// existed, with the camera idle:
///   POST /api/camera/abort -> 200 {"status":"aborted"}
/// which reads as "the exposure was stopped" when no exposure existed.
///
/// The `status` string is deliberately UNCHANGED in both branches: a consumer
/// audit found no client branching on it, and keeping it stable means no
/// pinned client can break on this change.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _AbortBackend backend;
  late DeviceHandlers handlers;

  setUp(() {
    backend = _AbortBackend();
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

  Request post(String path, Map<String, Object?> body) => Request(
    'POST',
    Uri.parse('http://localhost$path'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode(body),
  );

  Future<Map<String, Object?>> abort() async {
    final response = await handlers.handleCameraAbort(
      post('/api/camera/abort', {'deviceId': 'native:zwo:0'}),
    );
    expect(response.statusCode, 200, reason: 'stop/abort stays idempotent');
    return jsonDecode(await response.readAsString()) as Map<String, Object?>;
  }

  test('aborting an idle camera reports it did nothing', () async {
    backend.state = CameraState.idle;

    final body = await abort();

    expect(body[kWasRunningField], isFalse);
    expect(
      backend.abortCalls,
      isEmpty,
      reason: 'nothing was running, so the driver must not be actuated',
    );
    expect(body['message'], contains('nothing to abort'));
    // Unchanged for backward compatibility.
    expect(body['status'], 'aborted');
  });

  test('aborting a running exposure reports it stopped one', () async {
    backend.state = CameraState.exposing;

    final body = await abort();

    expect(body[kWasRunningField], isTrue);
    expect(backend.abortCalls, ['native:zwo:0']);
    expect(body['status'], 'aborted');
    expect(body.containsKey('message'), isFalse);
  });

  test('the two responses are distinguishable on a single field', () async {
    backend.state = CameraState.exposing;
    final ranBody = await abort();
    backend.state = CameraState.idle;
    final idleBody = await abort();

    expect(ranBody[kWasRunningField], isNot(idleBody[kWasRunningField]));
    // The whole point: `status` alone can NOT tell them apart, which is why
    // the boolean had to be added.
    expect(ranBody['status'], idleBody['status']);
  });

  for (final busy in [
    CameraState.exposing,
    CameraState.reading,
    CameraState.download,
  ]) {
    test('camera in $busy counts as running', () async {
      backend.state = busy;
      expect((await abort())[kWasRunningField], isTrue);
    });
  }

  test(
    'a faulted status read still aborts — fail safe, not just honest',
    () async {
      backend.throwOnStatus = true;

      final body = await abort();

      expect(
        backend.abortCalls,
        ['native:zwo:0'],
        reason:
            'refusing to abort because the precondition could not be confirmed '
            'would turn a truthfulness fix into a safety regression',
      );
      expect(body[kWasRunningField], isTrue);
    },
  );

  // /api/framing/abort-slew
  //
  // The `wasRunning: true` branch is pinned HERE rather than live because the
  // simulator mount completes a slew instantly — driven on the local instance,
  // `slewing` never reads true for a single sample at 50 ms — and the only
  // real mount available is on the rig, which is under a hard no-motion rule.
  // The `wasRunning: false` branch IS verified live; this covers the other.
  group('framing abort-slew', () {
    late _SlewBackend slewBackend;
    late FramingHandlers framing;

    setUp(() {
      slewBackend = _SlewBackend();
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, slewBackend),
          ),
        ],
      );
      addTearDown(container.dispose);
      framing = FramingHandlers(container);
    });

    Future<Map<String, Object?>> abortSlew() async {
      final response = await framing.handleAbortSlew(
        Request('POST', Uri.parse('http://localhost/api/framing/abort-slew')),
      );
      expect(response.statusCode, 200);
      return jsonDecode(await response.readAsString()) as Map<String, Object?>;
    }

    test('a mount that is not slewing reports it did nothing', () async {
      slewBackend.slewing = false;

      final body = await abortSlew();

      expect(body[kWasRunningField], isFalse);
      expect(
        slewBackend.abortCalls,
        isEmpty,
        reason: 'no motion to stop, so the mount must not be commanded',
      );
      expect(body['message'], contains('not slewing'));
      expect(body['status'], 'aborted');
    });

    test('a slewing mount reports it stopped one', () async {
      slewBackend.slewing = true;

      final body = await abortSlew();

      expect(body[kWasRunningField], isTrue);
      expect(slewBackend.abortCalls, ['sim_mount_1']);
      expect(body['status'], 'aborted');
    });

    test('a faulted mount status read still aborts — fail safe', () async {
      slewBackend.throwOnStatus = true;

      final body = await abortSlew();

      expect(
        slewBackend.abortCalls,
        ['sim_mount_1'],
        reason:
            'never skip a mount abort because motion could not be confirmed',
      );
      expect(body[kWasRunningField], isTrue);
    });
  });
}

class _SlewBackend extends DisconnectedBackend {
  bool slewing = false;
  bool throwOnStatus = false;
  final List<String> abortCalls = [];

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async => const [
    DeviceInfo(
      id: 'sim_mount_1',
      name: 'Simulator mount 1',
      deviceType: DeviceType.mount,
      driverType: DriverType.simulator,
      description: 'Simulator device',
      driverVersion: '1.0',
    ),
  ];

  @override
  Future<MountStatus> getMountStatus(String deviceId) async {
    if (throwOnStatus) throw StateError('mount poll faulted');
    return MountStatus(
      connected: true,
      tracking: true,
      slewing: slewing,
      parked: false,
      atHome: false,
      sideOfPier: PierSide.west,
      rightAscension: 5.5,
      declination: 22.0,
      altitude: 40.0,
      azimuth: 3.7,
      siderealTime: 19.4,
      trackingRate: TrackingRate.sidereal,
      canPark: true,
      canSlew: true,
      canSync: true,
      canPulseGuide: true,
      canSetTrackingRate: true,
      availability: const {},
    );
  }

  @override
  Future<void> mountAbort(String deviceId) async {
    abortCalls.add(deviceId);
  }
}

class _AbortBackend extends DisconnectedBackend {
  CameraState state = CameraState.idle;
  bool throwOnStatus = false;
  final List<String> abortCalls = [];

  @override
  Future<CameraStatus> getCameraStatus(String deviceId) async {
    if (throwOnStatus) throw StateError('driver poll faulted');
    return CameraStatus(
      connected: true,
      state: state,
      sensorTemp: 14.8,
      coolerPower: 0,
      targetTemp: -10,
      coolerOn: false,
      gain: 100,
      offset: 30,
      binX: 1,
      binY: 1,
      sensorWidth: 4656,
      sensorHeight: 3520,
      pixelSizeX: 3.8,
      pixelSizeY: 3.8,
      maxAdu: 65520,
      canCool: true,
      canSetGain: true,
      canSetOffset: true,
    );
  }

  @override
  Future<void> cameraAbortExposure(String deviceId) async {
    abortCalls.add(deviceId);
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
