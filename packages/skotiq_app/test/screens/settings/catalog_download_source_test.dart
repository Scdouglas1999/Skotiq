// Settings > Catalogs > Advanced: a self-hoster points catalog downloads at a
// mirror of the catalog release, and can go back to the default.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/catalog_download_source_card.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

Future<HarnessHandle> _pump(WidgetTester tester) async {
  final handle = await pumpAppScreen(
    tester,
    const SingleChildScrollView(child: CatalogDownloadSourceCard()),
    size: const Size(420, 900),
    extraOverrides: [
      appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
    ],
  );
  await tester.pumpAndSettle();
  return handle;
}

String _saved(HarnessHandle handle) =>
    handle.container.read(appSettingsProvider).requireValue.catalogBaseUrl;

void main() {
  testWidgets('folded away until Change, saving a mirror and resetting it', (
    tester,
  ) async {
    final handle = await _pump(tester);
    expect(
      find.textContaining('download from the Skotiq release'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://mirror.example.org/catalogs',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_saved(handle), 'https://mirror.example.org/catalogs');
    expect(find.byType(TextField), findsNothing);
    expect(find.text('https://mirror.example.org/catalogs'), findsOneWidget);
    expect(find.textContaining('from your mirror first'), findsOneWidget);

    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset to default'));
    await tester.pumpAndSettle();
    expect(_saved(handle), '');
    expect(
      find.textContaining('download from the Skotiq release'),
      findsOneWidget,
    );
  });

  testWidgets('an address that is not http or https is refused with the '
      'reason', (tester) async {
    final handle = await _pump(tester);
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'mirror.example.org');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('starts with https://'), findsOneWidget);
    expect(_saved(handle), '');
  });
}
