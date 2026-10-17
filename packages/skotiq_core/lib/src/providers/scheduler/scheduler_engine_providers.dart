part of '../scheduler_provider.dart';

/// Bridges the engine's "I picked a target" decision to the existing
/// SequenceExecutor by loading the generated Sequence and starting it.
class _ExecutorSequenceSink
    implements SchedulerSequenceSink, SchedulerRunOwnership {
  final Ref _ref;

  // Capture the notifier eagerly at construction (where ref.read is legal).
  // releaseSequenceOwnership() runs from SchedulerEngine.dispose(), which fires
  // inside the schedulerEngineProvider onDispose — at that point ref functions
  // are forbidden (the provider's dependency changed before it rebuilt), so we
  // must NOT call _ref.read there. currentSequenceProvider is a global (non-
  // autoDispose) StateNotifierProvider, so this notifier instance is stable for
  // the container's lifetime and safe to cache.
  final CurrentSequenceNotifier _currentSequence;

  _ExecutorSequenceSink(this._ref)
    : _currentSequence = _ref.read(currentSequenceProvider.notifier);

  @override
  Future<void> dispatchSequence(Sequence sequence) async {
    // The scheduler dispatches generated sequences as part of its own autopilot
    // loop. The editor slot is handed to the autopilot owner rather than
    // overwritten, so the operator's unsaved in-editor work survives:
    // takeOwnership STASHES the manual sequence on the first
    // hand-off and flips the owner to autopilot. stopSequence() restores it. A
    // re-dispatch while the autopilot already owns the slot (target switch) just
    // swaps the loaded plan without disturbing the stashed manual sequence.
    _currentSequence.takeOwnership(sequence, ActivePlanOwner.autopilot);
    final executor = _ref.read(sequenceExecutorProvider);
    await executor.start();
  }

  @override
  Future<void> pauseSequence() async {
    final executor = _ref.read(sequenceExecutorProvider);
    await executor.pause();
  }

  @override
  Future<void> resumeSequence() async {
    final executor = _ref.read(sequenceExecutorProvider);
    await executor.resume();
  }

  @override
  Future<void> stopSequence() async {
    final executor = _ref.read(sequenceExecutorProvider);
    // The autopilot is not the operator: the origin keeps its stop from
    // being recorded as (and rendered as) "Stopped by request".
    await executor.stop(origin: 'scheduler');
  }

  @override
  bool ownsRun(String sequenceId) {
    // Three facts have to hold for the autopilot's run to still be the active
    // one, and each of them is a way the operator can take the rig back:
    //   * the editor slot is still owned by the autopilot (a manual load or a
    //     release flips it back to `manual`),
    //   * the loaded plan is the very sequence we dispatched (a manual Start
    //     loads a different one — ids are per-dispatch UUIDs), and
    //   * that plan is actually executing (a finished/stopped run is nobody's
    //     to stop).
    if (_currentSequence.activeOwner != ActivePlanOwner.autopilot) return false;
    final loaded = _ref.read(currentSequenceProvider);
    if (loaded == null || loaded.id != sequenceId) return false;
    switch (_ref.read(sequenceExecutionStateProvider)) {
      case SequenceExecutionState.running:
      case SequenceExecutionState.paused:
      case SequenceExecutionState.recovering:
        return true;
      case SequenceExecutionState.idle:
      case SequenceExecutionState.stopping:
      case SequenceExecutionState.stopFailed:
      case SequenceExecutionState.completed:
      case SequenceExecutionState.failed:
      case SequenceExecutionState.finalizing:
      case SequenceExecutionState.cleanupFailed:
        return false;
    }
  }

  @override
  bool get hasActiveRun {
    // Deliberately NOT "is the plan the autopilot's": the question is whether
    // the executor is driving hardware for ANYONE. `stopping` / `finalizing` /
    // the failed-stop states count as active — a run whose teardown is still in
    // flight must not be dispatched over or parked out from under.
    switch (_ref.read(sequenceExecutionStateProvider)) {
      case SequenceExecutionState.running:
      case SequenceExecutionState.paused:
      case SequenceExecutionState.recovering:
      case SequenceExecutionState.stopping:
      case SequenceExecutionState.stopFailed:
      case SequenceExecutionState.finalizing:
      case SequenceExecutionState.cleanupFailed:
        return true;
      case SequenceExecutionState.idle:
      case SequenceExecutionState.completed:
      case SequenceExecutionState.failed:
        return false;
    }
  }

  @override
  SchedulerRunEnding endingFor(String sequenceId) {
    // Somebody took the editor slot or loaded a different plan: whatever the
    // executor is doing now, the autopilot's run ended by a human's hand.
    if (_currentSequence.activeOwner != ActivePlanOwner.autopilot) {
      return SchedulerRunEnding.stoppedByOperator;
    }
    final loaded = _ref.read(currentSequenceProvider);
    if (loaded == null || loaded.id != sequenceId) {
      return SchedulerRunEnding.stoppedByOperator;
    }
    switch (_ref.read(sequenceExecutionStateProvider)) {
      case SequenceExecutionState.completed:
        return SchedulerRunEnding.completed;
      case SequenceExecutionState.failed:
        return SchedulerRunEnding.failed;
      case SequenceExecutionState.idle:
        // The plan is still ours and still loaded, but nothing is executing:
        // the run was STOPPED by somebody outside the engine. WHO matters:
        // only a human's stop should pause the autopilot; a safety abort
        // (weather, dome, disk) is the system's doing, and pausing on it
        // would let one passing cloud end an unattended night — the
        // engine's own safety gating already refuses to dispatch into
        // unsafe conditions. The executor remembers its last run's end
        // origin; anything it cannot attribute stays conservative and asks
        // the human.
        final endOrigin = _ref.read(sequenceExecutorProvider).lastRunEndOrigin;
        if (endOrigin == 'safety') {
          return SchedulerRunEnding.failed;
        }
        return SchedulerRunEnding.stoppedByOperator;
      case SequenceExecutionState.running:
      case SequenceExecutionState.paused:
      case SequenceExecutionState.recovering:
      case SequenceExecutionState.stopping:
      case SequenceExecutionState.stopFailed:
      case SequenceExecutionState.finalizing:
      case SequenceExecutionState.cleanupFailed:
        // Still in flight or still tearing down: no verdict yet.
        return SchedulerRunEnding.unknown;
    }
  }

  @override
  Future<void> releaseSequenceOwnership() async {
    // Autopilot disengaged: restore manual ownership and the operator's stashed
    // unsaved sequence (a no-op if the autopilot never owned the slot). Uses the
    // cached notifier — this runs during schedulerEngineProvider disposal where
    // ref.read would throw "_didChangeDependency".
    _currentSequence.releaseOwnership();
  }

  @override
  Future<void> parkForEndOfNight() async {
    // End of night: park the mount so it stops tracking into the ground at
    // dawn, and notify the operator. We route through the shared
    // SafeRigService so this uses the same fail-closed, loudly-erroring park
    // path as the weather and low-disk watchdogs (pause sequence -> park mount,
    // with a CRITICAL notification summarizing what happened). We intentionally
    // do NOT close the dome/cover here: end-of-night is not a weather event,
    // and the operator's morning flats workflow may still need the optics open.
    //
    // SafeRigService throws a SafeRigException when a step fails (after
    // attempting every step). Let it propagate to the engine's evaluation
    // lifecycle: a swallowed dawn-park failure leaves the mount tracking past
    // sunrise with nothing said.
    final safeRig = _ref.read(safeRigServiceProvider);
    await safeRig.safeTheRig(
      reason: 'End of observing night — parking the mount',
      park: true,
      closeDome: false,
      closeCover: false,
    );
  }
}

