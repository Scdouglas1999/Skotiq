import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;

import 'depthlock_geometry.dart';
import 'depthlock_goal_editor.dart';
import 'depthlock_presentation.dart';
import 'depthlock_region_layer.dart';
import 'depthlock_selection.dart';

/// What the last attempt to turn a region into a goal had to say, or null.
///
/// Lives in a provider because the attempt is owned by one host mounted once
/// for the whole screen, while the message belongs on whichever surface the
/// operator is looking at.
final depthLockRegionErrorProvider = StateProvider<String?>((ref) => null);

/// True while a committed region is being turned into a definition.
final depthLockRegionBusyProvider = StateProvider<bool>((ref) => false);

/// Re-open the region tool on [goal]'s rectangles, projected onto whichever
/// canvas is in front of the operator.
///
/// The rectangles are stored on the sky, so they come back axis-aligned to the
/// canvas they are re-drawn on — the same thing that happens to any region
/// drawn there, since the tool only makes axis-aligned boxes.
void startDepthLockRegionEdit(WidgetRef ref, DepthLockGoal goal) {
  final selection = ref.read(depthLockActiveSelectionProvider);
  final geometry = selection.geometry;
  if (geometry == null) {
    ref.read(depthLockRegionErrorProvider.notifier).state =
        'The image on screen has no plate solve, so this goal\'s region '
        'cannot be shown on it. Open a solved sub of the same target.';
    return;
  }
  final measurement = goal.definition.measurement;
  final structure = _boundsOf(measurement.region, geometry);
  final background = _boundsOf(measurement.background, geometry);
  if (structure == null || background == null) {
    ref.read(depthLockRegionErrorProvider.notifier).state =
        'This goal\'s region does not fall on the image that is on screen. '
        'Open a frame of the target it was marked on.';
    return;
  }
  ref.read(depthLockRegionErrorProvider.notifier).state = null;
  ref
      .read(depthLockRegionDraftProvider.notifier)
      .load(structure: structure, background: background);
  ref.read(depthLockRegionEditTargetProvider.notifier).state = goal.id;
  ref.read(depthLockRegionToolActiveProvider.notifier).state = true;
}

Rect? _boundsOf(SkyRectangle rectangle, ReferenceGeometry geometry) {
  final corners = depthLockRectangleCorners(
    rectangle: rectangle,
    geometry: geometry,
  );
  if (corners == null || corners.isEmpty) return null;
  var bounds = Rect.fromPoints(corners.first, corners.first);
  for (final corner in corners.skip(1)) {
    bounds = bounds.expandToInclude(Rect.fromPoints(corner, corner));
  }
  return bounds;
}

/// Turns a finished region into a goal, wherever it was drawn.
///
/// Mounted exactly once for the Imaging screen rather than inside a panel: the
/// region tool works on two canvases and the DepthLock panel is only on one of
/// them, so a host that lived in the panel would miss every region marked on
/// the stack. It renders [child] unchanged and contributes no chrome of its
/// own.
class DepthLockRegionCommitHost extends ConsumerStatefulWidget {
  const DepthLockRegionCommitHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DepthLockRegionCommitHost> createState() =>
      _DepthLockRegionCommitHostState();
}

