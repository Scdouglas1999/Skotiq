// Live finding: on the pushed Mosaic projects screen the "< Back" affordance
// only responded on the chevron. The word "Back" was a plain Text sitting
// OUTSIDE the IconButton, so a press on the part that reads as the control did
// nothing — measured on the running app: clicking the label left "Multi-panel
// mosaics" on screen, clicking the chevron 28 px to its left popped the screen.
//
// The Observatory overhaul folded that full-width row into a header action
// (04-shell §4 gives this screen ONE header, and the row was a second one), so
// the affordance is now a single SkotiqIconButton whose label IS its
// tooltip. The split-target defect cannot recur by construction; what still has
// to hold is that the control carries the button role, names where it goes, and
// actually leaves. Those are what this file asserts.
//
// Also pinned here: the empty state used to send the operator to Framing or the
// Planetarium while "New mosaic" sat in this screen's own header.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_project_controller.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_projects_list_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _pushedList({List<MosaicProject> projects = const []}) => ProviderScope(
      overrides: [
        mosaicProjectsListProvider.overrideWith((ref) async => projects),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const MosaicProjectsListScreen(),
                  ),
                ),
                child: const Text('open list'),
              ),
            ),
          ),
        ),
      ),
    );

/// The header's back control: the one icon button whose tooltip says "Back".
final Finder _backAction = find.byWidgetPredicate(
  (widget) => widget is SkotiqIconButton && widget.tooltip.startsWith('Back'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The row used to be a bare InkWell: it published a tap action but no button
  // role, so a screen reader announced "Back" as static text with nothing to
  // say it could be activated.
  testWidgets('the back action announces itself as a button', (tester) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(_pushedList());
    await tester.tap(find.text('open list'));
    await tester.pumpAndSettle();

    final data = tester.getSemantics(_backAction).getSemanticsData();
    expect(
      data.hasFlag(SemanticsFlag.isButton),
      isTrue,
      reason: 'the back affordance must carry the button role',
    );
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue);
    expect(
      data.label,
      contains('Back'),
      reason: 'an icon-only control is named by its tooltip or it is unnamed',
    );

    semantics.dispose();
  });

  testWidgets('pressing the back action leaves the screen', (tester) async {
    await tester.pumpWidget(_pushedList());
    await tester.tap(find.text('open list'));
    await tester.pumpAndSettle();

    expect(find.text('Mosaic projects'), findsOneWidget);

    await tester.tap(_backAction);
    await tester.pumpAndSettle();

    expect(
      find.text('Mosaic projects'),
      findsNothing,
      reason: 'the back action pops the pushed route',
    );
    expect(find.text('open list'), findsOneWidget);
  });

  testWidgets('the empty state points at the action on this screen',
      (tester) async {
    await tester.pumpWidget(_pushedList());
    await tester.tap(find.text('open list'));
    await tester.pumpAndSettle();

    expect(find.text('No mosaic projects yet'), findsOneWidget);
    expect(
      find.widgetWithText(SkotiqButton, 'New mosaic'),
      findsNWidgets(2),
      reason: 'the header action plus one in the empty state, where an '
          'operator with nothing on screen is actually looking',
    );
  });
}
