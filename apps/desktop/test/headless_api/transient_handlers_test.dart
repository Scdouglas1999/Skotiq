import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/transient_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TransientHandlers', () {
    late ProviderContainer container;
    late TransientHandlers handlers;
    late SkotiqDatabase database;

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      handlers = TransientHandlers(container);
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    test('get settings returns JSON defaults', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetSettings(
          Request('GET', Uri.parse('http://localhost/api/transients/settings')),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['settings'], isA<Map>());
    });

    test(
      'update settings malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleUpdateSettings(
            Request(
              'POST',
              Uri.parse('http://localhost/api/transients/settings'),
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

    test('queue transient returns JSON state', () async {
      final response = await translateHandlerErrors(
        handlers.handleQueueTransient(
          Request(
            'POST',
            Uri.parse('http://localhost/api/transients/t-1/queue'),
          ),
          't-1',
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['status'], 'queued');
      expect(body['alertId'], 't-1');
      expect(body['queuedCount'], 1);
      expect(
        await database.settingsDao.getSetting('transient_alert_state_t-1'),
        'queued',
      );
    });

    test('generic alert states survive handler recreation', () async {
      final update = await translateHandlerErrors(
        handlers.handleUpdateState(
          Request(
            'POST',
            Uri.parse('http://localhost/api/transients/t-2/state'),
            body: '{"state":"observed"}',
          ),
          't-2',
        ),
      );
      expect(update.statusCode, HttpStatus.ok);

      container.invalidate(transientAlertStatesProvider);
      final recreated = TransientHandlers(container);
      final response = await translateHandlerErrors(
        recreated.handleGetStates(
          Request('GET', Uri.parse('http://localhost/api/transients/states')),
        ),
      );
      final body = jsonDecode(await response.readAsString()) as Map;
      expect((body['states'] as Map)['t-2'], 'observed');
    });
  });
}
