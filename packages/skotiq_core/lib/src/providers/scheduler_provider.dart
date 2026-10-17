import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../database/daos/settings_dao.dart';
import '../database/database.dart' as ndb;
import '../models/scheduler/integration_goal.dart';
import '../models/scheduler/scheduler_decision.dart';
import '../models/scheduler/scheduler_status.dart';
import '../models/scheduler/target_constraint.dart';
import '../models/planning/project.dart';
import '../models/readiness/readiness_models.dart';
import '../models/scheduler/scheduler_readiness.dart';
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../models/sequence/active_plan_owner.dart';
import '../models/sequence/sequence_models.dart';
import '../services/planning/project_service.dart'
    show
        projectTargetsProjectIndexSql,
        projectTargetsSchemaSql,
        projectsSchemaSql;
import '../services/logging_service.dart' show loggingServiceProvider;
import '../services/safe_rig_service.dart';
import '../services/disk_space_guard.dart' show kSafetyMarginBytes;
import '../services/scheduler/horizon_profile.dart';
import '../services/scheduler/integration_goal_service.dart';
import '../services/scheduler/scheduler_engine.dart';
import '../services/scheduler/scheduler_log.dart' show schedulerLogSinkFor;
import '../services/scheduler/scheduler_queue_service.dart'
    show schedulerQueueServiceProvider;
import '../services/scheduler/target_constraint_service.dart';
import '../services/smart_night_models.dart' show smartNightPlanningFilters;
import 'backend_provider.dart';
import 'clock_provider.dart';
import 'database_provider.dart';
import 'disk_space_provider.dart';
import 'event_provider.dart';
import 'readiness_provider.dart';
import 'equipment/guider_state_provider.dart';
import 'weather_safety_provider.dart';
// Multi-night planning (component C6): the active-project selection and the
// live project list scope the scheduler's candidate set to one campaign and
// re-trigger evaluation when the operator switches projects or edits
// membership. The dependency is one-directional (planning_provider imports
// scheduler_provider, not the reverse) — only these read-only providers are
// pulled in here, so there is no cycle.
import 'planning_provider.dart'
    show activeProjectIdProvider, projectListProvider;
import 'profiles_provider.dart';
import 'sequence_provider.dart';
// Hide settings_provider's legacy 8-compass-point HorizonProfile so the
// scheduler's samples-based HorizonProfile from services/scheduler/
// horizon_profile.dart resolves unambiguously below.
import 'settings_provider.dart' hide HorizonProfile;
// Pull in SkotiqEvent + EventPayload tagged-union subtypes (freezed
// generates EventPayload_Guiding / EventPayload_Equipment as part-of-library
// classes, so a plain import surfaces them here).
import 'package:skotiq_bridge/skotiq_bridge.dart';

part 'scheduler/scheduler_engine_providers.dart';
part 'scheduler/scheduler_candidate_loader.dart';
part 'scheduler/scheduler_config.dart';
part 'scheduler/scheduler_readiness.dart';
part 'scheduler/scheduler_remote_and_goals.dart';

/// Stream that pushes engine trigger events derived from the native bridge.
/// Hooks weather / guiding / mount events into the engine without
/// introducing new event types.
final schedulerTriggerStreamProvider = Provider<Stream<SchedulerTriggerEvent>>((
  ref,
) {
  final controller = StreamController<SchedulerTriggerEvent>.broadcast();
  final sub = ref.listen<AsyncValue<SkotiqEvent>>(
    skotiqEventsProvider,
    (previous, next) {
      next.whenData((event) {
        final mapped = _mapEventToTrigger(event);
        if (mapped != null) controller.add(mapped);
      });
    },
  );
  ref.onDispose(() {
    sub.close();
    controller.close();
  });
  return controller.stream;
});

