import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_desktop/headless_api/handlers/device_handlers.dart';
import 'package:nightshade_desktop/headless_api/job_manager.dart';
import 'package:nightshade_desktop/headless_api/validation.dart';
import 'package:shelf/shelf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cancelling an autofocus job propagates to the hardware backend',
    () async {
      final backend = _PendingAutofocusBackend();
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      final jobs = JobManager(emitEvent: (_) {});
      addTearDown(jobs.dispose);
      final handlers = DeviceHandlers(container, jobManager: jobs);

      final response = await handlers.handleAutofocusStart(
        Request(
          'POST',
          Uri.parse('http://localhost/api/focuser/autofocus/start'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'deviceId': 'native:focuser:1',
            'cameraId': 'native:camera:1',
            'exposureTime': 2.0,
            'stepSize': 50,
            'stepsOut': 4,
            'gain': 120,
            'offset': 18,
          }),
        ),
      );
      final body = jsonDecode(await response.readAsString()) as Map;
      final jobId = body['jobId'] as String;
      await _pumpUntil(() => jobs.get(jobId)?.state == JobState.running);
      expect(backend.gain, 120);
      expect(backend.offset, 18);

      final cancelResponse = await handlers.handleAutofocusCancel(
        Request(
          'POST',
          Uri.parse('http://localhost/api/focuser/autofocus/cancel'),
        ),
      );
      final cancelBody = jsonDecode(await cancelResponse.readAsString()) as Map;
      expect(cancelBody['status'], 'cancellation_requested');
      expect(cancelBody['jobIds'], [jobId]);

      await _pumpUntil(() => backend.cancelCalls == 1);
      // Cancellation is not terminal until the hardware sweep Future settles.
      expect(jobs.get(jobId)?.state, JobState.running);

      backend.pending.completeError(StateError('autofocus cancelled'));
      await _pumpUntil(() => jobs.get(jobId)?.state == JobState.cancelled);
      expect(backend.cancelCalls, 1);
      expect(jobs.get(jobId)?.error?['code'], 'job_cancelled');
    },
  );

  // Owner decision 2026-10-06: autofocus star selection is on. An API caller
  // that leaves it out gets the brightest 10 stars, the same as a profile
  // that never set it; counting every detection read the owner's in-focus
  // frame at 13.8 px instead of 3.2 px.
  test('an autofocus request that leaves star selection out uses the brightest '
      '10 stars', () async {
    final backend = _PendingAutofocusBackend();
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    final jobs = JobManager(emitEvent: (_) {});
    addTearDown(jobs.dispose);
    final handlers = DeviceHandlers(container, jobManager: jobs);

    final response = await handlers.handleAutofocusStart(
      Request(
        'POST',
        Uri.parse('http://localhost/api/focuser/autofocus/start'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'deviceId': 'native:focuser:1',
          'cameraId': 'native:camera:1',
          'exposureTime': 2.0,
          'stepSize': 50,
          'stepsOut': 4,
        }),
      ),
    );
    final body = jsonDecode(await response.readAsString()) as Map;
    final jobId = body['jobId'] as String;
    await _pumpUntil(() => jobs.get(jobId)?.state == JobState.running);
    expect(backend.useBrightestNStars, 10);

    backend.pending.completeError(StateError('test over'));
    await _pumpUntil(() => jobs.get(jobId)?.state != JobState.running);
  });

  group('focuser travel-range validation', () {
    // Checking only the lower bound lets an ASCOM focuser advertising
    // maxPosition 50000 accept `move-to 999999` with 200 {"status":"moving"},
    // and `move-relative delta 900000` runs the focuser for ~40s before the
    // driver silently clamps it at 50000.
    late _TravelBackend backend;
    late ProviderContainer container;
    late DeviceHandlers handlers;

    setUp(() {
      backend = _TravelBackend(position: 26000, maxPosition: 50000);
      container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);
      handlers = DeviceHandlers(container);
    });

    Future<Response> moveTo(int position) => handlers.handleFocuserMoveTo(
      Request(
        'POST',
        Uri.parse('http://localhost/api/focuser/move-to'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'deviceId': 'ascom:Sim.Focuser',
          'position': position,
        }),
      ),
    );

    Future<Response> moveRelative(int delta) =>
        handlers.handleFocuserMoveRelative(
          Request(
            'POST',
            Uri.parse('http://localhost/api/focuser/move-relative'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'deviceId': 'ascom:Sim.Focuser', 'delta': delta}),
          ),
        );

    test('absolute move beyond maxPosition is refused before the driver is '
        'touched', () async {
      await expectLater(
        moveTo(999999),
        throwsA(
          isA<BadRequestError>()
              .having((BadRequestError e) => e.field, 'field', 'position')
              .having(
                (BadRequestError e) => e.expected,
                'expected',
                '0 to 50000',
              ),
        ),
      );
      expect(backend.moveToCalls, isEmpty, reason: 'driver must not be called');
    });

    test('absolute move at the exact limit is allowed', () async {
      final response = await moveTo(50000);
      expect(response.statusCode, 200);
      expect(backend.moveToCalls, [50000]);
    });

    test('relative move whose resolved target overshoots is refused', () async {
      await expectLater(
        moveRelative(900000),
        throwsA(
          isA<BadRequestError>()
              .having((BadRequestError e) => e.field, 'field', 'delta')
              // The message must name the arithmetic so the operator can see
              // why a plausible-looking delta was rejected.
              .having(
                (BadRequestError e) => e.message,
                'message',
                contains('position 26000 + delta 900000'),
              ),
        ),
      );
      expect(backend.moveRelativeCalls, isEmpty);
    });

    test('relative move driving below zero is refused', () async {
      await expectLater(
        moveRelative(-30000),
        throwsA(
          isA<BadRequestError>().having(
            (BadRequestError e) => e.field,
            'field',
            'delta',
          ),
        ),
      );
      expect(backend.moveRelativeCalls, isEmpty);
    });

    test('in-range relative move still reaches the driver', () async {
      final response = await moveRelative(-500);
      expect(response.statusCode, 200);
      expect(backend.moveRelativeCalls, [-500]);
    });

    test(
      'a driver advertising no travel range is not second-guessed',
      () async {
        // maxPosition 0 means MaxStep threw PropertyNotImplementedException;
        // there is nothing to validate against, so the request passes through.
        backend.maxPosition = 0;
        final response = await moveTo(123456);
        expect(response.statusCode, 200);
        expect(backend.moveToCalls, [123456]);
      },
    );
  });
}

