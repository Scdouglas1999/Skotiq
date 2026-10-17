import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/static_file_handlers.dart';
import 'package:skotiq_desktop/headless_api/routes/headless_route.dart';
import 'package:skotiq_desktop/headless_api/routes/static_file_routes.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

/// D4W-4 — the run-watch SPA must have exactly one address.
///
/// The service worker registers with scope `/run-watch/`, so a document served
/// at `/run-watch` is outside it and nothing controls the page. Measured
/// against the release bundle: with the daemon killed, `/run-watch` rendered
/// Chrome's ERR_CONNECTION_REFUSED interstitial while `/run-watch/` loaded the
/// cached offline shell in the same browser, the same second. Both spellings
/// answered 200 and neither redirected.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LoggingService logger;
  late Router router;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ns_static_routes_test_');
    logger = LoggingService(
      applicationSupportDirectoryProvider: () async => tempDir,
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
    await logger.ensureInitialized();
    router = Router();
    registerRoutes(
      router,
      buildStaticFileRoutes(StaticFileHandlers(logger: logger)),
    );
  });

  tearDown(() async {
    await logger.dispose();
    await tempDir.delete(recursive: true);
  });

  test('GET /run-watch redirects permanently to the canonical URL', () async {
    final response = await router(
      Request('GET', Uri.parse('http://localhost/run-watch')),
    );

    expect(response.statusCode, HttpStatus.movedPermanently);
    expect(response.headers['location'], '/run-watch/');
  });

  test('the redirect carries the query string across', () async {
    final response = await router(
      Request('GET', Uri.parse('http://localhost/run-watch?token=abc&x=1')),
    );

    expect(response.statusCode, HttpStatus.movedPermanently);
    expect(response.headers['location'], '/run-watch/?token=abc&x=1');
  });

  test('the redirect asks for no credential of its own', () async {
    final response = await router(
      Request('GET', Uri.parse('http://localhost/run-watch')),
    );

    expect(response.headers['www-authenticate'], isNull);
    expect(response.headers['set-cookie'], isNull);
    expect(await response.readAsString(), isEmpty);
  });

  test('GET /run-watch/ is served, never redirected', () async {
    final response = await router(
      Request('GET', Uri.parse('http://localhost/run-watch/')),
    );

    expect(
      response.statusCode,
      isNot(HttpStatus.movedPermanently),
      reason: 'the canonical URL must not bounce — that is a redirect loop',
    );
    expect(response.headers['location'], isNull);
  });

  test('nested run-watch assets are untouched by the redirect', () async {
    for (final path in ['/run-watch/sw.js', '/run-watch/js/run-watch.js']) {
      final response = await router(
        Request('GET', Uri.parse('http://localhost$path')),
      );
      expect(
        response.statusCode,
        isNot(HttpStatus.movedPermanently),
        reason: '$path is an asset, not the SPA entry point',
      );
    }
  });

  // -------------------------------------------------------------------------
  // D4-02 — the public prefix carries only what the pages need.
  //
  // `/dashboard` and `/run-watch` are whole-subtree exemptions from the bearer
  // middleware (auth/public_paths.dart), so every file the bundler copied into
  // the SPA directory was readable with no credential. Measured against the
  // release bundle:
  //   curl -o /dev/null -w '%{http_code} %{size_download}'  \
  //     http://127.0.0.1:8212/dashboard/README.md    ->  200 16038
  // 16KB of internal developer documentation describing the sessionStorage
  // bearer path, the `GET /api/auth/csrf` cookie resume, the pairing
  // endpoints, the bearer-to-HttpOnly-cookie upgrade and its 30-day Max-Age,
  // the single-use WS ticket and its `?token=` fallback, the bearer-in-a-
  // query-string SSE log tail, the per-token rate budget, and the
  // `SKOTIQ_REQUIRE_AUTH=false` escape hatch. The SPA loads index.html,
  // css/dashboard.css, js/api.js and js/app.js and never asks for the README.
  // -------------------------------------------------------------------------

  test('an unauthenticated fetch cannot read the developer README', () async {
    final response = await router(
      Request('GET', Uri.parse('http://localhost/dashboard/README.md')),
    );

    expect(response.statusCode, HttpStatus.notFound);
    final body = await response.readAsString();
    expect(body, contains('Not an asset of this page'));
    expect(
      body,
      isNot(contains('Authentication')),
      reason: 'the refusal must not carry the document it refused',
    );
  });

  test(
    'the refusal names the served extensions so a real asset is diagnosable',
    () async {
      final response = await router(
        Request('GET', Uri.parse('http://localhost/dashboard/README.md')),
      );

      final body = await response.readAsString();
      for (final ext in ['.html', '.css', '.js', '.svg', '.woff2']) {
        expect(body, contains(ext));
      }
    },
  );

  test(
    'the allowlist runs before the disk, so it is no existence oracle',
    () async {
      // Same status and same body for a path that exists in the source tree and
      // one that exists nowhere: the answer turns on the extension alone.
      final present = await router(
        Request('GET', Uri.parse('http://localhost/dashboard/README.md')),
      );
      final absent = await router(
        Request('GET', Uri.parse('http://localhost/dashboard/NOPE.md')),
      );

      final presentBody = await present.readAsString();
      final absentBody = await absent.readAsString();

      expect(present.statusCode, absent.statusCode);
      expect(presentBody, contains('Not an asset'));
      expect(absentBody, contains('Not an asset'));
      expect(presentBody, isNot(absentBody), reason: 'each names its own path');
    },
  );

  test(
    'developer material of every kind is refused on both prefixes',
    () async {
      const paths = [
        '/dashboard/README.md',
        '/dashboard/test/dashboard_honesty_test.mjs',
        '/dashboard/tools/smoke.mjs',
        '/dashboard/.env',
        '/dashboard/notes.txt',
        '/dashboard/db.sqlite',
        '/run-watch/README.md',
        '/run-watch/notes.yaml',
      ];
      for (final path in paths) {
        final response = await router(
          Request('GET', Uri.parse('http://localhost$path')),
        );
        expect(
          response.statusCode,
          HttpStatus.notFound,
          reason: '$path is not an asset either page requests',
        );
      }
    },
  );

  test(
    'the assets the pages DO request are still served unauthenticated',
    () async {
      const paths = [
        '/dashboard',
        '/dashboard/',
        '/dashboard/index.html',
        '/dashboard/css/dashboard.css',
        '/dashboard/js/api.js',
        '/dashboard/js/app.js',
        '/run-watch/',
        '/run-watch/index.html',
        '/run-watch/css/style.css',
        '/run-watch/js/run-watch.js',
        '/run-watch/sw.js',
        '/run-watch/manifest.json',
        '/run-watch/icons/icon-192.svg',
      ];
      for (final path in paths) {
        final response = await router(
          Request('GET', Uri.parse('http://localhost$path')),
        );
        expect(
          response.statusCode,
          HttpStatus.ok,
          reason: '$path is an asset the page loads and must keep working',
        );
      }
    },
  );

  test('the shipped bundle declares no developer material as an asset', () {
    // The route allowlist is one half of the repair; the other is that the
    // README is not copied into the bundle at all. A bare `web_dashboard/`
    // entry copies every file sitting in that directory, which is how the
    // README got there.
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    final assets = pubspec
        .map((line) => line.trim())
        .where((line) => line.startsWith('- web_dashboard'))
        .toList();

    expect(
      assets,
      isNot(contains('- web_dashboard/')),
      reason:
          'a bare directory entry ships README.md, and anything else '
          'a future change drops beside it',
    );
    expect(assets, contains('- web_dashboard/index.html'));
    expect(assets, contains('- web_dashboard/css/'));
    expect(assets, contains('- web_dashboard/js/'));
  });
}
