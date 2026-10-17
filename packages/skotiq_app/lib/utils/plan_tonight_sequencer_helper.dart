import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:uuid/uuid.dart';
import '../widgets/auto_build_options_dialog.dart';

/// Build a multi-filter Smart Night sequence for a Plan Tonight target.
Future<SingleTargetSequenceResult> buildPlanTonightTargetSequence({
  required WidgetRef ref,
  required TargetSuggestion target,
  required SessionOptimizationPlan plan,
  bool includeSessionPreamble = false,
  AutoBuildOptions? options,
}) async {
  return _buildPlanTonightTargetSequenceCore(
    ref: ref,
    target: target,
    includeSessionPreamble: includeSessionPreamble,
    options: options,
  );
}

/// Build a multi-filter sequence from a target suggestion without an optimizer
/// plan (planetarium / annotation paths). Uses default Smart Night budget and
/// tonight's dark window.
Future<SingleTargetSequenceResult>
    buildPlanTonightTargetSequenceFromSuggestion({
  required WidgetRef ref,
  required TargetSuggestion target,
  bool includeSessionPreamble = false,
  AutoBuildOptions? options,
}) async {
  return _buildPlanTonightTargetSequenceCore(
    ref: ref,
    target: target,
    includeSessionPreamble: includeSessionPreamble,
    options: options,
  );
}

/// Build a multi-filter sequence from the currently framed target.
///
/// This is the Framing screen counterpart to
/// [buildPlanTonightTargetSequenceFromSuggestion]. It preserves the framing
/// rotation on the emitted [TargetHeaderNode] so "frame first, sequence
/// second" does not lose the user's composition.
Future<SingleTargetSequenceResult> buildPlanTonightTargetSequenceFromFraming({
  required WidgetRef ref,
  required FramingTarget target,
  TargetSuggestion? sourceSuggestion,
  double? rotationDegrees,
  bool includeSessionPreamble = false,
  AutoBuildOptions? options,
}) async {
  final suggestion = sourceSuggestion == null
      ? await framingTargetSuggestion(ref: ref, target: target)
      : sourceSuggestion.copyWith(
          targetName: target.name,
          catalogId: target.catalogId ?? sourceSuggestion.catalogId,
          raHours: target.raHours,
          decDegrees: target.decDegrees,
          objectType: target.objectType ??
              sourceSuggestion.objectType ??
              target.type?.displayName,
          magnitude: target.magnitude ?? sourceSuggestion.magnitude,
          sizeArcmin: target.sizeArcmin ?? sourceSuggestion.sizeArcmin,
          constellation: target.constellation ?? sourceSuggestion.constellation,
        );
  final result = await buildPlanTonightTargetSequenceFromSuggestion(
    ref: ref,
    target: suggestion,
    includeSessionPreamble: includeSessionPreamble,
    options: options,
  );
  return _withFramingRotation(result, rotationDegrees);
}

