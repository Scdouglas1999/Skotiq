// The profile editor shows and saves both binning axes: a 2x1
// profile from onboarding or an import, opened and saved for any other change,
// stays 2x1 instead of becoming 2x2.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/dialogs/profile_editor_dialog.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

Finder get _saveButton =>
    find.textContaining(RegExp(r'^(Save changes|Create profile)$'));

Future<EquipmentProfileModel> _seedProfile(SkotiqDatabase db) async {
  final dao = db.equipmentProfilesDao;
  final id = await dao.createProfile(
    const EquipmentProfilesCompanion(
      name: Value('Binned rig'),
      telescopeFocalLength: Value(550.0),
      telescopeAperture: Value(100.0),
      focalLength: Value(550.0),
      aperture: Value(100.0),
      focalRatio: Value(5.5),
      defaultBinX: Value(2),
      defaultBinY: Value(1),
    ),
  );
  final row = await dao.getProfileById(id);
  return row!.toModel();
}

Future<void> _openEditor(
  WidgetTester tester, {
  required List<Override> overrides,
  required EquipmentProfileModel? profile,
}) async {
  tester.view.physicalSize = const Size(1024, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // The editor checks the typed name against the existing profiles, so
        // it reads the profile list; stub its sources or the drift query it
        // opens outlives the test.
        activeProfileProvider.overrideWith((ref) => Stream.value(null)),
        allProfilesProvider.overrideWith((ref) => Stream.value(const [])),
        ...overrides,
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () =>
                    ProfileEditorDialog.show(context, profile: profile),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a 2x1 profile saved for another change stays 2x1',
      (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);
    final profile = await _seedProfile(db);
    expect((profile.defaultBinX, profile.defaultBinY), (2, 1));

    await _openEditor(
      tester,
      overrides: [databaseProvider.overrideWithValue(db)],
      profile: profile,
    );
    await tester.enterText(find.byType(TextField).first, 'Binned rig 2');
    await tester.pump();
    await tester.tap(_saveButton);
    await tester.pumpAndSettle();

    final saved = await db.equipmentProfilesDao.getProfileById(profile.id!);
    expect(saved!.name, 'Binned rig 2');
    expect((saved.defaultBinX, saved.defaultBinY), (2, 1));
  });
}
