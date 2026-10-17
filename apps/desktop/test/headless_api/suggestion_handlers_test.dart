import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/suggestion_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SuggestionHandlers', () {
    late ProviderContainer container;
    late SuggestionHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = SuggestionHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('get config returns JSON default config', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetConfig(
          Request('GET', Uri.parse('http://localhost/api/suggestions/config')),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['config'], isA<Map>());
    });

    test('invalid target ID returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetTargetScore(
          Request(
            'GET',
            Uri.parse('http://localhost/api/suggestions/score/not-an-id'),
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
  });

  // Fail-closed validation of GET /api/suggestions/tonight. A supplied but
  // invalid query param must be a 400 raised BEFORE the databaseProvider is
  // read — so these run against a bare container with no DB override, proving
  // no work happens on rejection.
  group('SuggestionHandlers tonight query validation (fail-closed)', () {
    late ProviderContainer container;
    late SuggestionHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = SuggestionHandlers(container);
    });
    tearDown(() => container.dispose());

    Future<Response> tonight(String qs) => translateHandlerErrors(
      handlers.handleGetSuggestionsForTonight(
        Request(
          'GET',
          Uri.parse('http://localhost/api/suggestions/tonight$qs'),
        ),
      ),
    );

    Future<void> expectBadField(String qs, String field) async {
      final r = await tonight(qs);
      expect(r.statusCode, HttpStatus.badRequest, reason: qs);
      final body = jsonDecode(await r.readAsString()) as Map;
      expect(body['field'], field, reason: qs);
    }

    test(
      'minAltitude: malformed / NaN / infinity / out-of-range → 400',
      () async {
        await expectBadField('?minAltitude=abc', 'minAltitude');
        await expectBadField('?minAltitude=NaN', 'minAltitude');
        await expectBadField('?minAltitude=Infinity', 'minAltitude');
        await expectBadField('?minAltitude=-91', 'minAltitude');
        await expectBadField('?minAltitude=91', 'minAltitude');
      },
    );

    test('minScore: malformed / NaN / out-of-range → 400', () async {
      await expectBadField('?minScore=abc', 'minScore');
      await expectBadField('?minScore=NaN', 'minScore');
      await expectBadField('?minScore=-1', 'minScore');
      await expectBadField('?minScore=101', 'minScore');
    });

    test(
      'maxResults: zero / negative / over-bound / non-integer → 400',
      () async {
        await expectBadField('?maxResults=0', 'maxResults');
        await expectBadField('?maxResults=-5', 'maxResults');
        await expectBadField('?maxResults=1001', 'maxResults');
        await expectBadField('?maxResults=5.5', 'maxResults');
        await expectBadField('?maxResults=abc', 'maxResults');
      },
    );

    test('sortMode: unknown value → 400 (not a silent bestScore)', () async {
      await expectBadField('?sortMode=bogus', 'sortMode');
    });

    test('prioritizeIncomplete: non-boolean → 400', () async {
      await expectBadField(
        '?prioritizeIncomplete=maybe',
        'prioritizeIncomplete',
      );
    });
  });

  // Valid params must flow through to the service (200) — the defaults on
  // absence and the accepted boundary values.
  group('SuggestionHandlers tonight valid forwarding', () {
    late SkotiqDatabase db;
    late ProviderContainer container;
    late SuggestionHandlers handlers;

    setUp(() async {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      // A configured location is a precondition; without it the handler returns
      // a *different* 400 that would mask the validation behaviour under test.
      await db.settingsDao.setObserverLatitude(40.0);
      await db.settingsDao.setObserverLongitude(-74.0);
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      handlers = SuggestionHandlers(container);
    });
    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<Response> tonight(String qs) => translateHandlerErrors(
      handlers.handleGetSuggestionsForTonight(
        Request(
          'GET',
          Uri.parse('http://localhost/api/suggestions/tonight$qs'),
        ),
      ),
    );

    test('absent params use defaults and return 200', () async {
      final r = await tonight('');
      expect(r.statusCode, HttpStatus.ok);
      final body = jsonDecode(await r.readAsString()) as Map;
      expect(body['suggestions'], isEmpty); // no targets seeded
    });

    test(
      'valid boundary + enum + normalized values are accepted (200)',
      () async {
        for (final qs in [
          '?minAltitude=-90&minScore=0&maxResults=1',
          '?minAltitude=90&minScore=100&maxResults=1000',
          '?sortMode=leastDataCollected&prioritizeIncomplete=false',
          '?sortMode=nearestTransit&prioritizeIncomplete=true',
          '?objectTypes=Galaxy,,Nebula', // blank entries are normalized away
        ]) {
          final r = await tonight(qs);
          expect(r.statusCode, HttpStatus.ok, reason: qs);
        }
      },
    );
  });
}
