import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_desktop/headless_api/handlers/depthlock_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/guiding_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:skotiq_desktop/headless_api/validation.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// The status and body the host answers for each native failure a handler
/// tells apart, pinned in `fixtures/native_failure_replies.json`.
///
/// These replies are published (OpenAPI, the dashboard, tools, rig scripts),
/// so the fixture is the contract: a change to how the native side reports a
/// failure changes [_failures] (what the producer raises), never the fixture.
/// `SKOTIQ_RECORD_REPLIES=1` rewrites the fixture.
final Map<String, Object> _failures = {
  // GET /api/guider/lock-position
  'lock.phd2_null': const bridge.SkotiqError.refused(
    kind: bridge.Refusal.noLockPosition,
    message:
        'Failed to get lock position: get_lock_position: expected array, got null',
  ),
  'lock.phd2_missing_x': const bridge.SkotiqError.refused(
    kind: bridge.Refusal.noLockPosition,
    message:
        'Failed to get lock position: get_lock_position: missing or non-numeric X',
  ),
  'lock.phd2_missing_y': const bridge.SkotiqError.refused(
    kind: bridge.Refusal.noLockPosition,
    message:
        'Failed to get lock position: get_lock_position: missing or non-numeric Y',
  ),
  'lock.phd2_not_array': const bridge.SkotiqError.operationFailed(
    'Failed to get lock position: get_lock_position: expected array, got 5',
  ),
  'lock.phd2_refused': const bridge.SkotiqError.operationFailed(
    'Failed to get lock position: PHD2 error: method not found',
  ),
  'lock.phd2_not_connected': const bridge.SkotiqError.notConnected('PHD2'),
  'lock.builtin_none': const bridge.SkotiqError.operationFailed(
    'No guide star is selected',
  ),
  'lock.dart_error': StateError('guider gone'),
  // GET /api/guider/star-image
  'star_image.phd2_no_star': const bridge.SkotiqError.refused(
    kind: bridge.Refusal.noStarSelected,
    message: 'Failed to get star image: PHD2 error: no star selected',
  ),
  'star_image.phd2_refused': const bridge.SkotiqError.operationFailed(
    'Failed to get star image: PHD2 error: camera not connected',
  ),
  'star_image.phd2_malformed': const bridge.SkotiqError.operationFailed(
    "Failed to get star image: get_star_image: missing or non-integer 'frame'",
  ),
  'star_image.builtin_busy': const bridge.SkotiqError.invalidState(
    'The guide camera is busy with the guiding loop.',
  ),
  'star_image.dart_error': StateError('no star selected'),
  // POST /api/guider/find-star
  'find_star.builtin_none': const bridge.SkotiqError.refused(
    kind: bridge.Refusal.noGuideStarFound,
    message: 'No guide star found',
  ),
  'find_star.phd2_refused': const bridge.SkotiqError.operationFailed(
    'Failed to find star: PHD2 error: could not find a suitable star',
  ),
  'find_star.phd2_not_connected': const bridge.SkotiqError.notConnected('PHD2'),
  'find_star.dart_no_star': Exception('No guide star found'),
  'find_star.dart_error': StateError('guider gone'),
  // POST /api/sequencer/start, the loaded-run path
  'start.not_idle': const bridge.SkotiqError.refused(
    kind: bridge.Refusal.executorNotIdle,
    message: 'Failed to start sequence: Cannot start: executor is Running',
  ),
  'start.not_idle_completed': const bridge.SkotiqError.refused(
    kind: bridge.Refusal.executorNotIdle,
    message: 'Failed to start sequence: Cannot start: executor is Completed',
  ),
  'start.no_sequence': const bridge.SkotiqError.refused(
    kind: bridge.Refusal.noSequenceLoaded,
    message: 'Failed to start sequence: No sequence loaded',
  ),
  'start.no_device_ops': const bridge.SkotiqError.operationFailed(
    'Failed to start sequence: No device operations configured. Call '
    'set_device_ops() before starting a sequence. This ensures all device '
    'operations use real hardware instead of silently doing nothing.',
  ),
  'start.no_save_path': const bridge.SkotiqError.operationFailed(
    'Failed to start sequence: This sequence captures frames but no save '
    'path is configured; every frame would otherwise be captured and '
    'discarded.',
  ),
  'start.internal': const bridge.SkotiqError.internal('Task panicked'),
  'start.dart_error': StateError('bridge is gone'),
  // GET /api/depthlock/goals/<id>
  'depthlock.not_found': const bridge.SkotiqError.refused(
    kind: bridge.Refusal.depthLockGoalNotFound,
    message: 'DepthLock goal m42-ha does not exist',
  ),
  'depthlock.stale': const bridge.SkotiqError.refused(
    kind: bridge.Refusal.depthLockStaleRevision,
    message: 'stale revision for DepthLock goal m42-ha',
  ),
  'depthlock.unavailable': const bridge.SkotiqError.refused(
    kind: bridge.Refusal.depthLockUnavailable,
    message:
        'DepthLock storage is not initialized; settings storage must be '
        'initialized first',
  ),
  'depthlock.removed': const bridge.SkotiqError.operationFailed(
    'DepthLock goal m42-ha was removed',
  ),
  'depthlock.invalid': const bridge.SkotiqError.operationFailed(
    'automaticCompletion requires enabled',
  ),
  'depthlock.raw_reference_missing': const bridge.SkotiqError.operationFailed(
    'Cannot read /data/m42/ref.cr2: /data/m42/ref.cr2 does not exist',
  ),
  'depthlock.fits_reference_missing': const bridge.SkotiqError.operationFailed(
    'Cannot read /data/m42/ref.fits: No such file or directory (os error 2)',
  ),
  'depthlock.io': const bridge.SkotiqError.ioError('disk gone'),
  'depthlock.dart_error': StateError('store gone'),
};

