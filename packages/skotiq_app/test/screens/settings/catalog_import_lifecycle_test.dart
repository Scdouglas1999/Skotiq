import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/catalog_settings_screen.dart';
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
      'skotiq_catalog_import_test_',
    );
    await CatalogManager.instance.initialize(catalogDirectory.path);
  });

  tearDownAll(() async {
    await catalogDirectory.delete(recursive: true);
  });

  testWidgets('catalog picker is single-flight and safe after screen disposal',
      (tester) async {
    final pick = Completer<XFile?>();
    var pickerCalls = 0;
    var importerCalls = 0;
    await pumpAppScreen(
      tester,
      const CatalogSettingsScreen(),
      size: const Size(1400, 1200),
      settle: false,
      extraOverrides: [
        catalogCsvPickerProvider.overrideWithValue((confirmLabel) {
          pickerCalls++;
          return pick.future;
        }),
        catalogCsvImporterProvider.overrideWithValue((path, type) async {
          importerCalls++;
          return true;
        }),
      ],
    );
    await _finishCatalogLoad(tester);

    final importButton = find.byTooltip('Import from file').first;
    await tester.tap(importButton);
    await tester.tap(importButton);
    await tester.pump();

    expect(pickerCalls, 1);
    expect(find.text('Importing: Star catalog'), findsOneWidget);
    expect(find.text('Selecting a CSV file...'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    pick.complete(XFile('/late-stars.csv'));
    await tester.pump();
    await tester.pump();

    expect(importerCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog picker failures are visible and unlock retry',
      (tester) async {
    await pumpAppScreen(
      tester,
      const CatalogSettingsScreen(),
      size: const Size(1400, 1200),
      settle: false,
      extraOverrides: [
        catalogCsvPickerProvider.overrideWithValue(
          (confirmLabel) async => throw StateError('picker unavailable'),
        ),
      ],
    );
    await _finishCatalogLoad(tester);

    await tester.tap(find.byTooltip('Import from file').first);
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('picker unavailable'), findsOneWidget);
    expect(find.byTooltip('Import from file'), findsWidgets);
    expect(find.text('Importing: Star catalog'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog import dispatches the selected path and type',
      (tester) async {
    final calls = <(String, String)>[];
    await pumpAppScreen(
      tester,
      const CatalogSettingsScreen(),
      size: const Size(1400, 1200),
      settle: false,
      extraOverrides: [
        catalogCsvPickerProvider.overrideWithValue(
          (confirmLabel) async => XFile('/selected-stars.csv'),
        ),
        catalogCsvImporterProvider.overrideWithValue((path, type) async {
          calls.add((path, type));
          return false;
        }),
      ],
    );
    await _finishCatalogLoad(tester);

    await tester.tap(find.byTooltip('Import from file').first);
    await tester.pump();
    await tester.pump();

    expect(calls, [('/selected-stars.csv', 'stars')]);
    expect(find.text('Failed to import catalog'), findsOneWidget);
    expect(find.byTooltip('Import from file'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
