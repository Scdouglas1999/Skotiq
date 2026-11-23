import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';
import 'package:skotiq_desktop/headless_api/validation.dart';

/// What `POST /api/focuser/autofocus/start` makes of each body: the request
/// that reaches the backend, field by field, or the 400 body it answers.
/// The answers are pinned in `fixtures/autofocus_start_bodies.json`, recorded
/// on the handler that parsed every field itself. `SKOTIQ_RECORD_REPLIES=1`
/// rewrites the fixture.
final _fixture = File('test/headless_api/fixtures/autofocus_start_bodies.json');

const _ids = {'deviceId': 'native:focuser:1', 'cameraId': 'native:camera:1'};
const _minimal = {..._ids, 'exposureTime': 2.0, 'stepSize': 50, 'stepsOut': 4};

Map<String, Object?> _with(Map<String, Object?> changes) => {
  ..._minimal,
  ...changes,
};

Map<String, Object?> _without(String key) => Map.of(_minimal)..remove(key);

final Map<String, Map<String, Object?>> _bodies = {
  'minimal': _minimal,
  'web dashboard': {
    ..._ids,
    'exposureTime': 3.0,
    'stepSize': 50,
    'stepsOut': 5,
    'method': 'VCurve',
    'binning': 2,
  },
  'every field': {
    ..._ids,
    'exposureTime': 6.5,
    'stepSize': 75,
    'stepsOut': 7,
    'method': 'Star HFR',
    'binning': 2,
    'gain': 120,
    'offset': 18,
    'curveFitting': 'Parabolic',
    'numberOfAttempts': 3,
    'exposuresPerPoint': 2,
    'rSquaredThreshold': 0.85,
    'outerCropRatio': 0.8,
    'innerCropRatio': 0.2,
    'useBrightestNStars': 25,
    'focuserSettleTimeMs': 750,
    'backlashCompMethod': 'Absolute',
    'backlashIn': 120,
    'backlashOut': 40,
    'measuredBacklashIn': 95,
    'failureHfrToleranceRatio': 2.4,
  },
  'every optional field null': _with({
    'method': null,
    'binning': null,
    'gain': null,
    'offset': null,
    'curveFitting': null,
    'numberOfAttempts': null,
    'exposuresPerPoint': null,
    'rSquaredThreshold': null,
    'outerCropRatio': null,
    'innerCropRatio': null,
    'useBrightestNStars': null,
    'focuserSettleTimeMs': null,
    'backlashCompMethod': null,
    'backlashIn': null,
    'backlashOut': null,
    'measuredBacklashIn': null,
    'failureHfrToleranceRatio': null,
  }),
  'empty strings read as absent': _with({
    'method': '',
    'curveFitting': '',
    'backlashCompMethod': '',
  }),
  'unknown key is ignored': _with({'somethingElse': 7}),
  'numbers as strings': _with({
    'exposureTime': '2.5',
    'stepSize': '60',
    'stepsOut': '6',
    'binning': '2',
    'rSquaredThreshold': '0.5',
  }),
  'whole doubles for integers': _with({
    'stepSize': 60.0,
    'stepsOut': 6.0,
    'backlashIn': 100.0,
  }),
  'integer exposure': _with({'exposureTime': 2}),
  'fractional integer': _with({'stepSize': 50.5}),
  'unparsable integer string': _with({'stepSize': 'fifty'}),
  'boolean for an integer': _with({'binning': true}),
  'boolean for a number': _with({'exposureTime': true}),
  'unparsable number string': _with({'exposureTime': 'abc'}),
  'non-finite number string': _with({'exposureTime': 'Infinity'}),
  'NaN number string': _with({'rSquaredThreshold': 'NaN'}),
  'number for a string': _with({'method': 5}),
  'missing deviceId': _without('deviceId'),
  'empty deviceId': _with({'deviceId': ''}),
  'number deviceId': _with({'deviceId': 5}),
  'missing cameraId': _without('cameraId'),
  'missing exposureTime': _without('exposureTime'),
  'missing stepSize': _without('stepSize'),
  'missing stepsOut': _without('stepsOut'),
  'exposureTime below range': _with({'exposureTime': 0.05}),
  'exposureTime above range': _with({'exposureTime': 301}),
  'exposureTime at bounds low': _with({'exposureTime': 0.1}),
  'exposureTime at bounds high': _with({'exposureTime': 300}),
  'stepSize below range': _with({'stepSize': 0}),
  'stepSize above range': _with({'stepSize': 10001}),
  'stepsOut below range': _with({'stepsOut': 0}),
  'stepsOut above range': _with({'stepsOut': 51}),
  'binning below range': _with({'binning': 0}),
  'binning above range': _with({'binning': 5}),
  'gain below range': _with({'gain': -1}),
  'gain large': _with({'gain': 100000}),
  'offset below range': _with({'offset': -1}),
  'numberOfAttempts below range': _with({'numberOfAttempts': 0}),
  'numberOfAttempts above range': _with({'numberOfAttempts': 11}),
  'exposuresPerPoint below range': _with({'exposuresPerPoint': 0}),
  'exposuresPerPoint above range': _with({'exposuresPerPoint': 21}),
  'rSquaredThreshold below range': _with({'rSquaredThreshold': -0.1}),
  'rSquaredThreshold above range': _with({'rSquaredThreshold': 1.1}),
  'outerCropRatio below range': _with({'outerCropRatio': -0.1}),
  'outerCropRatio above range': _with({'outerCropRatio': 1.1}),
  'innerCropRatio below range': _with({'innerCropRatio': -0.1}),
  'innerCropRatio above range': _with({'innerCropRatio': 1.1}),
  'outer crop zero': _with({'outerCropRatio': 0}),
  'inner crop equals outer': _with({
    'innerCropRatio': 0.5,
    'outerCropRatio': 0.5,
  }),
  'inner crop above outer': _with({
    'innerCropRatio': 0.6,
    'outerCropRatio': 0.5,
  }),
  'inner crop default above sent outer': _with({'outerCropRatio': 0.0001}),
  'useBrightestNStars zero': _with({'useBrightestNStars': 0}),
  'useBrightestNStars below range': _with({'useBrightestNStars': -1}),
  'useBrightestNStars above range': _with({'useBrightestNStars': 501}),
  'focuserSettleTimeMs below range': _with({'focuserSettleTimeMs': -1}),
  'focuserSettleTimeMs above range': _with({'focuserSettleTimeMs': 10001}),
  'backlashIn below range': _with({'backlashIn': -1}),
  'backlashIn above range': _with({'backlashIn': 10001}),
  'backlashOut below range': _with({'backlashOut': -1}),
  'backlashOut above range': _with({'backlashOut': 10001}),
  'measuredBacklashIn zero': _with({'measuredBacklashIn': 0}),
  'measuredBacklashIn below range': _with({'measuredBacklashIn': -1}),
  'measuredBacklashIn above range': _with({'measuredBacklashIn': 10001}),
  'failureHfrToleranceRatio below range': _with({
    'failureHfrToleranceRatio': -0.5,
  }),
  'failureHfrToleranceRatio above range': _with({
    'failureHfrToleranceRatio': 101,
  }),
  'two bad fields name the first': _with({'stepSize': 0, 'binning': 9}),
  'missing id before a bad number': {
    'cameraId': 'native:camera:1',
    'exposureTime': 0,
    'stepSize': 50,
    'stepsOut': 4,
  },
  'bad crop and bad star count': _with({
    'outerCropRatio': 0,
    'useBrightestNStars': 999,
  }),
  'bad star count and bad tolerance': _with({
    'useBrightestNStars': 999,
    'failureHfrToleranceRatio': 500,
  }),
  'bad tolerance and bad measured backlash': _with({
    'failureHfrToleranceRatio': 500,
    'measuredBacklashIn': -4,
  }),
};

