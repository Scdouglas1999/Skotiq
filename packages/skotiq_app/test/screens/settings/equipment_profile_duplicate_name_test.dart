// Settings › Equipment Profiles › Duplicate must not offer a fixed
// '<name> (Copy)' and accept it unchecked: duplicating the same profile twice
// then writes two rows with byte-identical names, and since the list, the
// status-bar profile chip and every profile picker show only the name, an
// operator with one of the twins active cannot tell which rig is loaded.
// Duplicate uses Import's '(n)' suffix rule and refuses a name already in
// use.

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

const _firstCopy = EquipmentProfileModel(
  id: 2,
  name: 'Adv Rig One (Copy)',
);

class _RecordingProfilesNotifier extends EquipmentProfilesNotifier {
  _RecordingProfilesNotifier(this.profiles);

  final List<EquipmentProfileModel> profiles;
  final duplicated = <String>[];

  @override
  Future<EquipmentProfilesState> build() => Future.value(
        EquipmentProfilesState(
            profiles: profiles, activeProfile: profiles.first),
      );

  @override
  Future<int> duplicateProfile(int sourceId, String newName) async {
    duplicated.add(newName);
    return 99;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('uniqueProfileName', () {
    test('keeps a free name and suffixes a taken one, as import does', () {
      expect(uniqueProfileName('Rig (Copy)', const []), 'Rig (Copy)');
      expect(
        uniqueProfileName('Rig (Copy)', const ['Rig (Copy)']),
        'Rig (Copy) (1)',
      );
      expect(
        uniqueProfileName('Rig (Copy)', const ['Rig (Copy)', 'Rig (Copy) (1)']),
        'Rig (Copy) (2)',
      );
    });

    test('collision is judged case- and whitespace-insensitively', () {
      // Matches the equipment editor's gate: ' rig (COPY) ' and 'Rig (Copy)'
      // are the same row to anyone reading the sidebar.
      expect(
        uniqueProfileName('Rig (Copy)', const [' rig (COPY) ']),
        'Rig (Copy) (1)',
      );
    });
  });

  Future<_RecordingProfilesNotifier> openDuplicateDialog(
    WidgetTester tester,
    List<EquipmentProfileModel> profiles,
  ) async {
    late _RecordingProfilesNotifier notifier;
    await pumpAppScreen(
      tester,
      const EquipmentProfilesScreen(),
      size: const Size(1400, 1000),
      settle: false,
      extraOverrides: [
        equipmentProfilesProvider.overrideWith(() {
          notifier = _RecordingProfilesNotifier(profiles);
          return notifier;
        }),
      ],
    );
    await tester.pump();
    await tester.pump();

    final overflow = find.byType(PopupMenuButton<String>);
    expect(overflow, findsWidgets);
    await tester.tap(overflow.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    expect(find.text('Duplicate Profile'), findsOneWidget);
    return notifier;
  }

  Future<void> confirm(WidgetTester tester) async {
    // The dialog's own action button, not the overflow-menu entry.
    final action = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('Duplicate'),
    );
    await tester.tap(action);
    await tester.pumpAndSettle();
  }

  testWidgets('the second copy is offered a name no other profile has',
      (tester) async {
    final notifier = await openDuplicateDialog(tester, [_rig, _firstCopy]);

    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller!.text, 'Adv Rig One (Copy) (1)',
        reason: 'the offered name must not repeat an existing profile');

    await confirm(tester);
    expect(notifier.duplicated, ['Adv Rig One (Copy) (1)']);
    // Let the post-duplicate "wait for the row to appear" window expire so the
    // test does not leave its timer pending.
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a hand-typed name that already exists is refused',
      (tester) async {
    final notifier = await openDuplicateDialog(tester, [_rig, _firstCopy]);

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Adv Rig One',
    );
    await confirm(tester);

    expect(notifier.duplicated, isEmpty,
        reason: 'a colliding name must never reach the DAO');
    expect(find.text('Duplicate Profile'), findsOneWidget);
    expect(find.text('Another profile is already called "Adv Rig One"'),
        findsOneWidget);
  });
}
