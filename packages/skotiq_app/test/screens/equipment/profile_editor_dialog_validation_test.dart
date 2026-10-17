import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/dialogs/profile_editor_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

/// An EquipmentProfilesDao whose first [createProfile] throws, then succeeds —
/// used to prove the editor stays open and retryable after an async save
/// failure.
class _FlakyProfilesDao extends EquipmentProfilesDao {
  _FlakyProfilesDao(super.db);

  int createCalls = 0;

  @override
  Future<int> createProfile(EquipmentProfilesCompanion profile) {
    createCalls++;
    if (createCalls == 1) {
      throw Exception('simulated save failure');
    }
    return super.createProfile(profile);
  }
}

/// The Profile Name field is the first text field in the form.
Finder get _nameField => find.byType(TextField).first;
Finder get _saveButton => find.text('Save changes');

/// Locate an optics field by its hint plus its `mm` suffix, so the finder does
/// not depend on field ordering and does not collide with the Gain field, which
/// shares the `e.g., 100` hint.
///
/// Matched on [SkotiqTextField]'s own `hint`/`suffix`, not on the Material
/// `InputDecoration` underneath: the design-system field has never put its unit
/// in `decoration.suffixText` (it was a sibling `Text` in the well's Row, and
/// is now a `decoration.suffix` widget), so a `suffixText` predicate matched
/// nothing and `enterText` threw `Bad state: No element`.
Finder _millimetreFieldWithHint(String hint) => find.descendant(
      of: find.byWidgetPredicate(
        (widget) =>
            widget is SkotiqTextField &&
            widget.hint == hint &&
            widget.suffix == 'mm',
      ),
      matching: find.byType(TextField),
    );

Finder get _focalLengthField => _millimetreFieldWithHint('e.g., 550');
Finder get _apertureField => _millimetreFieldWithHint('e.g., 100');

void main() {
  /// Pump a launcher that opens [ProfileEditorDialog] as a real pushed route
  /// (so its `Navigator.pop(true)` on success works), and open it. Returns a
  /// getter for the dialog's eventual result.
  Future<bool? Function()> openEditor(
    WidgetTester tester, {
    required List<Override> overrides,
  }) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    bool? result;
    var completed = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The name field is checked against the existing profiles, so the
          // editor reads the profile list; stub its sources or the drift query
          // it opens outlives the test.
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
                  onPressed: () async {
                    result = await ProfileEditorDialog.show(context);
                    completed = true;
                  },
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
    expect(find.text('New profile'), findsOneWidget);

    return () => completed ? result : null;
  }

  testWidgets('blank name blocks the save: dialog stays open, no row written',
      (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);

    final resultOf = await openEditor(tester, overrides: [
      databaseProvider.overrideWithValue(db),
    ]);

    // Leave the name blank and try to save.
    await tester.tap(_saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Editor stays open, an inline/summary error is shown, and nothing was
    // persisted.
    expect(find.text('New profile'), findsOneWidget);
    expect(find.text('Profile name is required'), findsWidgets);
    expect(resultOf(), isNull);
    expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
  });

  testWidgets('valid input saves one row and closes with success',
      (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);

    final resultOf = await openEditor(tester, overrides: [
      databaseProvider.overrideWithValue(db),
    ]);

    await tester.enterText(_nameField, 'Test Rig');
    await tester.tap(_saveButton);
    await tester.pumpAndSettle();

    final rows = await db.equipmentProfilesDao.getAllProfiles();
    expect(rows.length, 1);
    expect(rows.single.name, 'Test Rig');
    expect(resultOf(), isTrue);
  });

  // Validating optics only against `<= 0` accepts a focal length of 999999999 mm
  // with an aperture of 0.0001 mm and shows `f/9999999990000.0` in the f/Ratio
  // readout. Focal length reaches the FITS FOCALLEN card and the plate-solve
  // field-of-view estimate.
  testWidgets('implausible optics block the save and blank the f/Ratio readout',
      (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);

    final resultOf = await openEditor(tester, overrides: [
      databaseProvider.overrideWithValue(db),
    ]);

    await tester.enterText(_nameField, 'Absurd Rig');
    await tester.enterText(_focalLengthField, '999999999');
    await tester.enterText(_apertureField, '0.0001');
    await tester.pump();

    // The derived readout must not report an impossible ratio as a fact.
    expect(find.textContaining('9999999990000'), findsNothing);
    expect(find.text(kReadoutUnknown), findsWidgets);

    await tester.tap(_saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('New profile'), findsOneWidget,
        reason: 'the editor must stay open on rejection');
    expect(resultOf(), isNull);
    expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
  });

  testWidgets('an impossible f-ratio from in-range fields blocks the save',
      (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);

    await openEditor(tester, overrides: [
      databaseProvider.overrideWithValue(db),
    ]);

    // Both numbers are individually inside their own bounds; only the ratio
    // they imply (f/20000) is impossible.
    await tester.enterText(_nameField, 'Impossible Ratio');
    await tester.enterText(_focalLengthField, '40000');
    await tester.enterText(_apertureField, '2');
    await tester.tap(_saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('New profile'), findsOneWidget);
    expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
  });

  testWidgets('a real long-focus rig still saves with its optics intact',
      (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);

    final resultOf = await openEditor(tester, overrides: [
      databaseProvider.overrideWithValue(db),
    ]);

    // C14 with a 2x barlow: 7800 mm at 355.6 mm is f/21.9 — real, and far past
    // what a naive bound would allow.
    await tester.enterText(_nameField, 'C14 + 2x');
    await tester.enterText(_focalLengthField, '7800');
    await tester.enterText(_apertureField, '355.6');
    await tester.pump();
    expect(find.text('f/21.9'), findsOneWidget);

    await tester.tap(_saveButton);
    await tester.pumpAndSettle();

    final rows = await db.equipmentProfilesDao.getAllProfiles();
    expect(rows.length, 1);
    expect(rows.single.focalLength, 7800);
    expect(rows.single.aperture, 355.6);
    expect(resultOf(), isTrue);
  });

  testWidgets('a double-tap on Save issues exactly one create', (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);

    await openEditor(tester, overrides: [
      databaseProvider.overrideWithValue(db),
    ]);

    await tester.enterText(_nameField, 'Once Only');
    // Two taps before the widget can rebuild — the in-flight guard must drop
    // the second.
    await tester.tap(_saveButton);
    await tester.tap(_saveButton);
    await tester.pumpAndSettle();

    final rows = await db.equipmentProfilesDao.getAllProfiles();
    expect(rows.length, 1);
  });

  testWidgets('an async save failure stays editable and retry succeeds',
      (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);
    final flakyDao = _FlakyProfilesDao(db);

    final resultOf = await openEditor(tester, overrides: [
      databaseProvider.overrideWithValue(db),
      equipmentProfilesDaoProvider.overrideWithValue(flakyDao),
    ]);

    await tester.enterText(_nameField, 'Retry Rig');

    // First attempt fails: editor stays open, nothing persisted.
    await tester.tap(_saveButton);
    await tester.pumpAndSettle();
    expect(find.text('New profile'), findsOneWidget);
    expect(resultOf(), isNull);
    expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);

    // Retry succeeds.
    await tester.tap(_saveButton);
    await tester.pumpAndSettle();
    expect(flakyDao.createCalls, 2);
    final rows = await db.equipmentProfilesDao.getAllProfiles();
    expect(rows.length, 1);
    expect(rows.single.name, 'Retry Rig');
    expect(resultOf(), isTrue);
  });
}
