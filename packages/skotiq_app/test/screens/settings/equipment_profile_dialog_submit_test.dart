// The Create/Duplicate profile dialogs are a single pre-filled, auto-focused
// text field, so Return submits the dialog exactly as clicking its primary
// action does. Unwired, the focused field swallows the key and the only way to
// commit is to leave the keyboard and click.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/equipment_profiles_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

const _rig = EquipmentProfileModel(
  id: 1,
  name: 'Adv Rig One',
  isActive: true,
);

class _RecordingProfilesNotifier extends EquipmentProfilesNotifier {
  _RecordingProfilesNotifier(this.profiles);

  final List<EquipmentProfileModel> profiles;
  final duplicated = <String>[];
  final created = <String>[];

  @override
  Future<EquipmentProfilesState> build() => Future.value(
        EquipmentProfilesState(
          profiles: profiles,
          activeProfile: profiles.first,
        ),
      );

  @override
  Future<int> duplicateProfile(int sourceId, String newName) async {
    duplicated.add(newName);
    return 99;
  }

  @override
  Future<int> createProfile({
    required String name,
    String? description,
    bool setAsActive = false,
  }) async {
    created.add(name);
    return 98;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_RecordingProfilesNotifier> openScreen(WidgetTester tester) async {
    late _RecordingProfilesNotifier notifier;
    await pumpAppScreen(
      tester,
      const EquipmentProfilesScreen(),
      size: const Size(1400, 1000),
      settle: false,
      extraOverrides: [
        equipmentProfilesProvider.overrideWith(() {
          notifier = _RecordingProfilesNotifier(const [_rig]);
          return notifier;
        }),
      ],
    );
    await tester.pump();
    await tester.pump();
    return notifier;
  }

  Finder dialogField() => find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );

  testWidgets('Return in the Duplicate dialog creates the copy',
      (tester) async {
    final notifier = await openScreen(tester);

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    expect(find.text('Duplicate Profile'), findsOneWidget);

    // testTextInput.receiveAction is what a hardware Return reaches the focused
    // field as; no tap on the action button anywhere in this test.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(notifier.duplicated, ['Adv Rig One (Copy)']);
    expect(find.text('Duplicate Profile'), findsNothing,
        reason: 'submitting must also close the dialog');
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('Return in the Create dialog creates the profile',
      (tester) async {
    final notifier = await openScreen(tester);

    await tester.tap(find.text('New profile'));
    await tester.pumpAndSettle();
    expect(find.text('Create New Profile'), findsOneWidget);

    await tester.enterText(dialogField().first, 'Widefield');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(notifier.created, ['Widefield']);
    expect(find.text('Create New Profile'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('Return with an empty name is refused, not silently accepted',
      (tester) async {
    final notifier = await openScreen(tester);

    await tester.tap(find.text('New profile'));
    await tester.pumpAndSettle();
    await tester.enterText(dialogField().first, '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(notifier.created, isEmpty);
    expect(find.text('Enter a profile name.'), findsOneWidget);
  });
}
