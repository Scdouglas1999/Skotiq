import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/equipment_profiles_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

const _originalProfile = EquipmentProfileModel(
  id: 7,
  name: 'Imaging rig',
  filterNames: ['L'],
  isActive: true,
);

const _refreshedProfile = EquipmentProfileModel(
  id: 7,
  name: 'Imaging rig',
  filterNames: ['L', 'Ha'],
  isActive: true,
);

class _ReloadingProfilesNotifier extends EquipmentProfilesNotifier {
  final reload = Completer<EquipmentProfilesState>();
  int _buildCount = 0;

  @override
  Future<EquipmentProfilesState> build() {
    _buildCount++;
    if (_buildCount == 1) {
      return Future.value(
        const EquipmentProfilesState(
          profiles: [_originalProfile],
          activeProfile: _originalProfile,
        ),
      );
    }
    return reload.future;
  }
}

class _MockProfileService extends Mock implements ProfileService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('filter sync waits for and displays the refreshed profile',
      (tester) async {
    final service = _MockProfileService();
    late HarnessHandle handle;
    late _ReloadingProfilesNotifier profilesNotifier;
    when(() => service.syncFiltersToProfile(7)).thenAnswer((_) async {
      handle.container.invalidate(equipmentProfilesProvider);
      return true;
    });

    handle = await pumpAppScreen(
      tester,
      const EquipmentProfilesScreen(),
      size: const Size(1400, 1000),
      settle: false,
      extraOverrides: [
        equipmentProfilesProvider.overrideWith(() {
          profilesNotifier = _ReloadingProfilesNotifier();
          return profilesNotifier;
        }),
        profileServiceProvider.overrideWithValue(service),
      ],
    );
    await tester.pump();
    await tester.pump();

    final syncButton = find.byTooltip('Sync from filter wheel');
    expect(syncButton, findsOneWidget);
    await tester.ensureVisible(syncButton);
    await tester.tap(syncButton);
    await tester.pump();

    verify(() => service.syncFiltersToProfile(7)).called(1);
    expect(find.text('Ha'), findsNothing);
    expect(find.text('Filters synced from hardware'), findsNothing);

    profilesNotifier.reload.complete(
      const EquipmentProfilesState(
        profiles: [_refreshedProfile],
        activeProfile: _refreshedProfile,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Ha'), findsWidgets);
    expect(find.text('Filters synced from hardware'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
