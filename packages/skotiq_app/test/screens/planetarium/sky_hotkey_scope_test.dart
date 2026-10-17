// The planetarium's single-letter view hotkeys must not eat typing.
//
// The screen wraps everything in a Focus whose onKeyEvent claims bare
// c/e/f/g/h/m/n/r, and a handled key never reaches the platform text-input path.
// Unscoped, Plan Tonight > Planetarium > sidebar toggle > click "Search objects,
// names..." > type "Vega" leaves the field reading "Va" — 'e' toggles the
// ecliptic, 'g' toggles the RA/Dec grid — and the whole lowercase alphabet
// leaves "abd".
//
// The assertions below are on the two things that make the field usable:
//  * the hotkey callback is NOT invoked while a text field holds the caret;
//  * the event still PROPAGATES (result `ignored`), which is what lets the
//    engine hand the character to the IME. An outer Focus records that.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/sky_hotkey_scope.dart';

void main() {
  late List<LogicalKeyboardKey> hotkeys;
  late List<LogicalKeyboardKey> escaped;
  late TextEditingController controller;

  setUp(() {
    hotkeys = <LogicalKeyboardKey>[];
    escaped = <LogicalKeyboardKey>[];
    controller = TextEditingController();
  });

  tearDown(() => controller.dispose());

  // The hotkeys are a desktop affordance, and EditableText only releases focus
  // on a tap outside itself on desktop platforms.
  final desktop = TargetPlatformVariant.only(TargetPlatform.linux);

  Future<void> pumpScope(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            // Stands in for the rest of the app above the planetarium: it only
            // ever sees a key the sky scope declined to handle.
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent) escaped.add(event.logicalKey);
              return KeyEventResult.ignored;
            },
            child: SkyHotkeyScope(
              onHotkey: (node, event) {
                if (event is KeyDownEvent) hotkeys.add(event.logicalKey);
                return KeyEventResult.handled;
              },
              child: Column(
                children: [
                  TextField(controller: controller),
                  Expanded(
                    child: Container(
                      key: const ValueKey('sky'),
                      color: const Color(0xFF000010),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sky owns the keyboard while nothing is being typed into',
      (tester) async {
    await pumpScope(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();

    expect(hotkeys, [LogicalKeyboardKey.keyE],
        reason: 'the scope autofocuses so the sky keeps its shortcuts');
    expect(escaped, isEmpty,
        reason: 'a real hotkey is consumed, not passed upward');
  }, variant: desktop);

  testWidgets('hotkeys stand down while the caret is in a text field',
      (tester) async {
    await pumpScope(tester);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    hotkeys.clear();
    escaped.clear();

    // 'e' = ecliptic, 'g' = grid, 'h' = reset view — the three that mangled
    // "Vega" in the live repro.
    for (final key in [
      LogicalKeyboardKey.keyE,
      LogicalKeyboardKey.keyG,
      LogicalKeyboardKey.keyH,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }

    expect(hotkeys, isEmpty,
        reason: 'typing into search must not toggle sky layers');
    expect(
      escaped,
      [
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyG,
        LogicalKeyboardKey.keyH,
      ],
      reason: 'the scope must report `ignored` so the character still reaches '
          'the text-input path',
    );
  }, variant: desktop);

  testWidgets('arrow keys belong to the caret too', (tester) async {
    await pumpScope(tester);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    hotkeys.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(hotkeys, isEmpty,
        reason: 'arrows pan the sky, but in a field they move the caret');
  }, variant: desktop);

  testWidgets('tapping back onto the sky restores the hotkeys', (tester) async {
    await pumpScope(tester);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    hotkeys.clear();

    // A field that loses focus hands the keyboard to its enclosing scope, not
    // back to the sky — without the reclaim the screen stays deaf.
    await tester.tap(find.byKey(const ValueKey('sky')));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();

    expect(hotkeys, [LogicalKeyboardKey.keyG]);
  }, variant: desktop);
}
