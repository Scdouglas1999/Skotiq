// Output-path helpers, controller args, providers and the capture launcher.
part of '../mosaic_project_controller.dart';

/// Per-panel master FITS base path under the DURABLE [artifactsBaseDir]:
/// `<base>/project_<id>/panel_<index>.fits`. The integration service derives the
/// preview `.png` + rejection map from it by extension swap.
String mosaicPanelOutputPath(
    String artifactsBaseDir, MosaicProjectPanel panel) {
  return p.join(
    artifactsBaseDir,
    'project_${panel.projectId}',
    'panel_${panel.panelIndex}.fits',
  );
}

/// Per-project stitched-mosaic artifacts directory under the DURABLE
/// [artifactsBaseDir]: `<base>/project_<id>`.
String mosaicStitchOutputDirectory(
  String artifactsBaseDir,
  MosaicProject project,
) {
  return p.join(artifactsBaseDir, 'project_${project.id}');
}

/// Arguments to construct a [MosaicProjectController] via its family provider —
/// the project id plus the DURABLE artifacts base directory the on-disk paths
/// are derived from (the app resolves `<applicationSupport>/skotiq_mosaic`;
/// tests pass a temp dir).
///
/// CONTRACT — every field here must be VALUE-comparable. These args are the
/// family key: Riverpod caches one controller per distinct key, and the screen
/// rebuilds these args on every `build`. A closure is only ever equal to
/// itself, so one on these args mints a new key every frame → a new controller
/// → a new `load()` → a rebuild → an unbounded loop that pins the CPU and
/// leaves the screen spinning. Never put a closure (or any identity-compared
/// object) here.
class MosaicProjectControllerArgs {
  /// The `mosaic_projects.id` to review.
  final int projectId;

  /// The durable directory panel masters and stitched artifacts live under.
  final String artifactsBaseDir;

  /// Integration settings the per-panel integration runs with.
  final IntegrationSettings integrationSettings;

  const MosaicProjectControllerArgs({
    required this.projectId,
    required this.artifactsBaseDir,
    this.integrationSettings = IntegrationSettings.defaults,
  });

  @override
  bool operator ==(Object other) =>
      other is MosaicProjectControllerArgs &&
      other.projectId == projectId &&
      other.artifactsBaseDir == artifactsBaseDir &&
      other.integrationSettings == integrationSettings;

  @override
  int get hashCode => Object.hash(
        projectId,
        artifactsBaseDir,
        integrationSettings,
      );
}

/// Family provider for the per-project controller. Keyed on
/// [MosaicProjectControllerArgs] so two screens reviewing different projects get
/// independent controllers; the path builders ride on the args.
final mosaicProjectControllerProvider = StateNotifierProvider.family<
    MosaicProjectController, MosaicProjectState, MosaicProjectControllerArgs>(
  (ref, args) {
    return MosaicProjectController(
      projectId: args.projectId,
      projectsDao: ref.watch(mosaicProjectsDaoProvider),
      panelsDao: ref.watch(mosaicPanelsDaoProvider),
      mastersDao: ref.watch(integratedMastersDaoProvider),
      service: ref.watch(mosaicProjectServiceProvider),
      collaborativeService: ref.watch(collaborativeMosaicServiceProvider),
      // The hub-aware service is always wired, so gate the collaborative
      // affordances on whether a hub is actually configured/signed-in. Reuses
      // the same signal the Constellation screens use; unknown-while-loading
      // resolves false so the actions fail closed rather than enabled-then-fail.
      hubConfigured:
          ref.watch(constellationConfiguredProvider).valueOrNull ?? false,
      // Derived from the value-comparable base dir on the args, NOT taken as
      // closures on the args themselves (see the contract note there).
      panelOutputPathBuilder: (panel) =>
          mosaicPanelOutputPath(args.artifactsBaseDir, panel),
      stitchOutputDirectory: (project) =>
          mosaicStitchOutputDirectory(args.artifactsBaseDir, project),
      captureLauncher: buildMosaicCaptureLauncher(ref),
      integrationSettings: args.integrationSettings,
      // A hub mutation here invalidates the shared Collaborative Sky listings,
      // which are cached for the container's life. Without it the Collaborate
      // surface keeps rendering the answer it got BEFORE this project was
      // published/claimed.
      onHubStateChanged: () => invalidateCollaborativeMosaicState(ref),
    );
  },
);

/// Lists every durable mosaic project (newest first) for the projects list
/// screen. An `autoDispose` `FutureProvider` over [MosaicProjectsDao] so it
/// re-reads whenever the list screen is re-opened (a project created elsewhere
/// then shows on revisit); the screen also invalidates it on pull-to-refresh.
final mosaicProjectsListProvider =
    FutureProvider.autoDispose<List<MosaicProject>>((ref) async {
  return ref.watch(mosaicProjectsDaoProvider).listAll();
});