Future<SingleTargetSequenceResult> _buildPlanTonightTargetSequenceCore({
  required WidgetRef ref,
  required TargetSuggestion target,
  double? integrationBudgetHours,
  bool includeSessionPreamble = false,
  AutoBuildOptions? options,
}) async {
  final profile = ref.read(activeEquipmentProfileProvider);
  if (profile == null) {
    throw const SmartNightBuildException(
      'No equipment profile selected — configure a profile before building '
      'a sequence.',
    );
  }

  // An empty filter list is the normal state of an OSC rig with no wheel —
  // Smart Night plans a single unfiltered row for it. A wheel that IS
  // connected but reports no slots is a real fault, so that one still fails
  // loud rather than silently planning unfiltered frames on a rig that has
  // filters in the light path.
  final filters = ref.read(effectiveFiltersProvider);
  final wheel = ref.read(filterWheelStateProvider);
  if (filters.isEmpty &&
      wheel.connectionState == DeviceConnectionState.connected) {
    throw const SmartNightBuildException(
      'The connected filter wheel reports no filter slots. Reconnect the '
      'wheel or name its filters on the equipment profile before building '
      'a sequence.',
    );
  }

  final settings = await ref.read(appSettingsProvider.future);
  final exposureContext =
      await ref.read(smartNightExposureContextProvider.future);

  final window = SmartNightService(
    suggestionService: ref.read(targetSuggestionServiceProvider),
    logging: ref.read(loggingServiceProvider),
  ).calculateWindow(
    latitudeDeg: settings.latitude,
    longitudeDeg: settings.longitude,
  );

  final end = switch (options?.end) {
    AutoBuildEnd.astronomical => window.twilight.astronomicalDawn,
    AutoBuildEnd.nautical => window.twilight.nauticalDawn,
    AutoBuildEnd.civil => window.twilight.civilDawn,
    AutoBuildEnd.sunrise => window.twilight.sunrise,
    _ => window.end,
  };
  if (end == null) {
    throw const SmartNightBuildException(
        'The selected dawn does not occur at this location tonight. Choose a different end condition.');
  }
  final now = DateTime.now();
  final start = now.isAfter(window.start) ? now : window.start;
  if (!start.isBefore(end)) {
    throw const SmartNightBuildException('Tonight’s imaging window has ended.');
  }
  final fillWindow = options != null && options.end != AutoBuildEnd.integration;
  integrationBudgetHours = options == null
      ? integrationBudgetHours
      : (fillWindow ? end.difference(start).inSeconds / 3600 : options.hours);

  // The reviewed recipe owns its filters and exposure lengths. Saved
  // integration goals are used only by the automatic planning path.
  final integrationGoals = options == null
      ? await ref
          .read(integrationGoalServiceProvider)
          .progressForTarget(target.targetId)
      : null;

  await ref.read(hardwarePresetsServiceProvider.notifier).loaded;
  final camera = ref.read(cameraStateProvider);
  final connected = camera.connectionState == DeviceConnectionState.connected;
  final captureProfile =
      connected ? profile.copyWith(cameraName: camera.deviceName) : profile;
  final smartNightSettings = SmartNightSettings(
    gainOverride: options?.gain,
    offsetOverride: options?.offset,
    useExposurePresets: options != null && !options.useCalculator,
    defaultFrameDurationSecs: options?.exposures ??
        const SmartNightSettings().defaultFrameDurationSecs,
    // The site minimum altitude belongs to the site, not to this builder.
    // Leaving it at the SmartNightSettings default meant this path refused
    // targets at 27 deg ("no usable imaging window ... at min altitude 30")
    // that the scheduler on the very same screen was scoring as eligible
    // against its own 25 deg.
    minAltitudeDeg: ref.read(siteMinimumAltitudeDegProvider),
    defaultIntegrationBudgetHours: integrationBudgetHours ??
        const SmartNightSettings().defaultIntegrationBudgetHours,
    targetSnr: settings.smartNightTargetSnr,
    subExposureCeilingSecs: settings.smartNightSubExposureCeilingSecs,
    subExposureFloorSecs: settings.smartNightSubExposureFloorSecs,
    coolDownTargetC: profile.defaultCoolingTemp ?? -10.0,
    hasCoverCalibrator: profile.coverCalibratorId != null &&
        profile.coverCalibratorId!.trim().isNotEmpty,
  );

  return SmartNightService(
    suggestionService: ref.read(targetSuggestionServiceProvider),
    logging: ref.read(loggingServiceProvider),
    cameraLibrary: ref.read(hardwarePresetsServiceProvider),
  ).buildSingleTargetSequence(
    profile: captureProfile,
    suggestion: target,
    windowStart: start,
    windowEnd: end,
    availableFilters: filters,
    exposureContext: exposureContext,
    settings: smartNightSettings,
    strategy: options?.strategy,
    fillWindow: fillWindow,
    includeSessionShutdown: options?.shutdown,
    integrationBudgetHours: integrationBudgetHours,
    integrationGoalProgress: integrationGoals,
    includeSessionPreamble: includeSessionPreamble,
  );
}

