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

  group('FileSystemHandlers', () {
    late ProviderContainer container;
    late FileSystemHandlers handlers;
    late Directory envBrowseRoot;

    setUp(() async {
      envBrowseRoot = await Directory.systemTemp.createTemp(
        'skotiq_browse_root_',
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

    test(
      'browse returns allow-listed roots with JSON helper headers',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleBrowseDirectories(
            Request('GET', Uri.parse('http://localhost/api/files/browse')),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['currentPath'], isNull);
        expect(body['directories'], isA<List>());
        final dirs = (body['directories'] as List).cast<Map>();
        expect(
          dirs,
          contains(
            allOf(
              containsPair('name', 'Capture Disk'),
              containsPair('path', envBrowseRoot.resolveSymbolicLinksSync()),
            ),
          ),
        );
      },
    );

    test('browse allows configured headless root children', () async {
      final child = await Directory(
        '${envBrowseRoot.path}${Platform.pathSeparator}session-001',
      ).create();

      final response = await translateHandlerErrors(
        handlers.handleBrowseDirectories(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/files/browse?path=${Uri.encodeQueryComponent(envBrowseRoot.path)}',
            ),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final dirs = (body['directories'] as List).cast<Map>();
      expect(
        dirs,
        contains(
          allOf(
            containsPair('name', 'session-001'),
            containsPair('path', child.resolveSymbolicLinksSync()),
          ),
        ),
      );
    });

    test(
      'browse rejects existing directories outside configured roots',
      () async {
        final outside = await Directory.systemTemp.createTemp(
          'skotiq_outside_root_',
        );
        addTearDown(() async {
          if (await outside.exists()) {
            await outside.delete(recursive: true);
          }
        });

        final response = await translateHandlerErrors(
          handlers.handleBrowseDirectories(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/files/browse?path=${Uri.encodeQueryComponent(outside.path)}',
              ),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.forbidden);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'path_not_allowed');
      },
    );

    test('browse reports missing directory as JSON not found', () async {
      final missingPath = Directory.systemTemp
          .createTempSync('skotiq_missing_parent_')
          .path;
      await Directory(missingPath).delete(recursive: true);

      final response = await translateHandlerErrors(
        handlers.handleBrowseDirectories(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/files/browse?path=${Uri.encodeQueryComponent(missingPath)}',
            ),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.notFound);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'Directory not found');
    });

    test('validate directory reports required path errors as JSON', () async {
      final response = await translateHandlerErrors(
        handlers.handleValidateDirectory(
          Request(
            'POST',
            Uri.parse('http://localhost/api/files/validate'),
            body: jsonEncode({'path': ''}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'application/json');
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
