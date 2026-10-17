// Keyboard operability for SkotiqButton.
//
// Every SkotiqButton must be reachable with Tab and fire on Enter/Space; a
// `Semantics > MouseRegion > GestureDetector` with no focus node is neither,
// which leaves the first-run setup wizard unfinishable without a mouse. These
// tests pin the four properties the FocusableActionDetector has to hold on
// every platform: it is reachable, it fires exactly once per key press, a
// disabled button is skipped, and gaining focus does not move anything.
//
// The pixel test at the bottom guards the focus ring: a spread `BoxShadow` is a
// FILLED round-rect painted behind the box, and on `ghost`/`outline` — which
// are transparent until hover — it shows straight through as a solid slab.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Widget host(Widget child, {TargetPlatform? platform}) => MaterialApp(
    theme: platform == null
        ? SkotiqTheme.dark
        : SkotiqTheme.dark.copyWith(platform: platform),
    home: Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      body: Center(child: child),
    ),
  );

  group('SkotiqButton keyboard operability', () {
    // Every platform, because the bug was platform-independent: desktop users
    // driving the app from the keyboard and tablet users on a paired keyboard
    // were both locked out.
    for (final platform in TargetPlatform.values) {
      testWidgets('$platform: Tab reaches the button and Enter fires it once', (
        tester,
      ) async {
        var presses = 0;
        await tester.pumpWidget(
          host(
            SkotiqButton(label: 'Start', onPressed: () => presses++),
            platform: platform,
          ),
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.context,
          isNotNull,
          reason: 'Tab must land somewhere on $platform',
        );
        expect(
          find.descendant(
            of: find.byType(SkotiqButton),
            matching: find.byType(FocusableActionDetector),
          ),
          findsOneWidget,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(
          presses,
          1,
          reason:
              'Enter must fire onPressed exactly once on $platform '
              '(the GestureDetector and the ActivateIntent action must not '
              'both run)',
        );
      });
    }

    // Tab-order, Space and the plain disabled case are covered by
    // test/components/skotiq_button_keyboard_test.dart; the cases below are
    // the ones that file does not reach.
    testWidgets('a loading button is skipped by Tab', (tester) async {
      var loadingPresses = 0;
      var enabledPresses = 0;
      await tester.pumpWidget(
        host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SkotiqButton(
                label: 'Working',
                isLoading: true,
                onPressed: () => loadingPresses++,
              ),
              SkotiqButton(label: 'Ready', onPressed: () => enabledPresses++),
            ],
          ),
        ),
      );

      // Bare pumps, not pumpAndSettle: the loading button's
      // CircularProgressIndicator never stops animating.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(
        loadingPresses,
        0,
        reason: 'A button showing a spinner must not be keyboard-activatable',
      );
      expect(enabledPresses, 1);
    });

    testWidgets('focus does not change the button geometry', (tester) async {
      await tester.pumpWidget(
        host(SkotiqButton(label: 'Start sequence', onPressed: () {})),
      );

      final before = tester.getRect(find.byType(SkotiqButton));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final after = tester.getRect(find.byType(SkotiqButton));

      expect(
        after,
        before,
        reason:
            'The focus ring must be painted outside the box, never laid '
            'out, or focusing a button reflows every dense panel it sits in',
      );
    });

    // The ring lives in a Stack wrapped around the button's box. A Stack's
    // DEFAULT fit is loose, which strips the incoming minimum — so a button
    // handed tight constraints would have silently shrunk to its content the
    // moment the ring was introduced. That is not theoretical: it collapsed
    // 'Import Backup' and 'Restore Backup?' out of reach in the settings suite
    // until the Stack was switched to StackFit.passthrough.
    testWidgets('a button under tight constraints still fills them', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 400,
            child: Row(
              children: [
                Expanded(
                  child: SkotiqButton(label: 'Import', onPressed: () {}),
                ),
              ],
            ),
          ),
        ),
      );

      // Measure the PAINTED box, not the outer SkotiqButton element: the
      // Stack itself is handed the tight 400 either way, and only its
      // non-positioned child shrinks inside it under a loose fit — so
      // measuring the outer widget would report 400 and prove nothing.
      final box = find.descendant(
        of: find.byType(SkotiqButton),
        matching: find.byType(AnimatedContainer),
      );
      expect(
        tester.getSize(box).width,
        400,
        reason:
            'Expanded gives the button a tight width; the focus-ring Stack '
            'must pass it through rather than loosening it away',
      );
    });

    testWidgets('the ring survives inside a dialog and does not escape it', (
      tester,
    ) async {
      var dialogPresses = 0;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => SkotiqButton(
              label: 'Open',
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  content: SkotiqButton(
                    label: 'Confirm',
                    onPressed: () => dialogPresses++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Tab inside a modal route must stay inside it and reach the button.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(
        dialogPresses,
        1,
        reason: 'A SkotiqButton in a dialog must be keyboard-operable',
      );
    });
  });

  group('SkotiqButton focus ring', () {
    /// Reads the raw RGBA of the tree under [key].
    Future<(Uint8List, int)> capture(WidgetTester tester, Key key) async {
      final boundary =
          tester.renderObject(find.byKey(key)) as RenderRepaintBoundary;
      // toByteData needs the real event loop; the fake-async test zone never
      // completes its future, so the whole run hangs without runAsync.
      final result = await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage();
        final ByteData? data = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        return (data!.buffer.asUint8List(), image.width);
      });
      return result!;
    }

    Color pixel(Uint8List bytes, int width, int x, int y) {
      final i = (y * width + x) * 4;
      return Color.fromARGB(bytes[i + 3], bytes[i], bytes[i + 1], bytes[i + 2]);
    }

    const boundaryKey = ValueKey('ring-boundary');
    const background = Color(0xFF0B0E14);
    const pad = 20.0;

    /// A transparent-fill variant is the case the ring must not swallow.
    for (final variant in const [ButtonVariant.ghost, ButtonVariant.outline]) {
      testWidgets('$variant keeps a transparent interior while focused', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: SkotiqTheme.dark,
            home: Scaffold(
              backgroundColor: background,
              body: Center(
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: ColoredBox(
                    color: background,
                    child: Padding(
                      padding: const EdgeInsets.all(pad),
                      child: SkotiqButton(
                        label: 'Maybe Later',
                        variant: variant,
                        size: ButtonSize.small,
                        onPressed: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();

        final buttonRect = tester.getRect(find.byType(SkotiqButton));
        final boundaryRect = tester.getRect(find.byKey(boundaryKey));
        final (bytes, width) = await capture(tester, boundaryKey);

        // A point just inside the button's own border, clear of the glyphs:
        // 3px in from the left edge, vertically centred.
        final insideX = (buttonRect.left - boundaryRect.left + 3).round();
        final midY = (buttonRect.center.dy - boundaryRect.top).round();
        expect(
          pixel(bytes, width, insideX, midY),
          background,
          reason:
              '$variant is transparent until hover, so a focused button '
              'must still show the surface behind it. A filled ring (a spread '
              'BoxShadow) paints through the middle and makes the label '
              'unreadable.',
        );

        // ...and the ring itself is actually drawn, 1px outside the box.
        final ringX = (buttonRect.left - boundaryRect.left - 1).round();
        expect(
          pixel(bytes, width, ringX, midY),
          isNot(background),
          reason: 'The focus ring must be visible just outside the button',
        );
      });
    }

    testWidgets('an unfocused ghost button paints no ring at all', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            backgroundColor: background,
            body: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: ColoredBox(
                  color: background,
                  child: Padding(
                    padding: EdgeInsets.all(pad),
                    child: SkotiqButton(
                      label: 'Maybe Later',
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                      onPressed: null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final buttonRect = tester.getRect(find.byType(SkotiqButton));
      final boundaryRect = tester.getRect(find.byKey(boundaryKey));
      final (bytes, width) = await capture(tester, boundaryKey);

      final ringX = (buttonRect.left - boundaryRect.left - 1).round();
      final midY = (buttonRect.center.dy - boundaryRect.top).round();
      expect(pixel(bytes, width, ringX, midY), background);
    });
  });
}
