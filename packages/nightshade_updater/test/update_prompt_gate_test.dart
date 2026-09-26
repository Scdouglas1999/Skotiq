// When the app is allowed to interrupt you about an update.
//
// The rule is narrow on purpose: never talk over a run in progress, but do
// not hold the news forever either. An update found at the start of a night
// that was only mentioned at the next scheduled check would reach the
// operator up to twelve hours later, quite possibly while nobody is looking.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_updater/nightshade_updater.dart';

class _TestNotifier extends UpdateNotifier {
  _TestNotifier(Directory dir)
    : super(
        currentVersion: '7.1.0',
        currentBuildNumber: 28,
        updateService: UpdateService(
          currentVersion: '7.1.0',
          currentBuildNumber: 28,
          applicationSupportDirectoryProvider: () async => dir,
        ),
        promptStore: UpdatePromptStore(() async => dir),
      );

  @override
  Future<void> checkForUpdates({DateTime? now}) async {}

  @override
  Future<void> checkForUpdatesIfDue({DateTime? now}) async {}

  @override
  Future<void> checkStagedUpdate() async {}

  void offer(String version) {
    state = state.copyWith(
      status: UpdateStatus.available,
      sourceConfigured: true,
      availableUpdate: UpdateManifest(
        version: version,
        buildNumber: 42,
        releaseDate: DateTime.utc(2026, 9, 20),
        platform: 'linux',
        arch: 'x64',
        files: const {},
        totalSize: 0,
        compressedSize: 10 * 1024 * 1024,
        downloadUrl: 'https://example.invalid/pkg.zip',
      ),
    );
  }
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ns-prompt-gate-');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<(_TestNotifier, ProviderContainer)> pump(
    WidgetTester tester, {
    required SequenceExecutionState initialSequenceState,
  }) async {
    final notifier = _TestNotifier(dir);
    final container = ProviderContainer(
      overrides: [updateProvider.overrideWith((ref) => notifier)],
    );
    addTearDown(container.dispose);
    container.read(sequenceExecutionStateProvider.notifier).state =
        initialSequenceState;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: UpdateManagerWidget(child: Scaffold(body: Text('App'))),
        ),
      ),
    );
    await tester.pump();
    return (notifier, container);
  }

  testWidgets('an update found mid-run does not interrupt it', (tester) async {
    final (notifier, _) = await pump(
      tester,
      initialSequenceState: SequenceExecutionState.running,
    );

    notifier.offer('7.2.0');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.textContaining('7.2.0'),
      findsNothing,
      reason: 'nothing may be shown over a running sequence',
    );
    // But it was still found, so Settings can show it.
    expect(notifier.state.availableUpdate?.version, '7.2.0');

    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
  });

  testWidgets('the offer arrives once the run ends', (tester) async {
    final (notifier, container) = await pump(
      tester,
      initialSequenceState: SequenceExecutionState.running,
    );

    notifier.offer('7.2.0');
    await tester.pump();
    expect(find.textContaining('7.2.0'), findsNothing);

    // The night finishes.
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.idle;
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('7.2.0'),
      findsWidgets,
      reason: 'the held-back offer should arrive when the rig goes idle',
    );

    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
  });

  testWidgets('an idle rig is offered the update straight away', (
    tester,
  ) async {
    final (notifier, _) = await pump(
      tester,
      initialSequenceState: SequenceExecutionState.idle,
    );

    notifier.offer('7.2.0');
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('7.2.0'), findsWidgets);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
  });
}
