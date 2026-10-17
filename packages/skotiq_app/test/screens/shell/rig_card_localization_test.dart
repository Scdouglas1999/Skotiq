// The Language row promises "app chrome". The persistent Rig card IS app
// chrome — it is the one strip on every screen — and it was hard-coded English.
//
// Live (Settings > General > Language > Spanish, app_settings.language='es'):
// the nav rail translated (Panel / Equipo / Captura / Secuenciador) and the
// whole Settings tree translated, while the bar underneath still read
// "Camera Disconnected", "Mount Disconnected", "Guider Disconnected", "Focus",
// "Idle", "No save path", "Dashboard" on every one of those screens. The
// setting's own scoped claim was therefore still false.
//
// The rig card renders each pill's VALUE and nothing else — the glyph
// carries the noun — so the strings under test are the ones that name the
// empty slot ("No camera" / "Sin cámara") rather than a static label word
// beside a state word.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/rig_card.dart';

import '../../harness/pump_app_screen.dart';

Future<void> _pumpCard(WidgetTester tester, {Locale? locale}) async {
  await pumpAppScreen(
    tester,
    const Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [RigCard(isExpanded: true)],
    ),
    size: const Size(2600, 900),
    // The bar ticks a 1-second clock; pumpAndSettle would never return.
    settle: false,
    locale: locale,
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// Tears the tree down so the bar's periodic clock timer is cancelled before
/// the binding's pending-timer check runs.
Future<void> _disposeCard(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Finder _inCard(String text) => find.descendant(
      of: find.byType(RigCard),
      matching: find.text(text),
    );

void main() {
  testWidgets('no pill renders a raw translation key', (tester) async {
    // `SkotiqLocalizations.text` falls back to the KEY when a string is
    // missing, so a forgotten entry does not throw — it quietly paints
    // "statusNoCamera" into the chrome on every screen. That is exactly what
    // the four empty-slot strings did when they were first written.
    await _pumpCard(tester);

    for (final key in const [
      'statusNoCamera',
      'statusNoMount',
      'statusNoGuider',
      'statusNoFocuser',
      'statusReady',
      'statusConnected',
    ]) {
      expect(
        _inCard(key),
        findsNothing,
        reason: '"$key" reached the screen, so its string is missing',
      );
    }

    await _disposeCard(tester);
  });

  testWidgets('the Rig card follows the chosen language', (tester) async {
    await _pumpCard(tester, locale: const Locale('es'));

    // The four device pills, with nothing attached.
    expect(_inCard('Sin cámara'), findsOneWidget);
    expect(_inCard('Sin montura'), findsOneWidget);
    expect(_inCard('Sin guiado'), findsOneWidget);
    expect(_inCard('Sin enfocador'), findsOneWidget);
    // The run-state pill and the save-folder pill.
    expect(_inCard('Inactivo'), findsOneWidget);
    expect(_inCard('Sin ruta de guardado'), findsOneWidget);

    expect(_inCard('No camera'), findsNothing);
    expect(_inCard('No mount'), findsNothing);
    expect(_inCard('No save path'), findsNothing);
    expect(_inCard('Idle'), findsNothing);

    await _disposeCard(tester);
  });

  testWidgets('an English build is untouched', (tester) async {
    await _pumpCard(tester);

    expect(_inCard('No camera'), findsOneWidget);
    expect(_inCard('No mount'), findsOneWidget);
    expect(_inCard('No guider'), findsOneWidget);
    expect(_inCard('No focuser'), findsOneWidget);
    expect(_inCard('No save path'), findsOneWidget);
    // Exactly ONE run-state word anywhere on screen (04 §8): the pill. The
    // sequencer LED beside it no longer renders a label of its own, and the
    // Tonight eyebrow is a different screen's business.
    expect(_inCard('Idle'), findsOneWidget);

    await _disposeCard(tester);
  });
}
