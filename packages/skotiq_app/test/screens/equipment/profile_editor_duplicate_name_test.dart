// Two profiles must not be able to share a name.
//
// Live finding: the New Profile dialog rejects an empty name but accepted one
// byte-identical to an existing profile. The sidebar then showed two entries
// distinguishable only by their subtitle, while the screen header, the status
// bar and — worst — the delete confirmation ('Delete "My First Rig"?') quote
// nothing but the shared name.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/dialogs/profile_editor_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

Finder get _nameField => find.byType(TextField).first;
Finder get _saveButton => find.text('Save changes');

const _existing = EquipmentProfileModel(
  id: 1,
  name: 'My First Rig',
  telescopeName: 'Sky-Watcher Esprit 100ED',
);

Future<SkotiqDatabase> _openEditor(
  WidgetTester tester, {
  EquipmentProfileModel? editing,
}) async {
  final db = mockDatabase();
  addTearDown(db.close);
  if (editing != null) {
    // The row has to exist for the editor's update path to write it; the
    // provider override below is only what the sidebar would be showing.
    await db.equipmentProfilesDao.createProfile(editing.toCompanion());
  }
  tester.view.physicalSize = const Size(1024, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sortedProfilesProvider.overrideWithValue(const [_existing]),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () =>
                    ProfileEditorDialog.show(context, profile: editing),
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
  return db;
}

void main() {
  testWidgets('a name another profile already carries is refused',
      (tester) async {
    final db = await _openEditor(tester);

    await tester.enterText(_nameField, 'My First Rig');
    await tester.tap(_saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('Another profile is already called "My First Rig"'),
      findsWidgets,
    );
    expect(
      await db.equipmentProfilesDao.getAllProfiles(),
      isEmpty,
      reason:
          'a second "My First Rig" makes every destructive prompt ambiguous',
    );
  });

  testWidgets('the check ignores case and surrounding whitespace',
      (tester) async {
    final db = await _openEditor(tester);

    await tester.enterText(_nameField, '  my first rig ');
    await tester.tap(_saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(await db.equipmentProfilesDao.getAllProfiles(), isEmpty);
  });

  testWidgets('a genuinely new name still saves', (tester) async {
    final db = await _openEditor(tester);

    await tester.enterText(_nameField, 'Travel Rig');
    await tester.tap(_saveButton);
    await tester.pumpAndSettle();

    final rows = await db.equipmentProfilesDao.getAllProfiles();
    expect(rows.single.name, 'Travel Rig');
  });

  testWidgets('re-saving a profile under its own name is not a collision',
      (tester) async {
    await _openEditor(tester, editing: _existing);

    await tester.tap(_saveButton);
    await tester.pumpAndSettle();

    expect(find.textContaining('already called'), findsNothing);
    // The editor closed on a successful save rather than reporting that the
    // profile collides with itself.
    expect(_saveButton, findsNothing);
  });
}
