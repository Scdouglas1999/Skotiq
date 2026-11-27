// A target's goals offer the filters the rig can select: the connected
// wheel's names when the equipment profile names none. Plan > Targets told a
// phone linked to a rig with a 7-slot named wheel that the wheel "reports no
// filter slots", because the editor read only the profile's names.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planner/editors/integration_goals_editor.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _NamedWheel extends FilterWheelStateNotifier {
  _NamedWheel(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const FilterWheelState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'sim_filterwheel_1',
      deviceName: 'Simulated Filter Wheel',
      filterNames: ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
    );
  }
}

void main() {
  testWidgets(
    'a profile without filter names offers the connected wheel\'s filters',
    (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          activeEquipmentProfileProvider.overrideWithValue(null),
          filterWheelStateProvider.overrideWith(_NamedWheel.new),
          integrationGoalProgressProvider.overrideWith(
            (ref, targetId) async => const <IntegrationGoalProgress>[],
          ),
          smartNightExposureContextProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => showIntegrationGoalsDialog(
                  context,
                  ref,
                  targetId: 1,
                  targetName: 'M1',
                ),
                child: const Text('Goals'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Goals'));
      await tester.pumpAndSettle();

      expect(find.textContaining('reports no filter slots'), findsNothing);
      await tester.tap(find.byType(SkotiqDropdown));
      await tester.pumpAndSettle();
      expect(find.text('Ha').last, findsOneWidget);
      expect(find.text('SII').last, findsOneWidget);
    },
  );
}
