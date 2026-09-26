import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_ui/nightshade_ui.dart';
import 'package:nightshade_updater/nightshade_updater.dart';

void main() {
  testWidgets('dismissing an error cannot reveal a stale update banner', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'nightshade-update-manager-',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final notifier = _TestUpdateNotifier(tempDir);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [updateProvider.overrideWith((ref) => notifier)],
        child: const MaterialApp(
          home: UpdateManagerWidget(child: Scaffold(body: Text('App'))),
        ),
      ),
    );

    notifier.emitError('Update verification failed');
    await tester.pump();
    expect(find.text('Update verification failed'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(find.text('Update verification failed'), findsNothing);
    expect(find.byType(UpdateReceivedBanner), findsNothing);

    // Drain the widget's startup checks and stale error-dismiss timer so the
    // binding can verify that this test leaves no scheduled work behind.
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
  });
}

class _TestUpdateNotifier extends UpdateNotifier {
  _TestUpdateNotifier(Directory supportDirectory)
    : super(
        currentVersion: '1.0.0',
        currentBuildNumber: 1,
        updateService: UpdateService(
          currentVersion: '1.0.0',
          currentBuildNumber: 1,
          applicationSupportDirectoryProvider: () async => supportDirectory,
        ),
      );

  void emitError(String message) {
    state = state.copyWith(status: UpdateStatus.error, errorMessage: message);
  }

  @override
  Future<void> checkForUpdates({DateTime? now}) async {}

  @override
  Future<void> checkStagedUpdate() async {}
}
