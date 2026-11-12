// The Profiles page keeps the selected profile's editor open while the
// startup profile is changed from the list's menu. The editor's Default
// switch has to follow that change, and saving an unrelated edit must not
// move the startup star back.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/dialogs/profile_editor_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

const _rig = EquipmentProfileModel(
  id: 1,
  name: 'My First Rig',
  telescopeName: 'Sky-Watcher Esprit 100ED',
  isDefault: true,
);
const _copy = EquipmentProfileModel(
  id: 2,
  name: 'My First Rig (Copy)',
  telescopeName: 'Sky-Watcher Esprit 100ED',
);

Finder get _saveButton => find.widgetWithText(SkotiqButton, 'Save changes');

bool _saveEnabled(WidgetTester tester) =>
    tester.widget<SkotiqButton>(_saveButton).onPressed != null;

bool _defaultSwitchOn(WidgetTester tester) => tester
    .widget<SkotiqSwitchRow>(
      find.widgetWithText(SkotiqSwitchRow, 'Default profile'),
    )
    .value;

/// The editor watches the device slots, whose providers hold database query
/// streams; closing them schedules a zero-length timer that has to run before
/// the test ends.
Future<void> _closeEditor(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('the Default switch follows a startup change made elsewhere',
      (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);
    final dao = db.equipmentProfilesDao;
    await dao.createProfile(_rig.toCompanion());
    await dao.createProfile(_copy.toCompanion());
    await dao.setDefaultProfile(1, makeActive: true);

    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final shown = ValueNotifier<EquipmentProfileModel>(_rig);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sortedProfilesProvider.overrideWithValue(const [_rig, _copy]),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: ValueListenableBuilder<EquipmentProfileModel>(
              valueListenable: shown,
              builder: (context, profile, _) => ProfileEditorDialog(
                key: const ValueKey<int>(1),
                profile: profile,
                mode: ProfileEditorMode.profilePage,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_defaultSwitchOn(tester), isTrue);
    expect(_saveEnabled(tester), isFalse, reason: 'nothing was edited');

    // "Start up with this profile" on the copy, from the list's menu.
    await dao.setDefaultProfile(2, makeActive: true);
    shown.value = _rig.copyWith(isDefault: false);
    await tester.pumpAndSettle();

    expect(_defaultSwitchOn(tester), isFalse);
    expect(_saveEnabled(tester), isFalse);

    // An unrelated edit, saved.
    await tester.enterText(
      find.widgetWithText(TextField, 'Sky-Watcher Esprit 100ED'),
      'Esprit 100',
    );
    await tester.pump();
    expect(_saveEnabled(tester), isTrue);
    await tester.tap(_saveButton);
    await tester.pumpAndSettle();

    expect((await dao.getProfileById(1))!.isDefault, isFalse);
    expect((await dao.getProfileById(2))!.isDefault, isTrue);

    await _closeEditor(tester);
  });
}
