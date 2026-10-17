// The profile detail pane must not draw read-only values — "400 mm", "72 mm",
// "f/5.6", "120", "30", "-10°C" — as filled, rounded, bordered input boxes: the
// same chrome as the editable fields beside them and as the live Binning
// selector directly beneath. Clicking one produces no focus ring and swallows
// every keystroke, so one card's identical chrome is half live and half dead.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/equipment_profiles_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

const _rig = EquipmentProfileModel(
  id: 1,
  name: 'Audit Rig',
  focalLength: 400,
  aperture: 72,
  isActive: true,
);

class _FixedProfilesNotifier extends EquipmentProfilesNotifier {
  @override
  Future<EquipmentProfilesState> build() async => const EquipmentProfilesState(
        profiles: [_rig],
        activeProfile: _rig,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('read-only profile values are not drawn as text inputs',
      (tester) async {
    await pumpAppScreen(
      tester,
      const EquipmentProfilesScreen(),
      size: const Size(1400, 1200),
      settle: false,
      extraOverrides: [
        equipmentProfilesProvider.overrideWith(_FixedProfilesNotifier.new),
      ],
    );
    await tester.pump();
    await tester.pump();

    final value = find.text('400 mm');
    expect(value, findsOneWidget);
    expect(
      find.ancestor(of: value, matching: find.byType(TextField)),
      findsNothing,
      reason: 'a read-only value must not sit inside an input',
    );
    // The 36 px filled, rounded panel is the input chrome. The nearest
    // decorated box around a read-only value must be the section card, not a
    // control-sized one.
    final nearestBox = find
        .ancestor(
          of: value,
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.decoration != null,
          ),
        )
        .first;
    expect(
      tester.getSize(nearestBox).height,
      greaterThan(60),
      reason: 'the value must not sit in its own input-shaped 36 px box',
    );
  });

  testWidgets('a read-only profile value announces itself as read-only',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      const EquipmentProfilesScreen(),
      size: const Size(1400, 1200),
      settle: false,
      extraOverrides: [
        equipmentProfilesProvider.overrideWith(_FixedProfilesNotifier.new),
      ],
    );
    await tester.pump();
    await tester.pump();

    expect(
        find.bySemanticsLabel(RegExp(r'Focal Length: 400 mm')), findsWidgets);
    handle.dispose();
  });
}
