// Settings › Catalogs must LOG its outcomes, not only snackbar them. Snackbars
// alone leave a session that failed five GLADE+ downloads (and one that
// succeeded) with zero matching entries in Settings › Logs and zero in the
// exported log file — searching 'download' or 'glade' returns "0 of 139
// entries", and the level filter reports the whole night as one error, giving a
// user and a support engineer false confidence about a session that failed
// repeatedly.
//
// These tests assert against the SAME LoggingService instance the screen
// resolves from the provider graph, which is what feeds the in-app viewer and
// the export.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/catalog_settings_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../harness/harness.dart';

Future<void> _finishCatalogLoad(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (find.byTooltip('Import from file').evaluate().isNotEmpty) return;
  }
  expect(find.byTooltip('Import from file'), findsWidgets);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory catalogDirectory;

  setUpAll(() async {
    catalogDirectory = await Directory.systemTemp.createTemp(
      'skotiq_catalog_log_test_',
    );
    await CatalogManager.instance.initialize(catalogDirectory.path);
  });

  tearDownAll(() async {
    await catalogDirectory.delete(recursive: true);
  });

  testWidgets('a failed catalog import is written to the log, not only a toast',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const CatalogSettingsScreen(),
      size: const Size(1400, 1200),
      settle: false,
      extraOverrides: [
        catalogCsvPickerProvider.overrideWithValue(
          (confirmLabel) async => XFile('/selected-stars.csv'),
        ),
        catalogCsvImporterProvider.overrideWithValue(
          (path, type) async => throw StateError('VizieR TAP returned 503'),
        ),
      ],
    );
    await _finishCatalogLoad(tester);

    await tester.tap(find.byTooltip('Import from file').first);
    await tester.pump();
    await tester.pump();

    // The operator saw it...
    expect(find.textContaining('VizieR TAP returned 503'), findsOneWidget);

    // ...and so does anyone reading the logs afterwards.
    final logger = handle.container.read(loggingServiceProvider);
    final errors = logger
        .getRecentLogs(minLevel: LogLevel.error)
        .where((entry) => entry.message.contains('VizieR TAP returned 503'))
        .toList();
    expect(
      errors,
      hasLength(1),
      reason: 'a user-visible catalog failure must leave an ERROR log line',
    );
    expect(errors.single.source, 'CatalogSettings');
  });

  testWidgets('a successful catalog import is recorded too', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const CatalogSettingsScreen(),
      size: const Size(1400, 1200),
      settle: false,
      extraOverrides: [
        catalogCsvPickerProvider.overrideWithValue(
          (confirmLabel) async => XFile('/selected-stars.csv'),
        ),
        catalogCsvImporterProvider
            .overrideWithValue((path, type) async => true),
      ],
    );
    await _finishCatalogLoad(tester);

    await tester.tap(find.byTooltip('Import from file').first);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final logger = handle.container.read(loggingServiceProvider);
    final imported = logger
        .getRecentLogs()
        .where((entry) =>
            entry.source == 'CatalogSettings' &&
            entry.message.contains('Catalog imported'))
        .toList();
    expect(
      imported,
      hasLength(1),
      reason: 'a catalog that arrived tonight must be provable from the log',
    );
    expect(imported.single.fields['type'], 'stars');
  });
}
