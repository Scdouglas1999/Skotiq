// End-to-end proof that the Living Sky atlas handlers emit the unified error
// envelope, and that those responses decode through the single converged
// client parser ([ServerError.tryFromJson]) with a non-empty machine code —
// while still carrying a human-readable `error` string for legacy display
// clients.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/atlas_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockSkyAtlasService extends Mock implements SkyAtlasService {}

void main() {
  group('AtlasHandlers error envelope', () {
    late ProviderContainer container;
    late AtlasHandlers handlers;
    late _MockSkyAtlasService service;

    setUp(() {
      service = _MockSkyAtlasService();
      container = ProviderContainer(
        overrides: [skyAtlasServiceProvider.overrideWithValue(service)],
      );
      handlers = AtlasHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    Future<void> expectUnifiedError(
      Response response, {
      required int expectedStatus,
    }) async {
      expect(response.statusCode, expectedStatus);
      expect(response.headers['content-type'], 'application/json');

      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;

      // Legacy display field is still a human-readable string.
      expect(body['error'], isA<String>());
      expect((body['error'] as String), isNotEmpty);

      // Machine code present and non-empty.
      expect(body['code'], isA<String>());
      expect((body['code'] as String), isNotEmpty);

      // Decodes through the single converged parser with a non-empty code.
      final parsed = ServerError.tryFromJson(body, httpStatus: expectedStatus);
      expect(parsed, isNotNull);
      expect(parsed!.code, isNotEmpty);
      expect(parsed.message, body['message']);
      expect(parsed.httpStatus, expectedStatus);
    }

    test(
      'GET region with a non-integer id returns a 400 unified error',
      () async {
        final response = await handlers.handleGetRegion(
          Request(
            'GET',
            Uri.parse('http://localhost/api/atlas/region/not-an-id'),
          ),
          'not-an-id',
        );

        await expectUnifiedError(
          response,
          expectedStatus: HttpStatus.badRequest,
        );
      },
    );

    test(
      'GET region cutout with a non-integer id returns a 400 unified error',
      () async {
        final response = await handlers.handleGetRegionCutout(
          Request(
            'GET',
            Uri.parse('http://localhost/api/atlas/region/nope/cutout'),
          ),
          'nope',
        );

        await expectUnifiedError(
          response,
          expectedStatus: HttpStatus.badRequest,
        );
      },
    );

    test('GET region timeline with a non-integer id returns a 400 unified '
        'error', () async {
      final response = await handlers.handleGetRegionTimeline(
        Request(
          'GET',
          Uri.parse('http://localhost/api/atlas/region/xyz/timeline'),
        ),
        'xyz',
      );

      await expectUnifiedError(response, expectedStatus: HttpStatus.badRequest);
    });

    test('cutout rejects unsafe outPixels before resolving a region', () async {
      for (final raw in ['abc', '0', '-1', '4097', '1.5']) {
        final response = await translateHandlerErrors(
          handlers.handleGetRegionCutout(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/atlas/region/1/cutout?outPixels='
                '${Uri.encodeQueryComponent(raw)}',
              ),
            ),
            '1',
          ),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: raw);
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(body['field'], 'outPixels', reason: raw);
      }
    });

    test('POST regions persists validated metadata on the host', () async {
      when(
        () => service.ensureRegion(
          name: any(named: 'name'),
          centerRaDeg: any(named: 'centerRaDeg'),
          centerDecDeg: any(named: 'centerDecDeg'),
          radiusDeg: any(named: 'radiusDeg'),
          kind: any(named: 'kind'),
          targetId: any(named: 'targetId'),
        ),
      ).thenAnswer((_) async => 42);

      final response = await handlers.handleCreateRegion(
        Request(
          'POST',
          Uri.parse('http://localhost/api/atlas/regions'),
          body: jsonEncode({
            'name': '  M31 core  ',
            'centerRaDeg': 10.68,
            'centerDecDeg': 41.27,
            'radiusDeg': 1.5,
            'kind': 'target',
            'targetId': 31,
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(jsonDecode(await response.readAsString()), {'id': 42});
      verify(
        () => service.ensureRegion(
          name: 'M31 core',
          centerRaDeg: 10.68,
          centerDecDeg: 41.27,
          radiusDeg: 1.5,
          kind: 'target',
          targetId: 31,
        ),
      ).called(1);
    });

    test('POST regions rejects impossible sky coordinates', () async {
      for (final payload in [
        {
          'name': 'Bad RA',
          'centerRaDeg': 361,
          'centerDecDeg': 0,
          'radiusDeg': 1,
        },
        {
          'name': 'Bad Dec',
          'centerRaDeg': 10,
          'centerDecDeg': -91,
          'radiusDeg': 1,
        },
        {
          'name': 'Bad radius',
          'centerRaDeg': 10,
          'centerDecDeg': 20,
          'radiusDeg': 0,
        },
      ]) {
        final response = await translateHandlerErrors(
          handlers.handleCreateRegion(
            Request(
              'POST',
              Uri.parse('http://localhost/api/atlas/regions'),
              body: jsonEncode(payload),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: '$payload');
      }
      verifyNever(
        () => service.ensureRegion(
          name: any(named: 'name'),
          centerRaDeg: any(named: 'centerRaDeg'),
          centerDecDeg: any(named: 'centerDecDeg'),
          radiusDeg: any(named: 'radiusDeg'),
          kind: any(named: 'kind'),
          targetId: any(named: 'targetId'),
        ),
      );
    });
  });
}
