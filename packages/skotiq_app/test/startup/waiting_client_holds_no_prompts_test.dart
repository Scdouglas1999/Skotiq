// A client that has not reached its host waits to check for a run to recover
// and for sessions to offer. While it waits, the prompts queued after those
// checks still get their turn: a link may never come.

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_app/startup/quick_start_checker.dart';
import 'package:skotiq_app/utils/startup_surface_queue.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _Host extends Mock implements NetworkBackend {}

class _Offline extends DisconnectedBackend {
  int checkpointCalls = 0;

  @override
  Future<bool> hasCheckpoint() {
    checkpointCalls++;
    return Future<bool>.value(false);
  }
}

class _Swappable extends BackendNotifier {
  _Swappable(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void use(SkotiqBackend backend) => state = backend;
}

_Host _hostWithCheckpoint() {
  final host = _Host();
  when(() => host.eventStream)
      .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  when(() => host.connectionState).thenReturn(BackendConnectionState.connected);
  when(() => host.isAuthTokenRejected).thenReturn(false);
  when(() => host.serverHost).thenReturn('rig.local');
  when(() => host.scheme).thenReturn('http');
  when(() => host.serverPort).thenReturn(4700);
  when(() => host.lastLatency).thenReturn(null);
  when(() => host.unansweredPingAge).thenReturn(null);
  when(() => host.isRemoteHost).thenReturn(false);
  when(() => host.latencyStream)
      .thenAnswer((_) => const Stream<Duration>.empty());
  when(() => host.connectionStateStream)
      .thenAnswer((_) => const Stream<BackendConnectionState>.empty());
  when(() => host.hostRunInFlight()).thenAnswer((_) async => false);
  when(() => host.hasCheckpoint()).thenAnswer((_) async => true);
  when(() => host.getCheckpointInfo()).thenAnswer(
    (_) async => CheckpointInfo(
      sequenceName: 'Host NGC 891',
      timestamp: DateTime.now().toUtc(),
      completedExposures: 4,
      completedIntegrationSecs: 240,
      canResume: true,
      ageSeconds: 30,
    ),
  );
  return host;
}

Future<void> _setUpView(WidgetTester tester) async {
  final root = Directory.systemTemp.createTempSync('sk-waiting-client-');
  addTearDown(() => root.deleteSync(recursive: true));
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => root.path);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// Asks for the last start-up surface's turn and reports whether it came.
Future<bool> _laterPromptGetsItsTurn(
  WidgetTester tester,
  ProviderContainer container,
) async {
  var shown = false;
  unawaited(
    container.read(startupSurfaceQueueProvider).turn(
          StartupSurface.yourSkyOffNotice,
          () async => shown = true,
        ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return shown;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final role in [LaunchRole.linkedClient, LaunchRole.mobile]) {
    testWidgets(
        '${role.name}: the shell does not hold later prompts while it waits '
        'for the host, and offers the host run on link', (tester) async {
      await _setUpView(tester);
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      late _Swappable notifier;
      final host = _hostWithCheckpoint();
      final offline = _Offline();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            launchRoleProvider.overrideWithValue(role),
            backendProvider.overrideWith((ref) {
              notifier = _Swappable(ref, offline);
              return notifier;
            }),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const AppShell(child: SizedBox.shrink()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final container =
          ProviderScope.containerOf(tester.element(find.byType(AppShell)));

      expect(await _laterPromptGetsItsTurn(tester, container), isTrue);
      expect(offline.checkpointCalls, 0);

      notifier.use(host);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Host NGC 891'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 20));
    });
  }

  testWidgets(
      'the session check does not hold later prompts while it waits for '
      'the host', (tester) async {
    await _setUpView(tester);
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          launchRoleProvider.overrideWithValue(LaunchRole.linkedClient),
          backendProvider.overrideWith(
            (ref) => _Swappable(ref, DisconnectedBackend()),
          ),
          incompleteSessionsProvider.overrideWith(
            (ref) async => const <SessionRecoveryInfo>[],
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const QuickStartChecker(child: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(QuickStartChecker)),
    );

    expect(await _laterPromptGetsItsTurn(tester, container), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });
}
