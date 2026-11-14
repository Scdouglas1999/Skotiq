part of '../scheduler_provider.dart';

/// Normalized target row fed into candidate assembly — sourced from the local
/// DB on the host, or from the host's REST catalog on a remote slave. Keeping
/// a single shape lets the local and remote loads share one assembly path.
class _LoaderTarget {
  final int id;
  final String name;
  final double raHours;
  final double decDegrees;
  final int priority;
  final String? objectType;
  final String? notes;

  const _LoaderTarget({
    required this.id,
    required this.name,
    required this.raHours,
    required this.decDegrees,
    required this.priority,
    required this.objectType,
    required this.notes,
  });

  _LoaderTarget copyWithPriority(int newPriority) => _LoaderTarget(
    id: id,
    name: name,
    raHours: raHours,
    decDegrees: decDegrees,
    priority: newPriority,
    objectType: objectType,
    notes: notes,
  );

  bool get isMosaicTarget {
    final haystack = '$name ${objectType ?? ''} ${notes ?? ''}'.toLowerCase();
    return haystack.contains('mosaic');
  }
}

/// Source of candidate targets for the engine: assembles the latest target
/// rows, their integration goals + captured counts, their constraints, and
/// the equipment filter list.
class SchedulerCandidateLoader {
  final Ref ref;

  SchedulerCandidateLoader(this.ref);

  /// Assemble the candidate set.
  ///
  /// When [projectId] is non-null the candidate set is restricted to that
  /// planning project's targets: the catalog query is INNER-JOINed against
  /// `project_targets`, and each member's effective priority is the
  /// per-membership `priority_override` when present, falling back to the
  /// target's own global `priority`. When [projectId] is null the full catalog
  /// is loaded.
  ///
  /// Both modes assemble goals / counts / constraints / horizon and the
  /// effective-filter list the same way. Completed-goal rejection and
  /// remaining-need ranking happen downstream in the engine's `scoreCandidate`,
  /// so a fully-imaged member target drops out of tonight's rotation while
  /// remaining in the project.
  Future<List<SchedulerCandidate>> load({int? projectId}) async {
    final backendNotifier = ref.read(backendProvider.notifier);
    final backend = backendNotifier.currentBackend;
    void requireAuthority() {
      if (!backendNotifier.isCurrentBackend(backend)) {
        throw StateError(
          'Scheduler candidate load retired because the imaging backend changed',
        );
      }
    }

    // Snapshot equipment filters under the same backend authority as the
    // catalog. Reading this later, after remote awaits, could otherwise attach
    // the replacement host's filter wheel to the previous host's targets.
    final availableFilters = _availableFilters();
    final goalService = ref.read(integrationGoalServiceProvider);
    // Targets the operator removed from the queue. Read under the same
    // authority as the catalog: this is the difference between "removed" and
    // "goal-less", and a goal-less target is still an eligible free-form
    // candidate, so without it "Remove from scheduler" changes nothing the
    // autopilot can see.
    final removedTargetIds = await ref
        .read(schedulerQueueServiceProvider)
        .removedTargetIds();
    requireAuthority();

    // On a remote SLAVE the catalog/targets/constraints/horizons/project
    // membership all live in the HOST DB; the slave's local SQLite is empty.
    // Reading it would gate the autopilot preview with ZERO constraints and
    // ZERO custom horizons (silently wrong), and the project path's local
    // INNER JOIN would return no rows ("nothing eligible"). Source everything
    // from the host instead. goalService is already host-aware (above), so the
    // per-goal counts in the shared assembly loop are correct too.
    final hostTargets = ref.read(linkedHostImagingRecordsProvider);
    final hostPlanning = ref.read(linkedHostPlanningProvider);
    if (hostTargets != null && hostPlanning != null) {
      return _loadRemote(
        hostTargets: hostTargets,
        remote: hostPlanning,
        goalService: goalService,
        projectId: projectId,
        availableFilters: availableFilters,
        removedTargetIds: removedTargetIds,
        requireAuthority: requireAuthority,
      );
    }

    final db = ref.read(databaseProvider);

    final planning = db.planningDao;
    // In a project, the effective priority is the membership override when
    // set, else the target's own priority, and the engine sees that ranking.
    final targetRows = await planning.schedulerTargets(projectId: projectId);
    requireAuthority();

    // Pre-fetch all constraints + horizon profiles in two queries.
    final constraintRows = await planning.enabledTargetConstraints();
    requireAuthority();
    final horizonRows = await loadHorizonProfiles(db);
    requireAuthority();

    final horizonProfiles = <int, HorizonProfile>{};
    for (final hp in horizonRows) {
      horizonProfiles[hp.id!] = hp;
    }

    final constraintsByTarget = <int, List<TargetConstraint>>{};
    for (final row in constraintRows) {
      final tc = targetConstraintFromRow(row);
      constraintsByTarget.putIfAbsent(tc.targetId, () => []).add(tc);
    }

    final targets = targetRows
        .map(
          (row) => _LoaderTarget(
            id: row.id,
            name: row.name,
            raHours: row.ra,
            decDegrees: row.dec,
            priority: row.priority,
            objectType: row.objectType,
            notes: row.notes,
          ),
        )
        .toList();

    return _assembleCandidates(
      targets: targets,
      constraintsByTarget: constraintsByTarget,
      horizonProfiles: horizonProfiles,
      goalService: goalService,
      availableFilters: availableFilters,
      removedTargetIds: removedTargetIds,
      requireAuthority: requireAuthority,
    );
  }