/// Build a [TargetSuggestion] from a framed target.
Future<TargetSuggestion> framingTargetSuggestion({
  required WidgetRef ref,
  required FramingTarget target,
}) {
  return catalogTargetSuggestion(
    ref: ref,
    targetName: target.name,
    raHours: target.raHours,
    decDegrees: target.decDegrees,
    catalogId: target.catalogId,
    objectType: target.objectType ?? target.type?.displayName,
    magnitude: target.magnitude,
    sizeArcmin: target.sizeArcmin,
    constellation: target.constellation,
  );
}

/// Build a [TargetSuggestion] from catalog / planetarium object coordinates.
Future<TargetSuggestion> catalogTargetSuggestion({
  required WidgetRef ref,
  required String targetName,
  required double raHours,
  required double decDegrees,
  String? catalogId,
  String? objectType,
  double? magnitude,
  double? sizeArcmin,
  String? constellation,
  ObjectVisibility? visibility,
}) async {
  final settings = await ref.read(appSettingsProvider.future);
  if (!settings.hasObserverLocation) {
    throw const SmartNightBuildException(
      'No observer location set — configure latitude and longitude in Settings '
      'before building a sequence from the sky chart.',
    );
  }

  final window = SmartNightService(
    suggestionService: ref.read(targetSuggestionServiceProvider),
    logging: ref.read(loggingServiceProvider),
  ).calculateWindow(
    latitudeDeg: settings.latitude,
    longitudeDeg: settings.longitude,
  );

  final objectVisibility = visibility ??
      AstronomyCalculations.calculateObjectVisibility(
        raDeg: raHours * 15.0,
        decDeg: decDegrees,
        // window.start is the dark window's opening INSTANT, which at the west
        // edge of a timezone in mid-summer falls after local midnight. Handing
        // that to a noon-to-noon scan selected the next night — the same slip
        // that made "Best Targets Tonight" a sidereal day out.
        date: AstronomyCalculations.nightDateOf(window.start),
        latitudeDeg: settings.latitude,
        longitudeDeg: settings.longitude,
        minAltitude: ref.read(siteMinimumAltitudeDegProvider),
      );

  final altAz = AstronomyCalculations.objectAltAz(
    raDeg: raHours * 15.0,
    decDeg: decDegrees,
    dt: window.start,
    latitudeDeg: settings.latitude,
    longitudeDeg: settings.longitude,
  );

  final (moonRa, moonDec, _) = AstronomyCalculations.moonPosition(window.start);
  final moonDistance = AstronomyCalculations.angularSeparation(
    ra1Deg: raHours * 15.0,
    dec1Deg: decDegrees,
    ra2Deg: moonRa,
    dec2Deg: moonDec,
  );

  final hoursAbove = objectVisibility.durationAboveHorizon?.inMinutes != null
      ? objectVisibility.durationAboveHorizon!.inMinutes / 60.0
      : null;

  // Ensure a host/local library row exists so integration goals and progress
  // use a stable numeric id (not a synthetic hash fallback).
  final libraryTarget =
      await ref.read(targetLibraryServiceProvider).ensureCatalogTarget(
            targetName: targetName,
            raHours: raHours,
            decDegrees: decDegrees,
            catalogId: catalogId,
            objectType: objectType,
            magnitude: magnitude,
            sizeArcmin: sizeArcmin,
            constellation: constellation,
          );
  final targetId = libraryTarget.id;

  return TargetSuggestion(
    targetId: targetId,
    targetName: targetName,
    catalogId: catalogId,
    raHours: raHours,
    decDegrees: decDegrees,
    totalScore: 70,
    objectType: objectType,
    magnitude: magnitude,
    sizeArcmin: sizeArcmin,
    constellation: constellation,
    visibility: TargetVisibilityInfo(
      currentAltitude: altAz.$1,
      currentAzimuth: altAz.$2,
      transitAltitude: objectVisibility.transitAltitude,
      riseTime: objectVisibility.riseTime,
      transitTime: objectVisibility.transitTime,
      setTime: objectVisibility.setTime,
      isCircumpolar: objectVisibility.isCircumpolar,
      neverRises: objectVisibility.neverRises,
      airmass: AstronomyCalculations.airmass(altAz.$1),
      moonDistance: moonDistance,
      peakAltitude: objectVisibility.transitAltitude ?? altAz.$1,
      peakAltitudeTime: objectVisibility.transitTime,
      hoursAboveMinAlt: hoursAbove,
    ),
  );
}

