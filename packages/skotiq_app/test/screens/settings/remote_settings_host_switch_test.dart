import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/calibration_library_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/focus_model_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/imaging_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/log_viewer.dart';
import 'package:skotiq_app/screens/settings/widgets/rig_catalog_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_app/screens/settings/widgets/update_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart' as models;
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {
  int calibrationTagWrites = 0;
  int calibrationDeletes = 0;

  @override
  Future<CalibrationMasterRecord> setCalibrationMasterTags({
    required String type,
    required int id,
    required List<String> tags,
  }) {
    calibrationTagWrites++;
    return Future.error(StateError('unexpected calibration tag write'));
  }

  @override
  Future<CalibrationMasterRecord> setCalibrationMasterNotes({
    required String type,
    required int id,
    required String? notes,
  }) {
    calibrationTagWrites++;
    return Future.error(StateError('unexpected calibration notes write'));
  }

  @override
  Future<void> deleteCalibrationMaster({
    required String type,
    required int id,
    bool deleteFile = false,
  }) async {
    calibrationDeletes++;
  }
}

class _MockCalibrationLibraryService extends Mock
    implements CalibrationLibraryService {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

Widget _app({
  required SkotiqBackend initialBackend,
  required void Function(_SwappableBackendNotifier) receiveNotifier,
  required Widget child,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      backendProvider.overrideWith((ref) {
        final notifier = _SwappableBackendNotifier(ref, initialBackend);
        receiveNotifier(notifier);
        return notifier;
      }),
      ...overrides,
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: child),
    ),
  );
}

