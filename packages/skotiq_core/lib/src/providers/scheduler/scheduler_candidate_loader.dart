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
    if (backend is NetworkBackend) {
      return _loadRemote(
        backend: backend,
        goalService: goalService,
        projectId: projectId,
        availableFilters: availableFilters,
        removedTargetIds: removedTargetIds,
        requireAuthority: requireAuthority,
      );
    }

    final db = ref.read(databaseProvider);

    // Make sure all three scheduler tables exist before we read them. The
    // integration-goal service already ensures its own schema; we ensure
    // the other two here using the shared DDL constants.
    await db.customStatement(targetConstraintsSchemaSql);
    requireAuthority();
    await db.customStatement(targetConstraintsTargetIndexSql);
    requireAuthority();
    await db.customStatement(horizonProfilesSchemaSql);
    requireAuthority();

    final List<QueryRow> targetRows;
    if (projectId != null) {
      // Defensive: the planner tables are created by the v40 migration, but a
      // fresh database built without migrations (or a scheduler tick that runs
      // before the planner UI has touched ProjectService) must still find them.
      // Re-running the DDL is a no-op on an existing schema (`IF NOT EXISTS`).
      // These constants are the canonical project DDL, owned by ProjectService.
      await db.customStatement(projectsSchemaSql);
      requireAuthority();
      await db.customStatement(projectTargetsSchemaSql);
      requireAuthority();
      await db.customStatement(projectTargetsProjectIndexSql);
      requireAuthority();

      // Restrict to the project's members. The effective priority is the
      // membership override when set, else the target's own priority — and we
      // order by that effective value so the engine sees project-scoped ranking.
      targetRows = await db
          .customSelect(
            'SELECT t.id, t.name, t.ra, t.dec, '
            'COALESCE(pt.priority_override, t.priority) AS priority, '
            't.object_type, t.notes '
            'FROM targets t '
            'INNER JOIN project_targets pt ON pt.target_id = t.id '
            'WHERE pt.project_id = ? '
            'ORDER BY priority DESC, t.name ASC',
            variables: [Variable.withInt(projectId)],
          )
          .get();
      requireAuthority();
    } else {
      targetRows = await db
          .customSelect(
            'SELECT id, name, ra, dec, priority, object_type, notes FROM targets ORDER BY priority DESC, name ASC',
          )
          .get();
      requireAuthority();
    }

    // Pre-fetch all constraints + horizon profiles in two queries.
    final constraintRows = await db
        .customSelect(
          'SELECT id, target_id, kind, payload_json, enabled FROM target_constraints WHERE enabled = 1',
        )
        .get();
    requireAuthority();
    final horizonRows = await db
        .customSelect('SELECT id, name, samples_json FROM horizon_profiles')
        .get();
    requireAuthority();

    final horizonProfiles = <int, HorizonProfile>{};
    for (final row in horizonRows) {
      final hp = HorizonProfile.fromRow(
        id: row.read<int>('id'),
        name: row.read<String>('name'),
        samplesJson: row.read<String>('samples_json'),
      );
      horizonProfiles[hp.id!] = hp;
    }

    final constraintsByTarget = <int, List<TargetConstraint>>{};
    for (final row in constraintRows) {
      final tc = TargetConstraint.fromRow(
        id: row.read<int>('id'),
        targetId: row.read<int>('target_id'),
        kindName: row.read<String>('kind'),
        payloadJson: row.read<String>('payload_json'),
        enabled: row.read<int>('enabled') == 1,
      );
      constraintsByTarget.putIfAbsent(tc.targetId, () => []).add(tc);
    }

    final targets = targetRows
        .map(
          (row) => _LoaderTarget(
            id: row.read<int>('id'),
            name: row.read<String>('name'),
            raHours: row.read<double>('ra'),
            decDegrees: row.read<double>('dec'),
            priority: row.read<int>('priority'),
            objectType: row.readNullable<String>('object_type'),
            notes: row.readNullable<String>('notes'),
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
    required NetworkBackend backend,
    required IntegrationGoalService goalService,
    int? projectId,
    required List<String> availableFilters,
    required Set<int> removedTargetIds,
    required void Function() requireAuthority,
  }) async {
    // Host catalog rows, indexed by id.
    final rawTargets = await backend.getAllTargets();
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
      final memberships = await backend.getProjectTargets(projectId);
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
    final allConstraints = await backend.getTargetConstraints();
    requireAuthority();
    final constraintsByTarget = <int, List<TargetConstraint>>{};
    for (final tc in allConstraints) {
      if (!tc.enabled) continue;
      constraintsByTarget.putIfAbsent(tc.targetId, () => []).add(tc);
    }
    final horizonProfiles = <int, HorizonProfile>{};
    final remoteHorizons = await backend.getHorizonProfiles();
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
