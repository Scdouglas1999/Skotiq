// The plate-solver choice and program paths the settings document and the
// backup carry are the native preference's, the store the solver reads, even
// after the preference changed through its own route.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

class _MockProfileSettingsBackend extends Mock
    implements ProfileSettingsBackend {}

class _PreferenceBackend extends DisconnectedBackend {
  PlateSolverPreference saved = const PlateSolverPreference(
    astapPath: '/opt/astap/astap',
    choice: PlateSolverChoice.astap,
  );
  int writes = 0;
  bool unreadable = false;

  @override
  Future<void> setPlateSolverConfig(PlateSolverPreference pref) async {
    saved = pref;
    writes++;
  }

  @override
  Future<PlateSolverPreference> getPlateSolverConfig() async {
    if (unreadable) throw StateError('platesolver.json cannot be read');
    return saved;
  }

  @override
  Future<PlateSolverDetection> detectPlateSolvers() async =>
      const PlateSolverDetection();
}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  late SkotiqDatabase db;
  late ProviderContainer container;
  late HeadlessApiServer server;
  late HttpClient client;
  late _PreferenceBackend solver;

  setUpAll(() => registerFallbackValue(const AppSettings()));

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    solver = _PreferenceBackend();
    final profileBackend = _MockProfileSettingsBackend();
    when(() => profileBackend.getLocation()).thenAnswer((_) async => null);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, solver)),
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
        profileSettingsBackendProvider.overrideWithValue(profileBackend),
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '6.0.0', buildNumber: 1),
        ),
      ],
    );
    await container.read(appSettingsProvider.future);
    server = HeadlessApiServer(
      port: 0,
      container: container,
      bindLocalOnly: true,
      authToken: 'admin-token',
      scopedAuthTokens: const {'control-token': HeadlessTokenScope.control},
      webSocketHeartbeatInterval: const Duration(hours: 1),
      webSocketHeartbeatTimeout: const Duration(hours: 2),
    );
    await server.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    container.dispose();
    await db.close();
  });

  Future<(int, Map<String, dynamic>)> call(
    String token,
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.actualPort}$path'),
    );
    request.headers.set('x-skotiq-version', '6.0.0');
    request.headers.set('Authorization', 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    final decoded = text.isEmpty ? null : jsonDecode(text);
    return (
      response.statusCode,
      decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
    );
  }

  Future<void> changePreference() async {
    final (
      status,
      answer,
    ) = await call('admin-token', 'POST', '/api/plate-solver/config', {
      'astapPath': '/usr/local/bin/astap',
      'astrometryPath': '/usr/bin/solve-field',
      'catalogPath': '',
      'solverChoice': 'astrometry',
    });
    expect(status, HttpStatus.ok, reason: '$answer');
  }

  test(
    'the settings document serves the preference the solver reads',
    () async {
      await changePreference();

      final (_, read) = await call('admin-token', 'GET', '/api/settings');
      final settings = read['settings'] as Map;
      expect(settings['plateSolver'], 'Astrometry.net');
      expect(settings['astapPath'], '/usr/local/bin/astap');
      expect(settings['astrometryPath'], '/usr/bin/solve-field');

      final (_, store) = await call(
        'admin-token',
        'GET',
        '/api/settings/store',
      );
      final rows = store['settings'] as Map;
      for (final key in const [
        'plate_solver',
        'astap_path',
        'astrometry_path',
      ]) {
        if (rows.containsKey(key)) {
          expect(
            rows[key],
            {
              'plate_solver': 'Astrometry.net',
              'astap_path': '/usr/local/bin/astap',
              'astrometry_path': '/usr/bin/solve-field',
            }[key],
            reason: key,
          );
        }
      }
    },
  );

  test(
    'an unreadable preference is reported as a fresh install, not as a copy',
    () async {
      solver.unreadable = true;

      final (_, read) = await call('admin-token', 'GET', '/api/settings');
      final settings = read['settings'] as Map;
      expect(settings['plateSolver'], 'Auto');
      expect(settings['astapPath'], '');
      expect(settings['astrometryPath'], '');

      final (_, store) = await call(
        'admin-token',
        'GET',
        '/api/settings/store',
      );
      final rows = store['settings'] as Map;
      expect(rows['plate_solver'], 'Auto');
      expect(rows['astap_path'], '');
      expect(rows['astrometry_path'], '');

      // Saving another setting still works and asks nothing of the solver.
      final (saved, answer) = await call(
        'admin-token',
        'POST',
        '/api/settings',
        {
          'settings': {'phd2Port': 4412},
        },
      );
      expect(saved, HttpStatus.ok, reason: '$answer');
      expect(solver.writes, 0);
    },
  );

  test("the host's own settings name the solver a link chose", () async {
    await changePreference();

    final host = await container.read(appSettingsProvider.future);
    expect(host.plateSolver, 'Astrometry.net');
  });

  test('a backup carries the preference the solver reads', () async {
    await changePreference();
    final scratch = await Directory.systemTemp.createTemp('skotiq_solver_');
    addTearDown(() => scratch.delete(recursive: true));
    final file = '${scratch.path}/backup.skbackup';

    final result = await container
        .read(backupServiceProvider)
        .createBackup(customPath: file);
    expect(result.success, isTrue, reason: result.errorMessage);

    final line = (await File(
      file,
    ).readAsLines()).firstWhere((line) => line.startsWith('"settings":'));
    final settings =
        jsonDecode(line.substring('"settings":'.length, line.length - 1))
            as Map;
    expect(settings['plate_solver'], 'Astrometry.net');
    expect(settings['astap_path'], '/usr/local/bin/astap');
    expect(settings['astrometry_path'], '/usr/bin/solve-field');
  });

  test(
    'a control link saving the document it read leaves the solver alone',
    () async {
      await changePreference();
      final writes = solver.writes;

      final (_, read) = await call('control-token', 'GET', '/api/settings');
      final document = Map<String, dynamic>.from(read['settings'] as Map)
        ..removeWhere((key, value) => value == null)
        ..['phd2Port'] = 4411;
      final (status, answer) = await call(
        'control-token',
        'POST',
        '/api/settings',
        {'settings': document},
      );
      expect(status, HttpStatus.ok, reason: '$answer');
      expect(solver.saved.astapPath, '/usr/local/bin/astap');
      expect(solver.saved.astrometryPath, '/usr/bin/solve-field');
      expect(solver.saved.choice, PlateSolverChoice.astrometry);

      final (partial, _) = await call(
        'control-token',
        'POST',
        '/api/settings',
        {
          'settings': {'phd2Port': 4412},
        },
      );
      expect(partial, HttpStatus.ok);
      expect(solver.saved.astapPath, '/usr/local/bin/astap');
      expect(solver.writes - writes, lessThanOrEqualTo(2));

      final (refused, error) = await call(
        'control-token',
        'POST',
        '/api/settings',
        {
          'settings': {'astapPath': '/tmp/not-astap'},
        },
      );
      expect(refused, HttpStatus.forbidden);
      expect(error['code'], 'host_program_setting');
      expect(solver.saved.astapPath, '/usr/local/bin/astap');
    },
  );
}