/// Build and load a Plan Tonight multi-filter sequence into the editor.
Future<bool> addPlanTonightTargetToSequencer({
  required BuildContext context,
  required WidgetRef ref,
  required TargetSuggestion target,
  bool replaceSequence = false,
  bool includeSessionPreamble = false,
}) async {
  try {
    final options = await showAutoBuildOptions(context, ref, target);
    if (options == null || !context.mounted) return false;
    final built = await buildPlanTonightTargetSequenceFromSuggestion(
      ref: ref,
      target: target,
      options: options,
      includeSessionPreamble: includeSessionPreamble,
    );
    if (!context.mounted) return false;
    return loadPlanTonightSequenceIntoEditor(
      context: context,
      ref: ref,
      result: built,
      replaceSequence: replaceSequence,
    );
  } on SmartNightBuildException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
    return false;
  }
}

/// Build and load a framed target using the central Smart Night exposure math.
///
/// When the framing screen has mosaic mode enabled with a generated panel
/// grid (`FramingState.mosaicEnabled` && `mosaicPanels.isNotEmpty`), this
/// dispatches to [_addFramedMosaicToSequencer] instead of the single-target
/// path, so a mosaic designed in the framing screen reaches the sequencer as a
/// mosaic rather than as its central target alone.
///
/// The mosaic path applies ONE filter per panel — the Smart Night-derived
/// single-filter recommendation from [smartNightMosaicExposureSettings],
/// matching `MosaicWizardDialog`. Per-panel multi-filter composition would need
/// a multi-filter mosaic exposure model in skotiq_core.
Future<bool> addFramedTargetToSequencer({
  required BuildContext context,
  required WidgetRef ref,
  required FramingTarget target,
  TargetSuggestion? sourceSuggestion,
  double? rotationDegrees,
  bool replaceSequence = false,
  bool includeSessionPreamble = false,
}) async {
  final framingState = ref.read(framingProvider);

  // Mosaic dispatch — only when the user has actually generated panels.
  if (framingState.mosaicEnabled && framingState.mosaicPanels.isNotEmpty) {
    return _addFramedMosaicToSequencer(
      context: context,
      ref: ref,
      framingState: framingState,
      target: target,
      rotationDegrees: rotationDegrees,
      replaceSequence: replaceSequence,
    );
  }

  try {
    final suggestion = sourceSuggestion?.copyWith(
            raHours: target.raHours, decDegrees: target.decDegrees) ??
        await framingTargetSuggestion(ref: ref, target: target);
    if (!context.mounted) return false;
    final options = await showAutoBuildOptions(context, ref, suggestion);
    if (options == null || !context.mounted) return false;
    final built = await buildPlanTonightTargetSequenceFromFraming(
      ref: ref,
      target: target,
      options: options,
      sourceSuggestion: sourceSuggestion,
      rotationDegrees: rotationDegrees,
      includeSessionPreamble: includeSessionPreamble,
    );
    if (!context.mounted) return false;
    return loadPlanTonightSequenceIntoEditor(
      context: context,
      ref: ref,
      result: built,
      replaceSequence: replaceSequence,
    );
  } on SmartNightBuildException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
    return false;
  }
}

/// Resolve the per-panel FOV in arcminutes from framing state.
///
/// Custom equipment is the most authoritative source. When the user has
/// configured custom equipment in the framing screen we use its computed
/// FOV directly. Otherwise we fall back to the active equipment profile
/// via `framingFOVProvider`. The preview FOV (`previewFovDegrees`) is
/// explicitly NOT used: it controls how much sky context the survey
/// preview shows, not the actual sensor footprint.
Future<({double widthArcmin, double heightArcmin})?> _resolvePanelFovArcmin({
  required WidgetRef ref,
  required FramingState framingState,
}) async {
  if (framingState.useCustomEquipment && framingState.customEquipment != null) {
    final eq = framingState.customEquipment!;
    return (
      widthArcmin: eq.fovWidthDeg * 60.0,
      heightArcmin: eq.fovHeightDeg * 60.0,
    );
  }

  final result = await ref.read(framingFOVProvider.future);
  final eq = result.equipment;
  if (eq == null) return null;
  return (
    widthArcmin: eq.fovWidthDeg * 60.0,
    heightArcmin: eq.fovHeightDeg * 60.0,
  );
}

