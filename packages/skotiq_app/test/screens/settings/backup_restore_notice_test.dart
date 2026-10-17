// A completed restore leaves a banner that stays until the operator dismisses
// it. A snackbar saying "Restored N items. Restart Skotiq before the next
// run." fades, and then nothing on the screen contradicts an app that looks
// normal while showing in-memory state that disagrees with the database it just
// rewrote — and the reason you restore is usually that you are about to
// observe.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/backup_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _MockBackupService extends Mock implements BackupService {}

Future<void> _finishInitialLoad(WidgetTester tester) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    await tester.pump();
    if (find.text('Import Backup').evaluate().isNotEmpty) return;
  }
  expect(find.text('Import Backup'), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a completed restore leaves a banner that survives the snackbar',
      (tester) async {
    // Sync file work only: inside testWidgets the clock is faked, so a real
    // asynchronous filesystem call never completes unless it is wrapped in
    // tester.runAsync (which the list load below is).
    final directory = Directory.systemTemp.createTempSync('sk-backup-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final backupFile = File('${directory.path}/skotiq-2026-08-01.nsbackup')
      ..writeAsStringSync('{}');

    final service = _MockBackupService();
    when(service.listBackups).thenAnswer((_) async => [backupFile]);
    when(
      () => service.restoreBackup(
        filePath: any(named: 'filePath'),
        replaceExisting: any(named: 'replaceExisting'),
      ),
    ).thenAnswer(
      (_) async => RestoreResult(
        success: true,
        itemsRestored: 123,
        timestamp: DateTime(2026, 8, 1),
      ),
    );

    await pumpAppScreen(
      tester,
      const BackupScreen(),
      size: const Size(1280, 1200),
      settle: false,
      extraOverrides: [
        backupServiceProvider.overrideWithValue(service),
      ],
    );
    await _finishInitialLoad(tester);
    // The list load stats the file on disk; let that real I/O run.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    // The row's Restore action, then the confirmation's. Bounded pumps, not
    // pumpAndSettle: the Restore button spins while the work is in flight and
    // an indeterminate spinner never settles.
    await tester.tap(find.byTooltip('Restore'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(SkotiqButton, 'Restore'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Restart required'), findsOneWidget);
    expect(find.textContaining('Restored 123 items'), findsOneWidget);

    // Well past any snackbar's lifetime.
    await tester.pump(const Duration(seconds: 30));
    expect(
      find.text('Restart required'),
      findsOneWidget,
      reason: 'the app is still showing pre-restore state; say so until '
          'the operator acknowledges it',
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Dismiss'));
    await tester.pump();
    expect(find.text('Restart required'), findsNothing);
  });

  // The first version of this fix held the notice in the screen's State, so
  // walking away from Backup & Restore cleared it — i.e. the reminder was
  // cancelled by exactly the action that makes it matter (you restore, then go
  // to Imaging to start the run). Only the operator's Dismiss may clear it.
  testWidgets('the restart reminder survives leaving and re-entering the page',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('sk-backup-nav');
    addTearDown(() => directory.deleteSync(recursive: true));
    final backupFile = File('${directory.path}/skotiq-2026-08-01.nsbackup')
      ..writeAsStringSync('{}');

    final service = _MockBackupService();
    when(service.listBackups).thenAnswer((_) async => [backupFile]);
    when(
      () => service.restoreBackup(
        filePath: any(named: 'filePath'),
        replaceExisting: any(named: 'replaceExisting'),
      ),
    ).thenAnswer(
      (_) async => RestoreResult(
        success: true,
        itemsRestored: 7,
        timestamp: DateTime(2026, 8, 1),
      ),
    );

    final handle = await pumpAppScreen(
      tester,
      const BackupScreen(),
      size: const Size(1280, 1200),
      settle: false,
      extraOverrides: [
        backupServiceProvider.overrideWithValue(service),
      ],
    );
    await _finishInitialLoad(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Restore'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(SkotiqButton, 'Restore'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Restart required'), findsOneWidget);

    // Navigate away: the settings shell swaps the page body, which disposes
    // BackupScreen's State. Same ProviderScope, as in the real app.
    Future<void> show(Widget child) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: handle.container,
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: Scaffold(body: child),
          ),
        ),
      );
      await tester.pump();
    }

    await show(const SizedBox.shrink());
    expect(find.text('Restart required'), findsNothing);

    await show(const BackupScreen());
    await _finishInitialLoad(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    expect(
      find.text('Restart required'),
      findsOneWidget,
      reason: 'the app is still running on pre-restore state; only Dismiss '
          'may clear the reminder, not walking away from the page',
    );
    expect(find.textContaining('Restored 7 items'), findsOneWidget);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Dismiss'));
    await tester.pump();
    expect(find.text('Restart required'), findsNothing);
  });
}
