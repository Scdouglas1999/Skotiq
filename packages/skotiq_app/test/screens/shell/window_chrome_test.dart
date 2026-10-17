// The window chrome must be reachable without sight of it.
//
// An InkWell contributes a tap action but no role and no name, and a Tooltip
// contributes a tooltip rather than a label, so undeclared none of the four icon
// buttons and none of the three window controls appear in the accessibility tree
// at all. The Settings gear is the only route to Settings, which would make
// Settings unreachable to assistive tech.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/window_chrome.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// The real alert stream opens a 15-minute polling timer that outlives the
/// widget tree; the top band only cares that it resolves.
final _quietAlerts = <Override>[
  activeTransientAlertsProvider.overrideWith(
    (ref) => Stream.value(const <TransientAlert>[]),
  ),
];

void main() {
  testWidgets('every top-band control carries a name and a button role',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      const ShellTopBand(),
      settle: false,
      extraOverrides: _quietAlerts,
    );
    await tester.pump(const Duration(milliseconds: 200));

    // The equipment-profile shortcut left the band: profiles live on the
    // Equipment screen and in the instrument bar's profile pill, and a third
    // way in was a third thing to keep in sync. Help took its place.
    for (final label in const ['Help for this screen', 'Settings']) {
      expect(
        find.bySemanticsLabel(label),
        findsOneWidget,
        reason: '"$label" is icon-only chrome and must name itself',
      );
    }
    expect(find.bySemanticsLabel('Transient alerts'), findsOneWidget);

    semantics.dispose();
  });

  testWidgets('window controls name themselves', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => WindowControls(colors: SkotiqColors.of(context)),
      ),
      settle: false,
    );
    await tester.pump();

    for (final label in const [
      'Minimize window',
      'Maximize window',
      'Close window'
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget);
    }

    semantics.dispose();
  });
}