/// Build the real [MosaicCaptureLauncher] that
/// [MosaicProjectService.startCapture] hands the resolved
/// [MosaicCaptureRequest]: it rebuilds the project's mosaic sequence via the
/// canonical [MosaicService.createMosaicSequence] (so per-panel FITS provenance
/// matches the wizard / framing entry points), stamps each panel
/// `TargetHeaderNode.catalogTargetId` from the request's per-panel target map
/// (so a panel's subs attribute to that panel's distinct target), loads it into
/// the editor, and starts the executor.
///
/// Returns null when no equipment FOV is resolvable — capture cannot be planned
/// without the rig footprint, and surfacing "unavailable" beats building a
/// geometrically wrong mosaic. The controller then reports a clear error rather
/// than silently launching a bad run.
MosaicCaptureLauncher buildMosaicCaptureLauncher(Ref ref) {
  return (MosaicCaptureRequest request) async {
    final panels = request.panels;
    if (panels.isEmpty) {
      throw StateError('mosaic capture has no panels');
    }

    // Per-panel rig footprint (arcmin) from the active equipment profile (or
    // custom framing equipment). Without it the panel geometry is undefined.
    final fov = await ref.read(framingFOVProvider.future);
    final equipment = fov.equipment;
    if (equipment == null) {
      throw StateError(
        'cannot launch mosaic capture: no equipment FOV available — configure '
        'a camera + focal length in your active profile and try again',
      );
    }

    // Project center = mean of the stored panel centers (the same point the
    // grid was generated about), so regenerating the panels reproduces the
    // exact per-panel centers already persisted.
    var ra = 0.0;
    var dec = 0.0;
    for (final panel in panels) {
      ra += panel.centerRa;
      dec += panel.centerDec;
    }
    ra /= panels.length;
    dec /= panels.length;

    final project = request.project;
    final config = MosaicConfig(
      centerRa: ra,
      centerDec: dec,
      panelWidthArcmin: equipment.fovWidthDeg * 60.0,
      panelHeightArcmin: equipment.fovHeightDeg * 60.0,
      overlapPercent: project.overlapPct,
      rotation: project.positionAngleDeg,
      panelsHorizontal: project.cols,
      panelsVertical: project.rows,
    );

    final exposure = smartNightMosaicExposureSettings(
      ref.read(smartNightExposureContextProvider).valueOrNull,
    );

    final options = MosaicSequenceOptions(
      serpentineOrdering: true,
      centerAfterSlew: true,
      autofocusPerPanel: false,
      // W1 STRENGTHEN (never weaken): default each panel's minAltitude to the
      // Smart Night floor so every panel TargetHeader carries an altitude gate
      // — matching the wizard / headless mosaic paths. This ADDS the
      // no-daylight/altitude gate to the durable-project capture sequence; it
      // does not touch the live Dart Sun gate (W1) or the fail-closed weather
      // gate (W5).
      minAltitude: const SmartNightSettings().minAltitudeDeg,
    );

    final mosaicName = project.name.isEmpty
        ? 'Mosaic ${ra.toStringAsFixed(2)}h ${dec.toStringAsFixed(1)}deg'
        : project.name;

    const service = MosaicService();
    final nodes = service.createMosaicSequence(
      mosaicName: mosaicName,
      config: config,
      exposure: exposure,
      options: options,
      // CONTRACT (capture-wiring <-> project-service): pass the per-panel target
      // map so each panel's TargetHeaderNode is stamped with its DISTINCT
      // catalogTargetId — a panel's captured subs then attribute to that panel's
      // own target (the precise isolation per-panel integration relies on).
      panelTargetId: (panelIndex) => request.panelTargetIds[panelIndex],
    );

    // Reuse the canonical "wrap nodes + load into editor" path so the durable
    // project capture is byte-identical to the wizard/framing sequence shape.
    final rootNode = nodes.values.firstWhere(
      (n) => n is InstructionSetNode && n.parentId == null,
      orElse: () => throw StateError(
        'MosaicService.createMosaicSequence did not produce a root '
        'InstructionSetNode — refusing to launch a malformed mosaic.',
      ),
    );
    final sequence = Sequence.create(
      name: mosaicName,
      nodes: nodes,
      rootNodeId: rootNode.id,
    );

    // Hand the editor slot to the mosaic owner instead of clobbering unsaved
    // manual work: takeOwnership stashes the operator's sequence and flips the
    // owner so a later stop restores it.
    ref
        .read(currentSequenceProvider.notifier)
        .takeOwnership(sequence, ActivePlanOwner.mosaic);
    await ref.read(sequenceExecutorProvider).start();
  };
}
