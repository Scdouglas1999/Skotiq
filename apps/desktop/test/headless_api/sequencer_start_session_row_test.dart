import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_error;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// The `load -> start` path the appliance uses re-implements a subset of
/// `SequenceExecutor.start()`, so it must carry both host-side steps that make
/// a night reviewable: open the `imaging_sessions` row, and subscribe to the
/// native event stream that turns a captured frame into a `captured_images`
/// row. Missing either leaves frames on disk with no database record.
///
/// These tests pin both halves at the seam. They fail if either is removed.
class _MockSequencerBackend extends Mock implements SequencerBackend {}

class _MockDeviceBackend extends Mock implements DeviceBackend {}

/// The same appliance the role providers above stand for, seen whole.
///
/// `sequencerBackendProvider` and `deviceBackendProvider` are both narrowings
/// of `backendProvider`, so a container that overrides only the narrow ones
/// leaves the wide one pointing at the real FFI backend — a host that answers
/// the handler and throws at the executor, which no appliance does. The start
/// path reaches the wide provider through `sequenceExecutorProvider` for the
/// run row and for the runtime-config seed, so the fake host has to exist
/// there too. Unstubbed members answer with a completed `Future<void>`, the
/// shape every push on that path has.
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

/// One wired host per container: the event stream the executor subscribes to
/// has to be a real Stream, not the permissive `Future<void>` fallback.
_MockHostBackend _wiredHost() {
  final host = _MockHostBackend();
  when(() => host.eventStream).thenAnswer((_) => const Stream.empty());
  when(() => host.polarAlignmentEvents).thenAnswer((_) => const Stream.empty());
  return host;
}

SequencerStatus _status(String state) =>
    SequencerStatus(state: state, progress: 0.0);

/// A minimal serialized `SequenceDefinition`, shaped exactly as the Rust
/// executor deserializes it: `TargetHeader` -> `Loop{Count,2}` ->
/// `TakeExposure{count:5}`. Ten planned frames, which is the number the session
/// progress bar has to divide by.
String _wireSequence({
  String name = 'M42 Overnight',
  double raHours = 5.588,
  double decDegrees = -5.391,
}) => jsonEncode({
  'id': 'seq-1',
  'name': name,
  'root_node_id': 'target-1',
  'nodes': [
    {
      'id': 'target-1',
      'name': name,
      'enabled': true,
      'children': ['loop-1'],
      'node_type': {
        'type': 'TargetHeader',
        'target_name': name,
        'ra_hours': raHours,
        'dec_degrees': decDegrees,
        'priority': 0,
      },
    },
    {
      'id': 'loop-1',
      'name': 'Repeat',
      'enabled': true,
      'children': ['expose-1'],
      'node_type': {'type': 'Loop', 'iterations': 2, 'condition': 'Count'},
    },
    {
      'id': 'expose-1',
      'name': 'Lum 120s',
      'enabled': true,
      'children': <String>[],
      'node_type': {
        'type': 'TakeExposure',
        'duration_secs': 120.0,
        'count': 5,
        'filter': 'Lum',
        'binning': {'x': 1, 'y': 1},
      },
    },
  ],
});

/// The Rust `collect_required_devices` walk gates the five roles
/// `sequencerSetDevices` carries; the guider, dome and cover calibrator are
/// reached through `device_ops` with no id, so that walk structurally cannot
/// see them and a `Dither`, `StartGuiding` or `CalibratorOn` node answers
/// `200 {"status":"started"}` and then fails mid-run. The host is the only
/// place that knows what is connected.
String _wireWith(
  String nodeType, {
  String name = 'The Step',
  bool enabled = true,
}) => jsonEncode({
  'id': 'seq-role',
  'name': 'Role Preflight',
  'root_node_id': 'target-1',
  'nodes': [
    {
      'id': 'target-1',
      'name': 'M42',
      'enabled': true,
      'children': ['step-1'],
      'node_type': {
        'type': 'TargetHeader',
        'target_name': 'M42',
        'ra_hours': 5.588,
        'dec_degrees': -5.391,
        'priority': 0,
      },
    },
    {
      'id': 'step-1',
      'name': name,
      'enabled': enabled,
      'children': <String>[],
      'node_type': {'type': nodeType},
    },
  ],
});