class _DepthLockRegionCommitHostState
    extends ConsumerState<DepthLockRegionCommitHost> {
  @override
  Widget build(BuildContext context) {
    ref.listen<int>(depthLockRegionCommitProvider, (previous, next) {
      if (previous != null && next > previous) _onRegionCommitted();
    });
    return widget.child;
  }

  Future<void> _onRegionCommitted() async {
    final selection = ref.read(depthLockActiveSelectionProvider);
    final draft = ref.read(depthLockRegionDraftProvider);
    final structure = draft.structure;
    final background = draft.background;
    final editTargetId = ref.read(depthLockRegionEditTargetProvider);
    if (selection.referencePath == null ||
        structure == null ||
        background == null) {
      return;
    }
    final DepthLockGoal? editTarget = editTargetId == null
        ? null
        : (ref.read(depthLockGoalsProvider).valueOrNull ??
                const <DepthLockGoal>[])
            .where((goal) => goal.id == editTargetId)
            .firstOrNull;

    ref.read(depthLockRegionBusyProvider.notifier).state = true;
    ref.read(depthLockRegionErrorProvider.notifier).state = null;
    try {
      final backend = ref.read(depthLockBackendProvider);
      var definition = await buildDepthLockGoalDefinition(
        backend: backend,
        referencePath: selection.referencePath!,
        structure: structure,
        background: background,
        fallbackWcs: selection.wcs,
        // The rectangles are in the pixels of whatever they were drawn on, so
        // that is the grid the reference has to be on.
        drawnOnSize: selection.imageSize,
        projectId: editTarget?.definition.projectId ??
            ref.read(activeProjectIdProvider)?.toString() ??
            '',
        targetId: editTarget?.definition.targetId ??
            await _targetId(selection.capturedImageId),
        profileId: editTarget?.definition.profileId ??
            ref.read(activeProfileProvider).valueOrNull?.id.toString() ??
            '',
        label: editTarget?.definition.label ??
            p.basenameWithoutExtension(selection.referencePath!),
      );
      if (editTarget != null) {
        definition = depthLockDefinitionWithNewRegion(
          previous: editTarget.definition,
          fresh: definition,
        );
      }
      final masters = await _matchMasters(definition);
      definition = definition.copyWith(
        darkPath: masters.dark?.path ?? definition.darkPath,
        flatPath: masters.flat?.path ?? definition.flatPath,
      );
      if (!mounted) return;
      ref.read(depthLockRegionBusyProvider.notifier).state = false;
      final goal = await DepthLockGoalEditor.show(
        context,
        initialDefinition: definition,
        existing: editTarget,
        filterChoices: ref.read(activeEquipmentProfileProvider)?.filterNames ??
            const <String>[],
        dark: masters.dark,
        flat: masters.flat,
      );
      if (goal == null || !mounted) return;
      // The region is now the goal's, not a draft: leaving it drawn would
      // invite a second goal over the same structure.
      cancelDepthLockRegionTool(ref);
    } catch (error) {
      if (!mounted) return;
      ref.read(depthLockRegionBusyProvider.notifier).state = false;
      ref.read(depthLockRegionErrorProvider.notifier).state =
          depthLockErrorMessage(error);
    }
  }

  /// The target the reference frame was filed under, as the string identity a
  /// goal stores. Empty when the frame is not attached to one — a goal is
  /// still legitimate, it just is not tied to a planned target.
  Future<String> _targetId(int? capturedImageId) async {
    if (capturedImageId == null) return '';
    final row = await ref.read(
      capturedImageByIdProvider(capturedImageId).future,
    );
    return row?.targetId?.toString() ?? '';
  }

  /// What the calibration library matches for this acquisition, described the
  /// way the editor shows it.
  Future<({DepthLockMasterChoice? dark, DepthLockMasterChoice? flat})>
      _matchMasters(DepthLockGoalDefinition definition) async {
    final acquisition = definition.acquisition;
    try {
      final matches = await ref.read(calibrationLibraryServiceProvider).match(
            LightFrameContext(
              gain: acquisition.gain,
              offset: acquisition.offset,
              exposureSeconds: acquisition.exposureSecs,
              temperature: acquisition.ccdTempC,
              filter: acquisition.filter,
              binX: acquisition.binX,
              binY: acquisition.binY,
            ),
          );
      // The library's own warnings (a hub not consulted, an unverified
      // dimension) are context, not the reason a master is missing. The
      // reason the operator needs is which acquisition nothing matched.
      final String unmatched = _describeUnmatched(acquisition);
      return (
        dark: _choice(matches.dark, 'No master dark in the library $unmatched'),
        flat: _choice(matches.flat, 'No master flat in the library $unmatched'),
      );
    } catch (error) {
      // A library that cannot answer is not a reason to refuse the goal — the
      // editor asks for the two files instead, and says why it is asking.
      final reason = depthLockErrorMessage(error);
      return (
        dark: DepthLockMasterChoice(path: '', unmatchedReason: reason),
        flat: DepthLockMasterChoice(path: '', unmatchedReason: reason),
      );
    }
  }

  static String _describeUnmatched(AcquisitionSettings acquisition) {
    final parts = <String>[
      acquisition.instrument,
      '${acquisition.exposureSecs.toStringAsFixed(acquisition.exposureSecs % 1 == 0 ? 0 : 1)} s',
      if (acquisition.gain != null) 'gain ${acquisition.gain}',
      if (acquisition.ccdTempC != null)
        '${acquisition.ccdTempC!.toStringAsFixed(0)} °C',
      'bin ${acquisition.binX}×${acquisition.binY}',
    ];
    return 'matches this sub (${parts.join(', ')}). Choose one.';
  }

  DepthLockMasterChoice _choice(CalibrationMatch? match, String? warning) {
    final path = match?.record.filePath;
    if (match == null || path == null || path.isEmpty) {
      return DepthLockMasterChoice(path: '', unmatchedReason: warning);
    }
    return DepthLockMasterChoice(
      path: path,
      summary: depthLockMasterSummary(match.record),
    );
  }
}
