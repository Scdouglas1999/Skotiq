import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../models/planning/night_forecast.dart';
import '../models/planning/project.dart';
import '../models/planning/project_progress.dart';
import '../models/scheduler/integration_goal.dart';
import '../services/planning/forecast_planning_service.dart';
import '../services/planning/project_service.dart';
import '../services/scheduler/integration_goal_service.dart';
import '../services/weather/providers/openmeteo_cloud_provider.dart';
import '../services/weather/radar_provider.dart';
import '../utils/resilient_poll_stream.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'scheduler_provider.dart';
import 'settings_provider.dart';

/// Riverpod plumbing for the multi-night planner: [ProjectService] /
/// [ForecastPlanningService] and the [OpenMeteoCloudProvider] forecast feed,
/// wired into the provider graph the planner UI consumes.
///
/// Fail-closed throughout: a missing observing location throws (matching the
/// planner screen's `_plannerOptimizationProvider`), and a forecast-feed
/// failure surfaces as [WeekForecast.unavailable] rather than a fabricated
/// clear week.

/// `app_settings` key backing [activeProjectIdProvider]. Stored as the decimal
/// project id; an absent row or an empty string means "no active project".
const String _activeProjectIdSettingKey = 'planning.active_project_id';

String _activeProjectSettingKeyFor(Object backend) {
  if (backend is! NetworkBackend) return _activeProjectIdSettingKey;
  final identity =
      '${backend.scheme.toLowerCase()}://'
      '${backend.serverHost.trim().toLowerCase()}:${backend.serverPort}|'
      '${backend.pinnedFingerprint?.trim().toLowerCase() ?? ''}';
  final encoded = base64Url.encode(utf8.encode(identity)).replaceAll('=', '');
  return '$_activeProjectIdSettingKey.remote.$encoded';
}

/// Persisted selection of the operator's currently-focused project.
///
/// Mirrors the single-value-persisted-via-`settingsDao` pattern used by the
/// onboarding draft and other selections: the notifier hydrates from
/// `app_settings` on construction and writes back on every [setActiveProject].
/// `null` means no project is active.
final activeProjectIdProvider =
    StateNotifierProvider<ActiveProjectNotifier, int?>((ref) {
      final notifier = ActiveProjectNotifier(ref);
      ref.listen(backendProvider, (_, next) {
        notifier._switchBackend(next);
      });
      // Kick off the async hydrate immediately. Until it resolves the state is
      // `null` (no active project), which is the correct cold-start default.
      unawaited(notifier._load());
      return notifier;
    });

/// State notifier owning the active-project selection and its persistence.
class ActiveProjectNotifier extends StateNotifier<int?> {
  ActiveProjectNotifier(this._ref) : super(null) {
    _settingKey = _activeProjectSettingKeyFor(_ref.read(backendProvider));
  }

  final Ref _ref;
  late String _settingKey;
  int _scopeRevision = 0;
  bool _isLoaded = false;
  Completer<void>? _loadCompleter;
  int? _requestedProjectId;
  int _requestRevision = 0;
  Future<void> _writeTail = Future<void>.value();
  Future<void> _requestedWrite = Future<void>.value();

  /// True once the persisted selection (if any) has been read into [state].
  bool get isLoaded => _isLoaded;

  /// Resolves when the initial load is done. Awaited by tests that need to be
  /// certain of the hydrated state before asserting.
  Future<void> get loaded {
    if (_isLoaded) return Future<void>.value();
    _loadCompleter ??= Completer<void>();
    return _loadCompleter!.future;
  }

  Future<void> _load() async {
    final scopeAtStart = _scopeRevision;
    final settingKeyAtStart = _settingKey;
    final revisionAtStart = _requestRevision;
    try {
      final settingsDao = _ref.read(settingsDaoProvider);
      final raw = await settingsDao.getSetting(settingKeyAtStart);
      final parsed = _parse(raw);
      if (scopeAtStart == _scopeRevision &&
          revisionAtStart == _requestRevision &&
          mounted) {
        _requestedProjectId = parsed;
        state = parsed;
      }
    } catch (error, stackTrace) {
      developer.log(
        'Failed to hydrate the active planner project for $settingKeyAtStart',
        name: 'ActiveProjectNotifier',
        level: 1000,
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (scopeAtStart == _scopeRevision) {
        _isLoaded = true;
        final completer = _loadCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete();
        }
        _loadCompleter = null;
      }
    }
  }

