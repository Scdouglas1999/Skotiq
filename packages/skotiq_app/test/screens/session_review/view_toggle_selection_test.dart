// On Session Review the SELECTED tab must not read as the dim one, and the
// tab strip must say which view is live to assistive tech as well as in pixels.
//
// This used to guard a pair of pill chips under the header. The Observatory
// overhaul (05 §4) allows ONE tab style — the underline strip in the page
// header — so the pills are gone and the assertions moved onto `AdaptiveTabBar`.
// The DEFECTS the old test pinned are still the ones worth pinning:
//
//  * the app theme's `hoverColor` is opaque, and the pointer rests on whichever
//    tab was just clicked, so a selection painted as a FILL was repainted grey
//    by its own hover and the open tab looked disabled. The underline style has
//    no fill to erase, and the selected label must stay `textPrimary` with the
//    pointer parked on it;
//  * a tab that exposes no selected state leaves neither the pixels nor the
//    tree saying which view is live.

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsFlag;
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The tab strip as Session Review builds it: Narrative, then Workbench.
Widget _tabs(int selected, ValueChanged<int> onSelected) {
  return MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: AdaptiveTabBar(
        tabs: const [
          AdaptiveTab(label: 'Narrative', icon: SkotiqIcons.image),
          AdaptiveTab(label: 'Workbench', icon: SkotiqIcons.sliders),
        ],
        selectedIndex: selected,
        onSelected: onSelected,
      ),
    ),
  );
}

/// The colour the label [text] is painted in.
Color? _labelColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.color;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('hovering the selected tab cannot repaint it as unselected', (
    tester,
  ) async {
    await tester.pumpWidget(_tabs(1, (_) {}));
    await tester.pump();

    expect(_labelColor(tester, 'Workbench'), SkotiqColors.dark.textPrimary);

    // Park the pointer on the selected tab, exactly as a click leaves it.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Workbench')));
    await tester.pumpAndSettle();

    expect(
      _labelColor(tester, 'Workbench'),
      SkotiqColors.dark.textPrimary,
      reason: 'the hover must not dim the tab that is open',
    );
    expect(
      _labelColor(tester, 'Narrative'),
      isNot(SkotiqColors.dark.textPrimary),
      reason: 'the unselected tab must stay quieter than the selected one',
    );
  });

  testWidgets('each tab announces whether it is selected', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_tabs(1, (_) {}));
    await tester.pump();

    final workbench = tester.getSemantics(find.text('Workbench'));
    expect(workbench.hasFlag(SemanticsFlag.hasSelectedState), isTrue);
    expect(workbench.hasFlag(SemanticsFlag.isSelected), isTrue);

    final narrative = tester.getSemantics(find.text('Narrative'));
    expect(narrative.hasFlag(SemanticsFlag.hasSelectedState), isTrue);
    expect(narrative.hasFlag(SemanticsFlag.isSelected), isFalse);
    handle.dispose();
  });

  testWidgets('tapping an unselected tab still switches view', (tester) async {
    int? picked;
    await tester.pumpWidget(_tabs(1, (index) => picked = index));
    await tester.tap(find.text('Narrative'));
    await tester.pump();
    expect(picked, 0);
  });
}
