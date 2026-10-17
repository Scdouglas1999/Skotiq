// Glance mode must not read as a dead toggle.
//
// On an idle dashboard the button lights up blue, its icon flips to an open
// eye, the tree flips `button: Glance mode [off]` -> `[ON]` — and nothing else
// on the page changes, because what it re-sizes is the LIVE session readouts,
// which an idle dashboard does not show. A control has to say what it did.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/glance_mode_toggle.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

void main() {
  testWidgets('toggling acknowledges what changed', (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) =>
            GlanceModeToggle(colors: SkotiqColors.of(context)),
      ),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(GlanceModeToggle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('Glance mode on — session readouts use the large type.'),
      findsOneWidget,
      reason: 'nothing else on an idle dashboard changes, so the toggle has to '
          'say so itself',
    );
  });

  testWidgets('the tooltip names the effect, not the button state',
      (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) =>
            GlanceModeToggle(colors: SkotiqColors.of(context)),
      ),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byTooltip(
        'Glance mode — enlarge the session readouts to read across a room',
      ),
      findsOneWidget,
    );
  });
}