/// The single engine instance for the app.
final schedulerEngineProvider = Provider<SchedulerEngine>((ref) {
  final settingsAsync = ref.read(appSettingsProvider);
  final settings = settingsAsync.valueOrNull;
  final lat = settings?.latitude ?? 0.0;
  final lng = settings?.longitude ?? 0.0;
  // Hydrate the operator-tuned scoring config so tuned weights, minimum
  // altitude, and hysteresis survive an app restart. Loading is a one-shot
  // future; slider edits update the live engine in place rather than
  // invalidating this, so a running engine is not rebuilt mid-session.
  final persistedAsync = ref.read(schedulerPersistedConfigProvider);
  final persistedConfig =
      persistedAsync.valueOrNull ?? SchedulerConfig.defaults;
  // Why: route the scheduler's current-time reads through the user's
  // configured clock so window evaluations, scoring, and meridian-factor
  // calculations all reflect the operator's chosen timezone.
  //
  // Two separate things, and they must not be conflated. The engine wants a
  // real instant for ephemeris (`SchedulerEngine` does
  // `now.toUtc().add(site.localOffset)`), and it wants the *site's* offset to
  // decide whether "image between 22:00 and 04:00 local" is satisfied.
  // `clock.now` is a zone rendering, not an instant, and
  // `DateTime.now().timeZoneOffset` is the laptop's offset, not the
  // observatory's — either substitution evaluates a remote operator's time
  // windows in the wrong zone.
  final clock = ref.read(clockProvider);
  final localOffset = clock.utcOffset;

  // Build a candidate loader bound to a specific active-project scope. When
  // [activeId] is null the loader runs unfiltered (the full catalog — current
  // behavior for non-project users); when it is set, the candidate set is
  // restricted to that project's members. We capture [activeId] by value so a
  // reload triggered later still queries the scope the engine was configured
  // with, rather than re-reading a moving provider value mid-tick.
  Future<List<SchedulerCandidate>> Function() loaderFor(int? activeId) =>
      () =>
          ref.read(schedulerCandidateLoaderProvider).load(projectId: activeId);

  // Read (not watch) the initial scope: watching activeProjectIdProvider here
  // would rebuild the whole engine on every project switch and lose its
  // running state. Instead we ref.listen below and swap the loader in place,
  // which preserves the engine (and its run/pause status) across switches.
  final initialActiveId = ref.read(activeProjectIdProvider);

  final engine = SchedulerEngine(
    site: SchedulerSite(
      latitudeDegrees: lat,
      longitudeDegrees: lng,
      localOffset: localOffset,
    ),
    config: persistedConfig,
    sequenceSink: _ExecutorSequenceSink(ref),
    candidateLoader: loaderFor(initialActiveId),
    triggerStream: ref.read(schedulerTriggerStreamProvider),
    clock: clock.nowUtc,
    // Without this the engine's diagnostics exist only in `dart:developer`,
    // which a shipping build routes nowhere — the on-disk log is Rust-only and
    // the in-app Logs viewer reads LoggingService's ring.
    logSink: schedulerLogSinkFor(ref.read(loggingServiceProvider)),
  );

  // Hydrate a late settings/config read in place. Watching an async provider
  // here would dispose and recreate the engine on completion, losing run/pause
  // state and any target currently under scheduler control.
  ref.listen<AsyncValue<AppSettingsState>>(appSettingsProvider, (
    previous,
    next,
  ) {
    final value = next.valueOrNull;
    if (value == null) return;
    final nextSite = SchedulerSite(
      latitudeDegrees: value.latitude,
      longitudeDegrees: value.longitude,
      // The zone belongs to the clock listener below, not here. Re-reading
      // `clockProvider` at this point returns the pre-change clock — Riverpod
      // has not flushed it yet — so a Timezone edit would be compared against
      // itself, look unchanged, and leave the engine on the old offset.
      localOffset: engine.site.localOffset,
    );
    final currentSite = engine.site;
    if (nextSite.latitudeDegrees == currentSite.latitudeDegrees &&
        nextSite.longitudeDegrees == currentSite.longitudeDegrees &&
        nextSite.localOffset == currentSite.localOffset) {
      return;
    }
    engine.updateSite(nextSite);
    engine.requestReevaluation(reason: 'observer location changed');
  });
  // Settings → Location → Timezone decides what "22:00 local" means to a
  // time-window constraint. Nothing propagated it before: the site was built
  // once from the laptop's offset, so a remote operator's windows opened and
  // closed on their own evening rather than the observatory's.
  ref.listen<Clock>(clockProvider, (previous, next) {
    if (next.utcOffset == engine.site.localOffset) return;
    engine.updateSite(
      SchedulerSite(
        latitudeDegrees: engine.site.latitudeDegrees,
        longitudeDegrees: engine.site.longitudeDegrees,
        localOffset: next.utcOffset,
      ),
    );
    engine.requestReevaluation(reason: 'site timezone changed');
  });
  ref.listen<AsyncValue<SchedulerConfig>>(schedulerPersistedConfigProvider, (
    previous,
    next,
  ) {
    final value = next.valueOrNull;
    if (value == null ||
        ref.read(schedulerConfigUserDirtyProvider) ||
        value == engine.config) {
      return;
    }
    engine.updateConfig(value);
  });

  // Re-scope (and immediately re-evaluate) whenever the active project changes
  // without tearing down the engine. The auto-reeval provider also pokes the
  // engine on this same change, but re-setting the loader here is what makes
  // that re-evaluation pull from the new scope — the two are complementary.
  ref.listen<int?>(activeProjectIdProvider, (previous, next) {
    if (previous == next) return;
    engine.setCandidateLoader(loaderFor(next));
    engine.requestReevaluation(reason: 'active project changed');
  });

  ref.onDispose(() => engine.dispose());
  return engine;
});

