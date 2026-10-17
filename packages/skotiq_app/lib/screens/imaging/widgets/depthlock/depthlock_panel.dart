import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path/path.dart' as p;

import '../../../../utils/confirm_dialog.dart';
import '../../../../utils/snackbar_helper.dart';
import 'depthlock_commit_host.dart';
import 'depthlock_curve_chart.dart';
import 'depthlock_goal_editor.dart';
import 'depthlock_pickers.dart';
import 'depthlock_presentation.dart';
import 'depthlock_progress.dart';
import 'depthlock_region_layer.dart';
import 'depthlock_selection.dart';

/// The goal the panel is showing in detail, or null while it is showing the
/// list. Held in a provider so opening a goal survives the panel rebuilding
/// under it when evidence arrives.
final depthLockSelectedGoalProvider = StateProvider<String?>((ref) => null);

/// The Imaging screen's DepthLock section: mark a region on the frame, then
/// watch the goals it produced fill up across later nights.
///
/// The section is a list that opens into a detail view, not a stack of full
/// cards: a night with four goals on it is a list an operator scans, and each
/// goal's numbers are something they go and look at.
class DepthLockPanel extends ConsumerWidget {
  const DepthLockPanel({super.key, required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goalsAsync = ref.watch(depthLockGoalsProvider);
    final selectedId = ref.watch(depthLockSelectedGoalProvider);
    final goals = goalsAsync.valueOrNull ?? const <DepthLockGoal>[];
    final DepthLockGoal? selected = selectedId == null
        ? null
        : goals.where((goal) => goal.id == selectedId).firstOrNull;

    if (selected != null) {
      return DepthLockGoalDetail(
        goal: selected,
        colors: colors,
        onBack: () =>
            ref.read(depthLockSelectedGoalProvider.notifier).state = null,
        onEditRegion: () {
          startDepthLockRegionEdit(ref, selected);
          ref.read(depthLockSelectedGoalProvider.notifier).state = null;
        },
      );
    }

    // A goal that was removed, or a stale id from a previous session, must not
    // strand the panel on a detail view of nothing.
    if (selectedId != null && goalsAsync.hasValue) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(depthLockSelectedGoalProvider.notifier).state = null;
      });
    }

    return _GoalList(
      colors: colors,
      goalsAsync: goalsAsync,
      building: ref.watch(depthLockRegionBusyProvider),
      error: ref.watch(depthLockRegionErrorProvider),
      onOpen: (goal) =>
          ref.read(depthLockSelectedGoalProvider.notifier).state = goal.id,
    );
  }
}

/// The list half of the panel.
class _GoalList extends ConsumerWidget {
  const _GoalList({
    required this.colors,
    required this.goalsAsync,
    required this.building,
    required this.error,
    required this.onOpen,
  });

