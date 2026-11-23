import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/static_file_handlers.dart';
import 'package:skotiq_desktop/headless_api/route_table.dart';
import 'package:skotiq_desktop/headless_api/run_state_script.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_remote_protocol/wire.dart' show ApiErrorCodes;
import 'package:skotiq_core/utils.dart';

/// The run-watch SPA must have exactly one address.
///
/// The service worker registers with scope `/run-watch/`, so a document served
/// at `/run-watch` is outside it and nothing controls the page: with the
/// daemon down, the browser shows its own connection-refused interstitial
/// instead of the cached offline shell.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LoggingService logger;
  late Handler router;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_static_routes_test_');
    logger = LoggingService(
      applicationSupportDirectoryProvider: () async => tempDir,
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
    await logger.ensureInitialized();
    router = RouteTable.only(
      StaticFileHandlers(logger: logger, release: () => '8.2.1'),
    ).handler;
  });

  tearDown(() async {
    await logger.dispose();
    await tempDir.delete(recursive: true);
  });

  test(
    'the dashboard page reads the release of the host that serves it',
    () async {
      final response = await router(
        Request('GET', Uri.parse('http://localhost/dashboard/js/release.js')),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(
        response.headers['content-type'],
        startsWith('application/javascript'),
      );
      expect(response.headers['cache-control'], 'no-cache');
      expect(
        await response.readAsString(),
        "const SKOTIQ_RELEASE = \"8.2.1\";\n",
      );
    },
  );

  test('both pages read the error codes from the host\'s table', () async {
    for (final page in ['dashboard', 'run-watch']) {
      final response = await router(
        Request('GET', Uri.parse('http://localhost/$page/js/wire-errors.js')),
      );
      expect(response.statusCode, HttpStatus.ok, reason: page);
      expect(
        response.headers['content-type'],
        startsWith('application/javascript'),
      );
      final script = await response.readAsString();
      expect(script, ApiErrorCodes.javaScript());
      for (final MapEntry(:key, :value) in ApiErrorCodes.all.entries) {
        expect(script, contains('  $key: "$value",'));
      }
    }
  });

  test('both pages read the run state from the host\'s table', () async {
    for (final page in ['dashboard', 'run-watch']) {
      final response = await router(
        Request('GET', Uri.parse('http://localhost/$page/js/run-state.js')),
      );
      expect(response.statusCode, HttpStatus.ok, reason: page);
      expect(
        response.headers['content-type'],
        startsWith('application/javascript'),
      );
      expect(await response.readAsString(), RunStateScript.javaScript());
    }
  });

  // The pages also have kinds of their own ('version_mismatch' for a refusal
  // they classified); only a comparison against a body field reads a code.
  test('the pages compare body codes against the table', () {
    for (final path in [
      'web_dashboard/js/api.js',
      'web_dashboard/js/app.js',
      'web_run_watch/js/run-watch.js',
    ]) {
      final source = File(path).readAsStringSync();
      for (final code in ApiErrorCodes.all.values) {
        for (final quote in ["'", '"']) {
          expect(
            RegExp(
              r'(?:(?:\.code|\.error)\s*(?:===|!==)|includes\()\s*'
              '$quote$code$quote',
            ).hasMatch(source),
            isFalse,
            reason: '$path compares against a spelled-out $code',
          );
        }
      }
    }
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
  // The public prefix carries only what the pages need.
  //
  // `/dashboard` and `/run-watch` are whole-subtree exemptions from the bearer
  // middleware (auth/public_paths.dart), so any other file the bundler copied
  // into the SPA directory (a README describing the auth paths, for one)
  // would be readable with no credential. The SPA loads index.html,
  // css/dashboard.css, js/api.js and js/app.js.
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