/// One-shot authority gate for every operation that can evaluate or start the
/// unattended scheduler.
///
/// [schedulerEngineProvider] is synchronous because status listeners must
/// retain one stable engine instance, which means it can be constructed with
/// `(0, 0)` and factory scoring defaults while persisted settings are still
/// loading — enough for a fast preview/start to dispatch the wrong target.
/// This provider waits for both authoritative inputs before exposing the
/// engine and hydrates that same stable instance in place.
///
/// Reads are deliberately one-shot. Once an engine is ready, a later transient
/// settings refresh must not hide Pause/Stop or revoke control of an already
/// running scheduler. Callers can invalidate this provider together with the
/// failed input providers to retry a cold-start failure.
final schedulerEngineReadyProvider = FutureProvider<SchedulerEngine>((
  ref,
) async {
  final settingsFuture = ref.read(appSettingsProvider.future);
  final configFuture = ref.read(schedulerPersistedConfigProvider.future);
  final settings = await settingsFuture;
  final persistedConfig = await configFuture;
  final engine = ref.watch(schedulerEngineProvider);

  engine.updateSite(
    SchedulerSite(
      latitudeDegrees: settings.latitude,
      longitudeDegrees: settings.longitude,
      // The ready gate hydrates the site AFTER construction, so taking the
      // host's offset here would silently overwrite the observatory's on every
      // cold start — the same defect as the constructor's, one call site later.
      localOffset: ref.read(clockProvider).utcOffset,
    ),
  );
  if (!ref.read(schedulerConfigUserDirtyProvider)) {
    engine.updateConfig(persistedConfig);
  }
  return engine;
});

