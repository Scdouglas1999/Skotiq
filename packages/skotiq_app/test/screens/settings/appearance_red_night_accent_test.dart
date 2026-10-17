// Red night must not put a full-saturation swatch row on screen.
//
// Live: Settings > Appearance with Theme = Red night rendered the page at
// RGB(20,8,8) and then painted the seven accent circles at their literal
// values — (16,185,129) emerald, (245,158,11) amber, (6,182,212) cyan,
// (236,72,153) magenta. Opening Appearance at the telescope to check the theme
// was the thing that ruined dark adaptation.
//
// The picker is also inert there: `resolveSkotiqThemeData` returns the
// fixed `SkotiqTheme.redNight` without ever reading the accent, so every
// tap on those circles changed nothing on screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/appearance_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;
}

/// The seven swatches the picker renders on the DARK theme, keyed by hex in
/// the widget tree (03 §1.4: the offered set is per theme).
const _swatchKeys = [
  '#A48CF2',
  '#6EB3EC',
  '#43B67A',
  '#E0A53E',
  '#E86A6A',
  '#E77FB3',
  '#4FC3C8',
];

Future<void> _pump(
  WidgetTester tester, {
  required String theme,
  String accent = '#E0A53E',
}) async {
  await pumpAppScreen(
    tester,
    const AppearanceSettings(),
    size: const Size(1280, 900),
    extraOverrides: [
      appSettingsProvider.overrideWith(
        () => _StubAppSettingsNotifier(
          AppSettingsState(theme: theme, accentColor: accent),
        ),
      ),
    ],
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('red night renders no accent swatch at all', (tester) async {
    await _pump(tester, theme: 'redNight');

    for (final hex in _swatchKeys) {
      expect(
        find.byKey(ValueKey('settings-color-$hex')),
        findsNothing,
        reason: '$hex is drawn at full saturation over a red-night page',
      );
    }
  });

  testWidgets('red night says the accent does not apply', (tester) async {
    await _pump(tester, theme: 'redNight', accent: '#43B67A');

    expect(find.text('Accent'), findsOneWidget);
    expect(
      find.textContaining('no effect while it is selected'),
      findsOneWidget,
    );
    // The stored choice is still reported, so the row is not simply missing.
    expect(find.textContaining('#43B67A'), findsOneWidget);
  });

  testWidgets('dark still offers the swatches', (tester) async {
    await _pump(tester, theme: 'dark');

    for (final hex in _swatchKeys) {
      expect(find.byKey(ValueKey('settings-color-$hex')), findsOneWidget);
    }
    expect(
      find.textContaining('Used for the primary action'),
      findsOneWidget,
    );
  });
}