Future<void> _pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

class _PendingAutofocusBackend extends DisconnectedBackend {
  final Completer<AutofocusResult> pending = Completer<AutofocusResult>();
  int cancelCalls = 0;
  int? gain;
  int? offset;
  int? useBrightestNStars;

  @override
  Future<AutofocusResult> autofocusStart({
    required String deviceId,
    required String cameraId,
    required double exposureTime,
    required int stepSize,
    required int stepsOut,
    String method = 'VCurve',
    int binning = 1,
    int? gain,
    int? offset,
    String curveFitting = 'Hyperbolic',
    int numberOfAttempts = 1,
    int exposuresPerPoint = 1,
    double rSquaredThreshold = 0.7,
    double outerCropRatio = 1.0,
    double innerCropRatio = 0.0,
    int useBrightestNStars = 0,
    int focuserSettleTimeMs = 500,
    String backlashCompMethod = 'Overshoot',
    int backlashIn = 350,
    int backlashOut = 0,
    int? measuredBacklashIn,
  }) {
    this.gain = gain;
    this.offset = offset;
    this.useBrightestNStars = useBrightestNStars;
    return pending.future;
  }

  @override
  Future<void> autofocusCancel() async {
    cancelCalls++;
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, NightshadeBackend backend) {
    state = backend;
  }
}

/// Focuser backend that reports a fixed position/travel range and records the
/// move commands that actually reached the driver.
class _TravelBackend extends DisconnectedBackend {
  _TravelBackend({required this.position, required this.maxPosition});

  int position;
  int maxPosition;
  final List<int> moveToCalls = [];
  final List<int> moveRelativeCalls = [];

  @override
  Future<FocuserStatus> getFocuserStatus(String deviceId) async =>
      FocuserStatus(
        connected: true,
        position: position,
        moving: false,
        maxPosition: maxPosition,
        stepSize: 20.0,
        isAbsolute: true,
        hasTemperature: false,
      );

  @override
  Future<void> focuserMoveTo(String deviceId, int position) async {
    moveToCalls.add(position);
  }

  @override
  Future<void> focuserMoveRelative(String deviceId, int delta) async {
    moveRelativeCalls.add(delta);
  }
}