/// Build a [MosaicConfig] from framing-screen state for the sequencer.
///
/// Pure function — does not touch riverpod or context. Tests can hit this
/// directly to verify the framing-UI knobs (columns/rows/overlap%) map to
/// the service-layer geometry (panelWidthArcmin/panelHeightArcmin/...).
MosaicConfig buildFramingMosaicConfig({
  required FramingTarget target,
  required FramingState framingState,
  required double panelWidthArcmin,
  required double panelHeightArcmin,
  double? rotationOverrideDegrees,
}) {
  final framingMosaicConfig = framingState.mosaicConfig;
  return MosaicConfig(
    centerRa: target.raHours,
    centerDec: target.decDegrees,
    panelWidthArcmin: panelWidthArcmin,
    panelHeightArcmin: panelHeightArcmin,
    overlapPercent: framingMosaicConfig.overlapPercent,
    rotation: rotationOverrideDegrees ?? framingState.rotation,
    panelsHorizontal: framingMosaicConfig.columns,
    panelsVertical: framingMosaicConfig.rows,
  );
}

/// Construct the mosaic name that the framing → sequencer handoff uses for
/// a given target. Exposed for tests + diagnostic UIs.
String framingMosaicNameFor(FramingTarget target) {
  return target.name.isNotEmpty
      ? '${target.name} Mosaic'
      : 'Mosaic ${target.raHours.toStringAsFixed(2)}h '
          '${target.decDegrees.toStringAsFixed(1)}°';
}

/// Build a mosaic [Sequence] from the framing screen's mosaic configuration
/// and load it into the editor.
///
/// Reuses [MosaicService.createMosaicSequence] — the same code path the
/// in-sequencer Mosaic Wizard uses — so per-panel `TargetHeaderNode`
/// metadata (mosaic name + panel index/row/col/total) flows into FITS
/// headers identically across both entry points.
Future<bool> _addFramedMosaicToSequencer({
  required BuildContext context,
  required WidgetRef ref,
  required FramingState framingState,
  required FramingTarget target,
  double? rotationDegrees,
  bool replaceSequence = false,
}) async {
  final fov = await _resolvePanelFovArcmin(
    ref: ref,
    framingState: framingState,
  );
  if (!context.mounted) return false;
  if (fov == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Cannot build mosaic: equipment FOV is unavailable. Configure a '
          'camera + focal length in your active profile (or use custom '
          'equipment in framing) and try again.',
        ),
      ),
    );
    return false;
  }

  final config = buildFramingMosaicConfig(
    target: target,
    framingState: framingState,
    panelWidthArcmin: fov.widthArcmin,
    panelHeightArcmin: fov.heightArcmin,
    rotationOverrideDegrees: rotationDegrees,
  );

  const mosaicService = MosaicService();
  final validation = mosaicService.validateMosaic(config);
  if (!validation.isValid) {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Mosaic configuration invalid: ${validation.errors.join("; ")}',
        ),
      ),
    );
    return false;
  }

  final exposureContext =
      ref.read(smartNightExposureContextProvider).valueOrNull;
  final exposure = smartNightMosaicExposureSettings(exposureContext);

  final options = MosaicSequenceOptions(
    serpentineOrdering: framingState.mosaicConfig.serpentine,
    centerAfterSlew: true,
    autofocusPerPanel: false,
    // W1 no-daylight/altitude gate: default each panel's minAltitude to the
    // Smart Night floor so every panel TargetHeader carries a
    // `start_when AltitudeAbove` wait (serialized as `min_altitude`). Without
    // this the headless mosaic path gated on altitude but the framing →
    // sequencer path did not, so a panel could start imaging while still below
    // the horizon floor. STRENGTHENS the gate; it never weakens the Dart Sun
    // gate (W1) or the W5 weather gate.
    minAltitude: ref.read(siteMinimumAltitudeDegProvider),
  );

  final mosaicName = framingMosaicNameFor(target);

  final nodes = mosaicService.createMosaicSequence(
    mosaicName: mosaicName,
    config: config,
    exposure: exposure,
    options: options,
  );

  return _loadMosaicNodesIntoEditor(
    context: context,
    ref: ref,
    mosaicName: mosaicName,
    nodes: nodes,
    replaceSequence: replaceSequence,
  );
}

