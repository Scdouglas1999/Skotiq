// Snapshot and Loop on Tonight's Camera tab start from the active profile's
// gain and offset, without the Imaging screen having been opened.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/night_control_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';
import 'night_screen_test_support.dart';

const _profile = EquipmentProfileModel(
  id: 10,
  name: '10" Newt',
  isActive: true,
  defaultGain: 139,
  defaultOffset: 21,
);

void main() {
  testWidgets('Tonight seeds the capture settings from the active profile',
      (tester) async {
    await pumpAppScreen(
      tester,
      const NightControlScreen(),
      size: const Size(1536, 864),
      settle: false,
      extraOverrides: <Override>[
        ...nightScreenOverrides(NightScreenState.ready),
        activeEquipmentProfileProvider.overrideWithValue(_profile),
      ],
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NightControlScreen)),
    );
    final settings = container.read(exposureSettingsProvider);
    expect(settings.gain, 139);
    expect(settings.offset, 21);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
  });
}
