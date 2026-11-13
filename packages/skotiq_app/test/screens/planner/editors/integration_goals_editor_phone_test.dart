// The goals editor is what Plan > Projects and Analytics > Projects open to
// set a target's goal. At phone width its one-line rows ran past the dialog:
// the captured count, the delete button and the Add button were cut off.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planner/editors/integration_goals_editor.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('a goal and the add row fit a phone-width dialog',
      (tester) async {
    final goal = IntegrationGoal(
      id: 1,
      targetId: 2,
      filter: 'L',
      exposureSeconds: 105,
      frameCount: 20,
      createdAt: DateTime.utc(2026, 11, 11),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        integrationGoalProgressProvider.overrideWith(
          (ref, targetId) async =>
              [IntegrationGoalProgress(goal: goal, capturedCount: 0)],
        ),
        smartNightExposureContextProvider.overrideWith((ref) async => null),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 340,
              child: IntegrationGoalsEditor(
                targetId: 2,
                targetName: 'M33',
                availableFilters: const ['L', 'R', 'G', 'B'],
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('0 / 20 captured'), findsOneWidget);
    expect(find.byTooltip('Delete goal'), findsOneWidget);
    final add = tester.getRect(find.text('Add'));
    final editor = tester.getRect(find.byType(IntegrationGoalsEditor));
    expect(editor.contains(add.bottomRight - const Offset(1, 1)), isTrue);
  });
}
