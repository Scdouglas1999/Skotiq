import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/app_update.dart';
import 'package:skotiq_app/widgets/update/update_dialogs.dart';
import 'package:skotiq_app/widgets/update/update_manager_widget.dart';
import 'package:skotiq_updater/skotiq_updater.dart';

void main() {
  testWidgets('dismissing an error cannot reveal a stale update banner', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'skotiq-update-manager-',
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
    expect(find.byType(UpdateReadyBanner), findsNothing);

    // Drain the widget's startup checks and stale error-dismiss timer so the
    // binding can verify that this test leaves no scheduled work behind.
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
  });

  // ux walk-2 F1: the first thing a new user offline saw was a red toast
  // "UpdateException: Network error: Connection failed".
  testWidgets('a check that cannot reach its source raises no toast', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'skotiq-update-manager-',
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
    await tester.pump(const Duration(seconds: 4));

    notifier.emitStatus(UpdateStatus.checking);
    await tester.pump();
    notifier.emitError('Could not reach GitHub (Connection failed).');
    await tester.pump();

    expect(find.textContaining('Could not reach GitHub'), findsNothing);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
  });

  testWidgets(
      'a download that ends verified and staged raises no LAN push '
      'banner', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'skotiq-update-manager-',
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

    // Past the launch checks for an update staged by an earlier run.
    await tester.pump(const Duration(seconds: 4));

    for (final status in [
      UpdateStatus.downloading,
      UpdateStatus.verifying,
      UpdateStatus.staged,
    ]) {
      notifier.emitStatus(status);
      await tester.pump();
    }

    expect(find.byType(UpdateReadyBanner), findsNothing);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
  });

  testWidgets(
      'an update staged before launch is offered without claiming it '
      'came over the LAN, its title on one line at 1280 px', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final tempDir = Directory.systemTemp.createTempSync(
      'skotiq-update-manager-',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final notifier = _TestUpdateNotifier(tempDir, stagedAtLaunch: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [updateProvider.overrideWith((ref) => notifier)],
        child: const MaterialApp(
          home: UpdateManagerWidget(child: Scaffold(body: Text('App'))),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));

    final banner = find.byType(UpdateReadyBanner);
    expect(banner, findsOneWidget);
    expect(
      find.descendant(of: banner, matching: find.textContaining('LAN')),
      findsNothing,
    );
    final title = tester.renderObject<RenderParagraph>(
      find.descendant(of: banner, matching: find.byType(RichText)).first,
    );
    expect(
      title.size.width,
      greaterThanOrEqualTo(title.getMaxIntrinsicWidth(double.infinity) - 0.5),
      reason: 'the banner title wrapped',
    );

    await tester.pump(const Duration(seconds: 70));
    await tester.pump();
  });
}

class _TestUpdateNotifier extends UpdateNotifier {
  _TestUpdateNotifier(Directory supportDirectory, {this.stagedAtLaunch = false})
      : super(
          currentVersion: '1.0.0',
          currentBuildNumber: 1,
          dataDirectory: () async => supportDirectory,
          updateService: UpdateService(
            currentVersion: '1.0.0',
            currentBuildNumber: 1,
            applicationSupportDirectoryProvider: () async => supportDirectory,
          ),
        );

  void emitStatus(UpdateStatus status) {
    state = state.copyWith(
      status: status,
      availableUpdate: UpdateManifest(
        version: '1.1.0',
        buildNumber: 2,
        releaseDate: DateTime.utc(2026, 11, 1),
        platform: 'linux',
        arch: 'x64',
        files: const {},
        totalSize: 0,
        compressedSize: 0,
        downloadUrl: 'https://example.invalid/skotiq.zip',
      ),
    );
  }

  void emitError(String message) {
    state = state.copyWith(status: UpdateStatus.error, errorMessage: message);
  }

  @override
  Future<void> checkForUpdates({DateTime? now}) async {}

  /// An update downloaded from the update server by an earlier run.
  final bool stagedAtLaunch;

  @override
  Future<void> checkStagedUpdate() async {
    if (stagedAtLaunch) emitStatus(UpdateStatus.staged);
  }
}
