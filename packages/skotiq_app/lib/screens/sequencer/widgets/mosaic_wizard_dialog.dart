// Mosaic Wizard, powered by the planetarium's mosaic planner.
//
// The visual planner draws a grid of camera-FOV-shaped panels over a
// stylised sky background. The user can:
//   * drag the centre of the mosaic to reposition it
//   * use +/- buttons (or the "Advanced" panel) to change the grid
//     dimensions
//   * drag a slider to set rotation; the on-screen grid follows the
//     drag in real time
//   * click any panel to disable / re-enable it (useful when a corner
//     is occluded by trees in the user's view)
//
// The generated `MosaicConfig` shape is identical to the one produced
// by the earlier text-only wizard, so the executor and resume logic
// don't change.
//
// The mosaic-resume banner remains at the top of the dialog — see
// `_buildResumeBanner` below.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart' as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';

import 'package:go_router/go_router.dart';

import '../../../utils/snackbar_helper.dart';
import '../../../widgets/gated_action.dart';
import '../../../utils/authority_bound_dialog.dart';
import 'mosaic_wizard_dialog/mosaic_project_creation_controller.dart';
part 'mosaic_wizard_dialog/config_controls.dart';
part 'mosaic_wizard_dialog/panel_position.dart';
part 'mosaic_wizard_dialog/visual_planner.dart';
part 'mosaic_wizard_dialog/painters.dart';

part 'mosaic_wizard_dialog/wizard_logic.dart';

class MosaicWizardDialog extends ConsumerStatefulWidget {
  final double? initialRa;
  final double? initialDec;

  const MosaicWizardDialog({
    this.initialRa,
    this.initialDec,
    super.key,
  });

  @override
  ConsumerState<MosaicWizardDialog> createState() => _MosaicWizardDialogState();
}

/// Where the wizard's panel size came from.
enum _PanelSizeSource {
  /// Neither the rig nor the user has supplied one — the wizard must not
  /// quote a panel size or build anything from it.
  unknown,

  /// Derived from the active profile's focal length + the connected camera's
  /// sensor geometry (the same inputs the framing box uses).
  measured,

  /// Typed into the Advanced section by the user.
  user,
}

MosaicExposureSettings mosaicWizardExposureSettingsForContext(
  SmartNightExposureContext? exposureContext,
) =>
    smartNightMosaicExposureSettings(exposureContext);

class _MosaicWizardDialogState extends ConsumerState<MosaicWizardDialog> {
  late double _centerRa;
  late double _centerDec;

  /// One panel = one camera field. Seeded from the rig in [initState]; until
  /// then these are a PLACEHOLDER — 60' × 40' is nobody's camera, just the
  /// field initialiser. [_panelSizeSource] records where the numbers came from
  /// so the UI can say "unknown" and the build actions can refuse, rather than
  /// planning a mosaic from an invented field of view.
  double _panelWidthArcmin = 60.0;
  double _panelHeightArcmin = 40.0;
  _PanelSizeSource _panelSizeSource = _PanelSizeSource.unknown;

  /// Which of the two dimensions the user has actually supplied.
  ///
  /// A dimension is known only when it was measured from the rig or typed by
  /// the user. Tracked per dimension: one shared flag makes typing a WIDTH
  /// declare the whole panel size known, which fills the height from the
  /// placeholder and unlocks the footer actions on half-invented geometry.
  bool _userSuppliedWidth = false;
  bool _userSuppliedHeight = false;

  bool get _panelWidthKnown =>
      _panelSizeSource == _PanelSizeSource.measured || _userSuppliedWidth;
  bool get _panelHeightKnown =>
      _panelSizeSource == _PanelSizeSource.measured || _userSuppliedHeight;
  bool get _panelSizeKnown => _panelWidthKnown && _panelHeightKnown;
  double _overlapPercent = 10.0;
  double _rotation = 0.0;
  int _panelsHorizontal = 3;
  int _panelsVertical = 3;
  bool _advancedExpanded = false;

