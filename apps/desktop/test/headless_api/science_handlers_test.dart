import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_desktop/headless_api/handlers/science_handlers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockScienceCameraAutoConfig extends Mock
    implements ScienceCameraAutoConfig {}

void main() {
  group('ScienceHandlers', () {
    late ProviderContainer container;
    late ScienceHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = ScienceHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('invalid session bundle ID returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetSessionBundle(
          Request(
            'GET',
            Uri.parse('http://localhost/api/science/session/not-an-id/bundle'),
          ),
          'not-an-id',
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });

    test('compute transform without filter returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleComputePhotometricTransform(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/science/calibration/compute-transform',
            ),
            body: jsonEncode({'starMatches': []}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'filterName is required');
    });

    test(
      'transform profile filter rejects malformed and non-positive IDs',
      () async {
        for (final profileId in const ['abc', '0', '-1']) {
          final response = await translateHandlerErrors(
            handlers.handleGetPhotometricTransforms(
              Request(
                'GET',
                Uri.parse(
                  'http://localhost/api/science/transforms?profileId=$profileId',
                ),
              ),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: profileId);
        }
      },
    );

    test('session science config rejects unsafe processing bounds', () async {
      for (final config in const [
        {'psfGridRows': 0},
        {'psfGridCols': 65},
        {'transparencyAlertThreshold': -1},
        {'transparencyAlertThreshold': 101},
        {'photometryEnabled': 1},
      ]) {
        final response = await translateHandlerErrors(
          handlers.handleUpdateSessionConfig(
            Request(
              'POST',
              Uri.parse('http://localhost/api/science/session/1/config'),
              body: jsonEncode({'config': config}),
            ),
            '1',
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest, reason: '$config');
      }
    });

    test(
      'update settings malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleUpdateScienceSettings(
            Request(
              'POST',
              Uri.parse('http://localhost/api/science/settings'),
              body: '{',
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
      'update settings rejects keys outside the science namespace',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleUpdateScienceSettings(
            Request(
              'POST',
              Uri.parse('http://localhost/api/science/settings'),
              body: jsonEncode({
                'settings': {'remote_access.enabled': 'true'},
              }),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], contains('Only science settings'));
      },
    );

    test(
      'Smart Night raw settings round-trip through the host authority',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        container.dispose();
        container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(database)],
        );
        handlers = ScienceHandlers(container);

        final update = await handlers.handleUpdateSmartNightSettings(
          Request(
            'POST',
            Uri.parse('http://localhost/api/smart-night/settings'),
            body: jsonEncode({
              'settings': {
                HardwareSpecsService.cameraOverridesSettingKey:
                    '[{"model":"Rig camera"}]',
                'smart_night.glover_k_factor': 12,
              },
            }),
          ),
        );
        expect(update.statusCode, HttpStatus.ok);

        final response = await handlers.handleGetSmartNightSettings(
          Request(
            'GET',
            Uri.parse('http://localhost/api/smart-night/settings'),
          ),
        );
        final body = jsonDecode(await response.readAsString()) as Map;
        final settings = body['settings'] as Map;
        expect(settings['smart_night.glover_k_factor'], '12');
        expect(
          settings[HardwareSpecsService.cameraOverridesSettingKey],
          '[{"model":"Rig camera"}]',
        );
      },
    );

    test('Smart Night endpoint rejects unrelated setting keys', () async {
      final response = await translateHandlerErrors(
        handlers.handleUpdateSmartNightSettings(
          Request(
            'POST',
            Uri.parse('http://localhost/api/smart-night/settings'),
            body: jsonEncode({
              'settings': {'remote_access.enabled': 'true'},
            }),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], contains('Only Smart Night settings'));
    });

    test(
      're-enabling camera auto-config immediately resyncs the host',
      () async {
        final autoConfig = _MockScienceCameraAutoConfig();
        when(
          () => autoConfig.maybeSync(
            reason: any(named: 'reason'),
            force: any(named: 'force'),
          ),
        ).thenAnswer((_) async {});
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        container.dispose();
        container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            scienceCameraAutoConfigProvider.overrideWithValue(autoConfig),
          ],
        );
        handlers = ScienceHandlers(container);

        final response = await handlers.handleUpdateScienceSettings(
          Request(
            'POST',
            Uri.parse('http://localhost/api/science/settings'),
            body: jsonEncode({
              'settings': {ScienceCameraAutoConfig.autoManagedKey: true},
            }),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        verify(
          () => autoConfig.maybeSync(
            reason: 'remote setting re-enabled',
            force: true,
          ),
        ).called(1);
      },
    );
  });
}