class _MockBackend extends Mock implements SkotiqBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// Raises [failure] from every call a row reaches.
class _FailingBackend extends DisconnectedBackend {
  _FailingBackend(this.failure);

  final Object failure;

  @override
  Future<(double, double)> guiderGetLockPosition() async => throw failure;

  @override
  Future<Phd2StarImage> guiderGetStarImage({int size = 50}) async =>
      throw failure;

  @override
  Future<(double, double)> guiderFindStar() async => throw failure;

  @override
  Future<DepthLockGoal> getDepthLockGoal(String goalId) async => throw failure;
}

class _MockSequencerBackend extends Mock implements SequencerBackend {}

class _MockDeviceBackend extends Mock implements DeviceBackend {}

class _MockHostBackend extends Mock implements SkotiqBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation) ?? Future<void>.value();
}

final _fixture = File('test/headless_api/fixtures/native_failure_replies.json');

Future<Map<String, Object?>> _reply(Future<Response> Function() call) async {
  final handler = errorTranslationMiddleware(
    logError: (_, {fields}) {},
    requestIdFor: (_) => 'test-request-id',
  )((_) => call());
  final response = await handler(
    Request('GET', Uri.parse('http://localhost/api/pin')),
  );
  return {
    'status': response.statusCode,
    'body': jsonDecode(await response.readAsString()),
  };
}

Future<Response> _guiding(String id, Object failure) {
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, _FailingBackend(failure)),
      ),
    ],
  );
  addTearDown(container.dispose);
  final handlers = GuidingHandlers(container);
  final route = id.split('.').first;
  return switch (route) {
    'lock' => handlers.handleGuiderGetLockPosition(
      Request('GET', Uri.parse('http://localhost/api/guider/lock-position')),
    ),
    'star_image' => handlers.handleGuiderGetStarImage(
      Request('GET', Uri.parse('http://localhost/api/guider/star-image')),
    ),
    'find_star' => handlers.handleGuiderFindStar(
      Request('POST', Uri.parse('http://localhost/api/guider/find-star')),
    ),
    _ => throw ArgumentError(id),
  };
}

Future<Response> _depthLock(Object failure) {
  final container = createHeadlessTestContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, _FailingBackend(failure)),
      ),
    ],
  );
  addTearDown(container.dispose);
  return DepthLockHandlers(container).handleGetGoal(
    Request('GET', Uri.parse('http://localhost/api/depthlock/goals/m42-ha')),
    'm42-ha',
  );
}

Future<Response> _start(Object failure) {
  final sequencer = _MockSequencerBackend();
  final devices = _MockDeviceBackend();
  final host = _MockHostBackend();
  when(() => host.eventStream).thenAnswer((_) => const Stream.empty());
  when(() => host.polarAlignmentEvents).thenAnswer((_) => const Stream.empty());
  when(
    () => host.sequencerStart(),
  ).thenAnswer((_) => sequencer.sequencerStart());
  when(
    () => sequencer.sequencerSetSimulationMode(any()),
  ).thenAnswer((_) async {});
  when(() => sequencer.sequencerApplyRunConfig(any())).thenAnswer((_) async {});
  when(
    () => sequencer.sequencerSetDevices(
      cameraId: any(named: 'cameraId'),
      mountId: any(named: 'mountId'),
      focuserId: any(named: 'focuserId'),
      filterwheelId: any(named: 'filterwheelId'),
      rotatorId: any(named: 'rotatorId'),
      filterNames: any(named: 'filterNames'),
    ),
  ).thenAnswer((_) async {});
  when(() => sequencer.sequencerStart()).thenThrow(failure);
  when(() => devices.getConnectedDevices()).thenAnswer((_) async => []);
  final container = createHeadlessTestContainer(
    overrides: [
      backendProvider.overrideWith((ref) => _FixedBackendNotifier(ref, host)),
      sequencerBackendProvider.overrideWithValue(sequencer),
      deviceBackendProvider.overrideWithValue(devices),
    ],
  );
  addTearDown(container.dispose);
  return SequencerHandlers(container).handleSequencerStart(
    Request(
      'POST',
      Uri.parse('http://localhost/api/sequencer/start'),
      body: jsonEncode({}),
    ),
  );
}

Future<Response> _call(String id, Object failure) =>
    switch (id.split('.').first) {
      'lock' || 'star_image' || 'find_star' => _guiding(id, failure),
      'depthlock' => _depthLock(failure),
      'start' => _start(failure),
      _ => throw ArgumentError(id),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(_MockBackend());

  final record = Platform.environment['SKOTIQ_RECORD_REPLIES'] == '1';
  final recorded = <String, Object?>{};
  final expected = record
      ? const <String, Object?>{}
      : jsonDecode(_fixture.readAsStringSync()) as Map<String, Object?>;

  test('every pinned failure has a row and every row a pin', () {
    if (record) return;
    expect(_failures.keys.toSet(), expected.keys.toSet());
  });

  for (final MapEntry(key: id, value: failure) in _failures.entries) {
    test(id, () async {
      final reply = await _reply(() => _call(id, failure));
      if (record) {
        recorded[id] = reply;
        return;
      }
      expect(reply, expected[id]);
    });
  }

  tearDownAll(() {
    if (!record) return;
    _fixture.parent.createSync(recursive: true);
    _fixture.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(recorded)}\n',
    );
  });
}
