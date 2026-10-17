// The Language picker must not promise more than it delivers.
//
// Live: Settings > General > Language > Spanish translates the navigation rail,
// the top strip and the whole Settings tree, and leaves the Dashboard, the
// Sequencer, Imaging and the persistent status bar 100% English (0 of ~12
// visible Dashboard strings translated). Only 46 of the app's 837 source files
// call `l10n` at all. Meanwhile the Spanish subtitle read "Elegir el idioma de
// la interfaz principal" — choose the language of the MAIN interface — which is
// exactly what it does not do.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/general_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;
}

Future<HarnessHandle> _pump(
  WidgetTester tester, {
  required String language,
}) async {
  final handle = await pumpAppScreen(
    tester,
    const GeneralSettings(),
    size: const Size(1280, 900),
    // Production drives MaterialApp.locale from this same setting, so the row
    // has to be read in the locale it stores — the subtitle now comes from the
    // catalogue rather than from a hard-coded ternary on `settings.language`.
    locale: Locale(language),
    extraOverrides: [
      appSettingsProvider.overrideWith(
        () => _StubAppSettingsNotifier(AppSettingsState(language: language)),
      ),
    ],
  );
  await tester.pumpAndSettle();
  return handle;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Spanish option is marked partial', (tester) async {
    await _pump(tester, language: 'en');
    final picker = tester.widget<SkotiqDropdown>(
      find.byType(SkotiqDropdown).first,
    );
    final labels = <String>[
      for (var i = 0; i < picker.items.length; i++) picker.labelFor(i),
    ];
    expect(
      labels.any((l) => l.contains('(beta)')),
      isTrue,
      reason: 'an unqualified "Español" reads as a finished translation',
    );
  });

  testWidgets('the Spanish subtitle scopes itself to what changes', (
    tester,
  ) async {
    await _pump(tester, language: 'es');
    expect(
      find.text('Elegir el idioma de la interfaz principal'),
      findsNothing,
      reason: 'the picker does not change the language of the main interface',
    );
    expect(
      find.textContaining(
        'Captura, el Secuenciador y Analítica siguen en inglés',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the English subtitle keeps its scoped wording', (tester) async {
    await _pump(tester, language: 'en');
    // The scope claim names the Dashboard now that the briefing is wired to
    // the catalogue, and still names what stays English.
    expect(
      find.textContaining('the Dashboard'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Imaging, the Sequencer and Analytics stay in English',
      ),
      findsOneWidget,
    );
  });

  testWidgets('choosing a language still stores its code', (tester) async {
    final handle = await _pump(tester, language: 'en');

    await tester.tap(find.byType(SkotiqDropdown).first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('(beta)').last);
    await tester.pumpAndSettle();

    expect(
      handle.container.read(appSettingsProvider).requireValue.language,
      'es',
    );
  });
}