/// Side-effect provider that subscribes to the three "candidate inputs"
/// (target catalog rows, integration goals, target constraints) and pokes
/// the engine via `requestReevaluation()` whenever any of them changes.
///
/// The engine's internal debounce coalesces bursts (a goal upsert and a
/// constraint edit that arrive in the same microtask trigger ONE eval).
/// Must be `.watch`ed from the app shell (or any always-mounted Consumer)
/// so the listeners stay live for the lifetime of the scheduler engine.
final schedulerAutoReevalProvider = Provider<void>((ref) {
  // Starting the authority future here keeps the scheduler warm for the app
  // shell without constructing a default-config/default-site engine early.
  final engine = ref.watch(schedulerEngineReadyProvider).valueOrNull;
  if (engine == null) return;

  ref.listen<AsyncValue<List<ndb.Target>>>(allDbTargetsProvider, (
    previous,
    next,
  ) {
    // Only react once we have data, and only after the very first
    // emission (initial load is the cold-start, not a "change").
    if (previous == null || !previous.hasValue) return;
    if (!next.hasValue) return;
    engine.requestReevaluation(reason: 'targets table changed');
  });

  ref.listen<AsyncValue<List<IntegrationGoal>>>(
    integrationGoalsStreamProvider,
    (previous, next) {
      if (previous == null || !previous.hasValue) return;
      if (!next.hasValue) return;
      engine.requestReevaluation(reason: 'integration goals changed');
    },
  );

  ref.listen<AsyncValue<List<TargetConstraint>>>(
    targetConstraintsStreamProvider,
    (previous, next) {
      if (previous == null || !previous.hasValue) return;
      if (!next.hasValue) return;
      engine.requestReevaluation(reason: 'target constraints changed');
    },
  );

  // Switching the active project must re-pick tonight's targets immediately so
  // the operator sees the new campaign's rotation without waiting for the next
  // scheduled tick. The loader was already re-scoped in schedulerEngineProvider
  // for this same transition; the engine's internal debounce coalesces this
  // poke with that one into a single evaluation.
  ref.listen<int?>(activeProjectIdProvider, (previous, next) {
    if (previous == next) return;
    engine.requestReevaluation(reason: 'active project changed');
  });

  // Project membership changes (adding/removing a target, editing a priority
  // override) change which targets — and at what priority — the active project
  // contributes, so re-evaluate. projectListProvider re-emits on every
  // ProjectService mutation (it bridges watchChanges → re-list), which covers
  // membership edits as well as project CRUD. As above, only react after the
  // initial emission so the cold-start load is not treated as a change.
  ref.listen<AsyncValue<List<Project>>>(projectListProvider, (previous, next) {
    if (previous == null || !previous.hasValue) return;
    if (!next.hasValue) return;
    engine.requestReevaluation(reason: 'project membership changed');
  });
});
