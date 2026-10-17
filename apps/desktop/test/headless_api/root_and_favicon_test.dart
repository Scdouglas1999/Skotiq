import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api_server.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'handler_test_helpers.dart';

/// Someone typing the appliance's address into a browser must get something
/// comprehensible.
///
/// Measured against the running server: `GET /` returned
/// `{"error":"Authentication required", ...}` with `content-type:
/// application/json` and a 401 when unauthenticated, and a plain-text
/// `Route not found` (404) once authenticated. The site root had no route at
/// all, so an operator who did not already know `/dashboard` existed had nothing
/// to work from. `/favicon.ico` — which browsers request unprompted on every
/// page load — also 401'd, putting an authentication failure in the server log
/// and an error in the console for every page view.
void main() {
  group('site root and favicon', () {
    late ProviderContainer container;
    late HeadlessApiServer server;
    late HttpClient client;
    late Uri baseUri;

    setUp(() async {
      container = createHeadlessTestContainer(
        overrides: [
          appVersionProvider.overrideWithValue(
            const AppVersionInfo(version: '2.5.0', buildNumber: 5),
          ),
        ],
      );
      server = HeadlessApiServer(
        port: 0,
        container: container,
        bindLocalOnly: true,
        authToken: 'admin-token',
        scopedAuthTokens: const {'view-token': HeadlessTokenScope.view},
      );
      await server.start();
      client = HttpClient();
      baseUri = Uri.parse('http://127.0.0.1:${server.actualPort}');
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      container.dispose();
    });

    Future<HttpClientResponse> get(String path, {String? accept}) async {
      final request = await client.getUrl(baseUri.resolve(path));
      // Do NOT follow the redirect: the 302 itself is what is under test.
      request.followRedirects = false;
      if (accept != null) request.headers.set(HttpHeaders.acceptHeader, accept);
      return request.close();
    }

    test(
      'a browser at / is redirected to the dashboard, unauthenticated',
      () async {
        final response = await get(
          '/',
          accept: 'text/html,application/xhtml+xml',
        );

        expect(response.statusCode, HttpStatus.found);
        expect(
          response.headers.value(HttpHeaders.locationHeader),
          '/dashboard',
        );
      },
    );

    test('a machine at / gets a JSON pointer, not an auth error', () async {
      final response = await get('/', accept: 'application/json');
      final body =
          jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, dynamic>;

      expect(response.statusCode, HttpStatus.ok);
      expect(body['service'], 'skotiq');
      expect(body['api'], '/api/info');
      // `dashboard` is null when the SPA directory is not present next to the
      // test binary; the key must exist either way so a client can discover it.
      expect(body.containsKey('dashboard'), isTrue);
      expect(body['error'], isNull);
    });

    test('/favicon.ico answers 204 instead of 401', () async {
      final response = await get('/favicon.ico');

      expect(response.statusCode, HttpStatus.noContent);
      await response.drain<void>();
    });

    test('exempting / did not open anything else', () async {
      // The allowlist is exact-match, so a protected endpoint must still refuse.
      final response = await get(
        '/api/openapi.json',
        accept: 'application/json',
      );
      final body =
          jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, dynamic>;

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(body['error'], 'Authentication required');
    });
  });
}