/// Wrap a mosaic node graph into the current sequence (or replace it).
Future<bool> _loadMosaicNodesIntoEditor({
  required BuildContext context,
  required WidgetRef ref,
  required String mosaicName,
  required Map<String, SequenceNode> nodes,
  required bool replaceSequence,
}) async {
  final notifier = ref.read(currentSequenceProvider.notifier);

  // The mosaic node graph has a single InstructionSetNode at its root
  // whose children are the per-panel TargetHeaderNodes.
  final rootNode = nodes.values.firstWhere(
    (n) => n is InstructionSetNode && n.parentId == null,
    orElse: () => throw StateError(
      'MosaicService.createMosaicSequence did not produce a root '
      'InstructionSetNode — refusing to load a malformed mosaic into the '
      'sequencer.',
    ),
  );

  Future<bool> loadReplacing() async {
    try {
      final sequence = Sequence.create(
        name: mosaicName,
        nodes: nodes,
        rootNodeId: rootNode.id,
      );
      notifier.loadSequence(sequence, discardUnsaved: true);
      return true;
    } on SequenceLockedException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
      return false;
    }
  }

  if (replaceSequence || ref.read(currentSequenceProvider) == null) {
    return loadReplacing();
  }

  // Append: add each top-level target group under the current sequence's
  // root, then descend each subtree. Mirrors MosaicWizardDialog.
  try {
    final currentSeq = ref.read(currentSequenceProvider);
    if (currentSeq == null) {
      return loadReplacing();
    }
    final parentForChildren = currentSeq.rootNodeId;
    if (parentForChildren == null) {
      return loadReplacing();
    }

    // MosaicService builds descendants before their parents and leaves the
    // top-level TargetHeaderNodes with a null parent (the root owns them via
    // childIds). Calling addNode in map order therefore attached exposures and
    // loops directly to the editor root, then duplicated target IDs when the
    // generated root was encountered. Normalize the root relationship and use
    // the editor's atomic graph merge, which re-keys the complete subtree while
    // preserving every parent/child edge.
    final normalizedNodes = Map<String, SequenceNode>.from(nodes);
    for (final childId in rootNode.childIds) {
      final child = normalizedNodes[childId];
      if (child == null) {
        throw StateError(
          'Mosaic root references missing panel node $childId',
        );
      }
      normalizedNodes[childId] = child.copyWith(parentId: rootNode.id);
    }
    notifier.mergeTemplateNodes(
      templateNodes: normalizedNodes,
      templateRootId: rootNode.id,
      targetId: parentForChildren,
    );
    return true;
  } on NoActiveSequenceException {
    return loadReplacing();
  } on SequenceLockedException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
    return false;
  }
}

String dsoTypeLabel(DsoType type) => type.displayName;

/// Extract optional catalog metadata from any [CelestialObject].
({
  String? catalogId,
  String? objectType,
  double? sizeArcmin,
  String? constellation
}) celestialObjectMetadata(CelestialObject object) {
  if (object is DeepSkyObject) {
    return (
      catalogId:
          object.catalogIds.isNotEmpty ? object.catalogIds.first : object.name,
      objectType: dsoTypeLabel(object.type),
      sizeArcmin: object.sizeArcMin,
      constellation: object.constellation,
    );
  }
  if (object is Star) {
    return (
      catalogId:
          object.catalogIds.isNotEmpty ? object.catalogIds.first : object.name,
      objectType: 'Star',
      sizeArcmin: null,
      constellation: object.constellation,
    );
  }
  return (
    catalogId: object.name,
    objectType: null,
    sizeArcmin: null,
    constellation: null,
  );
}

