// The Equipment > Profiles tab must use the width it occupies, and a click on
// a profile must populate the pane beside the list.
//
// Live finding (owner, 1920x1080): "the profiles sub tab seems completely
// useless overall, most of the screen is blank negative space that doesn't fill
// with anything. Rather, if you click a profile it should populate in the
// center box of the profiles sub tab so you can make changes and whatnot."
//
// The tab body WAS `Align(topLeft, SizedBox(width: 360, ProfileSidebar))` — the
// list and nothing else, leaving ~1340 of 1920 px of bare background with
// nothing to populate. Selection was never broken; there was no pane.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/dialogs/profile_editor_dialog.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_app/screens/equipment/widgets/profile_sidebar.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

/// The owner's laptop. The defect is a function of how much room the tab has,
/// so the width is the point of the test.
const Size _ownerWindow = Size(1920, 1080);

Future<void> _drainFrames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _openProfilesTab(WidgetTester tester) async {
  await tester.tap(find.text('Profiles'));
  await _drainFrames(tester);
}

void main() {
  testWidgets('the Profiles tab fills its width with the selected profile',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const EquipmentScreen(),
      size: _ownerWindow,
      settle: false,
    );

    final dao = handle.container.read(equipmentProfilesDaoProvider);
    await dao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Redcat 51'),
    );
    await _drainFrames(tester);
    await _openProfilesTab(tester);

    // The pane exists at all — this is what "blank negative space" was.
    final editor = find.byType(ProfileEditorDialog);
    expect(editor, findsOneWidget,
        reason: 'the selected profile must populate the pane beside the list');

    final listRect = tester.getRect(find.byType(ProfileSidebar));
    final editorRect = tester.getRect(editor);

    // It takes the room the list does not, rather than leaving it empty. The
    // old layout left everything right of the list unpainted; the assertion is
    // that the gap between the list's right edge and the pane's is small and
    // that the pane runs to the end of the tab body.
    expect(editorRect.left, closeTo(listRect.right, 1.0));
    expect(
      editorRect.width,
      greaterThan(_ownerWindow.width / 2),
      reason: 'the pane should hold the majority of a 1920 px window, not a '
          'sliver beside a 360 px list; got $editorRect',
    );
  });

  testWidgets('clicking a profile populates the pane with that profile',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const EquipmentScreen(),
      size: _ownerWindow,
      settle: false,
    );

    final dao = handle.container.read(equipmentProfilesDaoProvider);
    await dao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Redcat 51'),
    );
    await dao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Esprit 100'),
    );
    await _drainFrames(tester);
    await _openProfilesTab(tester);

    // The editor is keyed on the profile id, so which profile the pane holds
    // is read off the key rather than off copy that appears in both columns.
    ValueKey<int?> paneKey() =>
        tester.widget<ProfileEditorDialog>(find.byType(ProfileEditorDialog)).key
            as ValueKey<int?>;

    final firstPane = paneKey();

    await tester.tap(find.text('Esprit 100').last);
    // The card carries an onDoubleTap, whose recognizer holds the gesture
    // arena for 300 ms; pumping frames alone does not deliver the tap.
    await tester.pump(const Duration(milliseconds: 400));
    await _drainFrames(tester);

    expect(paneKey(), isNot(firstPane),
        reason: 'selecting the other profile must swap the pane');
    expect(
      tester
          .widget<ProfileEditorDialog>(find.byType(ProfileEditorDialog))
          .profile!
          .name,
      'Esprit 100',
    );
  });

  testWidgets('with no profiles the tab is one full-width invitation',
      (tester) async {
    await pumpAppScreen(
      tester,
      const EquipmentScreen(),
      size: _ownerWindow,
      settle: false,
    );
    await _drainFrames(tester);
    await _openProfilesTab(tester);

    expect(find.byType(ProfileEditorDialog), findsNothing);

    // Exactly ONE invitation. Splitting the tab here would put the list's
    // empty state and a pane's empty state side by side, both saying there are
    // no profiles and both offering to make one.
    expect(find.text('No profiles yet'), findsOneWidget);
    expect(find.textContaining('A profile saves which devices'), findsOneWidget,
        reason: 'an empty state must say what the thing is for');
    expect(
      tester.getRect(find.byType(ProfileSidebar)).width,
      greaterThan(_ownerWindow.width / 2),
      reason: 'with nothing to inspect the list takes the width rather than '
          'sitting in a 360 px column beside dead space',
    );
  });

  testWidgets('below the two-pane width the tab stays a single column',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const EquipmentScreen(),
      // Wide enough for the desktop screen, too narrow to seat the list and
      // the editor's 120 px labels plus their controls side by side.
      size: const Size(820, 900),
      settle: false,
    );

    final dao = handle.container.read(equipmentProfilesDaoProvider);
    await dao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Redcat 51'),
    );
    await _drainFrames(tester);
    await _openProfilesTab(tester);

    expect(find.byType(ProfileSidebar), findsOneWidget);
    expect(find.byType(ProfileEditorDialog), findsNothing,
        reason: 'a cramped two-pane split is worse than the list alone');
    expect(tester.takeException(), isNull);
  });
}
