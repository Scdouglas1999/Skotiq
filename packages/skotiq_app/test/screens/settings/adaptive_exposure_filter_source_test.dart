// Adaptive Exposure must read the same "which filters exist" source of truth
// as the rest of the app (effectiveFiltersProvider = connected wheel, else
// profile). Reading only activeEquipmentProfileProvider makes the page claim
// 'No filter wheel on active profile' with a wheel connected, while Autofocus
// lists every slot.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/adaptive_exposure_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

Future<HarnessHandle> _pump(
  WidgetTester tester, {
  required List<String> profileFilters,
}) async {
  final database = mockDatabase();
  await database.settingsDao.setSettings({
    'adaptive_exposure_enabled': 'true',
    'adaptive_exposure_min_secs': '5',
    'adaptive_exposure_max_secs': '600',
  });
  addTearDown(database.close);
  return pumpAppScreen(
    tester,
    const SingleChildScrollView(child: AdaptiveExposureSettings()),
    size: const Size(900, 1400),
    database: database,
    extraOverrides: [
      activeEquipmentProfileProvider.overrideWithValue(
        EquipmentProfileModel(
          id: 1,
          name: 'Test Rig',
          filterNames: profileFilters,
          isActive: true,
        ),
      ),
    ],
    settle: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'connected wheel supplies the per-filter rows when the profile has none',
      (tester) async {
    final handle = await _pump(tester, profileFilters: const []);
    await tester.pump();

    // Precondition: with nothing connected the page honestly reports it.
    expect(
      find.textContaining('No filter wheel connected'),
      findsOneWidget,
      reason: 'no wheel + no profile filters is the only case that warns',
    );

    handle.container.read(filterWheelStateProvider.notifier).setConnected(
      filterNames: const ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
    );
    await tester.pump();

    expect(find.textContaining('No filter wheel connected'), findsNothing);
    expect(find.byType(SkotiqCheckbox), findsNWidgets(7));
    for (final filter in const ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII']) {
      expect(find.text(filter), findsOneWidget);
    }
  });

  testWidgets('the warning names both missing sources, not just the profile',
      (tester) async {
    await _pump(tester, profileFilters: const []);
    await tester.pump();

    // 'No filter wheel on active profile' is false as soon as a wheel is
    // connected or assigned.
    expect(find.textContaining('on active profile —'), findsNothing);
    expect(
      find.textContaining(
        'No filter wheel connected and no filters on the active profile',
      ),
      findsOneWidget,
    );
  });

  testWidgets('per-filter enablement materializes over the effective filters',
      (tester) async {
    final handle = await _pump(tester, profileFilters: const []);
    await tester.pump();
    handle.container
        .read(filterWheelStateProvider.notifier)
        .setConnected(filterNames: const ['L', 'R', 'G']);
    await tester.pump();

    final checkboxes = find.byType(SkotiqCheckbox);
    await tester.ensureVisible(checkboxes.first);
    await tester.tap(checkboxes.first);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    // Unticking one filter must not silently disable the peers that were
    // implicitly enabled by the empty map.
    expect(
      handle.container
          .read(appSettingsProvider)
          .value!
          .adaptiveExposurePerFilterEnabled,
      const {'L': false, 'R': true, 'G': true},
    );
  });
}
