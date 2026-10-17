import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _FailingProfilesNotifier extends EquipmentProfilesNotifier {
  @override
  Future<EquipmentProfilesState> build() async {
    throw StateError('profile database unavailable');
  }
}

class _PendingProfilesNotifier extends EquipmentProfilesNotifier {
  @override
  Future<EquipmentProfilesState> build() =>
      Completer<EquipmentProfilesState>().future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('profile failure is not rendered as first-time onboarding',
      (tester) async {
    await pumpAppScreen(
      tester,
      const EquipmentScreen(),
      extraOverrides: [
        equipmentProfilesProvider.overrideWith(_FailingProfilesNotifier.new),
      ],
      settle: false,
    );
    await tester.pump();

    expect(find.text('Could not load equipment profiles'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Start setup'), findsNothing);
  });

  testWidgets('profile loading is not rendered as first-time onboarding',
      (tester) async {
    await pumpAppScreen(
      tester,
      const EquipmentScreen(),
      extraOverrides: [
        equipmentProfilesProvider.overrideWith(_PendingProfilesNotifier.new),
      ],
      settle: false,
    );
    await tester.pump();

    expect(find.byType(SkotiqMark), findsOneWidget);
    expect(find.text('Start setup'), findsNothing);
  });
}
