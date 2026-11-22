import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_desktop/headless_api/handlers/framing_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/planetarium_handlers.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';
import 'package:skotiq_desktop/headless_api/validation.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// What the host answers a client's center request on
/// `POST /api/planetarium/center-on` and `POST /api/framing/center-on-target`,
/// with the centering each request ran, pinned in
/// `fixtures/centering_handler_replies.json`. `SKOTIQ_RECORD_REPLIES=1`
/// rewrites the fixture.
final _fixture = File(
  'test/headless_api/fixtures/centering_handler_replies.json',
);

class _Centering extends CenteringService {
  _Centering(super.ref, this.answer);

  final Object answer;
  final List<Map<String, Object?>> calls = [];
  int stops = 0;
  final _released = Completer<CenteringResult>();

  @override
  Future<void> stop() async {
    stops++;
    if (!_released.isCompleted) _released.complete(_aborted);
  }

  @override
  Future<CenteringResult> centerOnTarget({
    required double targetRa,
    required double targetDec,
    required CenteringConfig config,
    void Function(CenteringStatus)? onStatusUpdate,
  }) async {
    calls.add({
      'ra': targetRa,
      'dec': targetDec,
      'maxIterations': config.maxIterations,
      'toleranceArcsec': config.toleranceArcsec,
      'exposureTime': config.exposureTime,
      'syncMount': config.syncMount,
      'overallTimeoutSecs': config.overallTimeout.inSeconds,
    });
    final answer = this.answer;
    if (answer == _hang) return _released.future;
    if (answer is CenteringResult) return answer;
    throw answer;
  }
}

const _hang = 'hang until stopped';
const _aborted = CenteringResult(
  success: false,
  iterations: 1,
  errorMessage: 'Centering aborted',
  iterationHistory: [],
);
const _centered = CenteringResult(
  success: true,
  finalOffsetArcsec: 4.5,
  iterations: 2,
  iterationHistory: [],
);
const _missed = CenteringResult(
  success: false,
  finalOffsetArcsec: 300,
  iterations: 5,
  errorMessage: 'Did not converge',
  iterationHistory: [],
);

final Map<String, (Map<String, Object?>, Object)> _rows = {
  'defaults': ({'ra': 5.5, 'dec': -5.4}, _centered),
  'overrides': (
    {
      'ra': 0,
      'dec': 89.9,
      'maxIterations': 7,
      'toleranceArcsec': 12.5,
      'exposureTime': 2,
      'syncMount': false,
    },
    _centered,
  ),
  'missed': ({'ra': 12, 'dec': 30}, _missed),
  'throws': ({'ra': 12, 'dec': 30}, StateError('mount gone')),
  'ra_out_of_range': ({'ra': 25, 'dec': 30}, _centered),
  'bad_iterations': ({'ra': 1, 'dec': 2, 'maxIterations': 0}, _centered),
};

/// Framing only: the client cancels the job while the centering runs.
const _cancelRow = 'cancelled';

Future<Map<String, Object?>> _run(
  String route,
  Map<String, Object?> body,
  Object answer,
) async {
  late _Centering service;
  final container = createHeadlessTestContainer(
    overrides: [
      centeringServiceProvider.overrideWith((ref) {
        return service = _Centering(ref, answer);
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(centeringServiceProvider);
  final jobManager = JobManager(emitEvent: (_) {});
  addTearDown(jobManager.dispose);
  final request = Request(
    'POST',
    Uri.parse('http://localhost/api/pin'),
    body: jsonEncode(body),
  );
  final middleware = errorTranslationMiddleware(
    logError: (_, {fields}) {},
    requestIdFor: (_) => 'test-request-id',
  );
  final response = await middleware(
    (r) => route == 'planetarium'
        ? PlanetariumHandlers(container).handleCenterOn(r)
        : FramingHandlers(
            container,
            jobManager: jobManager,
          ).handleCenterOnTarget(r),
  )(request);
  final decoded = jsonDecode(await response.readAsString());
  Object? job;
  if (decoded is Map && decoded['jobId'] is String) {
    final id = decoded['jobId'] as String;
    if (answer == _hang) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      jobManager.cancel(id);
    }
    for (var i = 0; i < 200; i++) {
      final current = jobManager.get(id);
      if (current != null && current.state.isTerminal) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final done = jobManager.get(id)!;
    job = {
      'state': done.state.wireName,
      'result': done.result,
      'error': done.error,
    };
    decoded['jobId'] = '<job>';
  }
  return jsonDecode(
        jsonEncode({
          'status': response.statusCode,
          'body': decoded,
          'job': ?job,
          'centering': service.calls,
          'stops': service.stops,
          // The host's own centering status and last result: a client's
          // request leaves them alone.
          'hostStatus': container.read(centeringStatusProvider).state.name,
          'hostLastResult': container.read(lastCenteringResultProvider) != null,
        }),
      )
      as Map<String, Object?>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final record = Platform.environment['SKOTIQ_RECORD_REPLIES'] == '1';
  final recorded = <String, Object?>{};
  final expected = record
      ? const <String, Object?>{}
      : jsonDecode(_fixture.readAsStringSync()) as Map<String, Object?>;

  tearDownAll(() {
    if (!record) return;
    _fixture.parent.createSync(recursive: true);
    _fixture.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(recorded)}\n',
    );
  });

  test('framing.$_cancelRow', () async {
    final reply = await _run('framing', {'ra': 3, 'dec': 4}, _hang);
    const id = 'framing.$_cancelRow';
    if (record) {
      recorded[id] = reply;
      return;
    }
    expect(reply, expected[id]);
  });

  for (final route in ['planetarium', 'framing']) {
    for (final MapEntry(key: name, value: (body, answer)) in _rows.entries) {
      final id = '$route.$name';
      test(id, () async {
        final reply = await _run(route, body, answer);
        if (record) {
          recorded[id] = reply;
          return;
        }
        expect(reply, expected[id]);
      });
    }
  }
}
