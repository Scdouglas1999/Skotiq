import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/backup_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _MockBackupService extends Mock implements BackupService {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void swap(SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

Future<void> _finishInitialLoad(WidgetTester tester) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    await tester.pump();
    if (find.text('Import Backup').evaluate().isNotEmpty) return;
  }
  expect(find.text('Import Backup'), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('backup import picker is single-flight and rejects host switch',
      (tester) async {
    final service = _MockBackupService();
    when(service.listBackups).thenAnswer((_) async => []);
    final pick = Completer<XFile?>();
    var pickerCalls = 0;

    final handle = await pumpAppScreen(
      tester,
      const BackupScreen(),
      size: const Size(1280, 1000),
      settle: false,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
        ),
        backupServiceProvider.overrideWithValue(service),
        backupImportPickerProvider.overrideWithValue(() {
          pickerCalls++;
          return pick.future;
        }),
      ],
    );
    await _finishInitialLoad(tester);

    final importButton = find.widgetWithText(
      SkotiqButton,
      'Import Backup',
    );
    await tester.tap(importButton);
    await tester.tap(importButton);
    await tester.pump();

    expect(pickerCalls, 1);
    expect(
      find.widgetWithText(SkotiqButton, 'Importing...'),
      findsOneWidget,
    );

    final backend = handle.container.read(backendProvider.notifier)
        as _SwappableBackendNotifier;
    backend.swap(DisconnectedBackend());
    await tester.pump();
    expect(
      find.widgetWithText(SkotiqButton, 'Import Backup'),
      findsOneWidget,
    );

    pick.complete(XFile('/old-host-backup.nsbackup'));
    await tester.pump();
    await tester.pump();

    verifyNever(
      () => service.restoreBackup(
        filePath: any(named: 'filePath'),
        replaceExisting: any(named: 'replaceExisting'),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('local backup import confirms, restores, and reports success',
      (tester) async {
    final service = _MockBackupService();
    when(service.listBackups).thenAnswer((_) async => []);
    when(
      () => service.restoreBackup(
        filePath: any(named: 'filePath'),
        replaceExisting: any(named: 'replaceExisting'),
      ),
    ).thenAnswer(
      (_) async => RestoreResult(
        success: true,
        timestamp: DateTime(2026),
        itemsRestored: 7,
      ),
    );

    await pumpAppScreen(
      tester,
      const BackupScreen(),
      size: const Size(1280, 1000),
      settle: false,
      extraOverrides: [
        backupServiceProvider.overrideWithValue(service),
        backupImportPickerProvider.overrideWithValue(
          () async => XFile('/selected-backup.nsbackup'),
        ),
      ],
    );
    await _finishInitialLoad(tester);

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Import Backup'),
    );
    await tester.pump();
    expect(find.text('Restore Backup?'), findsOneWidget);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Restore'));
    await tester.pump();
    await tester.pump();

    verify(
      () => service.restoreBackup(
        filePath: '/selected-backup.nsbackup',
        replaceExisting: false,
      ),
    ).called(1);
    // The outcome is a banner that stays, not a snackbar that fades: after a
    // restore the running app is showing pre-restore state.
    expect(find.text('Restart required'), findsOneWidget);
    expect(find.textContaining('Restored 7 items'), findsOneWidget);
    expect(
      find.widgetWithText(SkotiqButton, 'Import Backup'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('backup picker failures are visible and unlock retry',
      (tester) async {
    final service = _MockBackupService();
    when(service.listBackups).thenAnswer((_) async => []);
    await pumpAppScreen(
      tester,
      const BackupScreen(),
      size: const Size(1280, 1000),
      settle: false,
      extraOverrides: [
        backupServiceProvider.overrideWithValue(service),
        backupImportPickerProvider.overrideWithValue(
          () async => throw StateError('picker unavailable'),
        ),
      ],
    );
    await _finishInitialLoad(tester);

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Import Backup'),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('picker unavailable'), findsOneWidget);
    expect(
      find.widgetWithText(SkotiqButton, 'Import Backup'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
