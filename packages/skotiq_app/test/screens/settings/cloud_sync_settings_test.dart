// Widget tests for [CloudSyncCard] — the "Backup & Sync" settings card —
// after S3-compatible support landed alongside WebDAV.
//
// What these lock in (the regressions a reviewer would fear most):
//
//   1. defaults_to_webdav_and_shows_webdav_fields — a pre-existing install
//      (provider resolves to WebDAV) shows the WebDAV fields, never the S3
//      ones. This is the back-compat hinge surfaced in the UI.
//   2. selecting_s3_reveals_s3_fields_and_hides_webdav — switching the
//      provider dropdown swaps the field set: endpoint/region/bucket/access
//      key/secret key + the MinIO path-style toggle appear; the WebDAV
//      server-URL field is gone.
//   3. successful_s3_test_connection_saves_then_probes_s3 — Test Connection
//      first persists the entered S3 config (provider==s3, secret via the
//      `password` param) then runs the connection probe; a green path shows
//      no failure.
//   4. saving_s3_routes_secret_via_password_param_not_config — Save hands the
//      service an S3 [SyncConfig] (which structurally cannot carry a secret)
//      plus the typed secret through the separate `password` parameter — the
//      card never smuggles the secret into a settings-bound field. The
//      keyring-vs-app_settings persistence split itself is pinned by the core
//      cloud_sync_service_test.
//   5. empty_required_s3_field_blocks_save — an empty S3 endpoint is rejected
//      inline with an error snackbar and saveConfig is never called.
//
// Why a hand-written fake instead of a real SyncService over in-memory drift:
// under `testWidgets` the binding runs in a fake-async zone, and a real drift
// query started from the card's initState `_load()` never resolves while the
// test pumps — it deadlocks. The fake keeps every method a synchronous-ish
// microtask so the card loads deterministically, and records the exact
// (config, password) the card saved so the secret-routing contract is
// asserted directly.

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/cloud_sync_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

/// In-memory [SyncService] double. The super-constructor deps are inert: the
/// database is never queried (so no drift async escapes the fake-async zone),
/// and every method the card calls is overridden to resolve immediately.
class _FakeSyncService extends SyncService {
  _FakeSyncService({
    required super.backupService,
    required super.settingsDao,
    required super.secretsStore,
    required super.logger,
    this.config = const SyncConfig(machineName: 'test-rig'),
  });

  SyncConfig config;
  bool storedWebdavSecret = false;
  bool storedS3Secret = false;

  int saveCalls = 0;
  SyncConfig? lastSavedConfig;
  String? lastSavedPassword;

  int testConnectionCalls = 0;
  bool failTestConnection = false;
  int pushCalls = 0;
  bool throwFromPush = false;
  Completer<void>? saveBarrier;

  @override
  Future<SyncConfig> loadConfig() async => config;

  @override
  Future<bool> hasStoredSecret(SyncProvider provider) async =>
      provider == SyncProvider.s3 ? storedS3Secret : storedWebdavSecret;

  @override
  Future<bool> hasStoredPassword() async => storedWebdavSecret;

  @override
  Future<SyncStatus> status() async => SyncStatus(
        configured: config.isConfigured,
        autoPushEnabled: config.autoPushEnabled,
        machineName: config.machineName,
        serverUrl: config.provider == SyncProvider.s3
            ? config.s3Endpoint
            : config.serverUrl,
        pushInProgress: false,
      );

  @override
  Future<void> saveConfig(SyncConfig config, {String? password}) async {
    saveCalls++;
    await saveBarrier?.future;
    lastSavedConfig = config;
    lastSavedPassword = password;
    this.config = config;
    if (password != null && password.isNotEmpty) {
      if (config.provider == SyncProvider.s3) {
        storedS3Secret = true;
      } else {
        storedWebdavSecret = true;
      }
    }
  }

  @override
  Future<void> testConnection() async {
    testConnectionCalls++;
    if (failTestConnection) {
      throw const SyncTargetException(
        'invalid credentials',
        kind: SyncTargetErrorKind.unknown,
      );
    }
  }