  /// Multi-filter plan. When [_multiFilterEnabled] is false (the default,
  /// simple path) the wizard images each panel with the Smart-Night
  /// single-filter recommendation exactly as before. When the user enables it,
  /// every panel is imaged through each entry of [_filterRows] in order, and
  /// the built sequence + time/exposure estimates use that per-filter plan.
  bool _multiFilterEnabled = false;

  /// The per-filter exposure plan, edited in the Filters card. Seeded lazily on
  /// first enable from the active profile's filters (or a single "Light" row)
  /// so the user starts from something sensible rather than an empty list.
  final List<_MosaicFilterRow> _filterRows = <_MosaicFilterRow>[];

  /// Grid cells the user has disabled by tapping, keyed by (row, col) rather
  /// than flat index. Keying by position means a grid resize drops only the
  /// cells that genuinely no longer exist (row/col out of range) instead of
  /// silently re-pointing a flat index at a different physical panel. The
  /// canonical recipe still generates every panel; disabled cells are skipped
  /// when the sequence is built. This lets users drop the corner panel that
  /// intersects with a tree without rebuilding the grid.
  final Set<({int row, int col})> _disabledPanels = <({int row, int col})>{};

  /// Holds the resumable checkpoint info when an interrupted mosaic
  /// sequence is detected. `null` while loading and when no mosaic
  /// checkpoint exists.
  CheckpointInfo? _resumableMosaicCheckpoint;
  bool _isCreatingProject = false;
  String? _checkpointAction;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  int _authorityGeneration = 0;

