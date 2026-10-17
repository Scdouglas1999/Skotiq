// The desktop status bar must not silently cut off its trailing readouts in a
// small window.
//
// A bare `Row` with a `Spacer` clips the overflow at the right edge once the
// pills and readouts exceed the window width — no ellipsis, no scroll, no
// indication anything is missing. At 1000x700 the clock and LST readouts are
// gone entirely; at 800x600 the save-path chip is cut mid-word ("No s").
//
// So the device-pill group takes the slack (and scrolls when there is none)
// while the readouts on the right stay pinned and whole. Both halves are pinned
// here: "make it scroll" is wrong if it also loses the right-alignment on a wide
// window.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/status_bar.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// The pill group's scroll view — the only Scrollable the bar owns.
Finder _pillScroller() => find.descendant(
      of: find.byType(StatusBar),
      matching: find.byType(Scrollable),
    );

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(_pillScroller().first).position;

/// The right-most readout: the clock is always last in the trailing group.
Finder _lastReadout() => find.descendant(
      of: find.byType(StatusBar),
      matching: find.byType(Text),
    );

Future<void> _pumpBar(WidgetTester tester, Size size) async {
  await pumpAppScreen(
    tester,
    // Bottom-align it the way the shell does, so the bar takes its natural
    // height instead of being stretched by the test Scaffold.
    const Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [StatusBar()],
    ),
    size: size,
    extraOverrides: [
      // The LST readout pulls in the planetarium's observation-time notifier,
      // whose own 1-second timer outlives the widget tree and trips the
      // binding's end-of-test timer check. The bar's layout does not care what
      // the number is.
      localSiderealTimeProvider.overrideWithValue(12.5),
    ],
    // The bar ticks a 1-second periodic timer for its clock; pumpAndSettle
    // would never return.
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// Dispose the tree so the bar's periodic clock timer is cancelled before the
/// binding's end-of-test timer check runs.
Future<void> _disposeBar(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets('a narrow window scrolls the pills instead of clipping',
      (tester) async {
    await _pumpBar(tester, const Size(800, 600));

    expect(tester.takeException(), isNull);
    expect(_pillScroller(), findsWidgets);
    expect(
      _position(tester).maxScrollExtent,
      greaterThan(0),
      reason: 'pills wider than the slack must be reachable by scrolling, '
          'not cut off at the edge',
    );

    await _disposeBar(tester);
  });

  testWidgets('the trailing readouts stay whole and on-screen when narrow',
      (tester) async {
    await _pumpBar(tester, const Size(800, 600));

    // Every readout in the trailing group is laid out inside the window. This
    // is the property that failed before: the tail of the bar was outside it.
    final barRect = tester.getRect(find.byType(StatusBar));
    final texts = _lastReadout();
    var checked = 0;
    for (var i = 0; i < texts.evaluate().length; i++) {
      final rect = tester.getRect(texts.at(i));
      // Skip anything inside the scrollable pill group — that is allowed to
      // extend past the viewport, because it can be scrolled to.
      final inScroller = find
          .descendant(of: _pillScroller().first, matching: texts.at(i))
          .evaluate()
          .isNotEmpty;
      if (inScroller) continue;
      checked++;
      expect(
        rect.right,
        lessThanOrEqualTo(barRect.right + 0.5),
        reason:
            'trailing readout "${(texts.at(i).evaluate().single.widget as Text).data}" '
            'is cut off at the window edge',
      );
      expect(rect.left, greaterThanOrEqualTo(barRect.left - 0.5));
    }
    expect(checked, greaterThan(0),
        reason: 'no trailing readouts were checked');
    expect(tester.takeException(), isNull);

    await _disposeBar(tester);
  });

  // Scrolling alone was not enough. On a desktop mouse a horizontal scroll view
  // with no scrollbar and no fade is close to undiscoverable, and its viewport
  // edge sliced the pill label mid-word — live at 800x600 the bar read
  // "Mount Dis", which looks like a rendering fault rather than "there is more
  // over here".
  //
  // The instrument pill answers that structurally: it renders ONE string, the
  // value, and the glyph carries the noun. What matters is that the string is
  // the one that DIFFERS per pill. Rendering the state instead left the Camera,
  // Mount and Guider pills all reading the identical word "Disconnected",
  // distinguished only by a small monochrome glyph — three pills' worth of
  // width spent saying nothing. So an empty slot names the thing that is
  // missing, at every width.
  testWidgets('every device pill names its own device, at any width',
      (tester) async {
    for (final size in const [Size(800, 600), Size(2600, 900)]) {
      await _pumpBar(tester, size);

      for (final value in [
        'No camera',
        'No mount',
        'No guider',
        'No focuser'
      ]) {
        expect(
          find.descendant(
            of: find.byType(StatusBar),
            matching: find.text(value),
          ),
          findsOneWidget,
          reason:
              '"$value" has to stay identifiable at ${size.width.toInt()}px',
        );
      }
      expect(
        find.descendant(
          of: find.byType(StatusBar),
          matching: find.text('Disconnected'),
        ),
        findsNothing,
        reason: 'the same word on three pills is width spent saying nothing',
      );
      expect(tester.takeException(), isNull);

      await _disposeBar(tester);
    }
  });

  // Shedding the labels is not always enough (a long profile name can still
  // push a pill past the edge). When the group really does overflow the bar
  // must SAY so: a silent cut made "mount pill scrolled out of view" look
  // identical to "no mount configured".
  testWidgets('an overflowing pill group is marked with a fade',
      (tester) async {
    await _pumpBar(tester, const Size(800, 600));
    expect(_position(tester).maxScrollExtent, greaterThan(0));

    expect(
      find.descendant(
        of: find.byType(StatusBar),
        matching: find.byType(ShaderMask),
      ),
      findsOneWidget,
      reason: 'an overflowing pill group must show an edge fade',
    );

    await _disposeBar(tester);
  });

  testWidgets('a bar with room shows no fade', (tester) async {
    await _pumpBar(tester, const Size(2600, 900));
    expect(_position(tester).maxScrollExtent, 0);

    expect(
      find.descendant(
        of: find.byType(StatusBar),
        matching: find.byType(ShaderMask),
      ),
      findsNothing,
      reason: 'a fade with nothing hidden behind it is a false affordance',
    );

    await _disposeBar(tester);
  });

  testWidgets('a wide window keeps the trailing group right-aligned',
      (tester) async {
    // Deliberately far wider than any real window: widget tests render with a
    // fixed-width test font, so the same bar that fits 1400 real pixels needs
    // ~1630 test pixels. The point of the case is the has-slack branch, not the
    // specific threshold.
    await _pumpBar(tester, const Size(2600, 900));

    expect(tester.takeException(), isNull);
    expect(
      _position(tester).maxScrollExtent,
      0,
      reason: 'a wide bar must not become scrollable',
    );
    // The pill group absorbs the slack, so the readouts stay pinned to the
    // right edge instead of drifting left.
    final barRect = tester.getRect(find.byType(StatusBar));
    final scrollerRect = tester.getRect(_pillScroller().first);
    // Inside the bar's own horizontal padding, not flush to the window edge:
    // what is being pinned is that the group starts at the LEADING edge and
    // grows rightwards, so the readouts keep the trailing edge.
    expect(
      scrollerRect.left - barRect.left,
      lessThanOrEqualTo(SkotiqTokens.spaceMd),
      reason: 'the pill group must start at the leading edge of the bar',
    );

    var rightMost = barRect.left;
    final texts = _lastReadout();
    for (var i = 0; i < texts.evaluate().length; i++) {
      final rect = tester.getRect(texts.at(i));
      if (rect.right > rightMost) rightMost = rect.right;
    }
    expect(
      rightMost,
      greaterThan(barRect.right - 40),
      reason: 'the trailing group is no longer right-aligned '
          '(right-most readout ends at $rightMost, bar ends at ${barRect.right})',
    );

    await _disposeBar(tester);
  });

  // At 900x760 the last visible pill is sliced mid-word ("Simulated Cam") with
  // the thermometer glyph painted straight against it and no separator, while
  // Mount / Guider / Focus are absent with nothing on screen saying they exist.
  // The 24 px fade is not a control — with a mouse there is nothing to click —
  // and it leaves no gap, so the cut reads as a rendering fault.
  testWidgets('an overflowing bar offers a reachable way to the rest',
      (tester) async {
    await _pumpBar(tester, const Size(900, 760));
    expect(_position(tester).maxScrollExtent, greaterThan(0));

    final affordance = find.bySemanticsLabel('More equipment status');
    expect(affordance, findsOneWidget,
        reason: 'a fade alone is not an affordance');

    // It sits clear of the scrolling group, so nothing is painted over a
    // half-visible pill.
    final scroller = tester.getRect(_pillScroller().first);
    expect(tester.getRect(affordance).left,
        greaterThanOrEqualTo(scroller.right - 0.5));

    // And it moves the group.
    final before = _position(tester).pixels;
    await tester.tap(affordance);
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, greaterThan(before));

    await _disposeBar(tester);
  });

  testWidgets('a bar with room offers no scroll affordance', (tester) async {
    await _pumpBar(tester, const Size(2600, 900));
    expect(_position(tester).maxScrollExtent, 0);
    expect(find.bySemanticsLabel('More equipment status'), findsNothing);

    await _disposeBar(tester);
  });
}
