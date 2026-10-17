import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/catalog_settings_screen.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

Future<void> _waitForDeleteButton(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (find
        .widgetWithText(SkotiqButton, 'Delete catalogs')
        .evaluate()
        .isNotEmpty) {
      return;
    }
  }
  expect(
    find.widgetWithText(SkotiqButton, 'Delete catalogs'),
    findsOneWidget,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory catalogDirectory;

  setUpAll(() async {
    catalogDirectory = await Directory.systemTemp.createTemp(
      'skotiq_catalog_delete_test_',
    );
    await CatalogManager.instance.initialize(catalogDirectory.path);
  });

  setUp(() async {
    await for (final entity in catalogDirectory.list()) {
      await entity.delete(recursive: true);
    }
    await File(CatalogManager.instance.starCatalogPath).writeAsString(
      'id,proper,ra,dec,mag\n1,Polaris,2.5,89.2,1.9\n',
    );
  });

  tearDownAll(() async {
    if (await catalogDirectory.exists()) {
      await catalogDirectory.delete(recursive: true);
    }
  });

  testWidgets('delete failure is visible, truthful, and retryable',
      (tester) async {
    var deleteCalls = 0;
    await pumpAppScreen(
      tester,
      const CatalogSettingsScreen(isMobile: true),
      size: const Size(1000, 1800),
      settle: false,
      extraOverrides: [
        catalogDeleteActionProvider.overrideWithValue(() async {
          deleteCalls++;
          throw StateError('catalog file is locked');
        }),
      ],
    );
    await _waitForDeleteButton(tester);

    final deleteButton =
        find.widgetWithText(SkotiqButton, 'Delete catalogs');
    await tester.ensureVisible(deleteButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(deleteButton);
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Delete').last);
    await tester.pump();
    await tester.pump();

    expect(deleteCalls, 1);
    expect(find.textContaining('Catalog deletion failed'), findsOneWidget);
    expect(find.textContaining('catalog file is locked'), findsOneWidget);
    expect(find.text('Star and deep-sky catalogs deleted'), findsNothing);
    expect(find.textContaining('Importing:'), findsNothing);
    final button = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Delete catalogs'),
    );
    expect(button.onPressed, isNotNull);
    expect(button.isLoading, isFalse);
    expect(tester.takeException(), isNull);
  });
}