void main() {
  group('headless load->start opens the run\'s session row', () {
    late _MockSequencerBackend sequencer;
    late _MockDeviceBackend devices;
    late ProviderContainer container;
    late SequencerHandlers handlers;

    setUp(() {
      sequencer = _MockSequencerBackend();
      devices = _MockDeviceBackend();

      when(() => sequencer.sequencerLoadJson(any())).thenAnswer((_) async {});
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
      when(() => devices.getConnectedDevices()).thenAnswer((_) async => []);

      container = createHeadlessTestContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, _wiredHost()),
          ),
          sequencerBackendProvider.overrideWithValue(sequencer),
          deviceBackendProvider.overrideWithValue(devices),
        ],
      );
      addTearDown(container.dispose);
      handlers = SequencerHandlers(container);
    });

    Future<Response> load(String json) => translateHandlerErrors(
      handlers.handleSequencerLoad(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sequencer/load'),
          body: jsonEncode({'json': json}),
        ),
      ),
    );

    Future<Response> start() => translateHandlerErrors(
      handlers.handleSequencerStart(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sequencer/start'),
          body: jsonEncode({}),
        ),
      ),
    );

    test(
      'a session row exists before the native executor is told to go',
      () async {
        expect(
          container.read(currentSequenceProvider),
          isNull,
          reason: 'this must be the bare headless branch, not the editor one',
        );
        expect(container.read(sessionStateProvider).isActive, isFalse);

        expect((await load(_wireSequence())).statusCode, 200);
        expect((await start()).statusCode, 200);

        final session = container.read(sessionStateProvider);
        expect(
          session.dbSessionId,
          isNotNull,
          reason:
              'without a session row every frame this run captures is stamped '
              'session_id NULL and the night is unreviewable',
        );
        expect(session.dbSessionId, greaterThan(0));
        expect(session.isActive, isTrue);
      },
    );

    test(
      'the row carries the sequence name and its single target\'s pointing',
      () async {
        await load(_wireSequence());
        await start();

        final session = container.read(sessionStateProvider);
        expect(session.targetName, 'M42 Overnight');
        expect(session.targetRa, closeTo(5.588, 1e-9));
        expect(session.targetDec, closeTo(-5.391, 1e-9));
      },
    );

    test('the planned frame count applies the loop multiplier', () async {
      await load(_wireSequence());
      await start();

      expect(
        container.read(sessionStateProvider).totalExposures,
        10,
        reason:
            '5 exposures inside a 2-iteration Count loop. A denominator of 5 '
            'would show the run at 100% halfway through the night',
      );
    });

    test('a multi-target sequence records no single pointing', () async {
      // Mirrors `_startSessionRow`: with more than one TargetHeader there is no
      // one direction to label the session with, and picking the first would
      // name a target the run may never reach.
      final twoTargets = jsonEncode({
        'id': 'seq-2',
        'name': 'Two Target Night',
        'root_node_id': 'root',
        'nodes': [
          {
            'id': 'root',
            'name': 'Night',
            'enabled': true,
            'children': ['t1', 't2'],
            'node_type': {
              'type': 'Loop',
              'iterations': 1,
              'condition': 'Count',
            },
          },
          for (final t in const [
            ('t1', 'M42', 5.588, -5.391),
            ('t2', 'M31', 0.712, 41.269),
          ])
            {
              'id': t.$1,
              'name': t.$2,
              'enabled': true,
              'children': <String>[],
              'node_type': {
                'type': 'TargetHeader',
                'target_name': t.$2,
                'ra_hours': t.$3,
                'dec_degrees': t.$4,
                'priority': 0,
              },
            },
        ],
      });

      await load(twoTargets);
      await start();

      final session = container.read(sessionStateProvider);
      expect(session.dbSessionId, isNotNull);
      expect(session.targetName, 'Two Target Night');
      expect(session.targetRa, isNull);
      expect(session.targetDec, isNull);
    });

    test(
      'the host is listening for the run\'s frame events before it starts',
      () async {
        // The half that actually writes `captured_images`. Thirty frames
        // reached disk on the rig with nobody subscribed; the eight that were
        // registered came from the resume path, which is the only other place
        // this subscription is installed.
        final executor = container.read(sequenceExecutorProvider);
        expect(executor.isListeningToNativeEventsForTest, isFalse);

        await load(_wireSequence());
        await start();

        expect(
          executor.isListeningToNativeEventsForTest,
          isTrue,
          reason:
              'with no subscription the night is written to disk and never '
              'reaches the database',
        );
      },
    );

    test(
      'a start with no prior load still runs, without a session row',
      () async {
        // A caller that starts whatever tree the executor already holds gets no
        // summary to label a row with. That must not cost it the run: frames on
        // disk beat a refusal.
        expect((await start()).statusCode, 200);
        verify(() => sequencer.sequencerStart()).called(1);
        expect(container.read(sessionStateProvider).dbSessionId, isNull);
      },
    );

    test('the second run of the night opens its own row', () async {
      // The appliance runs all night, one target after another.
      // `SessionService` refuses to open a second session while one is
      // active, so without closing the previous one every later target's
      // frames would be filed under the FIRST target's session — registered,
      // and registered against the wrong night.
      when(
        () => sequencer.sequencerGetStatus(),
      ).thenAnswer((_) async => _status('completed'));

      await load(_wireSequence(name: 'First Target'));
      await start();
      final first = container.read(sessionStateProvider).dbSessionId;

      await load(
        _wireSequence(name: 'Second Target', raHours: 20.0, decDegrees: 30.0),
      );
      await start();
      final second = container.read(sessionStateProvider);

      expect(second.dbSessionId, isNotNull);
      expect(second.dbSessionId, isNot(first));
      expect(second.targetName, 'Second Target');
    });

    test('a start refused as busy leaves the running session alone', () async {
      // The stale-session close must never fire against a live run. Here the
      // native executor is still running: ending its session on the way to the
      // 409 would strand the run in progress with nothing to attribute its
      // remaining frames to.
      when(
        () => sequencer.sequencerGetStatus(),
      ).thenAnswer((_) async => _status('running'));

      await load(_wireSequence(name: 'The Run In Progress'));
      await start();
      final live = container.read(sessionStateProvider);
      expect(live.dbSessionId, isNotNull);

      await load(_wireSequence(name: 'An Interloper'));
      await start();

      final after = container.read(sessionStateProvider);
      expect(after.dbSessionId, live.dbSessionId);
      expect(after.isActive, isTrue);
      expect(after.targetName, 'The Run In Progress');
    });
  });

  group('the guider, dome and cover calibrator get the pre-flight the native '
      'walk cannot give them', () {
    late _MockSequencerBackend sequencer;
    late _MockDeviceBackend devices;
    late ProviderContainer container;
    late SequencerHandlers handlers;

    setUp(() {
      sequencer = _MockSequencerBackend();
      devices = _MockDeviceBackend();
      when(() => sequencer.sequencerLoadJson(any())).thenAnswer((_) async {});
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
      when(() => devices.getConnectedDevices()).thenAnswer((_) async => []);

      container = createHeadlessTestContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, _wiredHost()),
          ),
          sequencerBackendProvider.overrideWithValue(sequencer),
          deviceBackendProvider.overrideWithValue(devices),
        ],
      );
      addTearDown(container.dispose);
      handlers = SequencerHandlers(container);
    });

    Future<Response> loadAndStart(String json) async {
      await translateHandlerErrors(
        handlers.handleSequencerLoad(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/load'),
            body: jsonEncode({'json': json}),
          ),
        ),
      );
      return translateHandlerErrors(
        handlers.handleSequencerStart(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/start'),
            body: jsonEncode({}),
          ),
        ),
      );
    }

    void connect(List<DeviceType> types) {
      when(() => devices.getConnectedDevices()).thenAnswer(
        (_) async => [
          for (final t in types)
            DeviceInfo(
              id: 'sim_${t.name}',
              name: t.name,
              deviceType: t,
              driverType: DriverType.simulator,
              description: t.name,
              driverVersion: '1.0',
            ),
        ],
      );
    }

    for (final (nodeType, role, phrase) in const [
      ('Dither', DeviceType.guider, 'guides or dithers'),
      ('StartGuiding', DeviceType.guider, 'guides or dithers'),
      ('OpenDome', DeviceType.dome, 'moves the dome'),
      ('CalibratorOn', DeviceType.coverCalibrator, 'cover or flat panel'),
    ]) {
      test(
        '$nodeType is refused at Start when no ${role.name} is connected',
        () async {
          final response = await loadAndStart(_wireWith(nodeType));

          expect(
            response.statusCode,
            400,
            reason:
                'the rig answered 200 {"status":"started"} and then died mid-run',
          );
          final body =
              jsonDecode(await response.readAsString()) as Map<String, dynamic>;
          expect(body['error'], 'preflight_rejected');
          expect(body['message'], contains(phrase));
          expect(body['missingDevices'], contains(role.name));
          verifyNever(() => sequencer.sequencerStart());
        },
      );
    }

    test('the same sequence starts once the device is connected', () async {
      connect([DeviceType.guider]);

      expect((await loadAndStart(_wireWith('Dither'))).statusCode, 200);
      verify(() => sequencer.sequencerStart()).called(1);
    });

    test('a disabled node does not block the run', () async {
      // The executor returns Skipped before it descends, so a disabled branch
      // never reaches hardware and must never cost the operator a night.
      expect(
        (await loadAndStart(_wireWith('Dither', enabled: false))).statusCode,
        200,
      );
      verify(() => sequencer.sequencerStart()).called(1);
    });

    test('StopGuiding alone is not a reason to refuse', () async {
      // Stopping a guider that was never started is a no-op.
      expect((await loadAndStart(_wireWith('StopGuiding'))).statusCode, 200);
    });

    test(
      'a device-listing failure does not become a new way to lose a night',
      () async {
        when(
          () => devices.getConnectedDevices(),
        ).thenThrow(StateError('device manager unavailable'));

        expect((await loadAndStart(_wireWith('Dither'))).statusCode, 200);
        verify(() => sequencer.sequencerStart()).called(1);
      },
    );
  });

  /// A `load` that fails on a missing field must leave no session row behind.
  /// Unguarded, the next `start` answers `409 no_sequence_loaded` while
  /// `GET /api/sessions` shows **a session named after a sequence from twenty
  /// minutes earlier, zero exposures, status completed** — a night that never
  /// happened, labelled with the wrong sequence.
  group('a refused start leaves no session behind', () {
    late _MockSequencerBackend sequencer;
    late _MockDeviceBackend devices;
    late ProviderContainer container;
    late SequencerHandlers handlers;

    setUp(() {
      sequencer = _MockSequencerBackend();
      devices = _MockDeviceBackend();
      when(() => sequencer.sequencerLoadJson(any())).thenAnswer((_) async {});
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
      when(() => devices.getConnectedDevices()).thenAnswer((_) async => []);
      when(
        () => sequencer.sequencerGetStatus(),
      ).thenAnswer((_) async => _status('idle'));

      container = createHeadlessTestContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, _wiredHost()),
          ),
          sequencerBackendProvider.overrideWithValue(sequencer),
          deviceBackendProvider.overrideWithValue(devices),
        ],
      );
      addTearDown(container.dispose);
      handlers = SequencerHandlers(container);
    });

    Future<Response> load(String json) => translateHandlerErrors(
      handlers.handleSequencerLoad(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sequencer/load'),
          body: jsonEncode({'json': json}),
        ),
      ),
    );

    Future<Response> start() => translateHandlerErrors(
      handlers.handleSequencerStart(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sequencer/start'),
          body: jsonEncode({}),
        ),
      ),
    );

    test('the native executor refusing the start closes the row', () async {
      await load(_wireSequence());
      when(() => sequencer.sequencerStart()).thenThrow(
        const bridge_error.SkotiqError.operationFailed(
          'Failed to start sequence: No sequence loaded',
        ),
      );

      final response = await start();
      expect(response.statusCode, 409);

      final session = container.read(sessionStateProvider);
      expect(
        session.isActive,
        isFalse,
        reason:
            'a run the executor refused must not appear in the session list '
            'as a night that happened',
      );
    });

    test('a failed load drops the previous sequence summary', () async {
      // The other half of the rig case: the summary that labelled the phantom
      // session came from a load twenty minutes earlier, because the FAILED
      // load in between left it in place.
      await load(_wireSequence(name: 'Twenty Minutes Ago'));
      when(
        () => sequencer.sequencerLoadJson(any()),
      ).thenThrow(StateError('missing field `auto_select_star`'));

      await expectLater(
        load(_wireSequence(name: 'The One That Failed')),
        completion(isA<Response>()),
      );

      // Whatever the next start does, it must not name itself after a
      // sequence that is no longer loaded.
      await start();
      final session = container.read(sessionStateProvider);
      expect(session.targetName, isNot('Twenty Minutes Ago'));
      expect(session.dbSessionId, isNull);
    });

    test('a validator-rejected load drops it too', () async {
      await load(_wireSequence(name: 'Still Loaded?'));

      // RA 0h / Dec 0deg is the unset-target sentinel the wire validator
      // blocks, so this load is rejected before it reaches the executor.
      final rejected = await load(
        _wireSequence(name: 'Unset', raHours: 0.0, decDegrees: 0.0),
      );
      expect(rejected.statusCode, 400);

      await start();
      expect(
        container.read(sessionStateProvider).targetName,
        isNot('Still Loaded?'),
      );
    });
  });

  /// Restart the appliance with the capture folder already configured, and
  /// without the restore:
  ///
  /// ```
  /// GET  /api/system/disk-space -> {"configured": true, "path": "C:\\", ...}
  /// POST /api/sequencer/start   -> 400 preflight_rejected
  ///        "... no image save path is configured ..."
  /// ```
  ///
  /// The native save path is per-process; imageOutputPath is durable. On an
  /// unattended rig any restart therefore costs the night, and the refusal
  /// names a setting the operator has already set.
  group('a restart does not lose the configured capture folder', () {
    late _MockSequencerBackend sequencer;
    late _MockDeviceBackend devices;
    late ProviderContainer container;
    late SequencerHandlers handlers;

    setUp(() {
      sequencer = _MockSequencerBackend();
      devices = _MockDeviceBackend();
      when(() => sequencer.sequencerLoadJson(any())).thenAnswer((_) async {});
      when(
        () => sequencer.sequencerSetSavePath(any()),
      ).thenAnswer((_) async {});
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
      when(() => devices.getConnectedDevices()).thenAnswer((_) async => []);
      when(
        () => sequencer.sequencerGetStatus(),
      ).thenAnswer((_) async => _status('idle'));

      container = createHeadlessTestContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, _wiredHost()),
          ),
          sequencerBackendProvider.overrideWithValue(sequencer),
          deviceBackendProvider.overrideWithValue(devices),
        ],
      );
      addTearDown(container.dispose);
      handlers = SequencerHandlers(container);
    });

    Future<void> start() async {
      await translateHandlerErrors(
        handlers.handleSequencerLoad(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/load'),
            body: jsonEncode({'json': _wireSequence()}),
          ),
        ),
      );
      await translateHandlerErrors(
        handlers.handleSequencerStart(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sequencer/start'),
            body: jsonEncode({}),
          ),
        ),
      );
    }

    test('start pushes the durable capture folder into the executor', () async {
      // A process that never saw POST /api/sequencer/save-path, exactly as
      // after a restart.
      await container.read(appSettingsProvider.future);
      await container
          .read(appSettingsProvider.notifier)
          .setImageOutputPath('/captures/tonight');

      await start();

      verify(
        () => sequencer.sequencerSetSavePath('/captures/tonight'),
      ).called(1);
    });

    test('an unconfigured folder pushes nothing, rather than null', () async {
      // Pushing null would clobber a checkpoint-restored path with
      // "don't save" — the same guard _startNativeExecution keeps.
      await start();

      verifyNever(() => sequencer.sequencerSetSavePath(any()));
    });
  });
}
