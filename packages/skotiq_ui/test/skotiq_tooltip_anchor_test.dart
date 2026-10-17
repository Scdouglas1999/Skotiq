import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A tooltip must be drawn ON the control it describes, and only one may be on
/// screen at a time.
///
/// Anchor: measuring the anchor in SCREEN coordinates with
/// `localToGlobal(Offset.zero)` misplaces it, because the overlay child is laid
/// out in the host Overlay's coordinate space. Wherever that overlay is inset
/// from the window the tooltip is displaced by exactly the inset — on the
/// planetarium toolbar the `Layers` label lands 176 px right and 79 px below
/// its button, out over the star field next to a different control.
///
/// Lifecycle: a tooltip owning an independent `OverlayPortalController` with no
/// arbitration leaves the first one alive when a second opens. Several stale
/// labels floating over a dark star field read as sky annotations.
void main() {
  const trigger = Key('trigger');

  const anchorBox = ColoredBox(
    key: trigger,
    color: Color(0xFF224466),
    child: SizedBox(width: 34, height: 34),
  );

  // An Overlay deliberately inset from the window origin — the shape that
  // separates "measured against the screen" from "measured against my
  // overlay". At the window origin the two are indistinguishable.
  Widget insetOverlayHost({
    required Offset inset,
    required SkotiqTooltipPosition side,
  }) {
    return MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.only(left: inset.dx, top: inset.dy),
          child: Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (_) => Center(
                  child: SkotiqTooltip(
                    message: 'Layers',
                    position: side,
                    child: anchorBox,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  for (final (name, inset) in const <(String, Offset)>[
    ('overlay at the window origin', Offset.zero),
    ('overlay inset by a nav rail and a header', Offset(176, 79)),
  ]) {
    testWidgets('tooltip is drawn on its trigger — $name', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        insetOverlayHost(inset: inset, side: SkotiqTooltipPosition.bottom),
      );
      await tester.longPress(find.byKey(trigger));
      await tester.pumpAndSettle();

      final triggerRect = tester.getRect(find.byKey(trigger));
      final tooltipRect = tester.getRect(find.text('Layers'));

      expect(
        tooltipRect.center.dx,
        closeTo(triggerRect.center.dx, 1.0),
        reason: '$name: tooltip is not centred on the control it describes',
      );
      // Below the trigger, and close enough to read as attached to it: the
      // gap is padding + arrow + the label's own vertical padding.
      expect(
        tooltipRect.top,
        greaterThanOrEqualTo(triggerRect.bottom),
        reason: '$name: a bottom-positioned tooltip drew over its trigger',
      );
      expect(
        tooltipRect.top - triggerRect.bottom,
        lessThan(40.0),
        reason: '$name: tooltip floats away from the control it describes',
      );

      // Long-press arms a 3 s auto-dismiss; let it run out so no timer
      // outlives the test.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('opening a second tooltip retires the first', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                SkotiqTooltip(
                  message: 'Reset view',
                  position: SkotiqTooltipPosition.bottom,
                  child: ColoredBox(
                    key: Key('a'),
                    color: Color(0xFF224466),
                    child: SizedBox(width: 34, height: 34),
                  ),
                ),
                SkotiqTooltip(
                  message: 'Equatorial view',
                  position: SkotiqTooltipPosition.bottom,
                  child: ColoredBox(
                    key: Key('b'),
                    color: Color(0xFF224466),
                    child: SizedBox(width: 34, height: 34),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.byKey(const Key('a')));
    await tester.pumpAndSettle();
    expect(find.text('Reset view'), findsOneWidget);

    await tester.longPress(find.byKey(const Key('b')));
    await tester.pumpAndSettle();

    expect(
      find.text('Reset view'),
      findsNothing,
      reason: 'the first tooltip stayed on screen after a second one opened',
    );
    expect(find.text('Equatorial view'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
