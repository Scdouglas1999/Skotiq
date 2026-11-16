// Equipment > Profiles: the selected profile's editor beside the list. Save
// sits in the editor's head above the form, the form's fields keep to a
// readable width on a wide window, and the icon picker offers Lucide icons by
// the word a profile stores.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/router/equipment_route.dart';
import 'package:skotiq_app/screens/equipment/dialogs/profile_editor_dialog.dart';
import 'package:skotiq_app/screens/equipment/widgets/profile_glyph.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';
import 'package:skotiq_core/database.dart';

const _rig = EquipmentProfileModel(
  id: 1,
  name: 'Backyard rig',
  telescopeName: 'GSO 10" F4',
  // An emoji an older build stored.
  profileIcon: '\u{1F52D}',
);

Finder get _saveButton => find.widgetWithText(SkotiqButton, 'Save changes');

Future<void> _pumpPage(WidgetTester tester, {required double width}) async {
  final db = mockDatabase();
  addTearDown(db.close);
  await db.equipmentProfilesDao.createProfile(_rig.toCompanion());

  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sortedProfilesProvider.overrideWithValue(const [_rig]),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: ProfileEditorDialog(
            key: ValueKey<int>(1),
            profile: _rig,
            mode: ProfileEditorMode.profilePage,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The editor watches the device slots, whose providers hold database query
/// streams; closing them schedules a zero-length timer that has to run before
/// the test ends.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('Save is in the head above the form and says what is unsaved',
      (tester) async {
    await _pumpPage(tester, width: 1600);

    final save = tester.getTopLeft(_saveButton);
    final firstSection = tester.getTopLeft(find.text('Profile identity'));
    expect(save.dy, lessThan(firstSection.dy));
    expect(find.text('Saved'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'GSO 10" F4'),
      'GSO 10" F4 with coma corrector',
    );
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(tester.widget<SkotiqButton>(_saveButton).onPressed, isNotNull);

    await _close(tester);
  });

  testWidgets('fields keep to their width on a wide window', (tester) async {
    await _pumpPage(tester, width: 2400);

    final name = find.widgetWithText(TextField, 'Backyard rig');
    expect(tester.getSize(name).width,
        lessThanOrEqualTo(profileEditorFieldMaxWidth));

    await _close(tester);
  });

  testWidgets('the icon picker offers Lucide icons, and an emoji reads as none',
      (tester) async {
    await _pumpPage(tester, width: 1600);

    for (final glyph in profileGlyphs.values) {
      final option = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == '${glyph.name} icon',
      );
      expect(
        find.descendant(of: option, matching: find.byIcon(glyph.icon)),
        findsOneWidget,
        reason: glyph.name,
      );
    }
    // No emoji is offered or drawn.
    expect(find.text('\u{1F52D}'), findsNothing);

    final none = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Default icon',
      ),
    );
    expect(none.properties.selected, isTrue,
        reason: 'a stored word this build does not offer is no icon');

    await _close(tester);
  });

  test('a stored icon word maps to its glyph, anything else to the default',
      () {
    expect(profileIconFor('moon'), LucideIcons.moon);
    expect(profileIconFor('\u{1F52D}'), defaultProfileIcon);
    expect(profileIconFor(null), defaultProfileIcon);
  });

  test('an optical-train link opens the Profiles tab', () {
    expect(EquipmentTab.values, [EquipmentTab.devices, EquipmentTab.profiles]);
    expect(EquipmentTab.fromQuery('optical-train'), EquipmentTab.profiles);
    expect(EquipmentTab.fromQuery('profiles'), EquipmentTab.profiles);
  });
}
