import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:skotiq_remote_protocol/wire.dart';

/// The route index answers by hash and prefix what a first-match walk over
/// the ordered list answers by testing every route. This holds it to the
/// walk: a shelf_router built from the same declarations, with a 405 entry
/// after the last route of each literal path for the verbs it lacks.
void main() {
  const verbs = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'];

  Router referenceRouter(List<ApiRoute> routes) {
    final lastOfPath = <String, int>{};
    final verbsOfPath = <String, Set<String>>{};
    for (var i = 0; i < routes.length; i++) {
      final route = routes[i];
      if (route.path.contains('<')) continue;
      lastOfPath[route.path] = i;
      (verbsOfPath[route.path] ??= {}).add(route.method.httpVerb);
    }
    final router = Router();
    for (var i = 0; i < routes.length; i++) {
      final route = routes[i];
      // Declared with the widest arity so one closure serves every route.
      router.add(
        route.method.httpVerb,
        route.path,
        (Request request) => Response.ok('$i'),
      );
      if (lastOfPath[route.path] != i) continue;
      for (final verb in verbs) {
        if (verbsOfPath[route.path]!.contains(verb)) continue;
        router.add(verb, route.path, (Request request) => Response(405));
      }
    }
    return router;
  }

  test('resolves every route, verb and sibling path as a first-match walk '
      'does', () async {
    final routes = apiRouteIndex.routes;
    final router = referenceRouter(routes);

    final paths = <String>{'/api/nope', '/nope', '/api'};
    final parameter = RegExp(r'<[^>]+>');
    for (final route in routes) {
      paths
        ..add(route.path.replaceAll(parameter, 'x'))
        ..add(route.path.replaceAll(parameter, '7'))
        ..add('${route.path.replaceAll(parameter, '7')}/extra');
    }

    var checked = 0;
    for (final path in paths) {
      for (final verb in [...verbs, 'HEAD']) {
        final response = await router.call(
          Request(verb, Uri.parse('http://localhost$path')),
        );
        final expected = switch (response.statusCode) {
          200 => await response.readAsString(),
          405 => '405',
          _ => '404',
        };
        final resolution = apiRouteIndex.resolve(verb, path);
        final actual = switch (resolution) {
          ApiRouteMatched(:final position) => '$position',
          ApiMethodNotAllowed() => '405',
          ApiRouteNotFound() => '404',
        };
        // shelf_router answers HEAD from the GET entry with the body removed.
        if (verb == 'HEAD' && response.statusCode == 200) {
          expect(resolution, isA<ApiRouteMatched>(), reason: '$verb $path');
        } else {
          expect(actual, expected, reason: '$verb $path');
        }
        checked++;
      }
    }
    expect(checked, greaterThan(5000));
  });

  test('every declared route is unique by method and path', () {
    final signatures = <String>{};
    for (final route in apiRouteIndex.routes) {
      expect(signatures.add(route.signature), isTrue, reason: route.signature);
    }
  });
}
