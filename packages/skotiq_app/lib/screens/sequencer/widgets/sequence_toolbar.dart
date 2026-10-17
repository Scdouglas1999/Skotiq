import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../models/command_action_result.dart';
import '../../../services/sequence_action_service.dart';
import '../../../utils/count_label.dart';
import '../../../utils/exported_file_reveal.dart';
import '../../../utils/sequence_mutator_helper.dart';
import '../../../utils/snackbar_helper.dart';
import 'run_dashboard/run_dashboard_providers.dart';
import 'flat_wizard_dialog.dart';
import 'mosaic_wizard_dialog.dart';
import 'quick_start_wizard_dialog.dart';
import 'sequence_issues_dialog.dart';
import 'sequence_overview_prefs.dart';
import 'sequencer_density.dart';
import 'sequence_step_finder.dart';
import 'sequence_tree_shortcuts.dart';
import 'slew_to_target_dialog.dart';
import 'smart_night_dialog.dart';
import 'trigger_configuration_dialog.dart';
import 'visual_timeline.dart';
import '../sequence_counts.dart';
import '../import_sequence_dialog.dart';

part 'sequence_toolbar/actions_and_estimate.dart';

class SequenceToolbar extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const SequenceToolbar({super.key, required this.colors});

  @override
  ConsumerState<SequenceToolbar> createState() => _SequenceToolbarState();
}

class _SequenceToolbarState extends ConsumerState<SequenceToolbar> {
  /// Width of the bar's bottom divider. Named because the bar's own height has
  /// to account for it — see the `height:` comment in [build].
  static const double _bottomBorderWidth = 1.0;

  /// The canvas bar's height (06 §Sequencer).
  static const double _canvasBarHeight = 44.0;

  /// The leading document glyph beside the sequence name.
  static const double _canvasBarGlyph = 15.0;

  /// The narrowest canvas that can still afford labelled Timeline / Map
  /// buttons. Below it they fall back to glyphs with the same tooltips.
  ///
  /// Measured against the summary chip, which is worth more than two words:
  /// at 816 px (a 1600 px window with the rail expanded and both side panels
  /// open) the labels and the summary cannot both fit, and the summary is the
  /// one carrying facts.
  static const double _labelledToolbarWidth = 900.0;

  /// The narrowest canvas that can afford anything but the name and the menu.
  static const double _narrowBarWidth = 400.0;

  /// The narrowest canvas that can still afford the view toggles at all.
  /// Below it they move into the overflow menu with the rest of the actions,
  /// so the bar shrinks by a whole group instead of overflowing.
  static const double _toggleToolbarWidth = 560.0;

  /// The most of the bar the sequence name may take before it ellipsises.
  ///
  /// The name is CAPPED rather than flexed, the way `PageHeader` caps its
  /// title: a flexible name beside flexible chips leaves BOTH short at
  /// 1280 px, which is the worst of both — the title read
  /// "Mono LRGB M51 (Whi…" while the summary lost the "m" off "~2h 54m". The
  /// chips state facts that are only useful whole, so they take their
  /// intrinsic width and the name takes what is left, up to this fraction.
  static const double _nameWidthFraction = 0.4;

  /// Everything in the wide row that is neither the name nor the toolbar: the
  /// leading document glyph and the three gaps around it.
  static const double _leadingCost = _canvasBarGlyph +
      SkotiqTokens.spaceSm +
      SkotiqTokens.spaceMd +
      SkotiqTokens.spaceSm;

  /// What the labelled Timeline / Map pair costs, measured at 1600 px
  /// (148.8 + 2 + 83.3 = 234.1) and rounded up, because a pressed toggle is
  /// `secondary` and carries a border the idle one does not.
  static const double _labelledToggleGroupWidth = 260.0;

  /// What the labelled density switch adds to the same group: three
  /// `buttonSm` segment labels ("Comfortable" is the long word) with the
  /// control's own segment padding and gaps, plus the item gap separating it
  /// from the Map button. Measured like [_labelledToggleGroupWidth] and
  /// rounded up.
  static const double _densityControlWidth = 244.0;

  /// The width of a [SkotiqToolbar] holding [buttons] glyph buttons in
  /// [groups] groups, each button [extent] wide.
  ///
  /// The tiers below cannot be constants alone: `SkotiqIconButton` grows
  /// its box to Android's 48 dp touch floor, so the same six glyphs are 200 px
  /// under a pointer and 320 px under a finger. A constant tuned on the
  /// desktop overflows the phone by exactly that difference.
  static double _toolbarWidth(int buttons, int groups, double extent) =>
      buttons * extent +
      (buttons - groups) * SkotiqToolbar.itemGap +
      (groups - 1) *
          (SkotiqToolbar.separatorWidth + SkotiqToolbar.groupPadding * 2);

  /// The narrowest bar that can host [toolbarWidth] and still give the name
  /// its full [_nameWidthFraction] share.
  static double _barWidthFor(double toolbarWidth) =>
      (_leadingCost + toolbarWidth) / (1 - _nameWidthFraction);

  bool _fileActionRunning = false;