  /// Remote-SLAVE candidate load: every input comes from the HOST over REST
  /// instead of the slave's empty local DB. Targets/constraints/horizons and
  /// (for the project path) the membership join are mirrored from the host so
  /// the autopilot preview gates with the SAME constraints/horizons/scope the
  /// operator configured on the master — not an un-gated, always-eligible set.
  Future<List<SchedulerCandidate>> _loadRemote({
    required HostImagingRecords hostTargets,
    required HostPlanningData remote,
    required IntegrationGoalService goalService,
    int? projectId,
    required List<String> availableFilters,
    required Set<int> removedTargetIds,
    required void Function() requireAuthority,
  }) async {
    // Host catalog rows, indexed by id.
    final rawTargets = await hostTargets.getAllTargets();
    requireAuthority();
    final byId = <int, _LoaderTarget>{};
    for (final json in rawTargets) {
      final id = json['id'] as int?;
      if (id == null) continue;
      byId[id] = _LoaderTarget(
        id: id,
        name: json['name'] as String? ?? 'Untitled target',
        raHours: (json['ra'] as num?)?.toDouble() ?? 0.0,
        decDegrees: (json['dec'] as num?)?.toDouble() ?? 0.0,
        priority: json['priority'] as int? ?? 5,
        objectType: json['objectType'] as String?,
        notes: json['notes'] as String?,
      );
    }

    final List<_LoaderTarget> targets;
    if (projectId != null) {
      // Project scope: the membership rows carry the per-project priority
      // override; fall back to the target's own priority when unset.
      final memberships = await remote.getProjectTargets(projectId);
      requireAuthority();
      final scoped = <_LoaderTarget>[];
      for (final m in memberships) {
        final base = byId[m.targetId];
        if (base == null) continue;
        scoped.add(base.copyWithPriority(m.priorityOverride ?? base.priority));
      }
      scoped.sort((a, b) {
        final byPriority = b.priority.compareTo(a.priority);
        return byPriority != 0 ? byPriority : a.name.compareTo(b.name);
      });
      targets = scoped;
    } else {
      targets = byId.values.toList()
        ..sort((a, b) {
          final byPriority = b.priority.compareTo(a.priority);
          return byPriority != 0 ? byPriority : a.name.compareTo(b.name);
        });
    }

    // Host constraints (enabled only, matching the local query) + horizons.
    final allConstraints = await remote.getTargetConstraints();
    requireAuthority();
    final constraintsByTarget = <int, List<TargetConstraint>>{};
    for (final tc in allConstraints) {
      if (!tc.enabled) continue;
      constraintsByTarget.putIfAbsent(tc.targetId, () => []).add(tc);
    }
    final horizonProfiles = <int, HorizonProfile>{};
    final remoteHorizons = await remote.getHorizonProfiles();
    requireAuthority();
    for (final hp in remoteHorizons) {
      if (hp.id != null) horizonProfiles[hp.id!] = hp;
    }

    return _assembleCandidates(
      targets: targets,
      constraintsByTarget: constraintsByTarget,
      horizonProfiles: horizonProfiles,
      goalService: goalService,
      availableFilters: availableFilters,
      removedTargetIds: removedTargetIds,
      requireAuthority: requireAuthority,
    );
  }

