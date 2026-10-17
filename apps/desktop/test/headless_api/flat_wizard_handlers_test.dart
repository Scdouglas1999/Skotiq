import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/flat_wizard_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockBackend extends Mock implements SkotiqBackend {}

/// Records every service invocation and the arguments it received, and returns
/// canned results without touching hardware. Lets the handler tests prove two
/// things: an invalid request is rejected BEFORE any of these methods runs
/// (counter stays 0), and a valid request forwards the validated/defaulted
/// values through unchanged.
class _SpyFlatWizardService extends FlatWizardService {
  _SpyFlatWizardService(super.backend);

  int calibrateFilterCalls = 0;
  int calibrateMultipleCalls = 0;
  int generateCalls = 0;
  int quickCalls = 0;

  double? lastTargetAdu;
  double? lastTolerance;
  double? lastMinExposure;
  double? lastMaxExposure;
  int? lastMaxIterations;
  int? lastBinX;
  int? lastBinY;
  int? lastGain;
  int? lastOffset;
  String? lastDeviceId;
  String? lastFilter;
  List<String>? lastFilters;
  int? lastFramesPerFilter;
  bool? lastOnlySuccessful;

  int get totalCalls =>
      calibrateFilterCalls +
      calibrateMultipleCalls +
      generateCalls +
      quickCalls;

  @override
  Future<FlatResult> calibrateFilter({
    required String deviceId,
    required String filter,
    int? gain,
    int? offset,
    required double targetAdu,
    required double tolerance,
    required double minExposure,
    required double maxExposure,
    int maxIterations = 10,
    int binX = 1,
    int binY = 1,
    FlatCancelToken? cancelToken,
    Duration abortSettleTimeout = const Duration(seconds: 10),
    Duration? overallTimeout,
    void Function(int iteration, double exposure, double adu)? onProgress,
  }) async {
    calibrateFilterCalls++;
    lastDeviceId = deviceId;
    lastFilter = filter;
    lastTargetAdu = targetAdu;
    lastTolerance = tolerance;
    lastMinExposure = minExposure;
    lastMaxExposure = maxExposure;
    lastMaxIterations = maxIterations;
    lastBinX = binX;
    lastBinY = binY;
    lastGain = gain;
    lastOffset = offset;
    return FlatResult(
      filter: filter,
      exposure: 1.23,
      adu: targetAdu,
      success: true,
      iterations: 2,
    );
  }

  @override
  Future<List<FlatResult>> calibrateMultipleFilters({
    required String deviceId,
    required List<String> filters,
    int? gain,
    int? offset,
    required double targetAdu,
    required double tolerance,
    required double minExposure,
    required double maxExposure,
    int maxIterations = 10,
    int binX = 1,
    int binY = 1,
    FlatCancelToken? cancelToken,
    Duration abortSettleTimeout = const Duration(seconds: 10),
    Duration? overallTimeout,
    void Function(String filter, int iteration, double exposure, double adu)?
    onProgress,
    void Function(String filter, FlatResult result)? onFilterComplete,
  }) async {
    calibrateMultipleCalls++;
    lastDeviceId = deviceId;
    lastFilters = filters;
    lastTargetAdu = targetAdu;
    lastTolerance = tolerance;
    lastMinExposure = minExposure;
    lastMaxExposure = maxExposure;
    lastMaxIterations = maxIterations;
    lastBinX = binX;
    lastBinY = binY;
    lastGain = gain;
    lastOffset = offset;
    return [
      for (final f in filters)
        FlatResult(
          filter: f,
          exposure: 1.0,
          adu: targetAdu,
          success: true,
          iterations: 1,
        ),
    ];
  }

  @override
  Future<FlatResult> quickCalibrate({
    required String deviceId,
    required String filter,
    int? gain,
    int? offset,
    double targetAdu = 30000,
    double tolerancePercent = 10.0,
    int binX = 1,
    int binY = 1,
  }) async {
    quickCalls++;
    lastDeviceId = deviceId;
    lastFilter = filter;
    lastTargetAdu = targetAdu;
    lastTolerance = tolerancePercent;
    lastBinX = binX;
    lastBinY = binY;
    lastGain = gain;
    lastOffset = offset;
    return FlatResult(
      filter: filter,
      exposure: 0.5,
      adu: targetAdu,
      success: true,
      iterations: 1,
    );
  }

