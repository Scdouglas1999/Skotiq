import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/wire.dart';

void main() {
  final routes = [for (final endpoint in apiEndpoints) endpoint.route];

  group('declared route policy', () {
    test('every method and path is declared once', () {
      final seen = <String>{};
      for (final route in routes) {
        expect(seen.add(route.signature), isTrue, reason: route.signature);
      }
    });

    test('a high-risk route is audited', () {
      for (final route in routes) {
        if (route.rate != ApiRateTier.highRisk) continue;
        expect(route.audit, isNotNull, reason: route.signature);
      }
    });

    test('a write that needs no token is rate limited', () {
      for (final route in routes) {
        if (route.scope != ApiScope.public) continue;
        if (route.method == ApiMethod.get) continue;
        expect(route.rate, isNot(ApiRateTier.none), reason: route.signature);
      }
    });

    test('only a stream has no time budget', () {
      for (final route in routes) {
        if (route.method == ApiMethod.ws) {
          expect(route.timeout, ApiTimeout.openEnded, reason: route.signature);
        }
        if (route.timeout == ApiTimeout.openEnded) {
          expect(
            route.method,
            anyOf(ApiMethod.ws, ApiMethod.get),
            reason: route.signature,
          );
        }
      }
    });
  });

  group('advertised lists', () {
    test('the endpoint list is the API routes and the WebSocket upgrades', () {
      expect(advertisedApiEndpoints, contains('GET /api/info'));
      expect(advertisedApiEndpoints, contains('WS /api/ws'));
      expect(advertisedApiEndpoints, contains('WS /events'));
      expect(advertisedApiEndpoints, isNot(contains('GET /dashboard')));
      expect(advertisedApiEndpoints, isNot(contains('GET /pair')));
    });

    test('the endpoint list is in one fixed order: by path, then method', () {
      final sorted = [...advertisedApiEndpoints]
        ..sort((a, b) {
          final pathA = a.substring(a.indexOf(' ') + 1);
          final pathB = b.substring(b.indexOf(' ') + 1);
          final byPath = pathA.compareTo(pathB);
          return byPath != 0 ? byPath : a.compareTo(b);
        });
      expect(advertisedApiEndpoints, sorted);
      expect(
        advertisedApiEndpoints.toSet().length,
        advertisedApiEndpoints.length,
      );
      // Not the order requests are matched in, which moves with the groups.
      final matchOrder = [
        for (final endpoint in apiEndpoints)
          if (advertisedApiEndpoints.contains(endpoint.route.signature))
            endpoint.route.signature,
      ];
      expect(matchOrder.toSet(), advertisedApiEndpoints.toSet());
      expect(matchOrder, isNot(advertisedApiEndpoints));
    });

    test('a public page root stands for the pages under it', () {
      expect(publicApiPaths, [
        '/',
        '/api/broadcast/info',
        '/api/broadcast/live-stack',
        '/api/broadcast/sse',
        '/api/info',
        '/api/pairing/lan-claim',
        '/api/pairing/start',
        '/api/pairing/verify',
        '/broadcast',
        '/dashboard',
        '/favicon.ico',
        '/pair',
        '/run-watch',
      ]);
    });
  });

  group('ApiRoute.fill', () {
    test('substitutes and encodes each parameter', () {
      const route = ApiRoute.get(
        '/api/things/<id>/parts/<name|[^/]+>',
        resource: ApiResource.system,
      );
      expect(
        route.fill({'id': 7, 'name': 'a b/c'}),
        '/api/things/7/parts/a%20b%2Fc',
      );
    });

    test('refuses a missing parameter', () {
      const route = ApiRoute.get(
        '/api/things/<id>',
        resource: ApiResource.system,
      );
      expect(() => route.fill(const {}), throwsArgumentError);
    });
  });

  group('ApiResource.tryParse', () {
    test('reads every resource by the name grants and 403 bodies use', () {
      for (final resource in ApiResource.values) {
        expect(ApiResource.tryParse(resource.wireName), resource);
      }
    });

    test('reads the other spellings a grant spec may use', () {
      expect(ApiResource.tryParse(' FilterWheel '), ApiResource.filterWheel);
      expect(ApiResource.tryParse('guider'), ApiResource.guiding);
      expect(ApiResource.tryParse('weather'), ApiResource.safety);
      expect(ApiResource.tryParse('files'), ApiResource.filesystem);
      expect(ApiResource.tryParse('co-imaging'), ApiResource.coimaging);
      expect(ApiResource.tryParse('collaboration'), ApiResource.constellation);
    });

    test('reads nothing else', () {
      expect(ApiResource.tryParse('telescope'), isNull);
      expect(ApiResource.tryParse(null), isNull);
    });
  });

  group('requests that match no route', () {
    test('are held to their verb on the path’s resource', () {
      final wrongVerb = apiRouteIndex.policyFor('GET', '/api/mount/slew');
      expect(wrongVerb.scope, ApiScope.view);
      expect(wrongVerb.resource, ApiResource.mount);

      final unknown = apiRouteIndex.policyFor('POST', '/api/nope');
      expect(unknown.scope, ApiScope.control);
      expect(unknown.resource, ApiResource.system);
      expect(unknown.rate, ApiRateTier.none);
    });

    test('stay public on a path whose own route is public', () {
      expect(
        apiRouteIndex.policyFor('POST', '/api/info').scope,
        ApiScope.public,
      );
    });
  });
}
