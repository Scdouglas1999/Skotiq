// The phone asks about a run to recover through the shell's prompt. Its
// Restore loads the run and waits for Start, and a run already restored is
// not offered again when the phone comes back after a drop.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/connection/connection_stale_banner.dart';
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

class _RecordingExecutor extends Fake implements SequenceExecutor {
  final calls = <String>[];

  @override
  Future<void> restoreFromCheckpoint() async => calls.add('restore');

  @override
  Future<void> start() async => calls.add('start');

  @override
  Future<void> resumeFromCheckpoint() async {
    calls.add('restore');
    calls.add('start');
  }

  @override
  Future<void> discardCheckpoint() async => calls.add('discard');
}

final _checkpoint = CheckpointInfo(
  sequenceName: 'Host NGC 891',
  timestamp: DateTime.now().toUtc(),
  completedExposures: 4,
  completedIntegrationSecs: 240,
  canResume: true,
  ageSeconds: 30,
);

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
  when(() => host.getCheckpointInfo()).thenAnswer((_) async => _checkpoint);
  when(() => host.discardCheckpoint()).thenAnswer((_) async {});
  when(() => host.sequencerGetStatus()).thenAnswer(
      (_) async => const SequencerStatus(state: 'idle', progress: 0));
  return host;
}

Future<ProviderContainer> _mountPhone(
  WidgetTester tester,
  _Host host,
  _RecordingExecutor executor,
) async {
  final root = Directory.systemTemp.createTempSync('sk-phone-checkpoint-');
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

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        launchRoleProvider.overrideWithValue(LaunchRole.mobile),
        backendProvider.overrideWith((ref) => _Linked(ref, host)),
        sequenceExecutorProvider.overrideWithValue(executor),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const AppShell(child: SizedBox.shrink()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return ProviderScope.containerOf(tester.element(find.byType(AppShell)));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Restore on the phone restores and never starts the run',
      (tester) async {
    final executor = _RecordingExecutor();
    await _mountPhone(tester, _hostWithCheckpoint(), executor);
    expect(find.text('Recover sequence?'), findsOneWidget);

    await tester.tap(find.text('Restore'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(executor.calls, ['restore']);
    expect(find.text('Recover sequence?'), findsNothing);

    await _unmount(tester);
  });

  testWidgets('Discard on the phone only discards', (tester) async {
    final host = _hostWithCheckpoint();
    final executor = _RecordingExecutor();
    await _mountPhone(tester, host, executor);

    await tester.tap(find.text('Discard'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    verify(() => host.discardCheckpoint()).called(1);
    expect(executor.calls, isEmpty);
    expect(find.text('Recover sequence?'), findsNothing);

    await _unmount(tester);
  });

  testWidgets(
      'a phone back after a drop does not offer a run that is restored and '
      'waits for Start', (tester) async {
    final host = _hostWithCheckpoint();
    final executor = _RecordingExecutor();
    final container = await _mountPhone(tester, host, executor);
    await tester.tap(find.text('Restore'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    container
        .read(runRecordProvider.notifier)
        .setRestoredCheckpoint(_checkpoint);
    await tester.pump();

    container.read(connectionStaleProvider.notifier).state = true;
    await tester.pump();
    container.read(connectionStaleProvider.notifier).state = false;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Recover sequence?'), findsNothing);
    expect(executor.calls, ['restore']);
    verifyNever(() => host.discardCheckpoint());

    await _unmount(tester);
  });
}
