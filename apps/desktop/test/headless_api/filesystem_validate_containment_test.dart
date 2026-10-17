// POST /api/files/validate must enforce the same allow-list root containment
// its sibling /api/files/browse does. A path outside the allow-list is
// rejected with the `path_not_allowed` 403 BEFORE any stat / write-probe runs,
// so the endpoint cannot act as a filesystem existence/writability oracle that
// drops a probe file at an arbitrary path.
// In-root validation (including not-yet-created save paths) is unaffected.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/filesystem_handlers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FileSystemHandlers.handleValidateDirectory containment', () {
    late ProviderContainer container;
    late FileSystemHandlers handlers;
    late Directory envBrowseRoot;

    setUp(() async {
      envBrowseRoot = await Directory.systemTemp.createTemp(
        'skotiq_validate_root_',
      );
      container = ProviderContainer(
        overrides: [appSettingsProvider.overrideWith(_TestSettings.new)],
      );
      handlers = FileSystemHandlers(
        container,
        environment: {
          'SKOTIQ_BROWSE_ROOTS': 'Capture Disk=${envBrowseRoot.path}',
        },
      );
    });

    tearDown(() async {
      container.dispose();
      if (await envBrowseRoot.exists()) {
        await envBrowseRoot.delete(recursive: true);
      }
    });

    Future<Response> validate(Map<String, dynamic> body) {
      return translateHandlerErrors(
        handlers.handleValidateDirectory(
          Request(
            'POST',
            Uri.parse('http://localhost/api/files/validate'),
            body: jsonEncode(body),
          ),
        ),
      );
    }

    test('rejects an out-of-root path with path_not_allowed and writes no '
        'probe file', () async {
      final outside = await Directory.systemTemp.createTemp(
        'skotiq_validate_outside_',
      );
      addTearDown(() async {
        if (await outside.exists()) {
          await outside.delete(recursive: true);
        }
      });

      final response = await validate({
        'path': outside.path,
        'mustBeWritable': true,
        'mustExist': true,
      });

      expect(response.statusCode, HttpStatus.forbidden);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'path_not_allowed');
      expect(body['valid'], isFalse);
      expect(body['exists'], isFalse);

      // The write-probe must never have run outside the allow-list.
      final probes = await outside
          .list()
          .where((e) => e.path.contains('.skotiq_write_test_'))
          .toList();
      expect(probes, isEmpty);
    });

    test('validates an in-root existing directory', () async {
      final response = await validate({
        'path': envBrowseRoot.path,
        'mustExist': true,
        'mustBeWritable': true,
      });

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['valid'], isTrue);
      expect(body['exists'], isTrue);
      expect(body['writable'], isTrue);
      expect(body['normalizedPath'], isA<String>());
    });

    test(
      'validates a not-yet-created save path under an allow-listed root',
      () async {
        final newSavePath =
            '${envBrowseRoot.path}${Platform.pathSeparator}NewTarget'
            '${Platform.pathSeparator}lights';

        final response = await validate({
          'path': newSavePath,
          // A save path the user has not created yet — must not regress to a
          // path_not_allowed rejection just because it does not exist.
          'mustExist': false,
        });

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        // Path is contained under the root, so it is not rejected; it just does
        // not exist yet.
        expect(body['exists'], isFalse);
        expect(body['valid'], isTrue);
      },
    );

    test('rejects a not-yet-created path whose ancestor is an in-root symlink '
        'pointing outside the roots (no existence oracle)', () async {
      final outside = await Directory.systemTemp.createTemp(
        'skotiq_validate_symlink_target_',
      );
      addTearDown(() async {
        if (await outside.exists()) await outside.delete(recursive: true);
      });

      // An in-root symlink whose target escapes the allow-list. Symlink
      // creation needs privilege on Windows; skip cleanly where unsupported.
      final escape = Link(
        '${envBrowseRoot.path}${Platform.pathSeparator}escape',
      );
      try {
        await escape.create(outside.path);
      } on FileSystemException {
        return; // platform can't create symlinks here
      }

      // Leaf does NOT exist under the target, so resolveSymbolicLinks throws
      // on the full path and the deepest-ancestor fallback must resolve the
      // `escape` symlink and reject — instead of leaking exists/writable for
      // an arbitrary out-of-root path.
      final response = await validate({
        'path': '${escape.path}${Platform.pathSeparator}secret_probe_target',
        'mustExist': false,
        'mustBeWritable': true,
      });

      expect(response.statusCode, HttpStatus.forbidden);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'path_not_allowed');
      expect(body['valid'], isFalse);
      expect(body['exists'], isFalse);

      // No write-probe may have leaked into the out-of-root target.
      final probes = await outside
          .list()
          .where((e) => e.path.contains('.skotiq_write_test_'))
          .toList();
      expect(probes, isEmpty);
    });

    test('reports empty path as a plain validation error (no containment '
        'check needed)', () async {
      final response = await validate({'path': ''});

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['valid'], isFalse);
      expect(body['error'], 'Path is required');
    });
  });
}

class _TestSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}
