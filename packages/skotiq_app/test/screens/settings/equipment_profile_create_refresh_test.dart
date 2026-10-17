import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/equipment_profiles_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _DelayedCreateProfilesNotifier extends EquipmentProfilesNotifier {
  final reload = Completer<EquipmentProfilesState>();
  int buildCount = 0;
  int createCalls = 0;
  String? createdName;
  String? createdDescription;

  @override
  Future<EquipmentProfilesState> build() {
    buildCount++;
    if (buildCount == 1) {
      return Future.value(const EquipmentProfilesState());
    }
    return reload.future;
  }

  @override
  Future<int> createProfile({required String name, String? description}) async {
    createCalls++;
    createdName = name;
    createdDescription = description;
    ref.invalidateSelf();
    return 41;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'create validates the name and waits for the authoritative refreshed row',
    (tester) async {
      late _DelayedCreateProfilesNotifier profilesNotifier;
      await pumpAppScreen(
        tester,
        const EquipmentProfilesScreen(),
        size: const Size(1400, 1000),
        settle: false,
        extraOverrides: [
          equipmentProfilesProvider.overrideWith(() {
            profilesNotifier = _DelayedCreateProfilesNotifier();
            return profilesNotifier;
          }),
        ],
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('New profile'));
      await tester.pumpAndSettle();

      // Blank submission stays in the dialog and explains what is missing.
      await tester.tap(find.text('Create'));
      await tester.pump();
      expect(find.text('Enter a profile name.'), findsOneWidget);
      expect(find.text('Create New Profile'), findsOneWidget);
      expect(profilesNotifier.createCalls, 0);

      final fields = find.byType(TextField);
      await tester.enterText(fields.first, '  Remote observatory  ');
      await tester.enterText(fields.at(1), '  Wide-field setup  ');
      await tester.tap(find.text('Create'));
      await tester.pump();

      expect(profilesNotifier.createCalls, 1);
      expect(profilesNotifier.createdName, 'Remote observatory');
      expect(profilesNotifier.createdDescription, 'Wide-field setup');

      // A slow host refresh must remain an honest loading state rather than
      // throwing firstWhere, however long it takes.
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull);

      const created = EquipmentProfileModel(
        id: 41,
        name: 'Remote observatory',
        description: 'Wide-field setup',
      );
      profilesNotifier.reload.complete(
        const EquipmentProfilesState(profiles: [created]),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('Remote observatory'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
