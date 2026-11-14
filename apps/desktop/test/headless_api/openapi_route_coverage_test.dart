import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/openapi.dart';
import 'package:skotiq_remote_protocol/wire.dart';

void main() {
  group('OpenAPI spec', () {
    test('OpenAPI spec lists every advertised HTTP route', () {
      final routes = [
        for (final endpoint in apiEndpoints)
          if (endpoint.route.path.startsWith('/api/')) endpoint.route,
      ];
      final spec = buildOpenApiSpec(routes: routes, port: 8080);
      final paths = spec['paths'] as Map<String, dynamic>;

      for (final route in routes.where((r) => r.method != ApiMethod.ws)) {
        expect(
          paths[openApiPath(route.path)],
          contains(route.method.wireName.toLowerCase()),
          reason: 'OpenAPI must include advertised route $route.',
        );
      }

      expect(
        paths.keys.any((path) => path == '/api/ws' || path == '/events'),
        isFalse,
        reason:
            'WebSocket endpoints are advertised in /api/info but not OpenAPI.',
      );
    });
  });
}