  @override
  Future<SyncPushResult> pushNow() async {
    pushCalls++;
    if (throwFromPush) throw StateError('cloud target unavailable');
    return SyncPushResult(
      success: true,
      remotePath: 'skotiq-sync/test-rig/bundle.nsbak',
      timestamp: DateTime.utc(2026, 7, 14),
    );
  }
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

LoggingService _testLogger(Directory tempDir) => LoggingService(
      applicationSupportDirectoryProvider: () async => tempDir,
      nativeInitWithLogging: ({String? logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );

/// Pump [CloudSyncCard] with [service] overriding the production provider and
/// drain the card's async `_load()` with bounded pumps (a bare pumpAndSettle
/// would wait forever on the loading CircularProgressIndicator animation).
Future<void> _pumpCard(WidgetTester tester, SyncService service) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1000, 1400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inMemoryDatabaseOverride(),
        syncServiceProvider.overrideWithValue(service)
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SingleChildScrollView(child: CloudSyncCard()),
        ),
      ),
    ),
  );
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (find
        .byType(DropdownButtonFormField<SyncProvider>)
        .evaluate()
        .isNotEmpty) {
      break;
    }
  }
}

/// Enter [text] into the [TextField] whose decoration label is [label]. The
/// label renders as a Text descendant of the TextField, so an ancestor lookup
/// uniquely identifies the field.
Future<void> _enter(WidgetTester tester, String label, String text) async {
  final field = find.ancestor(
    of: find.text(label),
    matching: find.byType(TextField),
  );
  expect(field, findsOneWidget, reason: 'expected a field labelled "$label"');
  await tester.enterText(field, text);
  await tester.pump();
}

Future<void> _selectS3(WidgetTester tester) async {
  await tester.tap(find.byType(DropdownButtonFormField<SyncProvider>));
  await tester.pumpAndSettle();
  // The S3 entry only exists in the opened menu overlay (the closed button
  // shows the current WebDAV value), so `.last` targets the menu item.
  await tester.tap(find.text('S3-compatible (AWS, MinIO, Backblaze B2)').last);
  await tester.pumpAndSettle();
}

