import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/filters.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_astro/skotiq_astro.dart'
    show AstronomyCalculations, CatalogSearchResult;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show catalogStateProvider;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../router/app_routes.dart';
import '../../../router/planner_route.dart';
import '../../../router/settings_sections.dart';
import '../../../services/run_dashboard_providers.dart'
    show runDashboardActiveTargetProvider;
import '../../../utils/confirm_dialog.dart';
import '../../../utils/darkroom_navigation.dart';
import '../../../utils/plan_tonight_sequencer_helper.dart';
import '../../../utils/snackbar_helper.dart';
import '../../analytics/widgets/campaign_rollup_dialog.dart';
import '../../discover/mosaic/mosaic_format.dart';
import '../../discover/mosaic/mosaic_project_controller.dart';
import '../../discover/mosaic/mosaic_project_screen.dart'
    show mosaicProjectStatusLabel;
import '../../../router/sequencer_route.dart';
import '../../sequencer/sequencer_screen.dart';
import '../../sequencer/widgets/mosaic_wizard_dialog.dart';
import '../../sequencer/widgets/smart_night_dialog.dart';
import '../editors/integration_goals_editor.dart';
import '../editors/target_constraints_editor.dart';
import '../widgets/week_forecast_strip.dart';

part 'autopilot_bar.dart';
part 'autopilot_dialogs.dart';
part 'group_dialogs.dart';
part 'group_menu.dart';
part 'target_detail.dart';
part 'target_list.dart';
part 'tonight_windows.dart';

/// The width from which the detail sits beside the list; below it the list
/// is the tab and a target opens over it.
const double _kSideBySideWidth = 1160;

/// The detail column's width beside the list.
const double _kDetailWidth = 420;

/// How the list is ordered.
enum PlanTargetSort {
  nextUp('Next up'),
  name('Name'),
  leastDone('Least done'),
  mostTime('Most time'),
  lastImaged('Last imaged');

  const PlanTargetSort(this.label);
  final String label;
}

/// Which targets the list keeps.
enum PlanTargetStatusFilter {
  any('Any status'),
  upTonight('Up tonight'),
  needsData('Needs data'),
  done('Goal met');

  const PlanTargetStatusFilter(this.label);
  final String label;
}

/// Plan > Targets: the owner's targets, how far along each is, and the
/// autopilot that works through them. A group narrows the list and the
/// autopilot to its members; mosaics are listed as their own group.
class PlanTargetsTab extends ConsumerStatefulWidget {
  const PlanTargetsTab({super.key, this.initialGroup, this.initialTargetId});

  /// A group id, or [plannerMosaicsGroupWord], from the link that opened the
  /// tab.
  final String? initialGroup;

  /// The target the link asked to select.
  final int? initialTargetId;

  @override
  ConsumerState<PlanTargetsTab> createState() => _PlanTargetsTabState();
}

