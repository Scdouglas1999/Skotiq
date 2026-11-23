// Requests this machine builds right before the bridge call, held to the keys
// the native request types read (test_fixtures/ffi_args/, traced by Rust from
// each type's Deserialize). The bridge itself records them here, so the maps
// checked are the ones the native side would parse.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show RustLib, RustLibApi;
import 'package:skotiq_core/src/providers/darkroom_pass/pass_providers.dart';
import 'package:skotiq_core/src/services/darkroom_autopilot/darkroom_seam.dart';
import 'package:skotiq_core/src/services/post_session_seam.dart';

import '../harness/args_fixture.dart';
import '../harness/reply_fixture.dart';

final _calls = <({String api, Map<String, dynamic> args})>[];

Future<String> _record(String api, String argsJson, String reply) async {
  _calls.add((api: api, args: jsonDecode(argsJson) as Map<String, dynamic>));
  return reply;
}

String _sample(String name) => jsonEncode(replyFixture(name));

class _RecordingNative extends Mock implements RustLibApi {
  @override
  Future<String> crateApiFinishingAnalyzeApiAnalyzeNight({
    required String argsJson,
  }) => _record('analyze_night', argsJson, _sample('analyze_night'));

  @override
  Future<String> crateApiFinishingAnalyzeApiDetectStarsPhotometry({
    required String argsJson,
  }) => _record(
    'detect_stars_photometry',
    argsJson,
    _sample('detect_stars_photometry'),
  );

  @override
  Future<String> crateApiFinishingAnalyzeApiColorCalibrate({
    required String argsJson,
  }) => _record('color_calibrate', argsJson, _sample('color_calibrate'));

  @override
  Future<String> crateApiPostSessionEntrypointsApiPostSessionCancel({
    required String argsJson,
  }) =>
      _record('post_session_cancel', argsJson, _sample('post_session_cancel'));

  @override
  Future<String> crateApiDarkroomEntrypointsApiDarkroomRegistry({
    required String argsJson,
  }) => _record('darkroom_registry', argsJson, _sample('darkroom_registry'));

  @override
  Future<String> crateApiDarkroomEntrypointsApiDarkroomCancel({
    required String argsJson,
  }) => _record('darkroom_cancel', argsJson, '{"cancelled":true}');

  @override
  Future<String> crateApiDarkroomEntrypointsApiDarkroomRenderExport({
    required String recipeJson,
    required String argsJson,
  }) => _record(
    'darkroom_render_export',
    argsJson,
    _sample('darkroom_render_export'),
  );
}

/// The single request recorded since the last test, checked against its own
/// fixture.
Map<String, dynamic> _onlyRequest(String api) {
  expect(_calls.map((c) => c.api), [api]);
  final args = _calls.single.args;
  expectNativeReadsEveryKey(args, [api]);
  return args;
}

void main() {
  setUpAll(() => RustLib.initMock(api: _RecordingNative()));
  tearDownAll(RustLib.dispose);
  setUp(_calls.clear);

  group('post-session seam', () {
    const seam = BridgePostSessionSeam();

    test('analyzeNight', () async {
      await seam.analyzeNight(
        qualities: [
          {'snr': 20.0, 'noise': 3.0},
        ],
        weights: [1.0],
        exposuresS: [120.0],
        aggressiveness: .5,
        minKeep: 3,
      );
      final args = _onlyRequest('analyze_night');
      expect(args['optimizer'], {'aggressiveness': .5, 'minKeep': 3});
    });

    test('detectStarsPhotometry', () async {
      await seam.detectStarsPhotometry(
        inputFits: '/masters/rgb.fits',
        maxStars: 400,
        aperture: 6,
      );
      final args = _onlyRequest('detect_stars_photometry');
      expect(args.keys, containsAll(['inputFits', 'maxStars', 'aperture']));
    });

    test('colorCalibrate', () async {
      await seam.colorCalibrate(
        inputFits: '/masters/rgb.fits',
        outputFits: '/masters/rgb_cc.fits',
        channels: 3,
        whiteRefBv: .65,
        matchedStars: [
          {
            'channelFlux': [1.0, 2.0, 3.0],
            'catalogBv': .4,
          },
        ],
      );
      final args = _onlyRequest('color_calibrate');
      expect(args['whiteRefBv'], .65);
    });
  });

  group('post-session cancel', () {
    test('a pass run is stopped and its stop cleared by run id', () async {
      const canceller = PassRunCanceller();
      await canceller.cancel('run-7');
      expect(_onlyRequest('post_session_cancel'), {'runId': 'run-7'});
      _calls.clear();
      await canceller.clear('run-7');
      expect(_onlyRequest('post_session_cancel'), {
        'op': 'clear',
        'runId': 'run-7',
      });
    });
  });

  group('Darkroom seam', () {
    // The seam forwards the caller's map; the callers' own maps are checked in
    // the tests that drive them through a fake seam.
    const seam = BridgeDarkroomSeam();

    test('registry, cancel and renderExport pass the map through', () async {
      final registry = {'masterPath': '/m.fits', 'baseMasterRef': '/m.fits'};
      await seam.registry(registry);
      expect(_onlyRequest('darkroom_registry'), registry);
      _calls.clear();

      final cancel = {'op': 'cancel', 'renderId': 'r-1'};
      await seam.cancel(cancel);
      expect(_onlyRequest('darkroom_cancel'), cancel);
      _calls.clear();

      final export = {
        'masterPath': '/m.fits',
        'renderId': 'r-1',
        'stage': {'kind': 'final'},
        'outputs': [
          {'format': 'png', 'path': '/out.png'},
        ],
      };
      await seam.renderExport(recipeJson: '{}', args: export);
      expect(_onlyRequest('darkroom_render_export'), export);
    });
  });
}