Future<void> _fillS3(WidgetTester tester, {required String secret}) async {
  await _enter(tester, 'Endpoint', 'https://s3.us-east-1.amazonaws.com');
  await _enter(tester, 'Region', 'us-east-1');
  await _enter(tester, 'Bucket', 'astro-backups');
  await _enter(tester, 'Access key', 'AKIAEXAMPLE');
  await _enter(tester, 'Secret key', secret);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // One shared, never-queried database backs the inert fake-service deps, so
  // the drift "multiple databases" debug warning never fires.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SkotiqDatabase db;
  late Directory tempDir;
  late LoggingService logger;

  setUpAll(() async {
    db = mockDatabase();
    tempDir = await Directory.systemTemp.createTemp('sk_cloud_sync_ui_');
    logger = _testLogger(tempDir);
  });

  tearDownAll(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  _FakeSyncService makeService({SyncConfig? initial}) => _FakeSyncService(
        backupService: BackupService(
          database: db,
          sequenceRepository: SequenceRepository(db.sequencesDao),
          logger: logger,
        ),
        settingsDao: SettingsDao(db),
        secretsStore: SecretsStore(InMemorySecureKeyValueStore()),
        logger: logger,
        config: initial ?? const SyncConfig(machineName: 'test-rig'),
      );

  testWidgets('defaults_to_webdav_and_shows_webdav_fields', (tester) async {
    await _pumpCard(tester, makeService());

    expect(find.byType(DropdownButtonFormField<SyncProvider>), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    // S3 fields absent until the provider is switched.
    expect(find.text('Endpoint'), findsNothing);
    expect(find.text('Region'), findsNothing);
    expect(find.text('Bucket'), findsNothing);
    expect(find.text('Access key'), findsNothing);
    expect(find.text('Secret key'), findsNothing);
  });

  testWidgets('selecting_s3_reveals_s3_fields_and_hides_webdav',
      (tester) async {
    await _pumpCard(tester, makeService());

    await _selectS3(tester);

    expect(find.text('Endpoint'), findsOneWidget);
    expect(find.text('Region'), findsOneWidget);
    expect(find.text('Bucket'), findsOneWidget);
    expect(find.text('Access key'), findsOneWidget);
    expect(find.text('Secret key'), findsOneWidget);
    expect(
      find.text('Path-style addressing (required for MinIO)'),
      findsOneWidget,
    );
    // WebDAV-only field gone; the shared machine-name field stays.
    expect(find.text('Server URL'), findsNothing);
    expect(find.text('Machine name'), findsOneWidget);
  });

  testWidgets('successful_s3_test_connection_saves_then_probes_s3',
      (tester) async {
    final service = makeService();
    await _pumpCard(tester, service);

    await _selectS3(tester);
    await _fillS3(tester, secret: 'the-secret');

    await tester.tap(find.widgetWithText(SkotiqButton, 'Test Connection'));
    await tester.pumpAndSettle();

    // Test Connection saved the entered config first, routing the secret via
    // the password param, then probed the (S3) target.
    expect(service.saveCalls, 1);
    expect(service.lastSavedConfig?.provider, SyncProvider.s3);
    expect(service.lastSavedConfig?.s3Bucket, 'astro-backups');
    expect(service.lastSavedPassword, 'the-secret');
    expect(service.testConnectionCalls, 1);
    expect(find.textContaining('Connection failed'), findsNothing);
  });

  testWidgets('saving_s3_routes_secret_via_password_param_not_config',
      (tester) async {
    final service = makeService();
    await _pumpCard(tester, service);

    await _selectS3(tester);
    await _fillS3(tester, secret: 'top-secret-value');

    await tester.tap(find.widgetWithText(SkotiqButton, 'Save'));
    await tester.pumpAndSettle();

    final saved = service.lastSavedConfig;
    expect(service.saveCalls, 1);
    expect(saved, isNotNull);
    expect(saved!.provider, SyncProvider.s3);
    // Non-secret fields ride the config.
    expect(saved.s3Endpoint, 'https://s3.us-east-1.amazonaws.com');
    expect(saved.s3Region, 'us-east-1');
    expect(saved.s3Bucket, 'astro-backups');
    expect(saved.s3AccessKey, 'AKIAEXAMPLE');
    // The secret travels ONLY through the password param.
    expect(service.lastSavedPassword, 'top-secret-value');
    // It is never smuggled into a settings-bound config field.
    for (final field in [
      saved.serverUrl,
      saved.username,
      saved.s3Endpoint,
      saved.s3Region,
      saved.s3Bucket,
      saved.s3AccessKey,
      saved.machineName,
    ]) {
      expect(field.contains('top-secret-value'), isFalse,
          reason: 'secret leaked into a non-secret SyncConfig field');
    }
    // The service recorded the S3 secret (and not the WebDAV one).
    expect(await service.hasStoredSecret(SyncProvider.s3), isTrue);
    expect(await service.hasStoredSecret(SyncProvider.webdav), isFalse);
  });

  testWidgets('empty_required_s3_field_blocks_save', (tester) async {
    final service = makeService();
    await _pumpCard(tester, service);

    await _selectS3(tester);
    // Leave Endpoint empty; fill the rest.
    await _enter(tester, 'Region', 'us-east-1');
    await _enter(tester, 'Bucket', 'astro-backups');
    await _enter(tester, 'Access key', 'AKIAEXAMPLE');
    await _enter(tester, 'Secret key', 'top-secret-value');

    await tester.tap(find.widgetWithText(SkotiqButton, 'Save'));
    await tester.pump();

    expect(find.text('S3 endpoint is required.'), findsOneWidget);
    // Validation fired before any persistence.
    expect(service.saveCalls, 0);
    expect(await service.hasStoredSecret(SyncProvider.s3), isFalse);
  });

  testWidgets('local actions are single-flight while config is saving',
      (tester) async {
    final service = makeService(
      initial: const SyncConfig(
        serverUrl: 'https://backups.example.test',
        machineName: 'test-rig',
      ),
    );
    service.saveBarrier = Completer<void>();
    await _pumpCard(tester, service);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Save'));
    await tester.pump();

    final push = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Push Now'),
    );
    expect(push.onPressed, isNull);
    expect(service.saveCalls, 1);

    service.saveBarrier!.complete();
    await tester.pump();
    await tester.pump();
    expect(service.saveCalls, 1);
  });

  testWidgets('thrown local push failure is visible and retryable',
      (tester) async {
    final service = makeService(
      initial: const SyncConfig(
        serverUrl: 'https://backups.example.test',
        machineName: 'test-rig',
      ),
    )..throwFromPush = true;
    await _pumpCard(tester, service);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Push Now'));
    await tester.pump();
    await tester.pump();

    expect(service.pushCalls, 1);
    expect(find.textContaining('cloud target unavailable'), findsWidgets);
    final push = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Push Now'),
    );
    expect(push.onPressed, isNotNull);
    expect(push.isLoading, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote card reads and pushes the imaging host', (tester) async {
    final backend = _MockNetworkBackend();
    const status = SyncStatus(
      configured: true,
      autoPushEnabled: true,
      machineName: 'observatory-host',
      serverUrl: 'https://backups.example.test',
      pushInProgress: false,
    );
    when(() => backend.getCloudSyncStatus()).thenAnswer((_) async => status);
    when(() => backend.pushCloudSyncNow()).thenAnswer(
      (_) async => SyncPushResult(
        success: true,
        remotePath: 'skotiq-sync/observatory-host/bundle.nsbak',
        timestamp: DateTime.utc(2026, 7, 13),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SingleChildScrollView(child: RemoteCloudSyncCard()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('observatory-host'), findsOneWidget);
    expect(find.text('Configured'), findsOneWidget);
    expect(find.text('Enabled'), findsOneWidget);

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Push Host Backup Now'),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    verify(() => backend.pushCloudSyncNow()).called(1);
    verify(() => backend.getCloudSyncStatus()).called(2);
    expect(
      find.textContaining('Host backup pushed to skotiq-sync'),
      findsOneWidget,
    );
  });

  testWidgets('remote card does not report a false push result as success',
      (tester) async {
    final backend = _MockNetworkBackend();
    const status = SyncStatus(
      configured: true,
      autoPushEnabled: false,
      machineName: 'observatory-host',
      serverUrl: 'https://backups.example.test',
      pushInProgress: false,
    );
    when(() => backend.getCloudSyncStatus()).thenAnswer((_) async => status);
    when(() => backend.pushCloudSyncNow()).thenAnswer(
      (_) async => SyncPushResult(
        success: false,
        errorMessage: 'quota exceeded',
        timestamp: DateTime.utc(2026, 7, 14),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SingleChildScrollView(child: RemoteCloudSyncCard()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Push Host Backup Now'),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('quota exceeded'), findsOneWidget);
    expect(find.textContaining('Host backup pushed'), findsNothing);
    verify(() => backend.getCloudSyncStatus()).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote card drops status from a previous imaging host',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final hostAResponse = Completer<SyncStatus>();
    when(() => hostA.getCloudSyncStatus())
        .thenAnswer((_) => hostAResponse.future);
    when(() => hostB.getCloudSyncStatus()).thenAnswer(
      (_) async => const SyncStatus(
        configured: true,
        autoPushEnabled: false,
        machineName: 'host-b',
        serverUrl: 'https://b.example.test',
        pushInProgress: false,
      ),
    );

    late _SwappableBackendNotifier notifier;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => notifier = _SwappableBackendNotifier(ref, hostA),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SingleChildScrollView(child: RemoteCloudSyncCard()),
          ),
        ),
      ),
    );
    await tester.pump();

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.pump();

    expect(find.text('host-b'), findsOneWidget);
    expect(find.text('https://b.example.test'), findsOneWidget);

    hostAResponse.complete(
      const SyncStatus(
        configured: true,
        autoPushEnabled: true,
        machineName: 'host-a',
        serverUrl: 'https://a.example.test',
        pushInProgress: false,
      ),
    );
    await tester.pump();

    expect(find.text('host-b'), findsOneWidget);
    expect(find.text('host-a'), findsNothing);
  });
}
