// Validating optics only against `<= 0` accepts a focal length of 999999999 mm
// with an aperture of 0.0001 mm and renders f/9999999990000.00. Focal length is
// written to the FITS `FOCALLEN` card and drives plate-solve field-of-view
// estimation and arcsec/px image scale, so an implausible value silently
// corrupts astrometry for that rig.
//
// The Settings › Equipment Profiles inline editor is the third of the three
// surfaces that persist an optical train (the others being the equipment
// `ProfileEditorDialog` and `POST /api/profiles`); all three go through
// `ProfileValidator` / `OpticalTrainLimits`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/equipment_profiles_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

const _profile = EquipmentProfileModel(
  id: 7,
  name: 'Imaging rig',
  focalLength: 550,
  aperture: 100,
  isActive: true,
);

/// Records every attempted write so a test can assert that a rejected edit
/// never reaches the DAO.
class _RecordingProfilesNotifier extends EquipmentProfilesNotifier {
  final saved = <EquipmentProfileModel>[];

  @override
  Future<EquipmentProfilesState> build() => Future.value(
        const EquipmentProfilesState(
          profiles: [_profile],
          activeProfile: _profile,
        ),
      );

  @override
  Future<int> updateProfile(EquipmentProfileModel profile) async {
    saved.add(profile);
    return profile.id ?? 0;
  }
}

/// The editable field inside the [label]led field card.
Finder _fieldUnder(String label) => find.descendant(
      of: find
          .ancestor(of: find.text(label), matching: find.byType(Column))
          .first,
      matching: find.byType(TextField),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_RecordingProfilesNotifier> openEditor(WidgetTester tester) async {
    late _RecordingProfilesNotifier notifier;
    await pumpAppScreen(
      tester,
      const EquipmentProfilesScreen(),
      size: const Size(1400, 1200),
      settle: false,
      extraOverrides: [
        equipmentProfilesProvider.overrideWith(() {
          notifier = _RecordingProfilesNotifier();
          return notifier;
        }),
      ],
    );
    await tester.pump();
    await tester.pump();

    // Edit lives behind the profile's overflow menu.
    final overflow = find.byType(PopupMenuButton<String>);
    expect(overflow, findsWidgets);
    await tester.tap(overflow.last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    return notifier;
  }

  Future<void> save(WidgetTester tester) async {
    final saveButton = find.text('Save');
    expect(saveButton, findsOneWidget);
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('an implausible focal length never reaches the DAO',
      (tester) async {
    final notifier = await openEditor(tester);

    await tester.enterText(_fieldUnder('Focal Length'), '999999999');
    await tester.enterText(_fieldUnder('Aperture'), '0.0001');
    await save(tester);

    expect(notifier.saved, isEmpty,
        reason: 'a rejected edit must not be written');
    // Still in edit mode, so the user can fix the value.
    expect(find.text('Save'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'an impossible f-ratio from in-range fields never reaches the DAO',
      (tester) async {
    final notifier = await openEditor(tester);

    // Both numbers are individually inside their own bounds; only the ratio
    // they imply (f/20000) is impossible.
    await tester.enterText(_fieldUnder('Focal Length'), '40000');
    await tester.enterText(_fieldUnder('Aperture'), '2');
    await save(tester);

    expect(notifier.saved, isEmpty);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('a real rig is written through unchanged', (tester) async {
    final notifier = await openEditor(tester);

    // RASA 11: 620 mm at 279 mm is f/2.2.
    await tester.enterText(_fieldUnder('Focal Length'), '620');
    await tester.enterText(_fieldUnder('Aperture'), '279');
    await save(tester);

    expect(notifier.saved, hasLength(1));
    expect(notifier.saved.single.focalLength, 620);
    expect(notifier.saved.single.aperture, 279);
  });
}