  @override
  Sequence generateCompleteSequence({
    required List<FlatResult> calibrations,
    required int framesPerFilter,
    String sequenceName = 'Flat Frame Sequence',
    String? description,
    int binX = 1,
    int binY = 1,
    int? gain,
    int? offset,
    bool onlySuccessful = true,
  }) {
    generateCalls++;
    lastFramesPerFilter = framesPerFilter;
    lastOnlySuccessful = onlySuccessful;
    lastBinX = binX;
    lastBinY = binY;
    lastGain = gain;
    lastOffset = offset;
    return super.generateCompleteSequence(
      calibrations: calibrations,
      framesPerFilter: framesPerFilter,
      sequenceName: sequenceName,
      description: description,
      binX: binX,
      binY: binY,
      gain: gain,
      offset: offset,
      onlySuccessful: onlySuccessful,
    );
  }
}

Request _post(String path, Map<String, dynamic> body) =>
    Request('POST', Uri.parse('http://localhost$path'), body: jsonEncode(body));

void main() {
  group('FlatWizardHandlers', () {
    late ProviderContainer container;
    late FlatWizardHandlers handlers;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          flatWizardServiceProvider.overrideWithValue(
            _SpyFlatWizardService(_MockBackend()),
          ),
        ],
      );
      handlers = FlatWizardHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('generate sequence returns JSON helper response', () async {
      final response = await translateHandlerErrors(
        handlers.handleGenerateSequence(
          Request(
            'POST',
            Uri.parse('http://localhost/api/flat-wizard/generate-sequence'),
            body: jsonEncode({
              'calibrations': [
                {
                  'filter': 'L',
                  'exposure': 1.5,
                  'adu': 30000.0,
                  'success': true,
                  'iterations': 3,
                },
                {
                  'filter': 'R',
                  'exposure': 2.0,
                  'adu': 29000.0,
                  'success': false,
                  'iterations': 5,
                  'errorMessage': 'outside tolerance',
                },
              ],
              'framesPerFilter': 20,
              'sequenceName': 'Test Flats',
              'description': 'Generated by handler test',
              'onlySuccessful': true,
            }),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      final sequence = body['sequence'] as Map;
      expect(sequence['name'], 'Test Flats');
      expect(sequence['rootNodeId'], isA<String>());
      final nodes = sequence['nodes'] as Map;
      expect(nodes.length, 2);
      expect(
        nodes.values.where(
          (node) => node is Map && node['type'] == 'ExposureNode',
        ),
        hasLength(1),
      );
    });

    test(
      'calibrate filter malformed body returns JSON internal server error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCalibrateFilter(
            Request(
              'POST',
              Uri.parse('http://localhost/api/flat-wizard/calibrate'),
              body: jsonEncode({'deviceId': 'camera-1'}),
            ),
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
      },
    );

    test(
      'quick calibrate malformed body returns JSON internal server error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleQuickCalibrate(
            Request(
              'POST',
              Uri.parse('http://localhost/api/flat-wizard/quick-calibrate'),
              body: jsonEncode({'deviceId': 'camera-1'}),
            ),
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
      },
    );
  });

  group('FlatWizardHandlers fail-fast validation', () {
    late _SpyFlatWizardService spy;
    late ProviderContainer container;
    late FlatWizardHandlers handlers;

    setUp(() {
      spy = _SpyFlatWizardService(_MockBackend());
      container = ProviderContainer(
        overrides: [flatWizardServiceProvider.overrideWithValue(spy)],
      );
      handlers = FlatWizardHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    Future<Map<String, dynamic>> expectBadRequest(Future<Response> call) async {
      final response = await translateHandlerErrors(call);
      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['code'], 'invalid_request');
      // Every rejection happens before the service is reached.
      expect(
        spy.totalCalls,
        0,
        reason: 'service must not run for an invalid request',
      );
      return body;
    }

    // calibrate

    const validCalibrate = {
      'deviceId': 'camera-1',
      'filter': 'L',
      'targetAdu': 30000.0,
      'gain': 100,
      'offset': 10,
    };

    final calibrateRejections = <String, Map<String, dynamic>>{
      'whitespace-only filter': {...validCalibrate, 'filter': '   '},
      'whitespace-only deviceId': {...validCalibrate, 'deviceId': '  '},
      'zero targetAdu': {...validCalibrate, 'targetAdu': 0},
      'negative targetAdu': {...validCalibrate, 'targetAdu': -5},
      // Larger than a 16-bit sensor (proves we do not assume 16-bit) but still
      // beyond the largest supported (32-bit) full scale.
      'absurd targetAdu': {...validCalibrate, 'targetAdu': 5000000000.0},
      'tolerance below range': {...validCalibrate, 'tolerance': 0},
      'tolerance above range': {...validCalibrate, 'tolerance': 30},
      'zero minExposure': {...validCalibrate, 'minExposure': 0},
      'inverted exposure bounds': {
        ...validCalibrate,
        'minExposure': 5.0,
        'maxExposure': 2.0,
      },
      'zero maxIterations': {...validCalibrate, 'maxIterations': 0},
      'excessive maxIterations': {...validCalibrate, 'maxIterations': 1000},
      'zero binX': {...validCalibrate, 'binX': 0},
      'binX above supported': {...validCalibrate, 'binX': 8},
      'binY above supported': {...validCalibrate, 'binY': 5},
      'negative gain': {...validCalibrate, 'gain': -1},
      'negative offset': {...validCalibrate, 'offset': -1},
    };

    calibrateRejections.forEach((name, body) {
      test('calibrate rejects $name as 400 without service', () async {
        await expectBadRequest(
          handlers.handleCalibrateFilter(
            _post('/api/flat-wizard/calibrate', body),
          ),
        );
      });
    });

    test('calibrate forwards validated values and defaults', () async {
      final response = await translateHandlerErrors(
        handlers.handleCalibrateFilter(
          _post('/api/flat-wizard/calibrate', validCalibrate),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final result = body['result'] as Map;
      expect(result['filter'], 'L');
      expect(result['success'], true);
      expect(spy.calibrateFilterCalls, 1);
      // Validated request value plus the documented defaults.
      expect(spy.lastDeviceId, 'camera-1');
      expect(spy.lastFilter, 'L');
      expect(spy.lastTargetAdu, 30000.0);
      expect(spy.lastTolerance, 10.0);
      expect(spy.lastMinExposure, 0.001);
      expect(spy.lastMaxExposure, 30.0);
      expect(spy.lastMaxIterations, 10);
      expect(spy.lastBinX, 1);
      expect(spy.lastBinY, 1);
      expect(spy.lastGain, 100);
      expect(spy.lastOffset, 10);
    });

    test('calibrate trims deviceId/filter before forwarding', () async {
      final response = await translateHandlerErrors(
        handlers.handleCalibrateFilter(
          _post('/api/flat-wizard/calibrate', {
            ...validCalibrate,
            'deviceId': '  camera-1  ',
            'filter': '  L  ',
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(spy.calibrateFilterCalls, 1);
      expect(spy.lastDeviceId, 'camera-1');
      expect(spy.lastFilter, 'L');
    });

    test('calibrate forwards asymmetric binning unchanged', () async {
      // The calibrate path passes binX/binY as independent ints straight to
      // cameraStartExposure, so an asymmetric sensor bin is preserved and must
      // NOT be collapsed or rejected here.
      final response = await translateHandlerErrors(
        handlers.handleCalibrateFilter(
          _post('/api/flat-wizard/calibrate', {
            ...validCalibrate,
            'binX': 2,
            'binY': 3,
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(spy.calibrateFilterCalls, 1);
      expect(spy.lastBinX, 2);
      expect(spy.lastBinY, 3);
    });

    // calibrate-multi

    const validMulti = {
      'deviceId': 'camera-1',
      'filters': ['L', 'R'],
      'targetAdu': 30000.0,
      'gain': 100,
      'offset': 10,
    };

    final multiRejections = <String, Map<String, dynamic>>{
      'whitespace-only deviceId': {...validMulti, 'deviceId': '  '},
      'empty filter list': {...validMulti, 'filters': <String>[]},
      'blank filter name': {
        ...validMulti,
        'filters': ['L', '  '],
      },
      'duplicate filter': {
        ...validMulti,
        'filters': ['L', 'L'],
      },
      'case-insensitive duplicate filter': {
        ...validMulti,
        'filters': ['Ha', 'ha'],
      },
      'shared invalid targetAdu': {...validMulti, 'targetAdu': 0},
      'shared invalid binning': {...validMulti, 'binX': 9},
    };

    multiRejections.forEach((name, body) {
      test('calibrate-multi rejects $name as 400 without service', () async {
        await expectBadRequest(
          handlers.handleCalibrateMultipleFilters(
            _post('/api/flat-wizard/calibrate-multi', body),
          ),
        );
      });
    });

    test('calibrate-multi forwards trimmed unique filters', () async {
      final response = await translateHandlerErrors(
        handlers.handleCalibrateMultipleFilters(
          _post('/api/flat-wizard/calibrate-multi', {
            ...validMulti,
            'filters': [' L ', 'R'],
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect((body['results'] as List), hasLength(2));
      expect(spy.calibrateMultipleCalls, 1);
      expect(spy.lastFilters, ['L', 'R']);
      expect(spy.lastGain, 100);
      expect(spy.lastOffset, 10);
    });

    // generate-sequence

    Map<String, dynamic> calEntry({
      String filter = 'L',
      double exposure = 1.5,
      double adu = 30000.0,
      bool success = true,
    }) => {
      'filter': filter,
      'exposure': exposure,
      'adu': adu,
      'success': success,
    };

    final generateRejections = <String, Map<String, dynamic>>{
      'empty calibrations': {
        'calibrations': <Map<String, dynamic>>[],
        'framesPerFilter': 10,
      },
      'no eligible when onlySuccessful': {
        'calibrations': [
          calEntry(success: false),
          calEntry(filter: 'R', success: false),
        ],
        'framesPerFilter': 10,
        'onlySuccessful': true,
      },
      'zero exposure entry': {
        'calibrations': [calEntry(exposure: 0)],
        'framesPerFilter': 10,
      },
      'negative exposure entry': {
        'calibrations': [calEntry(exposure: -1)],
        'framesPerFilter': 10,
      },
      'negative adu entry': {
        'calibrations': [calEntry(adu: -1)],
        'framesPerFilter': 10,
      },
      'zero framesPerFilter': {
        'calibrations': [calEntry()],
        'framesPerFilter': 0,
      },
      'excessive framesPerFilter': {
        'calibrations': [calEntry()],
        'framesPerFilter': 2000,
      },
      'blank entry filter': {
        'calibrations': [calEntry(filter: '   ')],
        'framesPerFilter': 10,
      },
      'duplicate entry filter': {
        'calibrations': [calEntry(), calEntry()],
        'framesPerFilter': 10,
      },
      'case-insensitive duplicate entry filter': {
        'calibrations': [calEntry(filter: 'Ha'), calEntry(filter: 'ha')],
        'framesPerFilter': 10,
      },
      'excessive entry iterations': {
        'calibrations': [
          {...calEntry(), 'iterations': 1000},
        ],
        'framesPerFilter': 10,
      },
      'fractional entry iterations': {
        'calibrations': [
          {...calEntry(), 'iterations': 2.5},
        ],
        'framesPerFilter': 10,
      },
      'asymmetric binning': {
        'calibrations': [calEntry()],
        'framesPerFilter': 10,
        'binX': 2,
        'binY': 3,
      },
      'blank sequenceName': {
        'calibrations': [calEntry()],
        'framesPerFilter': 10,
        'sequenceName': '   ',
      },
      'over-length sequenceName': {
        'calibrations': [calEntry()],
        'framesPerFilter': 10,
        'sequenceName': 'x' * 201,
      },
    };

    generateRejections.forEach((name, body) {
      test('generate-sequence rejects $name as 400 without service', () async {
        final decoded = await expectBadRequest(
          handlers.handleGenerateSequence(
            _post('/api/flat-wizard/generate-sequence', body),
          ),
        );
        expect(decoded['field'], isA<String>());
        expect(spy.generateCalls, 0);
      });
    });

    test(
      'generate-sequence builds a sequence for eligible calibrations',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleGenerateSequence(
            _post('/api/flat-wizard/generate-sequence', {
              'calibrations': [
                calEntry(),
                calEntry(filter: 'R', success: false),
              ],
              'framesPerFilter': 20,
              'onlySuccessful': true,
            }),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        final nodes = (body['sequence'] as Map)['nodes'] as Map;
        // One eligible (successful) exposure node under the root.
        expect(
          nodes.values.where((n) => n is Map && n['type'] == 'ExposureNode'),
          hasLength(1),
        );
        expect(spy.generateCalls, 1);
        expect(spy.lastFramesPerFilter, 20);
        expect(spy.lastOnlySuccessful, true);
      },
    );

    test(
      'generate-sequence allows all-failed set when onlySuccessful is false',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleGenerateSequence(
            _post('/api/flat-wizard/generate-sequence', {
              'calibrations': [calEntry(success: false)],
              'framesPerFilter': 5,
              'onlySuccessful': false,
            }),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(spy.generateCalls, 1);
      },
    );

    test('generate-sequence trims entry filter names into nodes', () async {
      final response = await translateHandlerErrors(
        handlers.handleGenerateSequence(
          _post('/api/flat-wizard/generate-sequence', {
            'calibrations': [calEntry(filter: '  L  ')],
            'framesPerFilter': 5,
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final nodes = (body['sequence'] as Map)['nodes'] as Map;
      final exposureNode = nodes.values.firstWhere(
        (n) => n is Map && n['type'] == 'ExposureNode',
      );
      expect((exposureNode as Map)['filter'], 'L');
      expect(exposureNode['name'], 'Flat L');
    });

    test('generate-sequence defaults the sequence name when absent', () async {
      final response = await translateHandlerErrors(
        handlers.handleGenerateSequence(
          _post('/api/flat-wizard/generate-sequence', {
            'calibrations': [calEntry()],
            'framesPerFilter': 5,
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect((body['sequence'] as Map)['name'], 'Flat Frame Sequence');
    });

    test('generate-sequence trims a supplied sequence name', () async {
      final response = await translateHandlerErrors(
        handlers.handleGenerateSequence(
          _post('/api/flat-wizard/generate-sequence', {
            'calibrations': [calEntry()],
            'framesPerFilter': 5,
            'sequenceName': '  My Flats  ',
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect((body['sequence'] as Map)['name'], 'My Flats');
    });

    // quick-calibrate

    const validQuick = {
      'deviceId': 'camera-1',
      'filter': 'L',
      'gain': 100,
      'offset': 10,
    };

    final quickRejections = <String, Map<String, dynamic>>{
      'whitespace-only filter': {...validQuick, 'filter': '   '},
      'whitespace-only deviceId': {...validQuick, 'deviceId': '  '},
      'zero targetAdu': {...validQuick, 'targetAdu': 0},
      'negative targetAdu': {...validQuick, 'targetAdu': -1},
      'tolerance above range': {...validQuick, 'tolerancePercent': 30},
      'binX above supported': {...validQuick, 'binX': 5},
      'negative gain': {...validQuick, 'gain': -1},
    };

    quickRejections.forEach((name, body) {
      test('quick-calibrate rejects $name as 400 without service', () async {
        await expectBadRequest(
          handlers.handleQuickCalibrate(
            _post('/api/flat-wizard/quick-calibrate', body),
          ),
        );
      });
    });

    test(
      'quick-calibrate applies defaults when optional fields omitted',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleQuickCalibrate(
            _post('/api/flat-wizard/quick-calibrate', validQuick),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect((body['result'] as Map)['filter'], 'L');
        expect(spy.quickCalls, 1);
        expect(spy.lastDeviceId, 'camera-1');
        expect(spy.lastFilter, 'L');
        expect(spy.lastTargetAdu, 30000.0);
        expect(spy.lastTolerance, 10.0);
        expect(spy.lastBinX, 1);
        expect(spy.lastGain, 100);
        expect(spy.lastOffset, 10);
      },
    );

    test('quick-calibrate forwards trimmed input and asymmetric binning', () async {
      // Same as calibrate: quickCalibrate hands binX/binY through to the camera
      // as independent ints, so asymmetric binning is preserved, not collapsed.
      final response = await translateHandlerErrors(
        handlers.handleQuickCalibrate(
          _post('/api/flat-wizard/quick-calibrate', {
            ...validQuick,
            'deviceId': '  camera-1  ',
            'filter': '  L  ',
            'binX': 2,
            'binY': 3,
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(spy.quickCalls, 1);
      expect(spy.lastDeviceId, 'camera-1');
      expect(spy.lastFilter, 'L');
      expect(spy.lastBinX, 2);
      expect(spy.lastBinY, 3);
    });
  });

  // Gain/offset resolution from the active profile
  //
  // Client-supplied gain/offset are floored at 0 by the request validators, so
  // the only way a negative can reach the camera is a legacy/negative default
  // stored on the active equipment profile. The handler validates the FINAL
  // resolved pair and fails closed (a 500 HandlerFailure — host config, not a
  // bad request) rather than coercing to zero or driving the hardware with it.
  group('FlatWizardHandlers gain/offset profile resolution', () {
    late _SpyFlatWizardService spy;

    FlatWizardHandlers handlersWithProfile(EquipmentProfileModel? profile) {
      spy = _SpyFlatWizardService(_MockBackend());
      final container = ProviderContainer(
        overrides: [
          flatWizardServiceProvider.overrideWithValue(spy),
          activeEquipmentProfileProvider.overrideWithValue(profile),
        ],
      );
      addTearDown(container.dispose);
      return FlatWizardHandlers(container);
    }

    const requestWithoutGainOffset = {
      'deviceId': 'camera-1',
      'filter': 'L',
      'targetAdu': 30000.0,
    };

    Future<void> expectProfileRejection(Future<Response> call) async {
      final response = await translateHandlerErrors(call);
      expect(response.statusCode, HttpStatus.internalServerError);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'invalid_profile_gain_offset');
      // A bad host profile must fail BEFORE the camera is ever driven.
      expect(spy.totalCalls, 0);
    }

    test('resolves gain/offset from a valid active profile', () async {
      final handlers = handlersWithProfile(
        const EquipmentProfileModel(
          name: 'Rig',
          defaultGain: 200,
          defaultOffset: 25,
        ),
      );

      final response = await translateHandlerErrors(
        handlers.handleCalibrateFilter(
          _post('/api/flat-wizard/calibrate', requestWithoutGainOffset),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(spy.calibrateFilterCalls, 1);
      expect(spy.lastGain, 200);
      expect(spy.lastOffset, 25);
    });

    test('rejects a negative profile gain before the service', () async {
      final handlers = handlersWithProfile(
        const EquipmentProfileModel(
          name: 'Rig',
          defaultGain: -1,
          defaultOffset: 25,
        ),
      );

      await expectProfileRejection(
        handlers.handleCalibrateFilter(
          _post('/api/flat-wizard/calibrate', requestWithoutGainOffset),
        ),
      );
    });

    test('rejects a negative profile offset before the service', () async {
      final handlers = handlersWithProfile(
        const EquipmentProfileModel(
          name: 'Rig',
          defaultGain: 200,
          defaultOffset: -5,
        ),
      );

      await expectProfileRejection(
        handlers.handleQuickCalibrate(
          _post('/api/flat-wizard/quick-calibrate', {
            'deviceId': 'camera-1',
            'filter': 'L',
          }),
        ),
      );
    });

    test('a supplied gain never pairs with a negative profile offset', () async {
      // gain is supplied (>= 0), offset falls back to a NEGATIVE profile
      // default: the resolved pair must still be rejected, never silently paired
      // with a coerced zero.
      final handlers = handlersWithProfile(
        const EquipmentProfileModel(
          name: 'Rig',
          defaultGain: 200,
          defaultOffset: -5,
        ),
      );

      await expectProfileRejection(
        handlers.handleCalibrateFilter(
          _post('/api/flat-wizard/calibrate', {
            ...requestWithoutGainOffset,
            'gain': 100,
          }),
        ),
      );
    });
  });
}