String annotationObjectTypeLabel(ObjectType type) {
  switch (type) {
    case ObjectType.galaxy:
      return 'Galaxy';
    case ObjectType.nebula:
      return 'Nebula';
    case ObjectType.planetaryNebula:
      return 'Planetary Nebula';
    case ObjectType.starCluster:
      return 'Open Cluster';
    case ObjectType.star:
      return 'Star';
    case ObjectType.doubleStar:
      return 'Double Star';
    case ObjectType.asterism:
      return 'Asterism';
    case ObjectType.unknown:
      return 'Deep Sky Object';
  }
}

SingleTargetSequenceResult _withFramingRotation(
  SingleTargetSequenceResult result,
  double? rotationDegrees,
) {
  if (rotationDegrees == null) return result;
  final targetHeader =
      result.sequence.nodes.values.whereType<TargetHeaderNode>().firstOrNull;
  if (targetHeader == null) return result;

  final nodes = Map<String, SequenceNode>.from(result.sequence.nodes);
  nodes[targetHeader.id] = targetHeader.copyWith(rotation: rotationDegrees);
  return SingleTargetSequenceResult(
    sequence: result.sequence.copyWith(nodes: nodes),
    strategy: result.strategy,
    filterPlans: result.filterPlans,
    plannedTarget: result.plannedTarget,
  );
}

/// Load a built Plan Tonight sequence into the editor.
///
/// When [replaceSequence] is true the entire editor sequence is replaced
/// (planner "Review in Sequencer"). When false the target sub-tree is
/// appended to the current sequence (dashboard "Add to Sequencer").
Future<bool> loadPlanTonightSequenceIntoEditor({
  required BuildContext context,
  required WidgetRef ref,
  required SingleTargetSequenceResult result,
  required bool replaceSequence,
}) async {
  final notifier = ref.read(currentSequenceProvider.notifier);
  final templateHeader =
      result.sequence.nodes.values.whereType<TargetHeaderNode>().firstOrNull;
  if (templateHeader == null) return false;

  Future<bool> loadReplacing() async {
    try {
      notifier.loadSequence(result.sequence, discardUnsaved: false);
      return true;
    } on UnsavedChangesException catch (e) {
      if (!context.mounted) return false;
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard unsaved changes?'),
          content: ConstrainedBox(
            constraints: AdaptiveDialogConstraints.hybrid(
              ctx,
              designMaxWidth: 440,
            ),
            child: Text('"${e.currentSequenceName}" has unsaved changes. '
                'Open the loaded sequence anyway?'),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            SkotiqButton(
              label: 'Discard and open',
              variant: ButtonVariant.primary,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );
      if (discard != true) return false;
      notifier.loadSequence(result.sequence, discardUnsaved: true);
      return true;
    } on SequenceLockedException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
      return false;
    }
  }

  if (replaceSequence || ref.read(currentSequenceProvider) == null) {
    return loadReplacing();
  }

  final newHeaderId = const Uuid().v4();
  final newHeader = templateHeader.copyWith(
    id: newHeaderId,
    childIds: const [],
  );

  try {
    notifier.addTargetHeader(newHeader);
    notifier.mergeTemplateNodes(
      templateNodes: result.sequence.nodes,
      templateRootId: templateHeader.id,
      targetId: newHeaderId,
    );
    return true;
  } on NoActiveSequenceException {
    return loadReplacing();
  } on SequenceLockedException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
    return false;
  }
}

String planTonightSequenceSummary(SingleTargetSequenceResult result) {
  final filters = result.filterPlans
      .map((p) => smartNightFilterLabel(p.filterName))
      .join(', ');
  final totalFrames = result.filterPlans.fold<int>(
    0,
    (sum, plan) => sum + plan.count,
  );
  return '$filters ($totalFrames frames)';
}