SchedulerTriggerEvent? _mapEventToTrigger(SkotiqEvent event) {
  switch (event.category) {
    case EventCategory.safety:
      return SchedulerTriggerEvent.weatherChange;
    case EventCategory.guiding:
      // The payload distinguishes loss vs recovery; we surface both as
      // discrete triggers so the engine can react. A finer-grained
      // mapping can be added when the payload accessor is stable.
      final payload = event.payload;
      if (payload is EventPayload_Guiding) {
        final name = payload.field0.toString().toLowerCase();
        if (name.contains('lost') || name.contains('stopped')) {
          return SchedulerTriggerEvent.guidingLost;
        }
        if (name.contains('settled') || name.contains('started')) {
          return SchedulerTriggerEvent.guidingRecovered;
        }
      }
      return null;
    case EventCategory.equipment:
      final payload = event.payload;
      if (payload is EventPayload_Equipment) {
        final name = payload.field0.toString().toLowerCase();
        if (name.contains('parked')) return SchedulerTriggerEvent.mountParked;
        if (name.contains('unparked')) {
          return SchedulerTriggerEvent.mountUnparked;
        }
      }
      return null;
    case EventCategory.sequencer:
      // A natural whole-sequence completion means the autopilot's dispatched
      // work for the current target finished. Without reacting, the rig sits
      // idle until the next periodic tick (and never re-dispatches a
      // still-eligible target held by hysteresis). Match the precise
      // SequencerEvent_Completed type only: SequencerEvent_Stopped is the
      // scheduler's OWN stop when switching targets (reacting to it would make
      // a dispatch feedback loop), and Node/Target/ExposureCompleted are
      // sub-events, not the end of the run.
      final payload = event.payload;
      if (payload is EventPayload_Sequencer &&
          payload.field0 is SequencerEvent_Completed) {
        return SchedulerTriggerEvent.sequenceCompleted;
      }
      return null;
    case EventCategory.imaging:
    case EventCategory.system:
    case EventCategory.polarAlignment:
      return null;
  }
}

/// StateNotifier that mirrors the engine's status stream into Riverpod so
/// widgets can `ref.watch(schedulerStatusProvider)` without subscribing to
/// the stream themselves.
final schedulerStatusProvider =
    StateNotifierProvider<SchedulerStatusNotifier, SchedulerStatus>((ref) {
      final engine = ref.watch(schedulerEngineProvider);
      return SchedulerStatusNotifier(engine);
    });

class SchedulerStatusNotifier extends StateNotifier<SchedulerStatus> {
  final SchedulerEngine _engine;
  late final StreamSubscription<SchedulerStatus> _sub;

  SchedulerStatusNotifier(this._engine) : super(_engine.status) {
    _sub = _engine.statusStream.listen((s) {
      if (!mounted) return;
      state = s;
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

/// StateNotifier surfacing the engine's last decision.
final currentSchedulerDecisionProvider =
    StateNotifierProvider<CurrentSchedulerDecisionNotifier, SchedulerDecision?>(
      (ref) {
        final engine = ref.watch(schedulerEngineProvider);
        return CurrentSchedulerDecisionNotifier(engine);
      },
    );

class CurrentSchedulerDecisionNotifier
    extends StateNotifier<SchedulerDecision?> {
  final SchedulerEngine _engine;
  late final StreamSubscription<SchedulerDecision> _sub;

  CurrentSchedulerDecisionNotifier(this._engine) : super(_engine.lastDecision) {
    _sub = _engine.decisionStream.listen((d) {
      if (!mounted) return;
      state = d;
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

/// Read-only PREVIEW of what the live autopilot would run right now.
///
/// This is the single source of truth for the Planner's "what will run
/// tonight" headline: it runs the SchedulerEngine's pure, side-effect-free
/// [SchedulerEngine.previewDecision] over the SAME candidate set the autopilot
/// scores (goals / constraints / horizon / filters / scheduled windows /
/// active-project scope), at the engine's current clock and hysteresis state.
/// By construction the target the human sees here is the target the rig will
/// slew to — no competing scorer.
///
/// It does NOT dispatch, park, or mutate engine status. It re-runs whenever
/// the engine's last decision changes (so it stays in step with live ticks and
/// trigger-driven re-evaluations) and whenever a candidate input changes; the
/// auto-reeval listeners that poke the engine cover the underlying data edits.
final schedulerPreviewDecisionProvider =
    FutureProvider.autoDispose<SchedulerDecision>((ref) async {
      // On a remote SLAVE the local scheduler engine has no candidate data — the
      // catalog/targets live in the HOST's database, never the slave's — so
      // previewDecision() would always return "nothing eligible". Mirror the
      // host's REAL preview ("what the rig would slew to next") instead. This
      // provider is invalidated by the on-connect hydrate and by scheduler
      // events (hydrateRemoteSessionState / _applySequencerEvent), so the banner
      // tracks the host live rather than computing a wrong local answer.
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return backend.getSchedulerPreview();
      }
      final engine = await ref.watch(schedulerEngineReadyProvider.future);
      final clock = ref.watch(clockProvider);
      // Re-derive the preview each time the autopilot publishes a fresh decision
      // so the read-only view tracks live evaluation. Watching the decision (not
      // just reading it once) keeps the headline current after ticks/triggers.
      ref.watch(currentSchedulerDecisionProvider);
      // The engine treats its argument as an instant to rebase (see
      // `SchedulerEngine`), so the preview has to be handed the same instant
      // the live tick gets, not a zone rendering of it — otherwise the
      // read-only preview and the autopilot disagree about what time it is.
      return engine.previewDecision(clock.nowUtc());
    });