  Future<void> _runFileAction(Future<void> Function() action) async {
    if (_fileActionRunning) return;
    setState(() => _fileActionRunning = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _fileActionRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final executionState = ref.watch(sequenceExecutionStateProvider);
    final sequence = ref.watch(currentSequenceProvider);
    // The SIMULATION badge reports what the executor is actually driving, not
    // what anyone asked for — the backend records simulation only once the
    // call installing simulated device ops has returned. Reading it here,
    // rather than off a persisted preference, keeps the badge from claiming
    // simulated hardware while real mounts and cameras are under the run.
    // A backend that cannot read the flag leaves the value absent, and an
    // absent value shows no badge rather than a wrong one.
    final executorInSimulation =
        ref.watch(executorSimulationModeProvider).valueOrNull ?? false;
    // Every action that *replaces* or *mutates* the sequence must be
    // disabled while the executor owns the tree. Save and "Slew to
    // Target" are NOT edits — they stay enabled even while running so
    // the user can still write a checkpoint or chase the current target.
    final canEdit = ref.watch(canEditSequenceProvider);
    // Whether anything in the tree is collapsed, so the one menu entry can be
    // "Collapse all" or "Expand all" rather than two entries, one of them
    // always a no-op.
    final anyCollapsed = ref.watch(
      collapsedNodeIdsProvider.select((ids) => ids.isNotEmpty),
    );
    // Phone is a device-class fact (short side < 600), so a phone in landscape
    // — where the ~430 px height is at a premium — still takes the compact
    // chrome instead of the desktop 64 px bar. isTablet keeps the medium size.
    final isPhone = Responsive.isPhone(context);
    final actionService = ref.read(sequenceActionServiceProvider);

    Future<void> runSequenceAction(
      Future<CommandActionResult> Function() action,
    ) async {
      final result = await action();
      if (!context.mounted) return;
      context.showCommandActionResult(result);
    }

    return Container(
      // The canvas bar is 44 px (06 §Sequencer) plus the hairline it draws.
      //
      // The phone tier is sized to the touch minimum PLUS that divider, not to
      // the touch minimum flat: `Container` folds `decoration.padding` into
      // the child's padding, and `BoxDecoration.padding` is the border's own
      // dimensions, so a flat `height: 48` leaves the row 47 dp — one dp under
      // Android's rule, from a number that looks exactly right at the call
      // site.
      height: isPhone
          ? SkotiqTokens.minTouchTarget + _bottomBorderWidth
          : _canvasBarHeight + _bottomBorderWidth,
      padding: EdgeInsets.symmetric(
        horizontal: isPhone ? SkotiqTokens.spaceSm : SkotiqTokens.spaceMd,
      ),
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(
          bottom: BorderSide(color: colors.border, width: _bottomBorderWidth),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final notifier = ref.read(currentSequenceProvider.notifier);

          // Build the list of secondary actions once. Each entry knows how
          // to render itself inline (icon button) or as a PopupMenuItem so
          // the overflow path can't drift from the inline path.
          void openWizard() => showDialog(
                context: context,
                builder: (_) => const QuickStartWizardDialog(),
              );

          void openFlatWizard() => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => const FlatWizardDialog(),
              );

          // Mosaic planner: visual planner + grid/overlap/filter controls +
          // "Create mosaic project". Seeded from the framed target when there
          // is one, so opening it after framing something lands on that object
          // rather than at 0h/0deg. The effective aim is used (not the
          // view-center target) so a reticle dragged off-center seeds the
          // wizard at the point the telescope would actually point.
          void openMosaicWizard() {
            final framedTarget = ref.read(framingProvider).effectiveAimTarget;
            showDialog<void>(
              context: context,
              builder: (_) => MosaicWizardDialog(
                initialRa: framedTarget?.raHours,
                initialDec: framedTarget?.decDegrees,
              ),
            );
          }

          // Smart Night auto-builder. One-click "Plan Tonight"
          // entry point. Always reachable while the sequencer is idle so
          // a user with a fully-connected rig can go from "I want to
          // image something" to "press Run" in 6 clicks. Funnels through the
          // canonical launcher so this matches every other "Plan Tonight"
          // affordance in the app.
          void openSmartNight() => showSmartNightDialog(context);

          // Triggers live ON exposure nodes, so a sequence with none has
          // nowhere to store them: the loop below would write to no nodes while
          // Save still reported success.
          final exposureNodes =
              sequence?.nodes.values.whereType<ExposureNode>().toList() ??
                  const <ExposureNode>[];

          List<ExposureTriggerConfig> currentExposureTriggers() {
            if (exposureNodes.isEmpty) return const [];
            return exposureNodes.first.triggers
                .map(ExposureTriggerConfig.fromNativeJson)
                .toList(growable: false);
          }

          Future<void> openExposureTriggers() async {
            if (exposureNodes.isEmpty) {
              // Belt and braces: the toolbar button is disabled in this
              // state, but the overflow menu and any future caller must not
              // be able to open a dialog whose Save is a no-op.
              context.showErrorSnackBar(
                'Add an exposure node first — triggers are stored on the '
                'exposure that runs them.',
              );
              return;
            }
            final result = await showDialog<List<ExposureTriggerConfig>>(
              context: context,
              builder: (_) => TriggerConfigurationDialog(
                initialTriggers: currentExposureTriggers(),
                appliesTo: exposureNodes.length == 1
                    ? 'Applies to the exposure node '
                        '"${exposureNodes.single.name}".'
                    : 'Applies to all ${exposureNodes.length} exposure nodes '
                        'in this sequence.',
              ),
            );
            if (result == null) return;

            final nativeTriggers =
                result.map((trigger) => trigger.toNativeJson()).toList();
            final current = ref.read(currentSequenceProvider);
            if (current == null) return;
            final notifier = ref.read(currentSequenceProvider.notifier);
            for (final node in current.nodes.values.whereType<ExposureNode>()) {
              notifier.updateNode(node.copyWith(triggers: nativeTriggers));
            }
            // The trigger update is in-memory only — `updateNode` mutates
            // the editor state but doesn't write to disk. The toolbar's own
            // file action EXPORTS a .nsq through a picker; it does not
            // persist into the library, so pointing the user at it would be
            // a lie. Auto-save (when on) picks this up on its next tick;
            // otherwise "Save Current" in the Sequences tab is what persists.
            if (context.mounted) {
              // Name the count so "applied" is checkable against what the
              // user expected, not a bare claim of success.
              context.showInfoSnackBar(
                'Exposure triggers applied to '
                '${countLabel(exposureNodes.length, 'exposure node')} — '
                'use "Save Current" in the Sequences tab to persist.',
              );
            }
          }

          Future<void> createNewSequence() async {
            final editor = ref.read(currentSequenceProvider.notifier);
            try {
              editor.createSequence();
            } on UnsavedChangesException catch (e) {
              // The editor has unsaved edits; ask the user before
              // throwing them away to start a new sequence. Matches the
              // Open / Import flows above so all three "clobber"
              // entry-points behave identically.
              if (!context.mounted) return;
              final discard = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Discard unsaved changes?'),
                  content: ConstrainedBox(
                    constraints: AdaptiveDialogConstraints.hybrid(
                      ctx,
                      designMaxWidth: 440,
                    ),
                    child:
                        Text('"${e.currentSequenceName}" has unsaved changes. '
                            'Discard them and start a new sequence?'),
                  ),
                  actions: [
                    SkotiqButton(
                      label: 'Cancel',
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                      onPressed: () => Navigator.of(ctx).pop(false),
                    ),
                    SkotiqButton(
                      label: 'Discard',
                      variant: ButtonVariant.destructive,
                      size: ButtonSize.small,
                      onPressed: () => Navigator.of(ctx).pop(true),
                    ),
                  ],
                ),
              );
              if (discard != true) return;
              editor.createSequence(discardUnsaved: true);
            }
          }

          Future<void> openSequenceFile() async {
            final authority = ref.read(backendProvider);
            final editorSnapshot = ref.read(currentSequenceProvider);

            bool requireCurrentContext() {
              if (!context.mounted) return false;
              if (identical(ref.read(backendProvider), authority)) return true;
              context.showWarningSnackBar(
                'The imaging host changed while the file dialog was open. '
                'Open the sequence again for the current host.',
              );
              return false;
            }

            bool requireUnchangedEditor() {
              if (ref.read(currentSequenceProvider) == editorSnapshot) {
                return true;
              }
              context.showWarningSnackBar(
                'The sequence editor changed while the file dialog was open. '
                'Open the file again if you still want to replace it.',
              );
              return false;
            }

            try {
              final fileService = ref.read(sequenceFileServiceProvider);
              final imported = await fileService.importSequence();
              if (imported != null) {
                if (!requireCurrentContext() || !requireUnchangedEditor()) {
                  return;
                }
                if (!ref.read(canEditSequenceProvider)) {
                  if (!context.mounted) return;
                  context.showWarningSnackBar(
                    'Stop the active sequence before opening another file.',
                  );
                  return;
                }
                final editor = ref.read(currentSequenceProvider.notifier);
                try {
                  editor.loadSequence(imported);
                } on UnsavedChangesException catch (e) {
                  // The editor has unsaved edits; ask the user before
                  // clobbering them with the freshly loaded sequence.
                  if (!context.mounted) return;
                  final discard = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Discard unsaved changes?'),
                      content: ConstrainedBox(
                        constraints: AdaptiveDialogConstraints.hybrid(
                          ctx,
                          designMaxWidth: 440,
                        ),
                        child: Text(
                            '"${e.currentSequenceName}" has unsaved changes. '
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
                  if (discard != true) return;
                  if (!requireCurrentContext() || !requireUnchangedEditor()) {
                    return;
                  }
                  if (!ref.read(canEditSequenceProvider)) {
                    if (!context.mounted) return;
                    context.showWarningSnackBar(
                      'Stop the active sequence before opening another file.',
                    );
                    return;
                  }
                  editor.loadSequence(imported, discardUnsaved: true);
                }
                if (context.mounted) {
                  context.showSuccessSnackBar(
                      'Sequence "${imported.name}" loaded');
                }
              }
            } on SnippetDeserializationException catch (e) {
              // Imported file contained a nodeType the editor does not
              // know about — never silently drop it onto the tree.
              if (requireCurrentContext() && context.mounted) {
                context.showErrorSnackBar(
                  'Could not load sequence: ${e.message}',
                  duration: const Duration(seconds: 6),
                );
              }
            } catch (e) {
              if (requireCurrentContext() && context.mounted) {
                context.showErrorSnackBar('Failed to load sequence: $e');
              }
            }
          }

          Future<void> saveSequenceFile() async {
            final current = ref.read(currentSequenceProvider);
            if (current == null) {
              if (context.mounted) {
                context.showWarningSnackBar('No sequence to save');
              }
              return;
            }
            final fileService = ref.read(sequenceFileServiceProvider);
            try {
              final savedPath = await fileService.exportSequence(current);
              if (savedPath != null && context.mounted) {
                await revealExportedFile(
                  context,
                  savedPath,
                  subject: 'Skotiq sequence: ${current.name}',
                  desktopMessage: 'Sequence "${current.name}" exported',
                );
              }
            } on SequenceValidationFailedException catch (e) {
              // Validation errors deserve a structured dialog, not a
              // one-line "Failed to save: ..." snackbar.
              // The user gets the per-issue list with severity icons,
              // category badges, descriptions and resolution hints, plus
              // a "Force Save anyway" escape hatch that re-invokes
              // exportSequence with forceExport: true.
              if (!context.mounted) return;
              final forceSave = await showValidationIssueDialog(
                context,
                issues: e.issues,
                operationName: 'export the sequence file',
                forceLabel: 'Force save anyway',
              );
              if (!forceSave) return;
              if (!context.mounted) return;
              try {
                final savedPath = await fileService.exportSequence(
                  current,
                  forceExport: true,
                );
                if (savedPath != null && context.mounted) {
                  await revealExportedFile(
                    context,
                    savedPath,
                    subject: 'Skotiq sequence: ${current.name}',
                    desktopMessage:
                        'Sequence "${current.name}" exported (forced)',
                  );
                }
              } catch (err) {
                if (context.mounted) {
                  context.showErrorSnackBar(
                    'Failed to export sequence file: $err',
                  );
                }
              }
            } catch (e) {
              if (context.mounted) {
                context.showErrorSnackBar(
                  'Failed to export sequence file: $e',
                );
              }
            }
          }

          // A slew is a physical action that can point the mount below the
          // horizon, so it is confirmed before it is commanded.
          Future<void> slewToTarget() async {
            final target = ref.read(runDashboardActiveTargetProvider);
            if (target == null) {
              context.showInfoSnackBar(
                'Add a target with coordinates before slewing.',
              );
              return;
            }
            final logger = ref.read(loggingServiceProvider);
            final confirmed = await showSlewToTargetConfirmation(
              context,
              targetName: target.targetName,
              raHours: target.raHours,
              decDegrees: target.decDegrees,
              altitudeDegrees:
                  ref.read(runDashboardSkyStatsProvider)?.altitudeDeg,
            );
            if (!confirmed) {
              logger.info(
                'Slew to ${target.targetName} cancelled at the confirmation.',
                source: 'Sequencer',
              );
              return;
            }
            logger.info(
              'Slewing to ${target.targetName} '
              '(RA ${CoordinateParser.formatRaHms(target.raHours)}, '
              'Dec ${CoordinateParser.formatDecDms(target.decDegrees)}) '
              'from the sequencer toolbar.',
              source: 'Sequencer',
            );
            if (context.mounted) {
              context.showInfoSnackBar('Slewing to ${target.targetName}…');
            }
            try {
              final deviceService = ref.read(deviceServiceProvider);
              await deviceService.slewMountToCoordinates(
                target.raHours,
                target.decDegrees,
              );
              logger.info(
                'Slew to ${target.targetName} commanded.',
                source: 'Sequencer',
              );
              if (context.mounted) {
                context.showInfoSnackBar('Mount is on ${target.targetName}.');
              }
            } catch (e) {
              logger.error(
                'Slew to ${target.targetName} failed: $e',
                source: 'Sequencer',
              );
              if (context.mounted) {
                context.showErrorSnackBar('Failed to slew: $e');
              }
            }
          }

          // Every action below that ends up mutating the sequence tree must
          // respect canEditSequenceProvider. "Export Sequence File"
          // and "Slew to Target" are read-only/runtime operations and
          // stay enabled. "Polar Alignment" navigates to another screen
          // and is also not an edit. The disabled-button visual is
          // already wired through _ToolbarIconButton / overflow popup
          // when `onPressed == null`.
          final lockedTooltipSuffix =
              canEdit ? '' : ' (locked while sequence is running)';
          final actions = <_ToolbarAction>[
            const _ToolbarAction.divider(),
            _ToolbarAction(
              icon: LucideIcons.filePlus,
              label: 'New sequence$lockedTooltipSuffix',
              onPressed: canEdit ? createNewSequence : null,
            ),
            _ToolbarAction(
              icon: LucideIcons.wand2,
              label: 'Quick-start wizard$lockedTooltipSuffix',
              onPressed: canEdit ? openWizard : null,
            ),
            _ToolbarAction(
              icon: LucideIcons.sun,
              label: sequence == null
                  ? 'Calibrate flat exposures (create or open a sequence first)'
                  : 'Calibrate flat exposures$lockedTooltipSuffix',
              onPressed: canEdit && sequence != null ? openFlatWizard : null,
            ),
            _ToolbarAction(
              icon: LucideIcons.grid,
              label: 'Plan mosaic$lockedTooltipSuffix',
              onPressed: canEdit ? openMosaicWizard : null,
            ),
            _ToolbarAction(
              icon: LucideIcons.sparkles,
              label: 'Plan tonight$lockedTooltipSuffix',
              onPressed: canEdit ? openSmartNight : null,
            ),
            _ToolbarAction(
              icon: LucideIcons.folderOpen,
              label: 'Open sequence$lockedTooltipSuffix',
              onPressed: canEdit && !_fileActionRunning
                  ? () => _runFileAction(openSequenceFile)
                  : null,
            ),
            _ToolbarAction(
              icon: LucideIcons.fileInput,
              label: 'Import from NINA / SGP$lockedTooltipSuffix',
              onPressed: canEdit && !_fileActionRunning
                  ? () => _runFileAction(
                        () async {
                          await ImportSequenceFlow.run(context, ref);
                        },
                      )
                  : null,
            ),
            const _ToolbarAction.divider(),
            _ToolbarAction(
              icon: LucideIcons.compass,
              label: 'Polar alignment',
              onPressed: () => context.push('/polar-alignment'),
            ),
            _ToolbarAction(
              icon: LucideIcons.bellRing,
              label: exposureNodes.isEmpty
                  ? 'Exposure triggers (add an exposure node first)'
                  : 'Exposure triggers$lockedTooltipSuffix',
              onPressed: canEdit && exposureNodes.isNotEmpty
                  ? openExposureTriggers
                  : null,
            ),
            const _ToolbarAction.divider(),
            if (sequence != null && sequence.targetHeaders.isNotEmpty)
              _ToolbarAction(
                icon: LucideIcons.navigation,
                // A mount command during a run fights the executor for the
                // telescope: the audit slewed away mid-exposure and the run
                // went on counting the frames either side as accepted. It
                // locks with its neighbours.
                label: 'Slew to target$lockedTooltipSuffix',
                onPressed: canEdit ? slewToTarget : null,
              ),
            const _ToolbarAction.divider(),
            // Canvas view actions that used to sit in the tree's own header
            // row. They belong to the document, so they follow it into the
            // canvas bar rather than getting a second bar of their own.
            _ToolbarAction(
              icon: LucideIcons.search,
              label: 'Find a step…',
              onPressed: sequence == null
                  ? null
                  : () => showSequenceStepFinder(context),
            ),
            _ToolbarAction(
              icon: anyCollapsed
                  ? LucideIcons.chevronsUpDown
                  : LucideIcons.chevronsDownUp,
              label: anyCollapsed ? 'Expand all steps' : 'Collapse all steps',
              onPressed: sequence == null
                  ? null
                  : () {
                      final collapsed =
                          ref.read(collapsedNodeIdsProvider.notifier);
                      if (anyCollapsed) {
                        collapsed.expandAll();
                        return;
                      }
                      collapsed.collapseAll(<String>[
                        for (final entry in sequence.nodes.entries)
                          if (entry.key != sequence.rootNodeId &&
                              entry.value.childIds.isNotEmpty)
                            entry.key,
                      ]);
                    },
            ),
            const _ToolbarAction.divider(),
            _ToolbarAction(
              icon: LucideIcons.skipForward,
              label: 'Skip to next step',
              onPressed: executionState.canSkip
                  ? () => runSequenceAction(actionService.skip)
                  : null,
            ),
            _ToolbarAction(
              icon: LucideIcons.rotateCcw,
              label: 'Reset run state',
              onPressed: executionState.canReset
                  ? () => runSequenceAction(actionService.reset)
                  : null,
            ),
          ];

          // What the bar can show is a question about THIS row's width, not
          // about the device: the same canvas is 1036 px in a 1600 px window
          // and 486 px in a 1000 px one with both side panels open. Below the
          // narrowest tier the bar is the sequence name and the menu, and the
          // menu still holds every action.
          // A glyph button is 28 px under a pointer and 48 px under a finger
          // (`SkotiqIconButton` lifts its box to the touch floor), so
          // every tier below is a constant OR what the buttons actually cost,
          // whichever is wider.
          final glyphExtent = math.max(
            SkotiqTokens.iconButtonSizeSm,
            SkotiqTouchTarget.minExtent(context),
          );
          final validation = ref.watch(liveValidationProvider);
          final showTimeline = ref.watch(timelineVisibleProvider);
          final density = ref.watch(sequencerDensityProvider);
          // The overview control speaks for the density the canvas is
          // DRAWING, not for the stored preference: on a canvas too narrow to
          // host Ledger the tree is showing compact rows and the strip below
          // them, and a button offering to hide a gutter that is not there is
          // how this control came to do nothing at all.
          final overviewDensity = ref.watch(canvasSequencerDensityProvider);
          final showOverview = ref.watch(sequenceOverviewVisibleProvider);
          final overviewLabel = sequenceOverviewToggleLabel(
            density: overviewDensity,
            visible: showOverview,
          );
          void toggleOverview() {
            ref
                .read(sequenceOverviewPrefsProvider.notifier)
                .setVisible(overviewDensity, !showOverview);
          }

          // The mobile builder forces comfortable rows
          // (`effectiveSequencerDensity`), so a density control there would
          // sell a mode the canvas refuses to draw. The gate mirrors the same
          // signal the layout applies to the tree: `builder_layout.dart`
          // picks `_MobileBuilderLayout` on the region's SHORT side
          // (`BreakpointTokens.isPhone(min(w, h))`), so a narrow-but-tall
          // desktop window keeps the switch while the tree keeps drawing
          // ledger rows. The window's short side is the closest measurement
          // this widget can take of that region's — they differ only by the
          // shell chrome between them.
          final mediaSize = MediaQuery.sizeOf(context);
          final showDensity = !BreakpointTokens.isPhone(
            math.min(mediaSize.width, mediaSize.height),
          );
          // Without the toggles the bar carries undo/redo and save/more.
          final barToolbarWidth = _toolbarWidth(4, 2, glyphExtent);
          // With them, three groups of two — plus the three density glyphs
          // riding inside the toggle group when the control is offered.
          final toggledToolbarWidth =
              _toolbarWidth(showDensity ? 9 : 6, 3, glyphExtent);
          // Labelled, the middle group is two worded buttons and the
          // segmented density control.
          final labelledToolbarWidth = _toolbarWidth(4, 3, glyphExtent) +
              _labelledToggleGroupWidth +
              (showDensity ? _densityControlWidth : 0);

          final isNarrowRow = constraints.maxWidth <
              math.max(_narrowBarWidth, _barWidthFor(barToolbarWidth));

          // Below these the toolbar costs more than the canvas can spare and
          // the row overflows — measured, not guessed: at 486 px (a 1000 px
          // window with both side panels open) the labelled "Timeline" and
          // "Map" are ~90 px wider than their glyphs, and at 570 px even the
          // glyphs are 32 px too many. Nothing loses its name at either step:
          // the glyphs keep the tooltips and the menu entries keep the words.
          final labelledToggles = constraints.maxWidth >=
              math.max(
                  _labelledToolbarWidth, _barWidthFor(labelledToolbarWidth));
          final inlineToggles = constraints.maxWidth >=
              math.max(_toggleToolbarWidth, _barWidthFor(toggledToolbarWidth));

          // When the bar cannot hold the toggle group, the toggles do not
          // vanish — they join the menu, with the words the buttons had.
          if (!inlineToggles) {
            actions
              ..add(const _ToolbarAction.divider())
              ..add(_ToolbarAction(
                icon: LucideIcons.clock,
                label: showTimeline ? 'Hide the timeline' : 'Show the timeline',
                onPressed: () => ref
                    .read(timelineVisibleProvider.notifier)
                    .state = !showTimeline,
              ))
              ..add(_ToolbarAction(
                icon: LucideIcons.map,
                label: overviewLabel,
                onPressed: toggleOverview,
              ));
          }

          // The density switch follows the toggles into the menu when the bar
          // cannot hold them. The active mode's entry is disabled — the menu
          // has no checkmark affordance, and a no-op tap is how a radio menu
          // says "this is where you are".
          if (!inlineToggles && showDensity) {
            for (final mode in SequencerDensity.values) {
              actions.add(_ToolbarAction(
                icon: mode.icon,
                label: 'Density: ${mode.label}',
                onPressed: mode == density
                    ? null
                    : () => ref
                        .read(sequencerDensityPrefsProvider.notifier)
                        .setDensity(mode),
              ));
            }
          }

          List<Widget> viewToggles() {
            if (!inlineToggles) return const <Widget>[];
            if (labelledToggles) {
              return <Widget>[
                // Labelled, with the on-state carried by the button's own
                // variant rather than a colour of its own: a pressed toggle is
                // `secondary` (outlined), an idle one `ghost`.
                SkotiqButton(
                  label: 'Timeline',
                  icon: LucideIcons.clock,
                  size: ButtonSize.small,
                  variant: showTimeline
                      ? ButtonVariant.secondary
                      : ButtonVariant.ghost,
                  onPressed: () => ref
                      .read(timelineVisibleProvider.notifier)
                      .state = !showTimeline,
                ),
                SkotiqButton(
                  label: sequenceOverviewButtonLabel(overviewDensity),
                  icon: LucideIcons.map,
                  size: ButtonSize.small,
                  variant: showOverview
                      ? ButtonVariant.secondary
                      : ButtonVariant.ghost,
                  // The name says WHAT it is and the variant says it is on;
                  // the hint is where a reader gets what pressing it does.
                  semanticsHint: overviewLabel,
                  onPressed: toggleOverview,
                ),
                // Density is a one-of-three choice, not a third on/off
                // toggle, so it keeps its own control shape even while it
                // shares the group: `SegmentedControl` publishes button /
                // enabled / selected / label per segment on its own.
                if (showDensity)
                  SegmentedControl(
                    segments: <String>[
                      for (final mode in SequencerDensity.values) mode.label,
                    ],
                    selectedIndex: density.index,
                    onSelected: (index) => ref
                        .read(sequencerDensityPrefsProvider.notifier)
                        .setDensity(SequencerDensity.values[index]),
                  ),
              ];
            }
            return <Widget>[
              SkotiqIconButton(
                icon: LucideIcons.clock,
                tooltip:
                    showTimeline ? 'Hide the timeline' : 'Show the timeline',
                size: IconButtonSize.sm,
                selected: showTimeline,
                onPressed: () => ref
                    .read(timelineVisibleProvider.notifier)
                    .state = !showTimeline,
              ),
              SkotiqIconButton(
                icon: LucideIcons.map,
                tooltip: overviewLabel,
                size: IconButtonSize.sm,
                selected: showOverview,
                onPressed: toggleOverview,
              ),
              // Glyph tier: one button per mode, named by its tooltip and
              // carrying the same `selected` treatment as Timeline / Map.
              if (showDensity)
                for (final mode in SequencerDensity.values)
                  SkotiqIconButton(
                    icon: mode.icon,
                    tooltip: '${mode.label} density',
                    size: IconButtonSize.sm,
                    selected: mode == density,
                    onPressed: () => ref
                        .read(sequencerDensityPrefsProvider.notifier)
                        .setDensity(mode),
                  ),
            ];
          }

          if (isNarrowRow) {
            return Row(
              children: [
                Expanded(
                  child: _CanvasBarName(colors: colors, sequence: sequence),
                ),
                _ToolbarOverflowMenu(colors: colors, actions: actions),
              ],
            );
          }

          return Row(
            children: [
              Icon(
                LucideIcons.fileText,
                size: _canvasBarGlyph,
                color: colors.textMuted,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              // The name is capped; the chips are whole. Nothing in this bar
              // may clip — a half-read count is worse than a shorter title.
              //
              // Two caps, the tighter one wins: the design share above, and
              // what is left once the toolbar has been paid for. The second is
              // what makes the row provably unable to overflow at ANY width,
              // including the ones between the tiers.
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: math.max(
                    0,
                    math.min(
                      constraints.maxWidth * _nameWidthFraction,
                      constraints.maxWidth -
                          _leadingCost -
                          (labelledToggles
                              ? labelledToolbarWidth
                              : inlineToggles
                                  ? toggledToolbarWidth
                                  : barToolbarWidth),
                    ),
                  ),
                ),
                child: _CanvasBarName(colors: colors, sequence: sequence),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              // The chips take ALL the space the name and the toolbar leave,
              // not a share of it. As `Flexible` beside a `Spacer` they were
              // allotted half the slack, and half was never enough for the
              // summary — it measured itself against a width the bar was not
              // actually short of, and dropped itself on a 1800 px window.
              Expanded(
                child: _CanvasBarMeta(
                  sequence: sequence,
                  validation: validation,
                  inSimulation: executorInSimulation,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              SkotiqToolbar(
                groups: <List<Widget>>[
                  <Widget>[
                    SkotiqIconButton(
                      icon: LucideIcons.undo2,
                      tooltip: 'Undo (Ctrl+Z)$lockedTooltipSuffix',
                      size: IconButtonSize.sm,
                      onPressed:
                          (canEdit && notifier.canUndo) ? notifier.undo : null,
                    ),
                    SkotiqIconButton(
                      icon: LucideIcons.redo2,
                      tooltip: 'Redo (Ctrl+Y)$lockedTooltipSuffix',
                      size: IconButtonSize.sm,
                      onPressed:
                          (canEdit && notifier.canRedo) ? notifier.redo : null,
                    ),
                  ],
                  if (inlineToggles) viewToggles(),
                  <Widget>[
                    SkotiqIconButton(
                      icon: LucideIcons.save,
                      // This writes a .nsq FILE through the OS chooser;
                      // saving into the app's library is the Saved tab's
                      // "Save current". Two actions both called "Save" was a
                      // real ambiguity — the name says which one this is.
                      tooltip: sequence == null
                          ? 'Export sequence file (create or open a sequence '
                              'first)'
                          : 'Export sequence file…',
                      size: IconButtonSize.sm,
                      onPressed: sequence != null && !_fileActionRunning
                          ? () => _runFileAction(saveSequenceFile)
                          : null,
                    ),
                    _ToolbarOverflowMenu(colors: colors, actions: actions),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The canvas bar's sequence name: 15 / 600, with a muted "· unsaved changes"
/// beside it while the editor holds edits the library has not got.
///
/// Double-click renames, as it always did.
class _CanvasBarName extends ConsumerWidget {
  const _CanvasBarName({required this.colors, required this.sequence});

  final SkotiqColors colors;
  final Sequence? sequence;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = sequence;
    if (current == null) {
      return Text(
        'No sequence',
        style: SkotiqTypography.sectionTitle.copyWith(
          color: colors.textMuted,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    return GestureDetector(
      onDoubleTap: () => _showRenameDialog(context, ref, current),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              current.name,
              style: SkotiqTypography.sectionTitle.copyWith(
                color: colors.textPrimary,
              ),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // The mockup's muted "· unsaved changes" is NOT rendered: the
          // editor's dirty flag lives on the notifier
          // (`SequenceEditor.isDirty`) and nothing publishes it as a provider,
          // so the label could only be read at build time and would keep
          // claiming unsaved work after a save. A label that lies is worse
          // than no label. See reports/observatory/w3-sequencer/notes.md.
        ],
      ),
    );
  }

  void _showRenameDialog(
    BuildContext context,
    WidgetRef ref,
    Sequence current,
  ) {
    final controller = TextEditingController(text: current.name);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename sequence'),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            dialogContext,
            designMaxWidth: 400,
          ),
          child: SkotiqTextField(
            controller: controller,
            autofocus: true,
            hint: 'Sequence name',
          ),
        ),
        actions: [
          SkotiqButton(
            onPressed: () => Navigator.pop(dialogContext),
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
          SkotiqButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) {
                dialogContext.showWarningSnackBar('Name cannot be empty');
                return;
              }
              ref.read(currentSequenceProvider.notifier).setName(name);
              Navigator.pop(dialogContext);
            },
            label: 'Rename',
            size: ButtonSize.small,
          ),
        ],
      ),
    );
  }
}

/// The canvas bar's meta chips: the live error and warning counts, then one
/// summary chip stating what the sequence IS
/// ("1 target · 27 nodes · ~2 h 54 m").
class _CanvasBarMeta extends ConsumerWidget {
  const _CanvasBarMeta({
    required this.sequence,
    required this.validation,
    required this.inSimulation,
  });

  final Sequence? sequence;
  final LiveValidationState validation;

  /// What the EXECUTOR is driving, not what anyone asked for. A run against
  /// simulated devices has to say so on the surface the operator is watching,
  /// which is why this chip survives the move to the instrument bar: the bar
  /// reports the run, this reports what the run is made of.
  final bool inSimulation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = sequence;
    if (current == null) return const SizedBox.shrink();

    final estimator = SequenceTimeEstimator(
      overhead: ref.watch(sequencerOverheadConfigProvider),
    );
    final totalSecs =
        estimator.estimateTotalDuration(current, DateTime.now()).inSeconds;
    final summary = <String>[
      countLabel(current.targetHeaders.length, 'target'),
      countLabel(visibleInstructionCount(current), 'node'),
      if (totalSecs > 0)
        '~${DurationFormat.seconds(totalSecs.toDouble(), style: DurationStyle.compact, rounding: DurationRounding.truncate)}',
    ].join(' · ');

    // The summary is the one chip here that is informational rather than
    // actionable, so it is the first thing dropped when the bar is tight — and
    // it is dropped WHOLE. A clipped summary reading "1 target" (or "~2h 54"
    // with the m cut) states something the sequence does not.
    //
    // Measured, not tiered: the width this row gets depends on how long the
    // operator called their sequence, so a breakpoint guesses wrong in both
    // directions. The counts are fixed-width; only the summary has to be
    // measured, and only when it is present.
    return LayoutBuilder(
      builder: (context, constraints) {
        final counts = (validation.errorCount > 0 ? _countChipWidth : 0.0) +
            (validation.warningCount > 0 ? _countChipWidth : 0.0) +
            (inSimulation ? _simulationChipWidth : 0.0);
        final summaryWidth = _chipWidth(context, summary);
        final showSummary = constraints.hasBoundedWidth &&
            counts + summaryWidth <= constraints.maxWidth;
        // A scroll view is the last line of defence, not a ClipRect: a
        // ClipRect hides the pixels but the Row inside it still asserts. It
        // is INSIDE this builder, not around it — wrapping the builder is
        // what handed it an unbounded width, and an unbounded width is a
        // measurement that always says "no room" and never shows the summary
        // at all.
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: _chips(context, summary: summary, showSummary: showSummary),
        );
      },
    );
  }

  /// A count chip: two digits at most, plus its glyph, padding and the gap
  /// after it. Fixed by construction, so it does not need measuring.
  static const double _countChipWidth = 52;

  /// The SIMULATION chip, which carries a word rather than a numeral.
  static const double _simulationChipWidth = 104;

  /// [text] as a [SkotiqChip] would lay it out, plus the gap after it.
  double _chipWidth(BuildContext context, String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: SkotiqChip.textStyle()),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width + SkotiqChip.horizontalPadding * 2 + SkotiqTokens.spaceXs + 2;
  }

  Widget _chips(
    BuildContext context, {
    required String summary,
    required bool showSummary,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // One tap opens the issue list. These chips are the only place the
        // builder admits the sequence has problems, and decoding "2" otherwise
        // means pressing Start and reading the pre-flight dialog — "press the
        // button that starts the rig" is not how you ask what is wrong.
        // The numeral is the design; the NAME is what a screen reader says,
        // and "4" on its own is not a fact about anything.
        if (validation.errorCount > 0) ...[
          Semantics(
            button: true,
            enabled: true,
            label: countLabel(validation.errorCount, 'error'),
            child: ExcludeSemantics(
              child: SkotiqChip(
                label: '${validation.errorCount}',
                icon: LucideIcons.xCircle,
                tone: ChipTone.error,
                onTap: () => SequenceIssuesDialog.show(context),
              ),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceXs + 2),
        ],
        if (validation.warningCount > 0) ...[
          Semantics(
            button: true,
            enabled: true,
            label: countLabel(validation.warningCount, 'warning'),
            child: ExcludeSemantics(
              child: SkotiqChip(
                label: '${validation.warningCount}',
                icon: LucideIcons.alertTriangle,
                tone: ChipTone.warning,
                onTap: () => SequenceIssuesDialog.show(context),
              ),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceXs + 2),
        ],
        if (showSummary) SkotiqChip(label: summary),
        if (inSimulation) ...[
          const SizedBox(width: SkotiqTokens.spaceXs + 2),
          const SkotiqChip(
            label: 'Simulation',
            icon: LucideIcons.testTube,
            tone: ChipTone.warning,
          ),
        ],
      ],
    );
  }
}