class _PlanTargetsTabState extends ConsumerState<PlanTargetsTab>
    with WidgetsBindingObserver {
  String _query = '';
  PlanTargetSort _sort = PlanTargetSort.nextUp;
  PlanTargetStatusFilter _statusFilter = PlanTargetStatusFilter.any;
  bool _showMosaics = false;
  int? _selectedTargetId;

  bool _autopilotBusy = false;
  bool _groupBusy = false;
  int? _staleGroupDropped;

  /// Autopilot actions sent to the host; a host change drops what the old
  /// host answers.
  late final _hostScopes = ref.backendScopes(alive: () => mounted);
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  /// The settings in force as the tab shows them, for the settings dialog,
  /// which stays open across saves and host changes.
  final _shownConfig = ValueNotifier<SchedulerConfig>(SchedulerConfig.defaults);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedTargetId = widget.initialTargetId;
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        // Nothing asked of the old host carries over to the new one.
        _hostScopes.cancelAll();
        if (mounted) {
          setState(() {
            _autopilotBusy = false;
            _groupBusy = false;
          });
        }
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyLinkGroup());
  }

  @override
  void didUpdateWidget(PlanTargetsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialGroup != oldWidget.initialGroup) _applyLinkGroup();
    if (widget.initialTargetId != oldWidget.initialTargetId &&
        widget.initialTargetId != null) {
      setState(() => _selectedTargetId = widget.initialTargetId);
    }
  }

  /// Selects the group a link named. A link without one leaves the saved
  /// group as it is.
  void _applyLinkGroup() {
    if (!mounted) return;
    final word = widget.initialGroup?.trim().toLowerCase();
    if (word == null || word.isEmpty) return;
    if (word == plannerMosaicsGroupWord) {
      setState(() => _showMosaics = true);
      return;
    }
    final id = int.tryParse(word);
    setState(() => _showMosaics = false);
    if (word == 'all') {
      unawaited(_selectGroup(null));
    } else if (id != null) {
      unawaited(_selectGroup(id));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = ref.read(autopilotControllerProvider.notifier);
    if (state == AppLifecycleState.resumed) {
      controller.resumePolling();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      controller.pausePolling();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backendSubscription?.close();
    _shownConfig.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- autopilot

  Future<void> _runAutopilot(
    _AutopilotAction action, {
    bool allowWarnings = false,
  }) async {
    if (_autopilotBusy) return;
    final command = _hostScopes.beginLatest(#schedulerAction);
    final scheduler = ref.read(schedulerControlProvider);
    setState(() => _autopilotBusy = true);
    try {
      if (action == _AutopilotAction.start) {
        final readiness = await scheduler.startReadiness();
        if (readiness.blocked ||
            (readiness.warnings.isNotEmpty && !allowWarnings)) {
          throw StateError(
            readiness.blocked
                ? 'The rig is not ready to run unattended.'
                : 'The start warnings need confirming.',
          );
        }
      }
      switch (action) {
        case _AutopilotAction.start:
          await scheduler.start(confirmWarnings: allowWarnings);
        case _AutopilotAction.pause:
          await scheduler.pause();
        case _AutopilotAction.resume:
          await scheduler.resume();
        case _AutopilotAction.stop:
          await scheduler.stop();
        case _AutopilotAction.evaluate:
          await scheduler.evaluate(reason: 'manual force re-evaluation');
      }
      if (command.isCurrent) _refreshAutopilot();
    } catch (error) {
      if (!mounted) return;
      if (command.isCurrent) {
        context.showErrorSnackBar(
          'The autopilot could not do that: ${userFacingError(error)}',
        );
      }
    } finally {
      if (command.isCurrent) setState(() => _autopilotBusy = false);
    }
  }

  void _refreshAutopilot() {
    ref.invalidate(schedulerRemoteSnapshotProvider);
    ref.invalidate(schedulerPreviewDecisionProvider);
  }

  Future<void> _reevaluate(String reason) async {
    try {
      await ref.read(schedulerControlProvider).evaluate(reason: reason);
      if (mounted) _refreshAutopilot();
    } catch (error) {
      if (!mounted) return;
      context.showErrorSnackBar(
        'Could not rescore the targets: ${userFacingError(error)}',
      );
    }
  }

  Future<void> _startWithConfirmation(
    List<SchedulerReadinessIssue> warnings,
  ) async {
    if (warnings.isEmpty) {
      await _runAutopilot(_AutopilotAction.start);
      return;
    }
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Start with these not ready?',
      message: 'The rig can run, but:\n\n'
          '${warnings.map((w) => '${w.title}: ${w.detail}').join('\n')}',
      confirmLabel: 'Start anyway',
    );
    if (confirmed) {
      await _runAutopilot(_AutopilotAction.start, allowWarnings: true);
    }
  }

  /// Shows [config] at once and saves it to the host.
  void _applyConfig(SchedulerConfig config) {
    _shownConfig.value = config;
    ref.read(autopilotControllerProvider.notifier).apply(
      config,
      onSaveFailed: (error) {
        if (!mounted) return;
        context.showErrorSnackBar(
          'Could not save the autopilot settings: ${userFacingError(error)}',
        );
      },
    );
  }

  // ------------------------------------------------------------------- groups

  /// Group edits are made on the imaging host's own screen.
  bool _groupsReadOnly() {
    if (!ref.read(isRemoteModeProvider)) return false;
    context.showInfoSnackBar('Groups are edited on the imaging host.');
    return true;
  }

  Future<void> _selectGroup(int? id) async {
    if (_showMosaics) setState(() => _showMosaics = false);
    if (ref.read(activeProjectIdProvider) == id) return;
    try {
      await ref.read(activeProjectIdProvider.notifier).setActiveProject(id);
    } catch (error) {
      if (!mounted) return;
      context.showErrorSnackBar(
        'Could not save the group choice: ${userFacingError(error)}',
      );
    }
  }

  /// The saved group no longer exists (deleted elsewhere), and the autopilot
  /// narrowed to it would have nothing to pick: fall back to all targets.
  void _dropStaleGroup(int staleId) {
    if (_staleGroupDropped == staleId) return;
    _staleGroupDropped = staleId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(activeProjectIdProvider) == staleId) {
        unawaited(_selectGroup(null));
      }
    });
  }

  /// Runs one group edit at a time and reports a failure in [failure].
  Future<bool> _groupEdit(
    String failure,
    Future<void> Function(ProjectService service) edit,
  ) async {
    if (_groupBusy) return false;
    final backend = ref.read(backendProvider);
    setState(() => _groupBusy = true);
    try {
      await edit(ref.read(projectServiceProvider));
      ref.invalidate(groupMembersProvider);
      return true;
    } catch (error) {
      if (mounted) {
        context.showErrorSnackBar(
          ref.scopeOver<Object>(backendProvider, backend).isCurrent
              ? '$failure ${userFacingError(error)}'
              : 'The imaging host changed. Try again.',
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _groupBusy = false);
    }
  }

  Future<void> _newGroup() async {
    if (_groupsReadOnly()) return;
    final result = await showDialog<_GroupFormResult>(
      context: context,
      builder: (_) => const _GroupFormDialog(),
    );
    if (result == null || !mounted) return;
    int? newId;
    final created = await _groupEdit('Could not create the group.', (s) async {
      newId = await s.createProject(
        name: result.name,
        description: result.description,
      );
    });
    if (created && newId != null) await _selectGroup(newId);
  }

  Future<void> _renameGroup(Project group) async {
    if (_groupsReadOnly()) return;
    final result = await showDialog<_GroupFormResult>(
      context: context,
      builder: (_) => _GroupFormDialog(existing: group),
    );
    if (result == null || !mounted) return;
    await _groupEdit(
      'Could not rename the group.',
      (s) => s.updateProject(
        group.copyWith(
          name: result.name,
          description: result.description,
          clearDescription: result.description == null,
        ),
      ),
    );
  }

  Future<void> _deleteGroup(Project group) async {
    if (_groupsReadOnly()) return;
    final id = group.id;
    if (id == null) return;
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Delete the group "${group.name}"?',
      message: 'Its targets, their frames and their goals are kept. Only the '
          'grouping is removed.',
      confirmLabel: 'Delete group',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    final deleted = await _groupEdit(
      'Could not delete the group.',
      (s) => s.deleteProject(id),
    );
    if (deleted && ref.read(activeProjectIdProvider) == id) {
      await _selectGroup(null);
    }
  }

  Future<void> _addTarget(Project? group, Set<int> listed) async {
    if (group != null && _groupsReadOnly()) return;
    final targetId = await showDialog<int>(
      context: context,
      builder: (_) => _AddTargetDialog(
        hiddenTargetIds: group == null ? const {} : listed,
        groupName: group?.name,
      ),
    );
    if (targetId == null || !mounted) return;
    final groupId = group?.id;
    if (groupId != null) {
      await _groupEdit(
        'Could not add the target to the group.',
        (s) => s.addTarget(projectId: groupId, targetId: targetId),
      );
    }
    if (mounted) setState(() => _selectedTargetId = targetId);
  }

  Future<void> _removeFromGroup(Project group, PlanTarget target) async {
    if (_groupsReadOnly()) return;
    final groupId = group.id;
    if (groupId == null) return;
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Take ${target.name} out of "${group.name}"?',
      message: 'Its frames and goals are kept, and it stays under All targets.',
      confirmLabel: 'Take out',
    );
    if (!confirmed || !mounted) return;
    await _groupEdit(
      'Could not take the target out of the group.',
      (s) => s.removeTarget(projectId: groupId, targetId: target.id),
    );
  }

  Future<void> _planTonight(Project group, List<PlanTarget> members) async {
    final unfinished = [
      for (final t in members)
        if (!t.progress.isCompleted) t.id,
    ];
    if (unfinished.isEmpty) {
      context.showSuccessSnackBar(
        members.isEmpty
            ? '"${group.name}" has no targets to plan.'
            : 'Every target in "${group.name}" has met its goal.',
      );
      return;
    }
    await showSmartNightDialog(
      context,
      seedTargetIds: unfinished,
      seedSourceLabel: group.name,
    );
  }

  Future<void> _cleanUp(int count) async {
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Remove $count unused ${count == 1 ? 'target' : 'targets'}?',
      message: 'Targets with no frames, no sessions and no goal are removed '
          'from your list. Nothing that was imaged is touched.',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    final host = ref.backendScope();
    try {
      final removed =
          await ref.read(targetLibraryProvider).deleteUntrackedTargets();
      if (!mounted || host.isStale) return;
      ref.invalidate(allDbTargetsProvider);
      ref.invalidate(favoriteDbTargetsProvider);
      ref.invalidate(unusedTargetsCountProvider);
      context.showSuccessSnackBar(
        'Removed $removed unused ${removed == 1 ? 'target' : 'targets'}.',
      );
    } catch (error) {
      if (!mounted || host.isStale) return;
      context.showErrorSnackBar(
        'Could not remove the unused targets: ${userFacingError(error)}',
      );
    }
  }

  // ------------------------------------------------------------ autopilot list

  /// Takes [target] off the autopilot's list, or puts it back. Its goals and
  /// limits stay either way.
  Future<void> _setInAutopilot(PlanTarget target, bool include) async {
    final host = ref.backendScope();
    final queue = ref.read(schedulerQueueServiceProvider);
    try {
      if (include) {
        await queue.readmit(target.id);
      } else {
        await queue.remove(target.id);
      }
      if (!mounted || host.isStale) return;
      ref.invalidate(autopilotRemovedTargetIdsProvider);
      await _reevaluate(include ? 'target readmitted' : 'target removed');
    } catch (error) {
      if (!mounted || host.isStale) return;
      context.showErrorSnackBar(
        'Could not change the autopilot list: ${userFacingError(error)}',
      );
    }
  }

  void _select(int? targetId) => setState(() => _selectedTargetId = targetId);

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final autopilot = ref.watch(autopilotViewProvider);
    ref.watch(autopilotControllerProvider);
    final shownConfig =
        ref.read(autopilotControllerProvider.notifier).shownConfig(autopilot);
    if (shownConfig != _shownConfig.value) {
      // The dialog listening to this is outside this build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _shownConfig.value = shownConfig;
      });
    }
    final targetsAsync = ref.watch(planTargetsProvider);
    final groupsAsync = ref.watch(projectListProvider);
    final groups = groupsAsync.valueOrNull ?? const [];
    final activeId = ref.watch(activeProjectIdProvider);
    final group = groups.where((g) => g.id == activeId).firstOrNull;
    if (activeId != null && group == null && groupsAsync.hasValue) {
      _dropStaleGroup(activeId);
    }
    final windows = ref.watch(_tonightWindowsProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final phone = constraints.maxWidth < SkotiqTokens.breakpointTablet;
        final wide = constraints.maxWidth >= _kSideBySideWidth;
        // Mosaics open on their own page, so their rows take the width.
        final sideBySide = wide && !_showMosaics;
        final padding = phone
            ? SkotiqTokens.screenPaddingCompact
            : SkotiqTokens.screenPadding;

        final all = targetsAsync.valueOrNull ?? const <PlanTarget>[];
        final scoped = group == null
            ? all
            : [
                for (final t in all)
                  if (t.inGroup(group.id!)) t,
              ];
        final now = ref.watch(clockProvider).instant;
        // A run started outside the autopilot (Image tonight, the
        // Sequencer) images its target too.
        final runTarget = ref.watch(sequenceExecutionStateProvider).isLive
            ? ref.watch(runDashboardActiveTargetProvider)
            : null;
        final rows =
            _rows(scoped, autopilot, windows, now, runTarget: runTarget);
        final selected =
            rows.where((r) => r.target.id == _selectedTargetId).firstOrNull;
        // Beside the list the detail always shows a target; the first row
        // stands in until one is chosen.
        final shown = selected ?? (sideBySide ? rows.firstOrNull : null);

        final bar = _AutopilotBar(
          view: autopilot,
          groupName: group?.name,
          busy: _autopilotBusy,
          compact: phone,
          nextLine: _nextLine(autopilot, rows, group, now),
          onStart: () => _startWithConfirmation(
            autopilot.readiness?.warnings ?? const [],
          ),
          onAction: _runAutopilot,
          onWhy: () => _showWhy(context, autopilot),
          onSettings: () => _showAutopilotSettings(
            context,
            config: _shownConfig,
            onChanged: _applyConfig,
          ),
        );

        final list = _TargetListColumn(
          loading: targetsAsync.isLoading && !targetsAsync.hasValue,
          error: targetsAsync.hasError ? targetsAsync.error : null,
          onRetry: () {
            ref.invalidate(allDbTargetsProvider);
            ref.invalidate(allDbImagesProvider);
            ref.invalidate(projectListProvider);
          },
          rows: rows,
          libraryEmpty: all.isEmpty,
          groups: groups,
          group: group,
          showMosaics: _showMosaics,
          query: _query,
          sort: _sort,
          statusFilter: _statusFilter,
          selectedId: shown?.target.id,
          compact: phone,
          scrolls: !phone,
          busy: _groupBusy,
          onQuery: (q) => setState(() => _query = q.trim()),
          onSort: (s) => setState(() => _sort = s),
          onStatusFilter: (f) => setState(() => _statusFilter = f),
          onSelectGroup: _selectGroup,
          onShowMosaics: () => setState(() => _showMosaics = true),
          onNewGroup: _newGroup,
          onRenameGroup: _renameGroup,
          onDeleteGroup: _deleteGroup,
          onCleanUp: _cleanUp,
          onAddTarget: () => _addTarget(group, {for (final t in scoped) t.id}),
          onPlanTonight:
              group == null ? null : () => _planTonight(group, scoped),
          onOpen: (row) {
            _select(row.target.id);
            if (!sideBySide) _openDetailOver(context, row.target.id);
          },
        );

        // The detail takes its column only when there is a target to show.
        final body = sideBySide && shown != null
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: list),
                  const SizedBox(width: SkotiqTokens.spaceLg),
                  SizedBox(
                    width: _kDetailWidth,
                    child: _TargetDetail(
                      key: ValueKey('plan-target-detail-${shown.target.id}'),
                      row: shown,
                      group: group,
                      onSetInAutopilot: _setInAutopilot,
                      onRemoveFromGroup: _removeFromGroup,
                      onLimitsChanged: () =>
                          unawaited(_reevaluate('constraint edit')),
                    ),
                  ),
                ],
              )
            : list;

        // With no target to run, the way forward is the list's "Add target",
        // not the rig's readiness.
        final banner = all.isEmpty && !autopilot.hasCandidates
            ? null
            : _blockerBanner(autopilot);
        // On a phone the bar and filters scroll away with the list.
        if (phone) {
          return SingleChildScrollView(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                bar,
                if (banner != null) ...[
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  banner,
                ],
                const SizedBox(height: SkotiqTokens.spaceLg),
                body,
              ],
            ),
          );
        }
        return Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              bar,
              if (banner != null) ...[
                const SizedBox(height: SkotiqTokens.spaceSm),
                banner,
              ],
              const SizedBox(height: SkotiqTokens.spaceLg),
              Expanded(child: body),
            ],
          ),
        );
      },
    );
  }

  /// The target's page over the list, for widths with no room beside it.
  void _openDetailOver(BuildContext context, int targetId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _TargetDetailPage(
          targetId: targetId,
          onSetInAutopilot: _setInAutopilot,
          onRemoveFromGroup: _removeFromGroup,
          onLimitsChanged: () => unawaited(_reevaluate('constraint edit')),
        ),
      ),
    );
  }

  /// The one thing that stops the autopilot, with its way out; null when
  /// nothing does.
  Widget? _blockerBanner(AutopilotView view) {
    final status = view.status;
    final readiness = view.readiness;
    if (status == null || readiness == null) return null;
    if (status.pausedByOperatorStop) {
      return SkotiqBanner(
        key: const ValueKey('autopilot-operator-pause-banner'),
        tone: BannerTone.warning,
        title: 'The autopilot stood down',
        message: 'You stopped the run it had started, so it is leaving the '
            'rig alone.',
        action: SkotiqButton(
          key: const ValueKey('autopilot-operator-pause-resume'),
          label: 'Resume',
          size: ButtonSize.small,
          variant: ButtonVariant.secondary,
          onPressed: _autopilotBusy
              ? null
              : () => _runAutopilot(_AutopilotAction.resume),
        ),
      );
    }
    if (status.state != SchedulerState.idle || !readiness.blocked) return null;
    final blockers = readiness.blockers;
    final first = blockers.firstOrNull;
    final more = blockers.length - 1;
    final fix = first == null ? null : _blockerFix(first.id);
    return SkotiqBanner(
      key: const ValueKey('autopilot-start-blocked-banner'),
      tone: BannerTone.warning,
      title: 'Cannot run unattended yet',
      message: first == null
          ? 'The imaging host did not report whether the rig is ready.'
          : '${first.title}. ${first.detail}'
              '${more > 0 ? ' $more more under Why.' : ''}',
      action: fix == null
          ? null
          : SkotiqButton(
              label: fix.$1,
              size: ButtonSize.small,
              variant: ButtonVariant.secondary,
              onPressed: () => context.go(fix.$2),
            ),
    );
  }
}

/// Where a start blocker is fixed: the button's label and its location.
(String, String)? _blockerFix(SchedulerReadinessIssueId id) => switch (id) {
      SchedulerReadinessIssueId.camera ||
      SchedulerReadinessIssueId.mount ||
      SchedulerReadinessIssueId.guider =>
        ('Open Equipment', AppRoute.equipment.path),
      SchedulerReadinessIssueId.location => (
          'Set location',
          AppRoutes.settings(SettingsSectionId.location),
        ),
      SchedulerReadinessIssueId.weather => (
          'Open Weather',
          AppRoute.weather.path
        ),
      _ => null,
    };

/// Hours the way the Darkroom and Analytics print them.
String _hours(double seconds) => DurationFormat.decimalHours(seconds);

/// "4.5h / 12h", "31.9h · no goal", or "Not started".
String _progressText(ProjectProgress p) {
  if (p.goal.isSet)
    return '${_hours(p.integratedSecs)} / ${_hours(p.goal.goalSecs)}';
  if (p.integratedSecs <= 0) return 'Not started';
  return '${_hours(p.integratedSecs)} · no goal';
}