  final SkotiqColors colors;
  final AsyncValue<List<DepthLockGoal>> goalsAsync;
  final bool building;
  final String? error;
  final ValueChanged<DepthLockGoal> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(depthLockStatusProvider).valueOrNull;
    final overlayVisible = ref.watch(depthLockGoalOverlayVisibleProvider);
    final selection = ref.watch(depthLockActiveSelectionProvider);
    // Where tonight's clear sky is best spent, across every goal at once.
    final String? allocation = depthLockAllocationSummary(
      goalsAsync.valueOrNull ?? const <DepthLockGoal>[],
    );

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SectionTitle(
            icon: SkotiqIcons.target,
            title: 'DepthLock',
            trailing: SkotiqIconButton(
              icon: SkotiqIcons.refresh,
              tooltip: 'Re-read the goals from the host',
              size: IconButtonSize.sm,
              onPressed: () =>
                  ref.read(depthLockGoalsProvider.notifier).refresh(),
            ),
          ),
          if (status != null && !status.available) ...<Widget>[
            const SkotiqBanner(
              title: 'DepthLock is unavailable on this host',
              message: 'The goal store did not start, so goals cannot be '
                  'created or measured here.',
              tone: BannerTone.warning,
              icon: SkotiqIcons.warning,
            ),
            const SizedBox(height: SidePanel.sectionGap),
          ],
          if (status != null && status.available && status.dropped > 0) ...[
            SkotiqInlineBanner(
              message: '${status.dropped} frames were not analysed because the '
                  'analysis queue was full. They are still on disk — offer '
                  'them to a goal with "Add frames".',
              severity: SkotiqAlertSeverity.warning,
            ),
            const SizedBox(height: SidePanel.sectionGap),
          ],
          if (error != null) ...<Widget>[
            SkotiqBanner(
              title: 'The region could not be anchored',
              message: error!,
              tone: BannerTone.error,
              icon: SkotiqIcons.error,
            ),
            const SizedBox(height: SidePanel.sectionGap),
          ],
          _SelectionCard(building: building),
          const SizedBox(height: SidePanel.sectionGap),
          SectionTitle(
            icon: SkotiqIcons.list,
            title: 'Goals',
            trailing: SkotiqIconButton(
              icon: overlayVisible ? SkotiqIcons.visible : SkotiqIcons.hidden,
              tooltip: overlayVisible
                  ? 'Hide saved goals on the frame'
                  : 'Draw saved goals on the frame',
              size: IconButtonSize.sm,
              selected: overlayVisible,
              onPressed: () => ref
                  .read(depthLockGoalOverlayVisibleProvider.notifier)
                  .state = !overlayVisible,
            ),
          ),
          if (allocation != null) ...<Widget>[
            Padding(
              padding: const EdgeInsets.only(
                bottom: SkotiqTokens.spaceSm,
              ),
              child: Text(
                allocation,
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
          goalsAsync.when(
            loading: () => const ShimmerLoading(
              child: SizedBox(width: double.infinity, height: 72),
            ),
            error: (error, _) => SkotiqBanner(
              title: 'The goal list could not be read',
              message: depthLockErrorMessage(error),
              tone: BannerTone.error,
              icon: SkotiqIcons.error,
            ),
            data: (goals) => goals.isEmpty
                ? EmptyState.compact(
                    icon: SkotiqIcons.target,
                    title: 'No depth goals',
                    body: 'Mark a faint region on a solved sub and Skotiq '
                        'keeps track of how much deeper it still needs to go.',
                    action: SkotiqButton(
                      label: 'Mark a region',
                      icon: SkotiqIcons.crosshair,
                      size: ButtonSize.small,
                      semanticsHint: selection.canSelect
                          ? 'Drag two boxes on the frame to define a goal'
                          : selection.blocker,
                      onPressed: selection.canSelect
                          ? () => ref
                              .read(
                                depthLockRegionToolActiveProvider.notifier,
                              )
                              .state = true
                          : null,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final goal in goals) ...<Widget>[
                        DepthLockGoalRow(
                          goal: goal,
                          colors: colors,
                          onTap: () => onOpen(goal),
                        ),
                        const SizedBox(height: SkotiqTokens.spaceSm),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Text(
            'Depth can only end a filter early. If the plan\'s count, time or '
            'visibility limit arrives first, the run ends as authored and the '
            'goal stays open for the next session.',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// One goal in the list: what it is, where it stands, and one line of why.
class DepthLockGoalRow extends StatelessWidget {
  const DepthLockGoalRow({
    super.key,
    required this.goal,
    required this.colors,
    required this.onTap,
  });

  final DepthLockGoal goal;
  final SkotiqColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final report = goal.report;
    final String status = goal.lastIssue?.isNotEmpty == true
        ? goal.lastIssue!
        : (report?.reason.isNotEmpty == true
            ? report!.reason
            : depthLockStateCaption(goal.state));

    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.panelSectionPadding),
      onTap: onTap,
      enableHover: true,
      child: Semantics(
        button: true,
        label: '${goal.definition.label}, ${goal.definition.filterName}, '
            '${depthLockStateLabel(goal.state)}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    goal.definition.label,
                    style: SkotiqTypography.label.copyWith(
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                SkotiqChip(
                  label: goal.definition.filterName,
                  tone: ChipTone.neutral,
                ),
                const SizedBox(width: SkotiqTokens.spaceXs),
                SkotiqChip(
                  label: depthLockStateLabel(goal.state),
                  tone: depthLockStateTone(goal.state),
                  dot: true,
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            DepthLockProgress(goal: goal, compact: true),
            const SizedBox(height: SkotiqTokens.spaceXs),
            Text(
              status,
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// The card that starts a region — and says why it cannot, when the displayed
/// frame is the wrong kind of thing to mark.
class _SelectionCard extends ConsumerWidget {
  const _SelectionCard({required this.building});

  final bool building;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final selection = ref.watch(depthLockActiveSelectionProvider);
    final toolActive = ref.watch(depthLockRegionToolActiveProvider);
    final draft = ref.watch(depthLockRegionDraftProvider);

    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.panelSectionPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Mark the detail you care about',
            style: SkotiqTypography.label.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            'Drag a box over the faint structure, then a second box over '
            'nearby blank sky. Only exposures taken after the goal is created '
            'count towards it.',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
          if (selection.blocker != null) ...<Widget>[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqInlineBanner(
              message: selection.blocker!,
              severity: SkotiqAlertSeverity.warning,
            ),
          ] else if (selection.advisory != null) ...<Widget>[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqInlineBanner(
              message: selection.advisory!,
              severity: SkotiqAlertSeverity.info,
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceMd),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: <Widget>[
              SkotiqButton(
                label: toolActive ? 'Stop marking' : 'Mark a region',
                icon: SkotiqIcons.crosshair,
                size: ButtonSize.small,
                variant: toolActive
                    ? ButtonVariant.secondary
                    : ButtonVariant.primary,
                isLoading: building,
                semanticsHint: toolActive
                    ? 'Leave the region tool and discard the boxes'
                    : (selection.canSelect
                        ? 'Drag two boxes on the frame to define a depth '
                            'goal'
                        : selection.blocker),
                onPressed: selection.canSelect && !building
                    ? () {
                        if (toolActive) {
                          cancelDepthLockRegionTool(ref);
                        } else {
                          ref
                              .read(
                                depthLockRegionToolActiveProvider.notifier,
                              )
                              .state = true;
                        }
                      }
                    : null,
              ),
              if (draft.step == DepthLockRegionStep.ready)
                SkotiqButton(
                  label: 'Use these boxes',
                  icon: SkotiqIcons.check,
                  size: ButtonSize.small,
                  semanticsHint: 'Open the goal editor for the two boxes',
                  onPressed: building ? null : () => commitDepthLockRegion(ref),
                ),
              if (!draft.isEmpty)
                SkotiqButton(
                  label: 'Undo box',
                  icon: SkotiqIcons.undo,
                  size: ButtonSize.small,
                  variant: ButtonVariant.ghost,
                  onPressed: () =>
                      ref.read(depthLockRegionDraftProvider.notifier).undo(),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One goal in full: every number the report carries, and everything that can
/// be done to it.
class DepthLockGoalDetail extends ConsumerStatefulWidget {
  const DepthLockGoalDetail({
    super.key,
    required this.goal,
    required this.colors,
    required this.onBack,
    required this.onEditRegion,
  });

  final DepthLockGoal goal;
  final SkotiqColors colors;
  final VoidCallback onBack;
  final VoidCallback onEditRegion;

  @override
  ConsumerState<DepthLockGoalDetail> createState() =>
      _DepthLockGoalDetailState();
}

class _DepthLockGoalDetailState extends ConsumerState<DepthLockGoalDetail> {
  bool _busy = false;

  DepthLockGoalsNotifier get _goals =>
      ref.read(depthLockGoalsProvider.notifier);

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) context.showErrorSnackBar(depthLockErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setPreferences({bool? enabled, bool? automatic}) {
    final goal = widget.goal;
    return _run(
      () => _goals.setPreferences(
        goalId: goal.id,
        expectedRevision: goal.revision,
        enabled: enabled ?? goal.definition.enabled,
        automaticCompletion: automatic ?? goal.definition.automaticCompletion,
      ),
    );
  }

  Future<void> _edit() async {
    final goal = widget.goal;
    await DepthLockGoalEditor.show(
      context,
      initialDefinition: goal.definition,
      existing: goal,
      filterChoices: ref.read(activeEquipmentProfileProvider)?.filterNames ??
          const <String>[],
      dark: DepthLockMasterChoice(path: goal.definition.darkPath),
      flat: DepthLockMasterChoice(path: goal.definition.flatPath),
      onEditRegion: widget.onEditRegion,
    );
  }

  Future<void> _remove() async {
    final goal = widget.goal;
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Remove this goal?',
      message:
          '"${goal.definition.label}" and the evidence gathered for it are '
          'deleted. Any Smart Exposure plan bound to it runs to its count '
          'instead.',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed) return;
    await _run(
      () => _goals.removeGoal(
        goalId: goal.id,
        expectedRevision: goal.revision,
      ),
    );
    if (mounted) widget.onBack();
  }

  Future<void> _ingest() async {
    final paths = await ref.read(depthLockFramesPickerProvider)();
    if (paths.isEmpty || !mounted) return;
    final outcomes = <String>[];
    await _run(() async {
      for (final path in paths) {
        final outcome = await _goals.ingestFrame(
          goalId: widget.goal.id,
          path: path,
        );
        outcomes.add(depthLockIngestSummary(p.basename(path), outcome));
      }
    });
    if (!mounted || outcomes.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (_) => SkotiqDialog(
        title: 'Frames offered to ${widget.goal.definition.label}',
        icon: SkotiqIcons.file,
        width: SkotiqDialog.widthConfirm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final line in outcomes)
              Padding(
                padding: const EdgeInsets.only(
                  bottom: SkotiqTokens.spaceSm,
                ),
                child: Text(line, style: SkotiqTypography.bodySm),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final goal = widget.goal;
    final colors = widget.colors;
    final definition = goal.definition;
    final report = goal.report;
    final state = goal.state;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              label: 'All goals',
              icon: SkotiqIcons.chevronLeft,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              semanticsHint: 'Back to the list of DepthLock goals',
              onPressed: widget.onBack,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  definition.label,
                  style: SkotiqTypography.sectionTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              SkotiqChip(
                label: definition.filterName,
                tone: ChipTone.neutral,
              ),
              const SizedBox(width: SkotiqTokens.spaceXs),
              SkotiqChip(
                label: depthLockStateLabel(state),
                tone: depthLockStateTone(state),
                dot: true,
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          // The estimator's own sentence when it has one — it knows why the
          // state is what it is — and the state's caption otherwise, so a
          // goal that has never been analysed still explains itself.
          Text(
            report?.reason.isNotEmpty == true
                ? report!.reason
                : depthLockStateCaption(state),
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          DepthLockProgress(goal: goal),

          const SizedBox(height: SkotiqTokens.spaceMd),
          ReadoutRow(
            gap: SkotiqTokens.spaceMd,
            children: <Readout>[
              Readout(value: depthLockScore(report?.score), label: 'S/N'),
              Readout(
                value: depthLockScore(report?.conservativeScore),
                label: 'Conservative',
              ),
              Readout(
                value: definition.measurement.threshold.toStringAsFixed(1),
                label: 'Threshold',
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            'The conservative score is the one that must clear the threshold; '
            'it is the score less the margin for having looked many times.',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          ReadoutRow(
            gap: SkotiqTokens.spaceMd,
            children: <Readout>[
              Readout(value: '${goal.evidenceFrames}', label: 'Evidence'),
              Readout(
                value: '${report?.confirmationFrames ?? 0}',
                label: 'Confirming',
              ),
              Readout(value: '${goal.candidateFrames}', label: 'Candidate'),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          KeyValueList(
            rows: <(String, String)>[
              ('Uncertainty', depthLockAdu(report?.uncertaintyAdu)),
              (
                'Coverage',
                report == null
                    ? '—'
                    : depthLockCoverageLabel(
                        coverage: report.coverage,
                        measurement: definition.measurement,
                      ),
              ),
              ('Marked on', depthLockTimestamp(goal.selectedAtMs)),
              ('Revision', '${goal.revision}'),
            ],
          ),
          if (report?.forecast != null) ...<Widget>[
            const SizedBox(height: SkotiqTokens.spaceSm),
            KeyValueList(
              rows: <(String, String)>[
                (
                  'Noise per exposure',
                  depthLockAdu(report!.forecast!.perFrameNoiseAdu),
                ),
                (
                  'Recent exposures',
                  depthLockAdu(report.forecast!.recentFrameNoiseAdu),
                ),
                (
                  'Best stretch',
                  depthLockAdu(report.forecast!.bestFrameNoiseAdu),
                ),
              ],
            ),
          ],
          const SizedBox(height: SidePanel.sectionGap),
          DepthLockCurveChart(goal: goal),
          if (!goal.analysisCurrent) ...<Widget>[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              'Analysis pending for the latest frame.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.warning,
              ),
            ),
          ],
          if (goal.lastIssue != null && goal.lastIssue!.isNotEmpty) ...<Widget>[
            const SizedBox(height: SkotiqTokens.spaceSm),
            SkotiqInlineBanner(
              // Verbatim: this is the ingestion layer explaining why the
              // newest frame was refused, and it is the only explanation
              // there is.
              message: goal.lastIssue!,
              severity: SkotiqAlertSeverity.warning,
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqSwitchRow(
            label: 'Collect evidence',
            compact: true,
            value: definition.enabled,
            onChanged:
                _busy ? null : (value) => _setPreferences(enabled: value),
          ),
          SkotiqSwitchRow(
            label: 'Automatic completion',
            subtitle:
                'Let a bound Smart Exposure plan finish this filter early '
                'once the goal is reliably achieved.',
            compact: true,
            value: definition.automaticCompletion,
            onChanged:
                _busy ? null : (value) => _setPreferences(automatic: value),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: <Widget>[
              SkotiqButton(
                label: 'Edit',
                icon: SkotiqIcons.edit,
                size: ButtonSize.small,
                variant: ButtonVariant.ghost,
                semanticsHint:
                    'Change this goal. Editing starts the evidence over.',
                onPressed: _busy ? null : _edit,
              ),
              SkotiqButton(
                label: 'Edit region',
                icon: SkotiqIcons.crosshair,
                size: ButtonSize.small,
                variant: ButtonVariant.ghost,
                semanticsHint:
                    'Reopen the two boxes on the frame. Saving is a revision '
                    'and starts the evidence over.',
                onPressed: _busy ? null : widget.onEditRegion,
              ),
              SkotiqButton(
                label: 'Re-measure',
                icon: SkotiqIcons.refresh,
                size: ButtonSize.small,
                variant: ButtonVariant.ghost,
                semanticsHint:
                    'Re-evaluate the goal over the evidence it already holds',
                onPressed:
                    _busy ? null : () => _run(() => _goals.replayGoal(goal.id)),
              ),
              SkotiqButton(
                label: 'Add frames',
                icon: SkotiqIcons.upload,
                size: ButtonSize.small,
                variant: ButtonVariant.ghost,
                semanticsHint: 'Offer saved lights to this goal',
                onPressed: _busy ? null : _ingest,
              ),
              SkotiqButton(
                label: 'Remove',
                icon: SkotiqIcons.delete,
                size: ButtonSize.small,
                variant: ButtonVariant.destructive,
                onPressed: _busy ? null : _remove,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
