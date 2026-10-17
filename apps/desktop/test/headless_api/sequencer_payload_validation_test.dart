import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// A client that mis-types a sequencer config field must be told which field
/// is wrong (400), not handed a 500 that reads as a server fault. Every
/// endpoint below used to route its payload through a handler-local reader
/// that threw `FormatException`, which the error-translation middleware has
/// no clause for.
void main() {
  group('mistyped sequencer config fields are rejected as 400', () {
    late ProviderContainer container;
    late SequencerHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = SequencerHandlers(container);
    });

    tearDown(() => container.dispose());

    Future<Response> post(
      Future<Response> Function(Request) handler,
      String path,
      Map<String, Object?> body,
    ) => translateHandlerErrors(
      handler(
        Request(
          'POST',
          Uri.parse('http://localhost$path'),
          body: jsonEncode(body),
        ),
      ),
    );

    Future<void> expectBadRequest(
      Future<Response> Function(Request) handler,
      String path,
      Map<String, Object?> body,
      String field,
    ) async {
      final response = await post(handler, path, body);
      expect(
        response.statusCode,
        HttpStatus.badRequest,
        reason: '$path with $body must be a client error',
      );
      final decoded = jsonDecode(await response.readAsString()) as Map;
      expect(decoded['field'], field);
    }

    test('sky-brightness mag', () async {
      await expectBadRequest(
        handlers.handleSequencerUpdateSkyBrightness,
        '/api/sequencer/update-sky-brightness',
        {'mag': 'bright'},
        'mag',
      );
    });

    test('weather-verdict unsafeOverride', () async {
      await expectBadRequest(
        handlers.handleSequencerUpdateWeatherVerdict,
        '/api/sequencer/update-weather-verdict',
        {'unsafeOverride': 'maybe'},
        'unsafeOverride',
      );
    });

    test('cloud-motion currentCoverPercent', () async {
      await expectBadRequest(
        handlers.handleSequencerUpdateCloudMotion,
        '/api/sequencer/update-cloud-motion',
        {'currentCoverPercent': 'overcast'},
        'currentCoverPercent',
      );
    });

    test('cloud-motion predictedClearSkyAz', () async {
      await expectBadRequest(
        handlers.handleSequencerUpdateCloudMotion,
        '/api/sequencer/update-cloud-motion',
        {'predictedClearSkyAz': <String, Object?>{}},
        'predictedClearSkyAz',
      );
    });

    test('secondary-rig exposureSecs', () async {
      await expectBadRequest(
        handlers.handleSecondaryRigStart,
        '/api/sequencer/secondary-rig/start',
        {'cameraId': 'cam-1', 'exposureSecs': 'long', 'saveBasePath': '/tmp'},
        'exposureSecs',
      );
    });

    test('secondary-rig targetTempC', () async {
      await expectBadRequest(
        handlers.handleSecondaryRigStart,
        '/api/sequencer/secondary-rig/start',
        {
          'cameraId': 'cam-1',
          'exposureSecs': 1.0,
          'saveBasePath': '/tmp',
          'targetTempC': 'cold',
        },
        'targetTempC',
      );
    });

    test(
      'adaptive-exposure per-filter maps keep their nested field path',
      () async {
        await expectBadRequest(
          handlers.handleSequencerUpdateDefaultAdaptiveExposure,
          '/api/sequencer/update-default-adaptive-exposure',
          {
            'enabled': true,
            'targetSnr': 10.0,
            'referenceSkyBrightnessMag': 21.0,
            'minExposureSecs': 1.0,
            'maxExposureSecs': 300.0,
            'perFilterMinSecs': {'L': 'short'},
          },
          'perFilterMinSecs.L',
        );
      },
    );

    test('carry-over nested map keeps its nested field path', () async {
      await expectBadRequest(
        handlers.handleSequencerUpdatePendingIntegrationCarryOver,
        '/api/sequencer/update-pending-integration-carry-over',
        {
          'carry_over': {
            'M31': {'L': 'lots'},
          },
        },
        'carry_over.M31.L',
      );
    });
  });
}
