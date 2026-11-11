import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/route_table.dart';
import 'package:shelf/shelf.dart';

import '../support/route_policy.dart';

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

const _darks = '/api/calibration/darks';
const _calibration = ApiResource.calibration;

class _Routes implements RouteSource {
  const _Routes(this.routes);

  @override
  final Map<ApiEndpoint, Function> routes;
}

/// The shape of the real table: literal siblings first, the `<id>` route after.
_Routes _darkRoutes() => const _Routes({
  TestEndpoint(ApiRoute.get(_darks, resource: _calibration)): _ok,
  TestEndpoint(ApiRoute.post(_darks, resource: _calibration)): _ok,
  TestEndpoint(ApiRoute.post('$_darks/find-match', resource: _calibration)):
      _ok,
  TestEndpoint(ApiRoute.get('$_darks/settings', resource: _calibration)): _ok,
  TestEndpoint(ApiRoute.post('$_darks/settings', resource: _calibration)): _ok,
  TestEndpoint(ApiRoute.post('$_darks/clear', resource: _calibration)): _ok,
  TestEndpoint(ApiRoute.get('$_darks/<id>', resource: _calibration)): _byId,
  TestEndpoint(ApiRoute.delete('$_darks/<id>', resource: _calibration)): _byId,
});

RouteTable _router(_Routes routes) => RouteTable.only(routes);

Future<Response> _call(RouteTable router, String method, String path) =>
    Future.value(
      router.handler(Request(method, Uri.parse('http://localhost$path'))),
    );

void main() {
  group('a wrong verb on a literal path answers 405, not the <id> route', () {
    late RouteTable router;

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

  group('route resolution', () {
    test('a parameterised path is never refused for its verb', () {
      final index = ApiRouteIndex(const [
        ApiRoute.get('/api/things/<id>', resource: ApiResource.system),
      ]);

      expect(index.resolve('POST', '/api/things/5'), isA<ApiRouteNotFound>());
    });

    test('a parameterised route declared before a literal one keeps it', () {
      final index = ApiRouteIndex(const [
        ApiRoute.get('/api/things/<id>', resource: ApiResource.system),
        ApiRoute.post('/api/things/find', resource: ApiResource.system),
      ]);

      final resolution = index.resolve('GET', '/api/things/find');
      expect(resolution, isA<ApiRouteMatched>());
      expect((resolution as ApiRouteMatched).params, {'id': 'find'});
    });

    test('HEAD resolves as GET and OPTIONS is not refused as a wrong verb', () {
      // HEAD is a legitimate probe of a GET route and OPTIONS is CORS
      // preflight; answering either with 405 would break working clients.
      final index = ApiRouteIndex(const [
        ApiRoute.get('/api/thing', resource: ApiResource.system),
      ]);

      expect(index.resolve('HEAD', '/api/thing'), isA<ApiRouteMatched>());
      expect(index.resolve('OPTIONS', '/api/thing'), isA<ApiRouteNotFound>());
      expect(index.resolve('PUT', '/api/thing'), isA<ApiMethodNotAllowed>());
    });
  });
}