Map<String, Object?> _fields(AutofocusRequest request) => {
  'deviceId': request.deviceId,
  'cameraId': request.cameraId,
  'exposureTime': request.exposureTime,
  'stepSize': request.stepSize,
  'stepsOut': request.stepsOut,
  'method': request.method,
  'binning': request.binning,
  'gain': request.gain,
  'offset': request.offset,
  'curveFitting': request.curveFitting,
  'numberOfAttempts': request.numberOfAttempts,
  'exposuresPerPoint': request.exposuresPerPoint,
  'rSquaredThreshold': request.rSquaredThreshold,
  'outerCropRatio': request.outerCropRatio,
  'innerCropRatio': request.innerCropRatio,
  'useBrightestNStars': request.useBrightestNStars,
  'focuserSettleTimeMs': request.focuserSettleTimeMs,
  'backlashCompMethod': request.backlashCompMethod,
  'backlashIn': request.backlashIn,
  'backlashOut': request.backlashOut,
  'measuredBacklashIn': request.measuredBacklashIn,
  'failureHfrToleranceRatio': request.failureHfrToleranceRatio,
};

Future<Map<String, Object?>> _answer(Map<String, Object?> body) async {
  final backend = _RecordingBackend();
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith((ref) => _TestBackendNotifier(ref, backend)),
      databaseProvider.overrideWith((ref) {
        final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
    ],
  );
  final jobs = JobManager(emitEvent: (_) {});
  try {
    final handlers = DeviceHandlers(container, jobManager: jobs);
    final Response response;
    try {
      response = await handlers.handleAutofocusStart(
        Request(
          'POST',
          Uri.parse('http://localhost/api/focuser/autofocus/start'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(body),
        ),
      );
    } on BadRequestError catch (error) {
      expect(jobs.list(), isEmpty, reason: 'a refused body starts no job');
      return {'refused': error.toJsonBody()};
    }
    expect(response.statusCode, 200);
    for (var i = 0; i < 100 && backend.request == null; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    backend.pending.completeError(StateError('test over'));
    return {'request': _fields(backend.request!)};
  } finally {
    await jobs.dispose();
    container.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final record = Platform.environment['SKOTIQ_RECORD_REPLIES'] == '1';
  final recorded = <String, Object?>{};
  final expected = record
      ? const <String, Object?>{}
      : jsonDecode(_fixture.readAsStringSync()) as Map<String, Object?>;

  test('every pinned body has a row and every row a pin', () {
    if (record) return;
    expect(_bodies.keys.toSet(), expected.keys.toSet());
  });

  for (final MapEntry(key: name, value: body) in _bodies.entries) {
    test(name, () async {
      final answer = await _answer(body);
      if (record) {
        recorded[name] = answer;
        return;
      }
      expect(answer, expected[name]);
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

class _RecordingBackend extends DisconnectedBackend {
  final Completer<AutofocusResult> pending = Completer<AutofocusResult>();
  AutofocusRequest? request;

  @override
  Future<AutofocusResult> autofocusStart(AutofocusRequest request) {
    this.request = request;
    return pending.future;
  }

  @override
  Future<void> autofocusCancel() async {}
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
