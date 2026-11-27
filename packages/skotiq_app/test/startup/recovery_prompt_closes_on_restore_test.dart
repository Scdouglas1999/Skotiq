import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _Host extends Mock implements NetworkBackend {}

class _Linked extends BackendNotifier {
  _Linked(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

final _checkpoint = CheckpointInfo(
  sequenceName: 'Host NGC 891',
  timestamp: DateTime.now().toUtc(),
  completedExposures: 4,
  completedIntegrationSecs: 240,
  canResume: true,
  ageSeconds: 30,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'the recovery prompt closes when another prompt restores the run, '
      'so its Discard cannot delete the restored run\'s checkpoint',
      (tester) async {
    final root = Directory.systemTemp.createTempSync('sk-recovery-restored-');
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

    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final host = _Host();
    when(
      () => host.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(
      () => host.connectionState,
    ).thenReturn(BackendConnectionState.connected);
    when(() => host.isAuthTokenRejected).thenReturn(false);
    when(() => host.serverHost).thenReturn('rig.local');
    when(() => host.scheme).thenReturn('http');
    when(() => host.serverPort).thenReturn(4700);
    when(() => host.lastLatency).thenReturn(null);
    when(() => host.unansweredPingAge).thenReturn(null);
    when(() => host.isRemoteHost).thenReturn(false);
    when(
      () => host.latencyStream,
    ).thenAnswer((_) => const Stream<Duration>.empty());
    when(() => host.connectionStateStream).thenAnswer(
      (_) => const Stream<BackendConnectionState>.empty(),
    );
    when(() => host.hostRunInFlight()).thenAnswer((_) async => false);
    when(() => host.hasCheckpoint()).thenAnswer((_) async => true);
    when(() => host.getCheckpointInfo()).thenAnswer((_) async => _checkpoint);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          remoteClientLaunchProvider.overrideWithValue(false),
          backendProvider.overrideWith((ref) => _Linked(ref, host)),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const AppShell(child: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Recover sequence?'), findsOneWidget);

    ProviderScope.containerOf(tester.element(find.byType(AppShell)))
        .read(runRecordProvider.notifier)
        .setRestoredCheckpoint(_checkpoint);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Recover sequence?'), findsNothing);
    verifyNever(() => host.discardCheckpoint());

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });
}
