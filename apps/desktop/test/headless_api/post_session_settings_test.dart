import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/post_session_handlers.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';
import 'package:skotiq_desktop/headless_api/route_metadata.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;
  late ProviderContainer container;
  late PostSessionHandlers handlers;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    handlers = PostSessionHandlers(
      container,
      jobManager: JobManager(emitEvent: (_) {}),
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test(
    'auto-integration setting defaults on and round-trips on the host',
    () async {
      var response = await translateHandlerErrors(
        handlers.handleGetSettings(
          Request(
            'GET',
            Uri.parse('http://localhost/api/post-session/settings'),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(jsonDecode(await response.readAsString()), {
        'autoIntegrate': true,
      });

      response = await translateHandlerErrors(
        handlers.handleUpdateSettings(
          Request(
            'POST',
            Uri.parse('http://localhost/api/post-session/settings'),
            body: jsonEncode({'autoIntegrate': false}),
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(
        await database.settingsDao.getSetting('post_session.auto_integrate'),
        'false',
      );

      response = await translateHandlerErrors(
        handlers.handleGetSettings(
          Request(
            'GET',
            Uri.parse('http://localhost/api/post-session/settings'),
          ),
        ),
      );
      expect(jsonDecode(await response.readAsString()), {
        'autoIntegrate': false,
      });
    },
  );

  test('malformed setting writes fail closed', () async {
    final response = await translateHandlerErrors(
      handlers.handleUpdateSettings(
        Request(
          'POST',
          Uri.parse('http://localhost/api/post-session/settings'),
          body: jsonEncode({'autoIntegrate': 'definitely'}),
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    expect(response.statusCode, HttpStatus.badRequest);
  });

  test('post-session settings use view/control scopes', () {
    expect(
      requiredAuthScopeNameForEndpoint(
        method: 'GET',
        path: '/api/post-session/settings',
      ),
      'view',
    );
    expect(
      requiredAuthScopeNameForEndpoint(
        method: 'POST',
        path: '/api/post-session/settings',
      ),
      'control',
    );
  });
}
