import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Finds a [SkotiqIconButton] by its tooltip.
///
/// `find.byTooltip` matches a Material `Tooltip`; the sheet's icon button
/// carries its tooltip through `Semantics` and `SkotiqTooltip` instead, so
/// the Material finder misses it entirely.
Finder skotiqIconButton(String tooltip) => find.byWidgetPredicate(
      (widget) => widget is SkotiqIconButton && widget.tooltip == tooltip,
      description: 'SkotiqIconButton("$tooltip")',
    );

/// Asserts whether a device panel's action is available, wherever it lives.
///
/// An action that did not fit inline is a menu item, and a menu item's
/// availability is its `enabled` flag rather than a button's `onPressed`. The
/// menu is opened, read and dismissed so the caller can keep asserting in the
/// order the panel presents its actions.
Future<void> expectDeviceAction(
  WidgetTester tester,
  String label, {
  required bool enabled,
  String? reason,
}) async {
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  final inline = find.widgetWithText(SkotiqButton, label);
  if (inline.evaluate().isNotEmpty) {
    expect(
      tester.widget<SkotiqButton>(inline.first).onPressed,
      enabled ? isNotNull : isNull,
      reason: reason ?? label,
    );
    return;
  }

  await tester.tap(skotiqIconButton('More actions').first);
  await settle();
  final item = find.ancestor(
    of: find.text(label),
    matching: find.byType(PopupMenuItem<VoidCallback>),
  );
  expect(item, findsOneWidget, reason: 'no action named "$label"');
  expect(
    tester.widget<PopupMenuItem<VoidCallback>>(item).enabled,
    enabled,
    reason: reason ?? label,
  );
  Navigator.of(tester.element(item)).pop();
  await settle();
}

/// Presses a device panel's action by LABEL, wherever it currently lives.
///
/// A device panel keeps at most two actions inline and puts the rest behind
/// its `more-vertical` menu (06 §Equipment: the row must never wrap), and which
/// two are inline depends on how wide the panel's grid cell is. A test that
/// wants "Park" should not have to know which side of that line it fell on.
Future<void> tapDeviceAction(WidgetTester tester, String label) async {
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  final inline = find.widgetWithText(SkotiqButton, label);
  if (inline.evaluate().isNotEmpty) {
    await tester.tap(inline.first);
    await settle();
    return;
  }

  await tester.tap(skotiqIconButton('More actions').first);
  await settle();
  await tester.tap(find.text(label).last);
  await settle();
}
