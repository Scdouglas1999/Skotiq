// "Edit layout" must not be silently inert in the first-run state: with nothing
// set up and Tonight showing the first-light checklist, clicking it changes
// nothing, so the control has to say why.
//
// A `Semantics(hint:)` cannot carry that. It passes a widget test while the
// LIVE AT-SPI probe of the node reads
//   button: 'Edit Dashboard\nEdit Dashboard'  desc=''
//   states=['sensitive','showing','visible']
// — enabled, undescribed, byte-identical to the genuinely-enabled button —
// because a descendant re-publishes `isEnabled` and the Linux bridge does not
// carry `hint`.
//
// So these tests pin the counter-checks: the node must be the ONLY one for the
// control (no doubled label), it must not be enabled, and the reason must be in
// the accessible NAME, which the bridge demonstrably exports.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/dashboard_header_actions.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/pump_app_screen.dart';

Future<HarnessHandle> _pumpEditButton(
  WidgetTester tester, {
  required bool standby,
  VoidCallback? onToggleEdit,
}) {
  return pumpAppScreen(
    tester,
    DashboardHeaderActions(
      isEditing: false,
      canEdit: !standby,
      onToggleEdit: onToggleEdit ?? () {},
      onManageWidgets: () {},
      onResetLayout: () {},
    ),
    settle: false,
  );
}

void main() {
  testWidgets('in standby the control is disabled and says why', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpEditButton(tester, standby: true);
    await tester.pump(const Duration(milliseconds: 200));

    final node = tester.getSemantics(find.text('Edit layout'));

    expect(node.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(
      node.hasFlag(SemanticsFlag.isEnabled),
      isFalse,
      reason: 'a control that refuses every click must say it is disabled',
    );
    // The counter-check the live probe failed: the reason has to be in the
    // NAME, because the Linux bridge dropped the hint entirely.
    expect(
      node.label,
      contains('unavailable'),
      reason: 'the refusal must survive a bridge that exports only the name',
    );
    expect(node.label, contains('Nothing to arrange yet'));
    // And the name must not be the doubled 'Edit layout\nEdit layout'
    // the probe printed — that doubling is the signature of a descendant node
    // still publishing itself underneath the wrapper.
    expect(node.label, isNot(contains('\n')));
    expect(standbyEditRefusalReason, contains('Connect a device'));

    semantics.dispose();
  });

  testWidgets('a click on the refusing control states the reason', (
    tester,
  ) async {
    var toggles = 0;
    final harness = await _pumpEditButton(
      tester,
      standby: true,
      onToggleEdit: () => toggles++,
    );
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Edit layout'), warnIfMissed: false);
    await tester.pump();

    expect(toggles, 0, reason: 'it must still refuse');
    final notifications = harness.container.read(uiNotificationProvider);
    expect(notifications, hasLength(1));
    expect(notifications.single.message, standbyEditRefusalReason);
  });

  testWidgets('with a live dashboard it is an ordinary enabled button', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var toggles = 0;
    final harness = await _pumpEditButton(
      tester,
      standby: false,
      onToggleEdit: () => toggles++,
    );
    await tester.pump(const Duration(milliseconds: 200));

    final node = tester.getSemantics(find.text('Edit layout'));
    expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);
    expect(
      node.label,
      isNot(contains('unavailable')),
      reason: 'the enabled and disabled names must be distinguishable',
    );

    await tester.tap(find.text('Edit layout'));
    await tester.pump();
    expect(toggles, 1);
    expect(harness.container.read(uiNotificationProvider), isEmpty);

    semantics.dispose();
  });
}
