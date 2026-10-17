// The 48dp floor, per tappable component.
//
// The Android tap-target audit (`skotiq_app/test/screens/mobile_tap_target_
// test.dart`) measured the imaging "Guiding" strip pill at 26x22, the binning
// select at 176x24 and the planner "More" chip at 112x28. Only
// `SkotiqButton` and `SkotiqIconButton` were applying
// `SkotiqTouchTarget`; every other small control in the kit was shipping a
// POINTER size to a phone.
//
// The rule these pin is the one 03 section 3.3 states: 22 / 28 / 30 / 32 are
// desktop pointer sizes, and on a touch platform the INTERACTIVE box grows to
// 48 while the painted control keeps the size the sheet specifies.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Widget host(Widget child, {required TargetPlatform platform}) => MaterialApp(
    theme: SkotiqTheme.dark.copyWith(platform: platform),
    home: Scaffold(body: Center(child: child)),
  );

  /// Each case: the control, and the height it paints for a pointer.
  final cases = <String, (Widget, double)>{
    'SkotiqChip': (SkotiqChip(label: 'More', onTap: () {}), SkotiqChip.height),
    'SkotiqFilterChip': (
      SkotiqFilterChip(
        label: 'Filter: Ha',
        trailingIcon: LucideIcons.chevronDown,
        onTap: () {},
      ),
      SkotiqFilterChip.height,
    ),
    'SegmentedControl': (
      SegmentedControl(
        segments: const <String>['Nodes', 'Queue'],
        selectedIndex: 0,
        onSelected: (_) {},
      ),
      SegmentedControl.segmentHeight,
    ),
    'InstrumentPill': (
      InstrumentPill(value: 'Guiding', onTap: () {}),
      InstrumentPill.height,
    ),
    'SkotiqDropdown': (
      SkotiqDropdown(
        value: '1x1',
        items: const <String>['1x1', '2x2'],
        onChanged: (_) {},
      ),
      SkotiqTokens.inputHeight,
    ),
  };

  for (final entry in cases.entries) {
    final (control, pointerHeight) = entry.value;
    final finder = find.byWidget(control);

    testWidgets('${entry.key} clears 48dp on a touch platform', (tester) async {
      await tester.pumpWidget(host(control, platform: TargetPlatform.android));
      final box = tester.getSize(finder);
      // The strip pill measured 26x22: BOTH edges have to clear the floor.
      expect(
        box.height,
        greaterThanOrEqualTo(SkotiqTokens.minTouchTarget),
        reason: '${entry.key} is ${box.height}px tall to a finger',
      );
      expect(
        box.width,
        greaterThanOrEqualTo(SkotiqTokens.minTouchTarget),
        reason: '${entry.key} is ${box.width}px wide to a finger',
      );
    });

    testWidgets('${entry.key} keeps its pointer size on the desktop', (
      tester,
    ) async {
      await tester.pumpWidget(host(control, platform: TargetPlatform.linux));
      expect(
        tester.getSize(finder).height,
        pointerHeight,
        reason: 'growing the box on a desktop would re-flow every dense panel',
      );
    });
  }

  testWidgets('a chip that is not a control is left at its own size', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const SkotiqChip(label: 'Connected', tone: ChipTone.success),
        platform: TargetPlatform.android,
      ),
    );
    expect(
      tester.getSize(find.byType(SkotiqChip)).height,
      SkotiqChip.height,
      reason:
          'a status label is not a tap target, and padding it to 48 would '
          'space out every status row on a phone for nothing',
    );
  });
}
