import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/scheduler/widgets/integration_goals_editor.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockIntegrationGoalService extends Mock
    implements IntegrationGoalService {}

/// Filter wheel that is physically present and online but reports zero slots.
///
/// That is the ONE case the editor may refuse to create a goal for: a wheel in
/// the light path whose slots are unknown. "No wheel at all" is a different
/// state and must stay usable.
class _OnlineWheelWithNoSlots extends FilterWheelStateNotifier {
  _OnlineWheelWithNoSlots(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const FilterWheelState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'sim_filterwheel_1',
      deviceName: 'Simulated Filter Wheel',
      filterNames: <String>[],
    );
  }
}

Widget _harness({
  required List<String> availableFilters,
  bool wheelOnline = false,
  IntegrationGoalService? service,
  List<IntegrationGoalProgress> existing = const <IntegrationGoalProgress>[],
}) {
  return ProviderScope(
    overrides: [
      if (service != null)
        integrationGoalServiceProvider.overrideWithValue(service),
      integrationGoalProgressProvider.overrideWith(
        (ref, targetId) async => existing,
      ),
      smartNightExposureContextProvider.overrideWith((ref) async => null),
      if (wheelOnline)
        filterWheelStateProvider.overrideWith(_OnlineWheelWithNoSlots.new),
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: IntegrationGoalsEditor(
          targetId: 42,
          targetName: 'M92',
          availableFilters: availableFilters,
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(
      IntegrationGoal(
        targetId: 0,
        filter: 'L',
        exposureSeconds: 1,
        frameCount: 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      ),
    );
  });

  testWidgets(
    'a rig with no filter wheel can still create an unfiltered goal',
    (tester) async {
      final service = _MockIntegrationGoalService();
      final saved = <IntegrationGoal>[];
      when(() => service.upsert(any())).thenAnswer((invocation) async {
        saved.add(invocation.positionalArguments.first as IntegrationGoal);
        return 1;
      });

      await tester.pumpWidget(_harness(
        availableFilters: const <String>[],
        service: service,
      ));
      await tester.pumpAndSettle();

      // A bare warning with no add-goal affordance dead-ends the autopilot for
      // every OSC / DSLR / wheel-less rig.
      expect(
        find.textContaining('configure a filter wheel first'),
        findsNothing,
      );
      expect(find.byType(DropdownButton<String>), findsOneWidget);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No filter').last);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(SkotiqButton, 'Add'));
      await tester.pumpAndSettle();

      expect(saved, hasLength(1));
      // The empty name is the wire contract Smart Night plans against, so the
      // goal and a Smart Night sequence describe the same frames.
      expect(saved.single.filter, smartNightUnfilteredName);
      expect(saved.single.targetId, 42);
    },
  );

  testWidgets(
    'a connected wheel reporting zero slots still refuses to create a goal',
    (tester) async {
      await tester.pumpWidget(_harness(
        availableFilters: const <String>[],
        wheelOnline: true,
      ));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('reports no filter slots'),
        findsOneWidget,
      );
      expect(find.byType(DropdownButton<String>), findsNothing);
    },
  );

  testWidgets(
    'an existing unfiltered goal renders as "No filter", not a blank cell',
    (tester) async {
      await tester.pumpWidget(_harness(
        availableFilters: const <String>[],
        existing: [
          IntegrationGoalProgress(
            goal: IntegrationGoal(
              id: 7,
              targetId: 42,
              filter: smartNightUnfilteredName,
              exposureSeconds: 120,
              frameCount: 30,
              createdAt: DateTime.utc(2026),
            ),
            capturedCount: 3,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('No filter'), findsOneWidget);
      expect(
        find.textContaining('already has its goal'),
        findsOneWidget,
      );
    },
  );
}
