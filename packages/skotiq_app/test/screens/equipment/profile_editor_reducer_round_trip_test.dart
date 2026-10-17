// The profile editor must not destroy the reducer.
//
// A profile carries its optical train as a PAIR — `telescopeFocalLength` is the
// OTA's native focal length, `focalLength` is what the rig actually images at
// (post reducer/barlow) and is the value that reaches the FITS FOCALLEN card,
// the plate-solve scale hint, the framing FOV and the guider px->arcsec
// conversion. An editor with no reducer field, seeding one Focal Length box from
// the telescope column and writing that same number back into BOTH on save,
// turns "Save changes" with zero edits on a 0.80x-reduced profile into
// 440.0 mm / f/4.4 rewritten as 550.0 mm / f/5.5 — a silent 25% image-scale
// error.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/dialogs/profile_editor_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

Finder get _saveButton => find.text('Save changes');

/// Locate an optics field by hint + suffix so the finder does not depend on
/// field ordering (mirrors profile_editor_dialog_validation_test.dart), on
/// [SkotiqTextField]'s own properties rather than the Material
/// `InputDecoration` — the design-system field has never set `suffixText`.
Finder _fieldWithHintAndSuffix(String hint, String suffix) => find.descendant(
      of: find.byWidgetPredicate(
        (widget) =>
            widget is SkotiqTextField &&
            widget.hint == hint &&
            widget.suffix == suffix,
      ),
      matching: find.byType(TextField),
    );

Finder get _focalLengthField => _fieldWithHintAndSuffix('e.g., 550', 'mm');
Finder get _reducerField => _fieldWithHintAndSuffix('1 (none)', '×');
Finder get _nameField => find.byType(TextField).first;

/// The Sky-Watcher Esprit 100ED + 0.80x reducer profile the first-run wizard
/// produces: native 550 mm, effective 440 mm at f/4.4.
Future<EquipmentProfileModel> _seedReducedProfile(
  SkotiqDatabase db,
) async {
  final dao = db.equipmentProfilesDao;
  final id = await dao.createProfile(
    const EquipmentProfilesCompanion(
      name: Value('My First Rig'),
      telescopeName: Value('Sky-Watcher Esprit 100ED'),
      telescopeFocalLength: Value(550.0),
      telescopeAperture: Value(100.0),
      focalLength: Value(440.0),
      aperture: Value(100.0),
      focalRatio: Value(4.4),
    ),
  );
  final row = await dao.getProfileById(id);
  return EquipmentProfileModel.fromDatabase(row!);
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
  testWidgets(
      'opening a reducer-equipped profile and saving with no edits leaves the '
      'stored optics untouched', (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);
    final profile = await _seedReducedProfile(db);

    await _openEditor(
      tester,
      overrides: [databaseProvider.overrideWithValue(db)],
      profile: profile,
    );

    // The editor must be able to REPRESENT the reducer, otherwise the number it
    // shows and the number it saves cannot both be right.
    expect(_reducerField, findsOneWidget);
    expect(
      tester.widget<TextField>(_reducerField).controller!.text,
      '0.8',
      reason: 'the 0.80x reducer is the ratio the two stored columns encode',
    );
    expect(
      tester.widget<TextField>(_focalLengthField).controller!.text,
      '550.0',
      reason: 'the Focal Length box holds the OTA native focal length',
    );
    // The derived readout must describe the train the profile stores (f/4.4),
    // not the un-reduced OTA (f/5.5).
    expect(find.text('f/4.4'), findsOneWidget);
    expect(find.text('f/5.5'), findsNothing);

    await tester.tap(_saveButton);
    await tester.pumpAndSettle();

    final saved = await db.equipmentProfilesDao.getProfileById(profile.id!);
    expect(saved!.focalLength, 440.0);
    expect(saved.focalRatio, closeTo(4.4, 1e-9));
    expect(saved.telescopeFocalLength, 550.0);
    expect(saved.aperture, 100.0);
  });

  testWidgets(
      'a reducer typed into the editor is folded into the stored '
      'focal length', (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);

    await _openEditor(
      tester,
      overrides: [databaseProvider.overrideWithValue(db)],
      profile: null,
    );

    await tester.enterText(_nameField, 'Esprit + reducer');
    await tester.enterText(_focalLengthField, '550');
    await tester.enterText(_reducerField, '0.8');
    await tester.enterText(
      _fieldWithHintAndSuffix('e.g., 100', 'mm'),
      '100',
    );
    await tester.pump();

    expect(find.text('f/4.4'), findsOneWidget);
    expect(find.text('440 mm'), findsOneWidget,
        reason: 'the effective focal length is what gets stored');

    await tester.tap(_saveButton);
    await tester.pumpAndSettle();

    final rows = await db.equipmentProfilesDao.getAllProfiles();
    expect(rows.length, 1);
    expect(rows.single.focalLength, 440.0);
    expect(rows.single.telescopeFocalLength, 550.0);
    expect(rows.single.focalRatio, closeTo(4.4, 1e-9));
  });

  testWidgets(
      'a barlow that pushes the train past the f-ratio ceiling is '
      'rejected rather than persisted', (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);

    await _openEditor(
      tester,
      overrides: [databaseProvider.overrideWithValue(db)],
      profile: null,
    );

    // 40000 mm at 200 mm is f/200 — just inside the ceiling. A 2x barlow puts
    // the train at f/400, which is not a real system.
    await tester.enterText(_nameField, 'Impossible Barlow');
    await tester.enterText(_focalLengthField, '40000');
    await tester.enterText(_reducerField, '2');
    await tester.enterText(_fieldWithHintAndSuffix('e.g., 100', 'mm'), '200');
    await tester.tap(_saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('New profile'), findsOneWidget);
    expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
  });
}
