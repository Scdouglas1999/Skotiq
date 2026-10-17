import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_error;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// The headless `load -> start` path must call `sequencerSetDevices`. Without
/// it the native executor's `camera_id` stays null and the run sits in
/// `recovering / "Device disconnected"` capturing nothing, while
/// `/api/devices/connected` lists the camera. No equipment profile is
/// involved: the ids come from the connected-device list.
class _MockSequencerBackend extends Mock implements SequencerBackend {}

class _MockDeviceBackend extends Mock implements DeviceBackend {}

/// The same appliance the role providers above stand for, seen whole.
///
/// `sequencerBackendProvider` and `deviceBackendProvider` are both narrowings
/// of `backendProvider`, so a container that overrides only the narrow ones
/// leaves the wide one pointing at the real FFI backend — a host that answers
/// the handler and throws at the executor, which no appliance does. The start
/// path reaches the wide provider through `sequenceExecutorProvider` to seed
/// the run's runtime config, so the fake host has to exist there too.
/// Unstubbed members answer with a completed `Future<void>`, the shape every
/// push on that path has.
class _MockHostBackend extends Mock implements SkotiqBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation) ?? Future<void>.value();
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

DeviceInfo _device(String id, DeviceType type) => DeviceInfo(
  id: id,
  name: id,
  deviceType: type,
  driverType: DriverType.ascom,
  description: 'ASCOM driver: $id',
  driverVersion: '1.0',
);

