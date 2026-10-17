// "Edit layout" must not offer to arrange a page the user cannot see.
//
// With nothing set up, Tonight shows the first-light checklist and its moon /
// weather / last-night column — none of which are arrangeable tiles. Swapping
// that for the five monitoring panels on Edit offers to arrange a set that is
// not on the page.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/dashboard_header_actions.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

Future<void> _pumpActions(WidgetTester tester, {required bool standby}) async {
  await pumpAppScreen(
    tester,
    DashboardHeaderActions(
      isEditing: false,
      canEdit: !standby,
      onToggleEdit: () {},
      onManageWidgets: () {},
      onResetLayout: () {},
    ),
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 100));
}

bool _editIsEnabled(WidgetTester tester) =>
    tester.widget<SkotiqButton>(find.byType(SkotiqButton)).onPressed !=
    null;

void main() {
  testWidgets('editing is refused while the checklist is showing',
      (tester) async {
    await _pumpActions(tester, standby: true);

    expect(_editIsEnabled(tester), isFalse);
    expect(
      find.byTooltip(
        'Nothing to arrange yet — the first-light checklist has no panels. '
        'Connect a device or load a sequence to arrange tonight’s panels.',
      ),
      findsOneWidget,
      reason: 'a control that refuses has to say why',
    );
  });

  testWidgets('editing is offered once the panels are on screen',
      (tester) async {
    await _pumpActions(tester, standby: false);

    expect(_editIsEnabled(tester), isTrue);
  });
}