  bool get _isBusy => _isCreatingProject || _checkpointAction != null;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        _authorityGeneration++;
        closeAuthorityBoundDialog(context);
      },
    );
    _centerRa = widget.initialRa ?? 0.0;
    _centerDec = widget.initialDec ?? 0.0;
    // Seed the panel size from the rig: focal length (profile) + sensor
    // geometry (connected camera). `fieldOfView` is null unless BOTH are
    // known, which is exactly when we must admit we don't know.
    final fov = ref.read(opticalConfigProvider)?.fieldOfView;
    if (fov != null && fov.$1 > 0 && fov.$2 > 0) {
      _panelWidthArcmin = fov.$1 * 60.0;
      _panelHeightArcmin = fov.$2 * 60.0;
      _panelSizeSource = _PanelSizeSource.measured;
    }
    // Start the checkpoint probe AFTER the first frame, never inline in
    // initState. Its error path calls `context.showErrorSnackBar`, which reads
    // an inherited Theme — and when the backend throws before the first `await`
    // suspension (a disconnected/erroring backend does exactly that), that
    // catch runs while initState is still on the stack, tripping
    // "dependOnInheritedWidgetOfExactType() was called before
    // initState() completed" and taking the whole dialog down instead of
    // showing a snackbar. The probe only decides whether to show a resume
    // banner, so a frame's delay costs nothing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_probeForInterruptedMosaic());
    });
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  bool _isCurrentAuthority(SkotiqBackend backend, int generation) =>
      mounted &&
      generation == _authorityGeneration &&
      identical(ref.read(backendProvider), backend);

  /// Memoised spherical panel geometry (centre/row/col, WITHOUT the
  /// disabled overlay). Recomputed only when a geometry input changes, since
  /// [build] runs [_calculatePanels] on every frame and the planner does real
  /// spherical trig per panel.
  List<_PanelPosition>? _cachedGeometry;
  String? _cachedGeometryKey;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final backend = ref.watch(backendProvider);
    final isRemote = backend is NetworkBackend;
    final isDisconnected = backend is DisconnectedBackend;
    final canCreateProject = !isRemote && !isDisconnected;
    final panels = _calculatePanels();
    final smartExposure = mosaicWizardExposureSettingsForContext(
      ref.watch(smartNightExposureContextProvider).valueOrNull,
    );
    final exposure = _effectiveExposure(smartExposure);
    final exposureSecsPerPanel = _exposureSecsPerPanel(exposure);
    final exposuresPerPanel = _exposuresPerPanel(exposure);

    return SkotiqDialog(
      title: 'Mosaic wizard',
      icon: SkotiqIcons.grid,
      closeEnabled: !_isBusy,
      width: 960,
      height: 720,
      scrollableBody: false,
      bodyPadding: EdgeInsets.zero,
      actions: [
        // The reason the primary action cannot run, next to the action itself.
        // A disabled button whose only explanation is a hover tooltip is
        // indistinguishable from a broken one — the operator clicks, nothing
        // happens, and the wizard says nothing.
        if (_actionBlockedReason(
          isRemote: isRemote,
          isDisconnected: isDisconnected,
        )
            case final reason?)
          ConstrainedBox(
            key: const ValueKey('mosaic_action_blocked_reason'),
            constraints: const BoxConstraints(maxWidth: 520),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(SkotiqIcons.warning, size: 14, color: colors.warning),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    reason,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: SkotiqTypography.fontSize12,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        SkotiqButton(
          onPressed: _isBusy ? null : () => Navigator.of(context).pop(),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        // Secondary path, unchanged: expand the grid into the live sequencer's
        // capture tree (no durable project row). Tooltip disambiguates the two
        // near-identical primary actions for the user, not just in code.
        Tooltip(
          message: _panelSizeKnown
              ? 'Add these panels to the current sequence now'
              : 'Panel size unknown — set a focal length and connect the '
                  'camera, or enter it under Advanced',
          child: GatedAction(
            label: 'Load into Sequencer',
            blockedReason: _panelSizeKnown
                ? null
                : 'panel size unknown, so there is no grid to lay out',
            child: SkotiqButton(
              key: const ValueKey('mosaic_generate_sequence_btn'),
              onPressed: _isBusy || !_panelSizeKnown ? null : _generateMosaic,
              icon: SkotiqIcons.add,
              label: 'Load into Sequencer',
              variant: ButtonVariant.outline,
              size: ButtonSize.small,
            ),
          ),
        ),
        // Primary path: persist the design as a durable mosaic project and open
        // the project screen (/mosaic/:id).
        Tooltip(
          message: isRemote
              ? 'Durable mosaic projects are managed on the imaging host'
              : isDisconnected
                  ? 'Connect to an imaging host before creating a durable project'
                  : !_panelSizeKnown
                      ? 'Panel size unknown — set a focal length and connect '
                          'the camera, or enter it under Advanced'
                      : 'Save a reusable project and track its progress',
          child: GatedAction(
            label: isRemote
                ? 'Create on imaging host'
                : isDisconnected
                    ? 'Connect to create project'
                    : 'Create mosaic project',
            blockedReason: _isBusy
                ? null
                : _actionBlockedReason(
                    isRemote: isRemote,
                    isDisconnected: isDisconnected,
                  ),
            child: SkotiqButton(
              key: const ValueKey('mosaic_create_project_btn'),
              onPressed: _isBusy || !canCreateProject || !_panelSizeKnown
                  ? null
                  : () => unawaited(_createMosaicProject()),
              icon: SkotiqIcons.layoutGrid,
              label: isRemote
                  ? 'Create on imaging host'
                  : isDisconnected
                      ? 'Connect to create project'
                      : 'Create mosaic project',
              isLoading: _isCreatingProject,
              variant: ButtonVariant.primary,
              size: ButtonSize.small,
            ),
          ),
        ),
      ],
      child: Row(
        children: [
          SizedBox(
            width: AdaptiveDialogConstraints.clampPanelWidth(
              context,
              designWidth: 340,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The resume banner outranks the panel-size warning: an
                  // interrupted mosaic is the one thing the operator must see
                  // before doing anything else, and the dialog's fixed height
                  // puts whatever is second below the fold.
                  if (_resumableMosaicCheckpoint != null) ...[
                    _buildResumeBanner(_resumableMosaicCheckpoint!, colors),
                    const SizedBox(height: 20),
                  ],
                  if (!_panelSizeKnown) ...[
                    _buildUnknownPanelSizeBanner(colors),
                    const SizedBox(height: 20),
                  ],
                  _GridSizer(
                    colors: colors,
                    rows: _panelsVertical,
                    cols: _panelsHorizontal,
                    overlapPercent: _overlapPercent,
                    rotation: _rotation,
                    onChange: ({
                      int? rows,
                      int? cols,
                      double? overlap,
                      double? rotation,
                    }) {
                      setState(() {
                        if (rows != null) _panelsVertical = rows;
                        if (cols != null) _panelsHorizontal = cols;
                        if (overlap != null) _overlapPercent = overlap;
                        if (rotation != null) _rotation = rotation;
                        // Drop disabled cells whose row/col no longer exist in
                        // the resized grid (semantically correct — that
                        // physical panel is gone). Surviving cells keep their
                        // disabled state because they are keyed by position.
                        _disabledPanels.removeWhere((cell) =>
                            cell.row >= _panelsVertical ||
                            cell.col >= _panelsHorizontal);
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  _StatsCard(
                    colors: colors,
                    activePanels: _activePanelCount,
                    gridLabel: '$_panelsHorizontal×$_panelsVertical',
                    panelArcminLabel: _panelSizeKnown
                        ? '${(_panelWidthArcmin / 60).toStringAsFixed(2)}° × ${(_panelHeightArcmin / 60).toStringAsFixed(2)}°'
                        : 'unknown',
                    overlapLabel: '${_overlapPercent.toStringAsFixed(0)}%',
                    filterCount:
                        exposure.isMultiFilter ? exposure.filters!.length : 1,
                    exposureSecsPerPanel: exposureSecsPerPanel,
                    exposuresPerPanel: exposuresPerPanel,
                    estTimeHours:
                        _calculateTotalTime(exposureSecsPerPanel) / 3600,
                    totalExposures: _activePanelCount * exposuresPerPanel,
                  ),
                  const SizedBox(height: 16),
                  _FilterPlanCard(
                    colors: colors,
                    enabled: _multiFilterEnabled,
                    rows: _filterRows,
                    onToggle: (on) {
                      setState(() {
                        _multiFilterEnabled = on;
                        if (on) _seedFilterRowsIfNeeded();
                      });
                    },
                    onChanged: () => setState(() {}),
                    onAddRow: () {
                      setState(() {
                        _filterRows.add(_MosaicFilterRow(
                          filterName: 'Filter ${_filterRows.length + 1}',
                          exposureSeconds: smartExposure.exposureSeconds,
                          count: smartExposure.exposuresPerPanel,
                        ));
                      });
                    },
                    onRemoveRow: (row) {
                      setState(() => _filterRows.remove(row));
                    },
                  ),
                  const SizedBox(height: 16),
                  _AdvancedPanel(
                    colors: colors,
                    expanded: _advancedExpanded,
                    centerRa: _centerRa,
                    centerDec: _centerDec,
                    panelWidthArcmin: _panelWidthArcmin,
                    panelHeightArcmin: _panelHeightArcmin,
                    panelWidthKnown: _panelWidthKnown,
                    panelHeightKnown: _panelHeightKnown,
                    onToggle: () =>
                        setState(() => _advancedExpanded = !_advancedExpanded),
                    onChanged: ({
                      double? centerRa,
                      double? centerDec,
                      double? panelWidthArcmin,
                      double? panelHeightArcmin,
                    }) {
                      setState(() {
                        if (centerRa != null) _centerRa = centerRa;
                        if (centerDec != null) _centerDec = centerDec;
                        if (panelWidthArcmin != null) {
                          _panelWidthArcmin = panelWidthArcmin;
                          _userSuppliedWidth = true;
                        }
                        if (panelHeightArcmin != null) {
                          _panelHeightArcmin = panelHeightArcmin;
                          _userSuppliedHeight = true;
                        }
                        // An explicit panel size is a legitimate answer to
                        // "what field does one panel cover?" — it just has to
                        // come from the user rather than from a field
                        // initialiser nobody chose, and it takes BOTH
                        // dimensions. One typed number leaves the panel size
                        // half-unknown, so the wizard keeps saying so.
                        if (_userSuppliedWidth && _userSuppliedHeight) {
                          _panelSizeSource = _PanelSizeSource.user;
                        }
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
                border: Border.all(color: colors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: _VisualMosaicPlanner(
                key: const ValueKey('mosaic_visual_planner'),
                colors: colors,
                centerRa: _centerRa,
                centerDec: _centerDec,
                panels: panels,
                panelWidthArcmin: _panelWidthArcmin,
                panelHeightArcmin: _panelHeightArcmin,
                rotation: _rotation,
                onPanelToggle: (panel) {
                  final cell = (row: panel.row, col: panel.col);
                  setState(() {
                    if (_disabledPanels.contains(cell)) {
                      _disabledPanels.remove(cell);
                    } else {
                      _disabledPanels.add(cell);
                    }
                  });
                },
                onDragCenter: (dRaHours, dDecDeg) {
                  setState(() {
                    _centerRa = (_centerRa + dRaHours) % 24.0;
                    if (_centerRa < 0) _centerRa += 24;
                    _centerDec = (_centerDec + dDecDeg).clamp(-90.0, 90.0);
                  });
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Shown while the panel size is neither measured from the rig nor supplied
  /// by the user. Wording mirrors the framing dialog, which already refuses to
  /// guess a field of view, so the two surfaces tell the same story.
  Widget _buildUnknownPanelSizeBanner(SkotiqColors colors) {
    final config = ref.watch(opticalConfigProvider);
    final reason = config == null ||
            config.focalLength == null ||
            config.focalLength! <= 0
        ? 'No equipment profile with a focal length, so the panel field cannot '
            'be measured.'
        : 'No camera connected, so the sensor size is unknown.';
    return Container(
      key: const ValueKey('mosaic_unknown_panel_size_banner'),
      padding: const EdgeInsets.all(16),
      decoration: SkotiqDecorations.iconChip(
        colors.warning,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        borderAlpha: 0.4,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(SkotiqIcons.warning, color: colors.warning, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Panel size unknown',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$reason Set a focal length in Settings and connect the '
                  'camera, or enter the panel width and height yourself under '
                  'Advanced (numerical) below — either one lets the grid be '
                  'laid out.',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: SkotiqTypography.fontSize13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResumeBanner(CheckpointInfo info, SkotiqColors colors) {
    final ageMinutes = info.ageSeconds ~/ 60;
    final ageStr = ageMinutes < 60
        ? '${ageMinutes}m ago'
        : '${ageMinutes ~/ 60}h ${ageMinutes % 60}m ago';
    final integrationMins = (info.completedIntegrationSecs / 60).round();
    return Container(
      key: const ValueKey('mosaic_resume_banner'),
      padding: const EdgeInsets.all(16),
      decoration: SkotiqDecorations.iconChip(
        colors.warning,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        borderAlpha: 0.4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(SkotiqIcons.undo, color: colors.warning, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Restore previous mosaic?',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '"${info.sequenceName}" was interrupted $ageStr. '
            '${info.completedExposures} frames captured (${integrationMins}m '
            'integration). Restore loads it with its progress; nothing moves '
            'until you press Start, which picks up at the next unfinished '
            'panel.',
            style: TextStyle(
                color: colors.textSecondary,
                fontSize: SkotiqTypography.fontSize13),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SkotiqButton(
                onPressed:
                    _checkpointAction == null ? _resumeInterruptedMosaic : null,
                icon: SkotiqIcons.play,
                label: 'Restore',
                isLoading: _checkpointAction == 'resume',
                variant: ButtonVariant.primary,
                size: ButtonSize.small,
              ),
              SkotiqButton(
                onPressed:
                    _checkpointAction == null ? _discardMosaicCheckpoint : null,
                icon: SkotiqIcons.delete,
                label: 'Start over',
                isLoading: _checkpointAction == 'discard',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Configuration widgets