void main() {
  group('headless load->start device wiring', () {
    late _MockSequencerBackend sequencer;
    late _MockDeviceBackend devices;
    late _MockHostBackend host;
    late ProviderContainer container;
    late SequencerHandlers handlers;

    setUp(() {
      sequencer = _MockSequencerBackend();
      devices = _MockDeviceBackend();
      host = _MockHostBackend();
      when(() => host.eventStream).thenAnswer((_) => const Stream.empty());
      when(
        () => host.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());

      when(
        () => sequencer.sequencerSetSimulationMode(any()),
      ).thenAnswer((_) async {});
      when(
        () => sequencer.sequencerSetSafetyFailMode(any()),
      ).thenAnswer((_) async {});
      when(
        () => sequencer.sequencerSetDevices(
          cameraId: any(named: 'cameraId'),
          mountId: any(named: 'mountId'),
          focuserId: any(named: 'focuserId'),
          filterwheelId: any(named: 'filterwheelId'),
          rotatorId: any(named: 'rotatorId'),
          filterNames: any(named: 'filterNames'),
          filterFocusOffsets: any(named: 'filterFocusOffsets'),
        ),
      ).thenAnswer((_) async {});
      when(() => sequencer.sequencerStart()).thenAnswer((_) async {});

      container = createHeadlessTestContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, host),
          ),
          sequencerBackendProvider.overrideWithValue(sequencer),
          deviceBackendProvider.overrideWithValue(devices),
        ],
      );
      addTearDown(container.dispose);
      handlers = SequencerHandlers(container);
    });

    Future<Response> start() => translateHandlerErrors(
      handlers.handleSequencerStart(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sequencer/start'),
          body: jsonEncode({}),
        ),
      ),
    );

    test('start pushes the connected camera into the native executor before '
        'starting the run', () async {
      // Exactly what the rig reported while the executor called the camera
      // disconnected.
      when(() => devices.getConnectedDevices()).thenAnswer(
        (_) async => [
          _device('ascom:ASCOM.ASICamera2.Camera', DeviceType.camera),
          _device('ascom:ASCOM.ASICAA.Rotator', DeviceType.rotator),
          _device('ascom:ASCOM.EFW2.FilterWheel', DeviceType.filterWheel),
          _device('ascom:ASCOM.EAF.Focuser', DeviceType.focuser),
          _device('ascom:ASCOM.PegasusAstroNYX101.Telescope', DeviceType.mount),
        ],
      );

      // No in-editor sequence => the bare headless load->start branch, which
      // is the branch that never wired devices.
      expect(container.read(currentSequenceProvider), isNull);

      final response = await start();
      expect(response.statusCode, 200);

      // Ordering is the whole point: ids pushed after the run began would
      // not save it, because the first TakeExposure has already failed. The
      // ids themselves are captured from the same in-order verification, so
      // "wired" and "wired first" are proven by one assertion.
      final results = verifyInOrder([
        () => sequencer.sequencerSetDevices(
          cameraId: captureAny(named: 'cameraId'),
          mountId: captureAny(named: 'mountId'),
          focuserId: captureAny(named: 'focuserId'),
          filterwheelId: captureAny(named: 'filterwheelId'),
          rotatorId: captureAny(named: 'rotatorId'),
          filterNames: any(named: 'filterNames'),
          filterFocusOffsets: any(named: 'filterFocusOffsets'),
        ),
        () => sequencer.sequencerStart(),
      ]);

      expect(
        results.first.captured,
        [
          'ascom:ASCOM.ASICamera2.Camera',
          'ascom:ASCOM.PegasusAstroNYX101.Telescope',
          'ascom:ASCOM.EAF.Focuser',
          'ascom:ASCOM.EFW2.FilterWheel',
          'ascom:ASCOM.ASICAA.Rotator',
        ],
        reason:
            'the executor resolves hardware through these ids, so every '
            'connected device must reach it or the run recovers forever',
      );
    });

    test('a device-backend failure does not block the start; the native camera '
        'preflight is the backstop', () async {
      when(
        () => devices.getConnectedDevices(),
      ).thenThrow(StateError('device manager unavailable'));

      final response = await start();

      // The handler must not turn a device-listing hiccup into a 500. The
      // run either starts (devices already wired) or is refused by the
      // native camera preflight with an operator-facing reason.
      expect(response.statusCode, 200);
      verify(() => sequencer.sequencerStart()).called(1);
      verifyNever(
        () => sequencer.sequencerSetDevices(
          cameraId: any(named: 'cameraId'),
          mountId: any(named: 'mountId'),
          focuserId: any(named: 'focuserId'),
          filterwheelId: any(named: 'filterwheelId'),
          rotatorId: any(named: 'rotatorId'),
          filterNames: any(named: 'filterNames'),
          filterFocusOffsets: any(named: 'filterFocusOffsets'),
        ),
      );
    });

    test('a rig with no camera connected pushes a null camera id', () async {
      // The executor must be told the truth — null — so its camera preflight
      // refuses the run at Start instead of the run discovering it mid-night.
      when(() => devices.getConnectedDevices()).thenAnswer(
        (_) async => [_device('ascom:ASCOM.EAF.Focuser', DeviceType.focuser)],
      );

      await start();

      verify(
        () => sequencer.sequencerSetDevices(
          cameraId: null,
          mountId: null,
          focuserId: 'ascom:ASCOM.EAF.Focuser',
          filterwheelId: null,
          rotatorId: null,
          filterNames: any(named: 'filterNames'),
          filterFocusOffsets: any(named: 'filterFocusOffsets'),
        ),
      ).called(1);
    });

    /// The start-time wiring rebuilds all five ids from the connected-device
    /// list. Reproduced against the Linux appliance (release bundle, headless,
    /// scratch DB) on 2026-08-09, that silently undid the one endpoint a
    /// headless-only operator has for assigning hardware:
    ///
    /// ```
    /// POST /api/sequencer/devices {"cameraId":"sim_camera_1"} -> {"status":"ok"}
    /// POST /api/sequencer/start
    ///   -> 400 {"error":"preflight_rejected",
    ///           "message":"... no camera is assigned to the run ..."}
    /// ```
    ///
    /// A camera was assigned; the appliance discarded it and then reported it
    /// missing.
    group('an explicit POST /api/sequencer/devices assignment survives start', () {
      Future<void> assign(Map<String, dynamic> body) async {
        await handlers.handleSequencerSetDevices(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/devices'),
            body: jsonEncode(body),
          ),
        );
      }

      test(
        'an assigned camera is kept when nothing of that type is connected',
        () async {
          when(() => devices.getConnectedDevices()).thenAnswer(
            (_) async => [
              _device(
                'ascom:ASCOM.PegasusAstroNYX101.Telescope',
                DeviceType.mount,
              ),
            ],
          );

          await assign({'cameraId': 'sim_camera_1'});
          expect((await start()).statusCode, 200);

          verify(
            () => sequencer.sequencerSetDevices(
              cameraId: 'sim_camera_1',
              mountId: 'ascom:ASCOM.PegasusAstroNYX101.Telescope',
              focuserId: null,
              filterwheelId: null,
              rotatorId: null,
              filterNames: any(named: 'filterNames'),
              filterFocusOffsets: any(named: 'filterFocusOffsets'),
            ),
          ).called(1);
        },
      );

      test('a connected device still wins over an older assignment', () async {
        when(() => devices.getConnectedDevices()).thenAnswer(
          (_) async => [
            _device('ascom:ASCOM.ASICamera2.Camera', DeviceType.camera),
          ],
        );

        await assign({'cameraId': 'stale-camera-from-an-earlier-rig'});
        await start();

        verify(
          () => sequencer.sequencerSetDevices(
            cameraId: 'ascom:ASCOM.ASICamera2.Camera',
            mountId: null,
            focuserId: null,
            filterwheelId: null,
            rotatorId: null,
            filterNames: any(named: 'filterNames'),
            filterFocusOffsets: any(named: 'filterFocusOffsets'),
          ),
        ).called(1);
      });

      test('an explicit clear is honoured, not resurrected', () async {
        when(() => devices.getConnectedDevices()).thenAnswer((_) async => []);

        await assign({'cameraId': 'sim_camera_1'});
        await assign({'cameraId': null});
        await start();

        // Three calls total: two assignments, then the wiring. The wiring must
        // push null — the caller withdrew the camera, and inventing one back
        // would start a run with hardware nobody assigned.
        verify(
          () => sequencer.sequencerSetDevices(
            cameraId: null,
            mountId: null,
            focuserId: null,
            filterwheelId: null,
            rotatorId: null,
            filterNames: any(named: 'filterNames'),
            filterFocusOffsets: any(named: 'filterFocusOffsets'),
          ),
        ).called(2);
      });

      test('the wiring never records its own result as an assignment', () async {
        // A camera that was connected for one run and unplugged before the next
        // must not survive as a phantom assignment: the pre-flight has to be
        // free to refuse the second run.
        when(() => devices.getConnectedDevices()).thenAnswer(
          (_) async => [
            _device('ascom:ASCOM.ASICamera2.Camera', DeviceType.camera),
          ],
        );
        await start();

        when(() => devices.getConnectedDevices()).thenAnswer((_) async => []);
        await start();

        verify(
          () => sequencer.sequencerSetDevices(
            cameraId: null,
            mountId: null,
            focuserId: null,
            filterwheelId: null,
            rotatorId: null,
            filterNames: any(named: 'filterNames'),
            filterFocusOffsets: any(named: 'filterFocusOffsets'),
          ),
        ).called(1);
      });
    });

    group('a native pre-flight refusal is a rejection, not a host fault', () {
      setUp(() {
        when(() => devices.getConnectedDevices()).thenAnswer((_) async => []);
      });

      /// Reproduced against the Linux appliance (release bundle, headless,
      /// scratch DB, `GET /api/profiles -> {"profiles":[]}`) on 2026-08-09:
      ///
      /// ```
      /// POST /api/sequencer/start -> HTTP 500
      ///   {"error":"internal_error","message":"Failed to start sequence: This
      ///    sequence captures frames but no camera is assigned to the run. ..."}
      /// ```
      ///
      /// The words were right and the status was a lie. A 5xx tells an
      /// unattended controller "the appliance broke, retry" about a condition
      /// no retry can clear.
      test(
        'the camera pre-flight comes back 400, not 500 internal_error',
        () async {
          when(() => sequencer.sequencerStart()).thenThrow(
            const bridge_error.SkotiqError.operationFailed(
              'Failed to start sequence: This sequence captures frames but no '
              'camera is assigned to the run. Connect a camera and assign it '
              'before starting — every exposure would otherwise fail and the run '
              'would sit in recovery waiting for a camera it was never given.',
            ),
          );

          final response = await start();
          final body =
              jsonDecode(await response.readAsString()) as Map<String, dynamic>;

          expect(response.statusCode, 400);
          expect(body['error'], 'preflight_rejected');
          expect(body['message'], contains('no camera is assigned'));
          expect(
            body['error'],
            isNot('internal_error'),
            reason:
                'a missing camera is the operator\'s to fix, not a host fault',
          );
        },
      );

      test('the same envelope carries the save-path refusal', () async {
        when(() => sequencer.sequencerStart()).thenThrow(
          const bridge_error.SkotiqError.operationFailed(
            'Failed to start sequence: This sequence captures frames but no '
            'save path is configured; every frame would otherwise be captured '
            'and discarded.',
          ),
        );

        final response = await start();
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;

        expect(response.statusCode, 400);
        expect(body['error'], 'preflight_rejected');
        expect(body['message'], contains('save path'));
      });

      test('a busy executor is 409, not 400 — the payload was fine', () async {
        when(() => sequencer.sequencerStart()).thenThrow(
          const bridge_error.SkotiqError.operationFailed(
            'Failed to start sequence: Cannot start: executor is Running',
          ),
        );

        final response = await start();
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;

        expect(response.statusCode, 409);
        expect(body['error'], 'sequencer_busy');
      });

      /// The guard must stay narrow. A failure in the SETUP calls that run
      /// before the native start is not a pre-flight refusal and must keep its
      /// old handling, or a genuine host fault would be relabelled a bad
      /// request and hidden from whoever has to fix it.
      test('a failure before the native start is not relabelled', () async {
        when(
          () => sequencer.sequencerSetSimulationMode(any()),
        ).thenThrow(StateError('bridge is gone'));

        final response = await start();
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;

        expect(response.statusCode, 500);
        expect(body['error'], 'internal_error');
        verifyNever(() => sequencer.sequencerStart());
      });
    });
  });
}
