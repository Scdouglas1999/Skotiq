import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/screens/planner/targets/plan_targets_tab.dart';
import 'package:skotiq_core/database.dart' as ndb;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../scheduler_test_doubles.dart';

/// What Plan > Targets reads besides the targets and groups a test supplies:
/// an idle autopilot that is ready to start, no site, no forecast, nothing
/// taken off the autopilot's list.
List<Override> planTargetsTabOverrides() => [
      allSessionsProvider.overrideWith(
        (ref) => Stream.value(const <ndb.ImagingSession>[]),
      ),
      integrationGoalsStreamProvider.overrideWith(
        (ref) => Stream.value(const <IntegrationGoal>[]),
      ),
      integrationGoalProgressProvider.overrideWith(
        (ref, _) async => <IntegrationGoalProgress>[],
      ),
      targetConstraintsStreamProvider.overrideWith(
        (ref) => const Stream<List<TargetConstraint>>.empty(),
      ),
      autopilotRemovedTargetIdsProvider.overrideWith((ref) async => <int>{}),
      unusedTargetsCountProvider.overrideWith((ref) async => 0),
      appObserverLocationProvider.overrideWithValue(null),
      weekForecastProvider.overrideWith(
        (ref) => Completer<WeekForecast>().future,
      ),
      smartNightExposureContextProvider.overrideWith((ref) async => null),
      integrationGoalServiceProvider
          .overrideWithValue(FakeIntegrationGoalService()),
      targetConstraintServiceProvider
          .overrideWithValue(FakeTargetConstraintService()),
      schedulerEngineProvider.overrideWithValue(buildTestSchedulerEngine()),
      schedulerStatusProvider.overrideWith(
        (ref) => FakeSchedulerStatusNotifier(
          const SchedulerStatus(state: SchedulerState.idle),
        ),
      ),
      currentSchedulerDecisionProvider.overrideWith(
        (ref) => FakeCurrentSchedulerDecisionNotifier(null),
      ),
      schedulerEngineReadyProvider.overrideWith(
        (ref) => ref.read(schedulerEngineProvider),
      ),
      schedulerStartReadinessProvider.overrideWithValue(
        const SchedulerStartReadiness(
          issues: [],
          available: true,
          solverRequired: false,
        ),
      ),
      schedulerAutoReevalProvider.overrideWith((ref) {}),
      schedulerPreviewDecisionProvider.overrideWith(
        (ref) => Completer<SchedulerDecision>().future,
      ),
    ];