  void _switchBackend(Object backend) {
    final nextKey = _activeProjectSettingKeyFor(backend);
    if (nextKey == _settingKey) return;

    _settingKey = nextKey;
    _scopeRevision++;
    _requestRevision++;
    _requestedProjectId = null;
    _requestedWrite = Future<void>.value();
    _isLoaded = false;
    if (mounted) state = null;
    unawaited(_load());
  }

  /// Parse the stored value. Null/empty/whitespace and non-numeric values all
  /// resolve to "no active project" — a corrupt row is treated as unset rather
  /// than throwing, since the selection is a soft UI focus, not load-bearing
  /// data. A non-positive id is likewise rejected (row ids are AUTOINCREMENT,
  /// hence always >= 1).
  static int? _parse(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final value = int.tryParse(trimmed);
    if (value == null || value <= 0) return null;
    return value;
  }

  /// Select (or clear, with `null`) the active project and persist it. Repeating
  /// the confirmed selection is idempotent, and concurrent changes are applied
  /// in invocation order so the last requested project wins.
  Future<void> setActiveProject(int? id) {
    if (id != null && id <= 0) {
      return Future<void>.error(
        ArgumentError.value(id, 'id', 'must be a positive project id'),
      );
    }
    if (_isLoaded && id == _requestedProjectId) return _requestedWrite;

    _requestedProjectId = id;
    final scopeAtRequest = _scopeRevision;
    final settingKeyAtRequest = _settingKey;
    final revision = ++_requestRevision;
    final operation = _writeTail
        .then((_) async {
          final settingsDao = _ref.read(settingsDaoProvider);
          await settingsDao.setSetting(
            settingKeyAtRequest,
            id?.toString() ?? '',
          );
          if (mounted &&
              scopeAtRequest == _scopeRevision &&
              revision == _requestRevision) {
            state = id;
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (scopeAtRequest == _scopeRevision &&
              revision == _requestRevision) {
            _requestedProjectId = state;
          }
          Error.throwWithStackTrace(error, stackTrace);
        });
    _writeTail = operation.then<void>((_) {}, onError: (_, __) {});
    _requestedWrite = operation;
    return operation;
  }
}

/// Live list of every project, most-recently-updated first.
///
/// The `projects` / `project_targets` tables are raw-SQL and invisible to
/// Drift's reactive graph, so we mirror [integrationGoalsStreamProvider]'s
/// pattern: bridge [ProjectService.watchChanges] (a `void` change-notification
/// stream) into a `List<Project>` stream by emitting the current list once up
/// front and then re-listing on each mutation.
final projectListProvider = StreamProvider<List<Project>>((ref) {
  final service = ref.watch(projectServiceProvider);
  final backend = ref.watch(backendProvider);

  // On a remote SLAVE the projects live in the HOST DB and there is no local
  // mutation stream to bridge — service.watchChanges() never fires — so poll
  // the host on a fixed tick with a change-guard (mirrors database_provider's
  // _pollRemote). Host-side project CRUD surfaces within the interval.
  if (backend is NetworkBackend) {
    return resilientDistinctPoll(
      fetch: service.listProjects,
      unchanged: listEquals,
      interval: const Duration(seconds: 10),
      onRetainedError: (error, stackTrace) {
        developer.log(
          'Remote project poll failed; retaining last value',
          name: 'PlanningProvider',
          level: 900,
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  Stream<List<Project>> listOnChange() async* {
    // Initial emit so the UI has data before the first mutation.
    yield await service.listProjects();
    await for (final _ in service.watchChanges()) {
      yield await service.listProjects();
    }
  }

  return listOnChange();
});

/// Per-project accrued-vs-remaining roll-up.
///
/// Accrued frames are derived live from capture history, so the roll-up
/// recomputes on every input to [ProjectService.buildProgress]: captures,
/// integration goals, and project membership.
///
/// `autoDispose` so a closed project detail view stops recomputing.
final projectProgressProvider = FutureProvider.autoDispose
    .family<CampaignProgress, int>((ref, id) {
      ref.watch(allDbImagesProvider);
      ref.watch(integrationGoalsStreamProvider);
      ref.watch(projectListProvider);
      return ref.watch(projectServiceProvider).buildProgress(id);
    });

/// The roll-up for the active project, or `null` when no project is active.
///
/// Delegates to [projectProgressProvider] for the active id so the
/// recomputation triggers (captures / goals / membership) are inherited.
final activeProjectProgressProvider =
    FutureProvider.autoDispose<CampaignProgress?>((ref) async {
      final activeId = ref.watch(activeProjectIdProvider);
      if (activeId == null) return null;
      return ref.watch(projectProgressProvider(activeId).future);
    });

/// Factory seam that builds the [OpenMeteoCloudProvider] used by
/// [weekForecastProvider].
///
/// In production this returns a provider backed by the default
/// `http.Client`. Tests override this provider to inject a fake `http.Client`
/// (e.g. a `MockClient`) so the forecast fetch can be driven without real
/// network access — including the error path that exercises the fail-closed
/// contract.
final planningCloudProviderFactoryProvider =
    Provider<OpenMeteoCloudProvider Function()>((ref) {
      return OpenMeteoCloudProvider.new;
    });

/// Immutable (latitude, longitude) key for the cloud-fetch provider family.
///
/// Equality is by value so two reads at the same site share one cached fetch
/// result (and thus one HTTP round-trip) regardless of how many times the
/// downstream combiner rebuilds.
@immutable
class ForecastSite {
  final double latitude;
  final double longitude;

  const ForecastSite(this.latitude, this.longitude);

  @override
  bool operator ==(Object other) =>
      other is ForecastSite &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);
}

/// The hourly cloud feed for a site, keyed ONLY on (lat, lng).
///
/// Deliberately decoupled from the capture/goal/active-project triggers: a
/// seven-night forecast does not change frame-to-frame, and a fetch tied to
/// arriving subs would exhaust the free Open-Meteo endpoint's rate limit and
/// leave the strip "unavailable". [weekForecastProvider] does the
/// capture/goal-driven candidate recompute and re-reads this cached
/// [RadarFetchResult].
///
/// `autoDispose` so the feed (and its HTTP client) is torn down when the
/// planner view closes.
final weekForecastCloudProvider = FutureProvider.autoDispose
    .family<RadarFetchResult, ForecastSite>((ref, site) async {
      // The provider owns an http.Client, so dispose it once we have the result to
      // avoid leaking a connection per fetch.
      final cloudProvider = ref.watch(planningCloudProviderFactoryProvider)();
      try {
        return await cloudProvider.fetchRadarFrames(
          latitude: site.latitude,
          longitude: site.longitude,
        );
      } finally {
        cloudProvider.dispose();
      }
    });

/// The seven-night "This Week" forecast, scored against the active project's
/// still-incomplete targets.
///
/// An unset observing location (lat == 0 && lng == 0) throws [StateError],
/// matching the planner screen's `_plannerOptimizationProvider`: a forecast at
/// (0,0) is meaningless. A network/API failure arrives as an error
/// [RadarFetchResult] and maps to [WeekForecast.unavailable], never a
/// fabricated clear week.
///
/// With no active project the candidate set falls back to every catalog target
/// with an unmet integration goal, built from the goal stack rather than the
/// scheduler candidate set — the candidate set carries no per-filter
/// accrued-vs-goal progress, which is the "incomplete" signal needed here.
///
/// `autoDispose` so the forecast is torn down when the planner view closes.
final weekForecastProvider = FutureProvider.autoDispose<WeekForecast>((
  ref,
) async {
  final settings = await ref.watch(appSettingsProvider.future);
  final lat = settings.latitude;
  final lng = settings.longitude;
  if (lat == 0.0 && lng == 0.0) {
    throw StateError(
      'Observing location is not configured. '
      'Set your latitude and longitude in Settings before using the '
      'multi-night forecast.',
    );
  }

  // Capture/goal/active-project triggers establish the candidate set. We read
  // them BEFORE the first await so the dependency edges are registered
  // synchronously (watching after a suspension is the documented Riverpod
  // foot-gun). These intentionally do NOT gate the cloud fetch — that lives in
  // weekForecastCloudProvider, keyed only on the site, so a new frame or a goal
  // edit recomputes only the candidate set and reuses the cached feed.
  ref.watch(allDbImagesProvider);
  ref.watch(integrationGoalsStreamProvider);
  // Also subscribe to the catalog up front: _incompleteCandidates resolves
  // per-target altitude floors from allDbTargetsProvider (host-aware), so the
  // dependency edge must be registered before the first await below.
  ref.watch(allDbTargetsProvider);
  final activeProjectId = ref.watch(activeProjectIdProvider);

  // Cloud feed — cached per site; capture/goal rebuilds reuse it.
  final cloudResult = await ref.watch(
    weekForecastCloudProvider(ForecastSite(lat, lng)).future,
  );

  final candidates = await _incompleteCandidates(ref, activeProjectId);

  final service = ForecastPlanningService(
    latitudeDegrees: lat,
    longitudeDegrees: lng,
  );
  return service.buildWeek(
    cloudResult: cloudResult,
    targets: candidates,
    nowLocal: DateTime.now(),
  );
});

/// Build the [ProjectTargetCandidate] set the forecast scores visibility for.
///
/// When [activeProjectId] is non-null we use that project's incomplete
/// targets (via [ProjectService.buildProgress]); otherwise we fall back to
/// every catalog target carrying an unmet integration goal. In both cases each
/// candidate's `minAltitude` comes from the live `targets` row so the
/// "is it up?" test honors the operator's per-target altitude floor.
Future<List<ProjectTargetCandidate>> _incompleteCandidates(
  Ref ref,
  int? activeProjectId,
) async {
  // Resolve target rows through the host-aware catalog stream so this works on
  // a remote slave (where the local targets DAO is empty). On the host this is
  // the same catalog the DAO serves. Indexed by id for O(1) per-target lookup.
  final targetRows = await ref.watch(allDbTargetsProvider.future);
  final targetsById = {for (final t in targetRows) t.id: t};

  if (activeProjectId != null) {
    final projectService = ref.read(projectServiceProvider);
    final progress = await projectService.buildProgress(activeProjectId);
    final candidates = <ProjectTargetCandidate>[];
    for (final tp in progress.incompleteTargets) {
      final row = targetsById[tp.targetId];
      // A membership pointing at a deleted target is a data-integrity error,
      // but buildProgress already throws on that case before we get here, so a
      // null here would be a genuine race; surface it rather than swallow.
      if (row == null) {
        throw StateError(
          'Active project $activeProjectId references target ${tp.targetId}, '
          'which no longer exists in the catalog',
        );
      }
      candidates.add(
        ProjectTargetCandidate(
          targetId: tp.targetId,
          name: tp.targetName,
          raHours: tp.raHours,
          decDegrees: tp.decDegrees,
          minAltitudeDeg: row.minAltitude,
        ),
      );
    }
    return candidates;
  }

  // No active project: every catalog target with a configured-but-unmet goal.
  // We derive the unmet set from the integration-goal stack (the single source
  // of truth for accrued-vs-goal) keyed by target.
  final goalService = ref.read(integrationGoalServiceProvider);
  final goals = await goalService.listAll();
  if (goals.isEmpty) return const [];

  // Group goals by target and decide incompleteness: a target is incomplete if
  // ANY of its goals still has frames remaining. capturedFrameCount is the same
  // accrued-from-history primitive buildProgress uses, so the two paths agree.
  final goalsByTarget = <int, List<IntegrationGoal>>{};
  for (final goal in goals) {
    (goalsByTarget[goal.targetId] ??= <IntegrationGoal>[]).add(goal);
  }

  final candidates = <ProjectTargetCandidate>[];
  for (final entry in goalsByTarget.entries) {
    final targetId = entry.key;
    var incomplete = false;
    for (final goal in entry.value) {
      final captured = await goalService.capturedFrameCount(
        targetId: targetId,
        filter: goal.filter,
      );
      if (captured < goal.frameCount) {
        incomplete = true;
        break;
      }
    }
    if (!incomplete) continue;

    final row = targetsById[targetId];
    // A goal referencing a missing target is a data-integrity error — fail
    // loud rather than silently skip.
    if (row == null) {
      throw StateError(
        'Integration goal references target $targetId, which no longer exists '
        'in the catalog',
      );
    }
    candidates.add(
      ProjectTargetCandidate(
        targetId: targetId,
        name: row.name,
        raHours: row.ra,
        decDegrees: row.dec,
        minAltitudeDeg: row.minAltitude,
      ),
    );
  }
  return candidates;
}
