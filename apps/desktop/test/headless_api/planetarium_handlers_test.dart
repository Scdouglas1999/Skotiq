import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/planetarium_handlers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('PlanetariumHandlers', () {
    late ProviderContainer container;
    late PlanetariumHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = PlanetariumHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('subscribe info returns JSON websocket metadata', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetSubscribeInfo(
          Request(
            'GET',
            Uri.parse('http://localhost:8080/api/planetarium/subscribe-info'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['websocketUrl'], 'ws://localhost:8080/api/ws');
      expect(body['alternateUrl'], 'ws://localhost:8080/events');
      expect(body['pingPongSupport'], isTrue);
      expect(body['eventTypes'], contains('mount_position'));
    });

    test(
      'catalog region missing parameters returns JSON bad request',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCatalogRegion(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/planetarium/catalog/region?ra=12.5',
              ),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(
          body['error'],
          'Missing required parameters: ra, dec, radius (in degrees)',
        );
      },
    );

    test('catalog region rejects impossible cones and unknown types', () async {
      for (final query in const [
        'ra=-1&dec=0&radius=1',
        'ra=0&dec=91&radius=1',
        'ra=0&dec=0&radius=-1',
        'ra=0&dec=0&radius=181',
        'ra=0&dec=0&radius=1&type=planet',
      ]) {
        final response = await translateHandlerErrors(
          handlers.handleCatalogRegion(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/planetarium/catalog/region?$query',
              ),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest, reason: query);
        expect(response.headers['content-type'], 'application/json');
      }
    });

    test('slew to malformed payload returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handleSlewTo(
          Request(
            'POST',
            Uri.parse('http://localhost/api/planetarium/slew-to'),
            body: jsonEncode({}),
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
    });

    test('catalog search rejects malformed or unsafe limits', () async {
      for (final limit in const ['many', '0', '-1', '501']) {
        final response = await translateHandlerErrors(
          handlers.handleCatalogSearch(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/planetarium/catalog/search?query=M31&limit=$limit',
              ),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: limit);
      }
    });

    test('observing-list query IDs must be positive integers', () async {
      final handlersByPath = <String, Future<Response> Function(Request)>{
        'items': handlers.handleGetObservingListItems,
        'listed-catalog-ids': handlers.handleGetListedCatalogIds,
      };
      for (final entry in handlersByPath.entries) {
        for (final id in const ['abc', '0', '-1']) {
          final response = await translateHandlerErrors(
            entry.value(
              Request(
                'GET',
                Uri.parse(
                  'http://localhost/api/observing-lists/${entry.key}?listId=$id',
                ),
              ),
            ),
          );
          expect(
            response.statusCode,
            HttpStatus.badRequest,
            reason: '${entry.key}: $id',
          );
        }
      }
    });

    test('observing-list delete IDs must be positive integers', () async {
      final handlersByPath = <String, Future<Response> Function(Request)>{
        'lists': handlers.handleDeleteObservingList,
        'items': handlers.handleRemoveObservingListItem,
      };
      for (final entry in handlersByPath.entries) {
        for (final id in const ['abc', '0', '-1']) {
          final response = await translateHandlerErrors(
            entry.value(
              Request(
                'DELETE',
                Uri.parse('http://localhost/api/observing-${entry.key}?id=$id'),
              ),
            ),
          );
          expect(
            response.statusCode,
            HttpStatus.badRequest,
            reason: '${entry.key}: $id',
          );
        }
      }
    });

    test('observing-list update can explicitly clear a description', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      container.dispose();
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      handlers = PlanetariumHandlers(container);
      final id = await database.observingListsDao.createList(
        name: 'Winter targets',
        description: 'Old description',
      );

      final response = await translateHandlerErrors(
        handlers.handleUpdateObservingList(
          Request(
            'POST',
            Uri.parse('http://localhost/api/observing-lists/update'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'id': id, 'description': null}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(
        (await database.observingListsDao.getListById(id))!.description,
        isNull,
      );
    });
  });
}
