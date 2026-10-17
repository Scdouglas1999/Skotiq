import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/routes/headless_route.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

/// Stand-in for a real literal-path handler.
Future<Response> _ok(Request request) async => Response.ok('real handler');

Future<Response> _byId(Request request, String id) async {
  final parsed = int.tryParse(id);
  if (parsed == null) {
    // Verbatim shape of the handler that produced the misleading answer.
    return Response(
      400,
      body: jsonEncode({
        'error': 'Path segment is not a valid integer',
        'field': 'id',
        'expected': 'integer',
      }),
      headers: const {'content-type': 'application/json'},
    );
  }
  return Response.ok('dark $parsed');
}

/// The shape of the real table: literal siblings first, the `<id>` route after.
List<HeadlessRoute> _darkRoutes() => <HeadlessRoute>[
  HeadlessRoute(HttpMethod.get, '/api/calibration/darks', _ok),
  HeadlessRoute(HttpMethod.post, '/api/calibration/darks', _ok),
  HeadlessRoute(HttpMethod.post, '/api/calibration/darks/find-match', _ok),
  HeadlessRoute(HttpMethod.get, '/api/calibration/darks/settings', _ok),
  HeadlessRoute(HttpMethod.post, '/api/calibration/darks/settings', _ok),
  HeadlessRoute(HttpMethod.post, '/api/calibration/darks/clear', _ok),
  HeadlessRoute(HttpMethod.get, '/api/calibration/darks/<id>', _byId),
  HeadlessRoute(HttpMethod.delete, '/api/calibration/darks/<id>', _byId),
];

Router _router(List<HeadlessRoute> routes) {
  final router = Router();
  registerRoutes(router, routes);
  return router;
}

Future<Response> _call(Router router, String method, String path) =>
    Future.value(
      router.call(Request(method, Uri.parse('http://localhost$path'))),
    );

void main() {
  group('a wrong verb on a literal path answers 405, not the <id> route', () {
    late Router router;

    setUp(() => router = _router(_darkRoutes()));

    test('the exact rig case', () async {
      final response = await _call(
        router,
        'GET',
        '/api/calibration/darks/find-match',
      );

      expect(response.statusCode, 405);
      expect(response.headers['allow'], 'POST');

      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['code'], 'method_not_allowed');
      expect(body['error'], contains('GET is not supported'));
      expect(body['error'], contains('accepts: POST'));
      expect(
        body['error'],
        isNot(contains('integer')),
        reason:
            'the old answer named a field the caller never sent and pointed '
            'away from its own cause',
      );
    });

    test(
      'every verb the path does implement still reaches its handler',
      () async {
        expect(
          (await _call(
            router,
            'POST',
            '/api/calibration/darks/find-match',
          )).statusCode,
          200,
        );
        expect(
          (await _call(
            router,
            'GET',
            '/api/calibration/darks/settings',
          )).statusCode,
          200,
        );
        expect(
          (await _call(
            router,
            'POST',
            '/api/calibration/darks/settings',
          )).statusCode,
          200,
        );
      },
    );

    test('Allow lists every implemented verb, not just one', () async {
      final response = await _call(
        router,
        'DELETE',
        '/api/calibration/darks/settings',
      );

      expect(response.statusCode, 405);
      expect(response.headers['allow'], 'GET, POST');
    });

    test('the parameterised route is untouched for real ids', () async {
      final response = await _call(router, 'GET', '/api/calibration/darks/42');

      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'dark 42');
    });

    test('an unregistered path is still a 404, not a 405', () async {
      // 405 asserts the path exists, so claiming it for a path nobody
      // registered would be its own false statement.
      final response = await _call(router, 'GET', '/api/calibration/nope');
      expect(response.statusCode, 404);
    });
  });

  group('withMethodNotAllowedFallbacks', () {
    test('leaves parameterised paths alone', () {
      final expanded = withMethodNotAllowedFallbacks(<HeadlessRoute>[
        HeadlessRoute(HttpMethod.get, '/api/things/<id>', _byId),
      ]);

      expect(expanded, hasLength(1));
    });

    test('stubs land after the last real registration of their path', () {
      final expanded = withMethodNotAllowedFallbacks(_darkRoutes());
      final paths = expanded.map((r) => r.path).toList();

      // The `<id>` route must still come after every literal sibling AND after
      // the synthesized stubs for those siblings, or a stub would be shadowed
      // by the parameterised route it exists to pre-empt.
      final lastLiteral = paths.lastIndexWhere((p) => !p.contains('<'));
      final firstParam = paths.indexWhere((p) => p.contains('<'));
      expect(lastLiteral, lessThan(firstParam));

      // Both real POST /settings and real GET /settings precede their stubs.
      final settings = <int>[
        for (var i = 0; i < expanded.length; i++)
          if (expanded[i].path == '/api/calibration/darks/settings') i,
      ];
      final realCount = expanded
          .where(
            (r) =>
                r.path == '/api/calibration/darks/settings' &&
                (r.method == HttpMethod.get || r.method == HttpMethod.post),
          )
          .length;
      expect(realCount, 2);
      expect(settings.length, 5, reason: 'GET, POST + PUT/DELETE/PATCH stubs');
    });

    test('does not synthesize HEAD or OPTIONS', () {
      // HEAD is a legitimate probe of a GET route and OPTIONS is CORS
      // preflight; answering either with 405 would break working clients.
      final expanded = withMethodNotAllowedFallbacks(<HeadlessRoute>[
        HeadlessRoute(HttpMethod.get, '/api/thing', _ok),
      ]);

      expect(expanded.map((r) => r.method), isNot(contains(HttpMethod.head)));
      expect(
        expanded.map((r) => r.method),
        isNot(contains(HttpMethod.options)),
      );
    });
  });
}