  /// Shared candidate assembly used by both the local and remote loads. Pure
  /// over its inputs — only the goal counts come from [goalService] (already
  /// host-aware), so this is identical on host and slave.
  Future<List<SchedulerCandidate>> _assembleCandidates({
    required List<_LoaderTarget> targets,
    required Map<int, List<TargetConstraint>> constraintsByTarget,
    required Map<int, HorizonProfile> horizonProfiles,
    required IntegrationGoalService goalService,
    required List<String> availableFilters,
    required Set<int> removedTargetIds,
    required void Function() requireAuthority,
  }) async {
    final out = <SchedulerCandidate>[];
    for (final target in targets) {
      final id = target.id;
      // A removed target is not a candidate at all — not a candidate that
      // scores badly. Dropping it here is what makes it disappear from the
      // queue table as well, since that table renders the decision's scored
      // candidates.
      if (removedTargetIds.contains(id)) continue;
      final goals = await goalService.listForTarget(id);
      requireAuthority();
      final counts = <int>[];
      for (final g in goals) {
        counts.add(
          await goalService.capturedFrameCount(targetId: id, filter: g.filter),
        );
        requireAuthority();
      }
      final cs = constraintsByTarget[id] ?? const <TargetConstraint>[];
      // Only attach horizon profiles a constraint actually references —
      // saves the engine from copying the whole catalogue.
      final usedProfiles = <int, HorizonProfile>{};
      for (final ct in cs) {
        if (ct.kind == TargetConstraintKind.customHorizon &&
            ct.customHorizonId != null) {
          final hp = horizonProfiles[ct.customHorizonId];
          if (hp == null) {
            throw StateError(
              'Target $id references horizon profile ${ct.customHorizonId} which does not exist',
            );
          }
          usedProfiles[ct.customHorizonId!] = hp;
        }
      }

      out.add(
        SchedulerCandidate(
          targetId: id,
          name: target.name,
          raHours: target.raHours,
          decDegrees: target.decDegrees,
          userPriority: target.priority,
          goals: goals,
          capturedCounts: counts,
          constraints: cs,
          horizonProfiles: usedProfiles,
          availableFilters: availableFilters,
          isMosaicTarget: target.isMosaicTarget,
        ),
      );
    }
    requireAuthority();
    return out;
  }

  List<String> _availableFilters() {
    // Pull from the active equipment profile via the existing provider.
    //
    // A profile with no named filters is the NORMAL state of an OSC/DSLR rig
    // with no wheel, not a misconfiguration. Handing the engine a bare empty
    // list made every filter containment check false, so an unfiltered goal
    // (filter == smartNightUnfilteredName, the empty string) scored 0 in
    // _filterCoverageFactor and its frames were dropped from the dispatched
    // sequence. smartNightPlanningFilters yields [''] for that rig — the same
    // one-unfiltered-row contract Smart Night plans against — so admission,
    // scoring and sequence building all agree.
    try {
      final profile = ref.read(activeEquipmentProfileProvider);
      if (profile != null) {
        return smartNightPlanningFilters(profile.filterNames);
      }
    } catch (_) {
      // activeEquipmentProfileProvider may not yet be initialized in a
      // background tick; that's fine — fall through to an empty list and
      // the engine will treat goals as un-imageable until the operator
      // sets a profile.
    }
    return const <String>[];
  }
}

final schedulerCandidateLoaderProvider = Provider<SchedulerCandidateLoader>((
  ref,
) {
  return SchedulerCandidateLoader(ref);
});