Map<String, dynamic> _master(String host, int id) => {
      'type': 'dark',
      'id': id,
      'filePath': '/tmp/$host-master.fit',
      'isMaster': true,
      'createdAt': '2026-07-13T00:00:00Z',
      'tags': const <String>[],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings text is replaced when the imaging host changes',
      (tester) async {
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    when(() => hostA.eventStream)
        .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => hostB.eventStream)
        .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(hostA.getSettings).thenAnswer(
      (_) async => const models.AppSettings(fileNamingPattern: 'host-a'),
    );
    when(hostB.getSettings).thenAnswer(
      (_) async => const models.AppSettings(fileNamingPattern: 'host-b'),
    );

    late _SwappableBackendNotifier notifier;
    await tester.pumpWidget(
      _app(
        initialBackend: hostA,
        receiveNotifier: (value) => notifier = value,
        overrides: [databaseProvider.overrideWithValue(database)],
        child: const ImagingSettings(),
      ),
    );
    final field = find.descendant(
      of: find.byType(SettingsTextInput),
      matching: find.byType(EditableText),
    );
    for (var i = 0; i < 12 && field.evaluate().isEmpty; i++) {
      await tester.pump();
    }
    expect(tester.widget<EditableText>(field).controller.text, 'host-a');
    await tester.enterText(field, 'unsaved host-a edit');

    notifier.switchTo(hostB);
    await tester.pump();
    for (var i = 0; i < 12 && field.evaluate().isEmpty; i++) {
      await tester.pump();
    }

    expect(tester.widget<EditableText>(field).controller.text, 'host-b');
  });

  testWidgets('calibration library ignores a late response from the old rig',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final hostAResponse = Completer<List<Map<String, dynamic>>>();
    final service = _MockCalibrationLibraryService();
    when(() => hostA.getCalibrationMasters(type: any(named: 'type')))
        .thenAnswer((_) => hostAResponse.future);
    when(() => hostB.getCalibrationMasters(type: any(named: 'type')))
        .thenAnswer((_) async => [_master('host-b', 2)]);

    late _SwappableBackendNotifier notifier;
    await tester.pumpWidget(
      _app(
        initialBackend: hostA,
        receiveNotifier: (value) => notifier = value,
        overrides: [
          calibrationLibraryServiceProvider.overrideWithValue(service),
        ],
        child: const CalibrationLibrarySettings(isMobile: true),
      ),
    );
    await tester.pump();

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.pump();
    expect(find.text('/tmp/host-b-master.fit'), findsOneWidget);

    hostAResponse.complete([_master('host-a-stale', 1)]);
    await tester.pump();
    await tester.pump();

    expect(find.text('/tmp/host-b-master.fit'), findsOneWidget);
    expect(find.text('/tmp/host-a-stale-master.fit'), findsNothing);
  });

  testWidgets('calibration tag editor cannot write through a host switch',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final service = _MockCalibrationLibraryService();
    when(() => hostA.getCalibrationMasters(type: any(named: 'type')))
        .thenAnswer((_) async => [_master('host-a', 1)]);
    when(() => hostB.getCalibrationMasters(type: any(named: 'type')))
        .thenAnswer((_) async => [_master('host-b', 2)]);

    late _SwappableBackendNotifier notifier;
    await tester.pumpWidget(
      _app(
        initialBackend: hostA,
        receiveNotifier: (value) => notifier = value,
        overrides: [
          calibrationLibraryServiceProvider.overrideWithValue(service),
        ],
        child: const CalibrationLibrarySettings(isMobile: true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit tags / notes'));
    await tester.pumpAndSettle();
    expect(find.text('Tags — Dark #1'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(hostA.calibrationTagWrites, 0);
    expect(hostB.calibrationTagWrites, 0);
    expect(find.textContaining('action was cancelled'), findsOneWidget);
  });

  testWidgets('calibration delete cannot cross imaging hosts', (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final service = _MockCalibrationLibraryService();
    when(() => hostA.getCalibrationMasters(type: any(named: 'type')))
        .thenAnswer((_) async => [_master('host-a', 1)]);
    when(() => hostB.getCalibrationMasters(type: any(named: 'type')))
        .thenAnswer((_) async => [_master('host-b', 2)]);

    late _SwappableBackendNotifier notifier;
    await tester.pumpWidget(
      _app(
        initialBackend: hostA,
        receiveNotifier: (value) => notifier = value,
        overrides: [
          calibrationLibraryServiceProvider.overrideWithValue(service),
        ],
        child: const CalibrationLibrarySettings(isMobile: true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete calibration master?'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(hostA.calibrationDeletes, 0);
    expect(hostB.calibrationDeletes, 0);
    expect(find.textContaining('action was cancelled'), findsOneWidget);
  });

  testWidgets('focus model ignores a late response from the old rig',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final hostAResponse = Completer<Map<String, dynamic>>();
    when(hostA.getFocusModel).thenAnswer((_) => hostAResponse.future);
    when(hostB.getFocusModel).thenAnswer(
      (_) async => {'hasModel': false, 'message': 'Host B focus model'},
    );

    late _SwappableBackendNotifier notifier;
    await tester.pumpWidget(
      _app(
        initialBackend: hostA,
        receiveNotifier: (value) => notifier = value,
        child: const FocusModelSettings(isMobile: true),
      ),
    );
    await tester.pump();

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.pump();
    expect(find.text('Host B focus model'), findsOneWidget);

    hostAResponse.complete({
      'hasModel': false,
      'message': 'Host A stale focus model',
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('Host B focus model'), findsOneWidget);
    expect(find.text('Host A stale focus model'), findsNothing);
  });

  testWidgets('appliance catalogs ignore a late response from the old rig',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final hostAStatus = Completer<RemoteCatalogStatusResponse>();
    when(hostA.getCatalogStatus).thenAnswer((_) => hostAStatus.future);
    when(hostA.listAvailableCatalogs)
        .thenAnswer((_) async => const <RemoteAvailableCatalog>[]);
    when(hostB.getCatalogStatus).thenAnswer(
      (_) async => const RemoteCatalogStatusResponse(
        catalogs: [
          RemoteCatalogStatus(name: 'Host B catalog', status: 'installed'),
        ],
        totalBytes: 0,
        dataDir: '/host-b',
      ),
    );
    when(hostB.listAvailableCatalogs)
        .thenAnswer((_) async => const <RemoteAvailableCatalog>[]);

    late _SwappableBackendNotifier notifier;
    await tester.pumpWidget(
      _app(
        initialBackend: hostA,
        receiveNotifier: (value) => notifier = value,
        child: const RigCatalogSettings(isMobile: true),
      ),
    );
    await tester.pump();

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.pump();
    expect(find.text('Host B catalog'), findsOneWidget);

    hostAStatus.complete(
      const RemoteCatalogStatusResponse(
        catalogs: [
          RemoteCatalogStatus(
            name: 'Host A stale catalog',
            status: 'installed',
          ),
        ],
        totalBytes: 0,
        dataDir: '/host-a',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Host B catalog'), findsOneWidget);
    expect(find.text('Host A stale catalog'), findsNothing);
  });

  testWidgets('log viewer ignores a late response from the old rig',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final hostAResponse = Completer<List<LogEntry>>();
    when(() => hostA.fetchRecentServerLogs(limit: 500))
        .thenAnswer((_) => hostAResponse.future);
    when(() => hostB.fetchRecentServerLogs(limit: 500)).thenAnswer(
      (_) async => [
        LogEntry(
          timestamp: DateTime(2026, 7, 13),
          level: LogLevel.info,
          message: 'Host B log entry',
        ),
      ],
    );

    late _SwappableBackendNotifier notifier;
    await tester.pumpWidget(
      _app(
        initialBackend: hostA,
        receiveNotifier: (value) => notifier = value,
        child: const LogViewer(isMobile: true),
      ),
    );
    await tester.pump();

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.pump();
    expect(find.text('Host B log entry'), findsOneWidget);

    hostAResponse.complete([
      LogEntry(
        timestamp: DateTime(2026, 7, 13),
        level: LogLevel.info,
        message: 'Host A stale log entry',
      ),
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.text('Host B log entry'), findsOneWidget);
    expect(find.text('Host A stale log entry'), findsNothing);
  });

  testWidgets('log clear confirmation cannot cross imaging hosts',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    when(() => hostA.fetchRecentServerLogs(limit: 500))
        .thenAnswer((_) async => const <LogEntry>[]);
    when(() => hostB.fetchRecentServerLogs(limit: 500))
        .thenAnswer((_) async => const <LogEntry>[]);
    when(hostA.clearServerLogs).thenAnswer((_) async {});
    when(hostB.clearServerLogs).thenAnswer((_) async {});

    late _SwappableBackendNotifier notifier;
    await tester.pumpWidget(
      _app(
        initialBackend: hostA,
        receiveNotifier: (value) => notifier = value,
        child: const LogViewer(isMobile: true),
      ),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Clear'));
    await tester.pump();
    expect(find.text('Clear logs?'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(SkotiqButton, 'Clear'),
      ),
    );
    await tester.pump();

    verifyNever(hostA.clearServerLogs);
    verifyNever(hostB.clearServerLogs);
    expect(
      find.text('Clear cancelled because the imaging host changed.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('appliance updates ignore a late response from the old rig',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final hostAVersion = Completer<RemoteVersionInfo>();
    when(hostA.getSystemVersion).thenAnswer((_) => hostAVersion.future);
    when(hostA.getUpdateStatus).thenAnswer(
      (_) async => const RemoteUpdateStatus(state: 'idle'),
    );
    when(hostB.getSystemVersion).thenAnswer(
      (_) async => const RemoteVersionInfo(
        currentVersion: 'host-b-version',
        buildNumber: 22,
        channel: 'stable',
        platform: 'linux',
      ),
    );
    when(hostB.getUpdateStatus).thenAnswer(
      (_) async => const RemoteUpdateStatus(state: 'idle'),
    );

    late _SwappableBackendNotifier notifier;
    await tester.pumpWidget(
      _app(
        initialBackend: hostA,
        receiveNotifier: (value) => notifier = value,
        child: const UpdateSettings(isMobile: true),
      ),
    );
    await tester.pump();

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.pump();
    expect(find.text('host-b-version (build 22)'), findsOneWidget);

    hostAVersion.complete(
      const RemoteVersionInfo(
        currentVersion: 'host-a-stale-version',
        buildNumber: 11,
        channel: 'stable',
        platform: 'linux',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('host-b-version (build 22)'), findsOneWidget);
    expect(find.text('host-a-stale-version (build 11)'), findsNothing);
  });

  testWidgets('verification remains busy but cannot be aborted',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(backend.getSystemVersion).thenAnswer(
      (_) async => const RemoteVersionInfo(
        currentVersion: '6.0.0',
        buildNumber: 60,
        channel: 'stable',
        platform: 'linux',
      ),
    );
    when(backend.getUpdateStatus).thenAnswer(
      (_) async => const RemoteUpdateStatus(
        state: 'verifying',
        progressPct: 100,
      ),
    );

    await tester.pumpWidget(
      _app(
        initialBackend: backend,
        receiveNotifier: (_) {},
        child: const UpdateSettings(isMobile: true),
      ),
    );
    await tester.pump();
    await tester.pump();

    final check = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Check for Updates'),
    );
    expect(check.onPressed, isNull);
    expect(find.widgetWithText(SkotiqButton, 'Abort'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('slow update-status polling never overlaps on one rig',
      (tester) async {
    final backend = _MockNetworkBackend();
    final slowPoll = Completer<RemoteUpdateStatus>();
    var statusReads = 0;
    var inFlight = 0;
    var maxInFlight = 0;
    when(backend.getSystemVersion).thenAnswer(
      (_) async => const RemoteVersionInfo(
        currentVersion: '6.0.0',
        buildNumber: 60,
        channel: 'stable',
        platform: 'linux',
      ),
    );
    when(backend.getUpdateStatus).thenAnswer((_) async {
      statusReads++;
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      if (statusReads > 1) await slowPoll.future;
      inFlight--;
      return const RemoteUpdateStatus(state: 'downloading', progressPct: 25);
    });

    await tester.pumpWidget(
      _app(
        initialBackend: backend,
        receiveNotifier: (_) {},
        child: const UpdateSettings(isMobile: true),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(statusReads, 1);

    await tester.pump(const Duration(seconds: 2));
    expect(statusReads, 2);
    await tester.pump(const Duration(seconds: 8));

    expect(statusReads, 2);
    expect(maxInFlight, 1);

    slowPoll.complete(
      const RemoteUpdateStatus(state: 'downloading', progressPct: 50),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('update actions reflect host-reported readiness', (tester) async {
    final backend = _MockNetworkBackend();
    when(backend.getSystemVersion).thenAnswer(
      (_) async => const RemoteVersionInfo(
        currentVersion: '6.0.0',
        buildNumber: 60,
        channel: 'stable',
        platform: 'linux',
      ),
    );
    when(backend.getUpdateStatus).thenAnswer(
      (_) async => const RemoteUpdateStatus(
        state: 'available',
        availableVersion: '6.1.0',
        availableBuildNumber: 61,
        rollbackAvailable: true,
      ),
    );

    await tester.pumpWidget(
      _app(
        initialBackend: backend,
        receiveNotifier: (_) {},
        child: const UpdateSettings(isMobile: true),
      ),
    );
    await tester.pump();
    await tester.pump();

    final download = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Download'),
    );
    final rollback = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Rollback'),
    );
    expect(download.onPressed, isNotNull);
    expect(rollback.onPressed, isNotNull);
    expect(find.text('Available: 6.1.0 (build 61)'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('idle host does not advertise invalid update actions',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(backend.getSystemVersion).thenAnswer(
      (_) async => const RemoteVersionInfo(
        currentVersion: '6.0.0',
        buildNumber: 60,
        channel: 'stable',
        platform: 'linux',
      ),
    );
    when(backend.getUpdateStatus).thenAnswer(
      (_) async => const RemoteUpdateStatus(state: 'idle'),
    );

    await tester.pumpWidget(
      _app(
        initialBackend: backend,
        receiveNotifier: (_) {},
        child: const UpdateSettings(isMobile: true),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Download'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Rollback'),
          )
          .onPressed,
      isNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('applying a staged update requires explicit restart confirmation',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(backend.getSystemVersion).thenAnswer(
      (_) async => const RemoteVersionInfo(
        currentVersion: '6.0.0',
        buildNumber: 60,
        channel: 'stable',
        platform: 'linux',
      ),
    );
    when(backend.getUpdateStatus).thenAnswer(
      (_) async => const RemoteUpdateStatus(
        state: 'staged',
        stagedVersion: '6.1.0',
      ),
    );
    when(backend.applyUpdate).thenAnswer(
      (_) async => const RemoteJob(
        jobId: 'apply-1',
        operation: 'system.update.apply',
        state: 'queued',
      ),
    );

    await tester.pumpWidget(
      _app(
        initialBackend: backend,
        receiveNotifier: (_) {},
        child: const UpdateSettings(isMobile: true),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Apply staged'),
    );
    await tester.pumpAndSettle();
    verifyNever(backend.applyUpdate);
    expect(find.text('Apply 6.1.0?'), findsOneWidget);

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Apply and Restart'),
    );
    await tester.pump();
    verify(backend.applyUpdate).called(1);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('stale staged state blocks apply after confirmation',
      (tester) async {
    final backend = _MockNetworkBackend();
    var statusReads = 0;
    when(backend.getSystemVersion).thenAnswer(
      (_) async => const RemoteVersionInfo(
        currentVersion: '6.0.0',
        buildNumber: 60,
        channel: 'stable',
        platform: 'linux',
      ),
    );
    when(backend.getUpdateStatus).thenAnswer((_) async {
      statusReads++;
      return statusReads == 1
          ? const RemoteUpdateStatus(
              state: 'staged',
              stagedVersion: '6.1.0',
            )
          : const RemoteUpdateStatus(state: 'idle');
    });

    await tester.pumpWidget(
      _app(
        initialBackend: backend,
        receiveNotifier: (_) {},
        child: const UpdateSettings(isMobile: true),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Apply staged'),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Apply and Restart'),
    );
    await tester.pump();
    await tester.pump();

    verifyNever(backend.applyUpdate);
    expect(find.textContaining('no longer staged'), findsOneWidget);
    expect(find.text('Ready to check'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('discarding a staged update requires confirmation',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(backend.getSystemVersion).thenAnswer(
      (_) async => const RemoteVersionInfo(
        currentVersion: '6.0.0',
        buildNumber: 60,
        channel: 'stable',
        platform: 'linux',
      ),
    );
    when(backend.getUpdateStatus).thenAnswer(
      (_) async => const RemoteUpdateStatus(
        state: 'staged',
        stagedVersion: '6.1.0',
      ),
    );
    when(backend.discardStagedUpdate).thenAnswer((_) async {});

    await tester.pumpWidget(
      _app(
        initialBackend: backend,
        receiveNotifier: (_) {},
        child: const UpdateSettings(isMobile: true),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Discard staged'),
    );
    await tester.pumpAndSettle();
    verifyNever(backend.discardStagedUpdate);
    expect(find.text('Discard 6.1.0?'), findsOneWidget);

    await tester.tap(find.text('Discard Update'));
    await tester.pump();
    await tester.pump();
    verify(backend.discardStagedUpdate).called(1);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unknown host update state disables every mutating action',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(backend.getSystemVersion).thenAnswer(
      (_) async => const RemoteVersionInfo(
        currentVersion: '6.0.0',
        buildNumber: 60,
        channel: 'stable',
        platform: 'linux',
      ),
    );
    when(backend.getUpdateStatus).thenAnswer(
      (_) async => const RemoteUpdateStatus(
        state: 'migrating-database',
        availableVersion: '6.1.0',
        stagedVersion: '6.1.0',
        rollbackAvailable: true,
      ),
    );

    await tester.pumpWidget(
      _app(
        initialBackend: backend,
        receiveNotifier: (_) {},
        child: const UpdateSettings(isMobile: true),
      ),
    );
    await tester.pump();
    await tester.pump();

    for (final label in [
      'Check for Updates',
      'Download',
      'Apply staged',
      'Discard staged',
      'Rollback',
    ]) {
      expect(
        tester
            .widget<SkotiqButton>(
              find.widgetWithText(SkotiqButton, label),
            )
            .onPressed,
        isNull,
      );
    }
    expect(find.text('Host state: migrating-database'), findsOneWidget);
    expect(
      find.textContaining('does not recognize'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
