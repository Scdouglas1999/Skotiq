import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
// CatalogSearchResult: the Add Target sheet searches the installed sky
// catalogs, not only the target library. catalogStateProvider: and when no
// catalog has been downloaded there is nothing on this machine to search, so
// the sheet must say that instead of "nothing matches".
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show CatalogSearchResult, catalogStateProvider;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../scheduler/widgets/integration_goals_editor.dart';
import '../../sequencer/widgets/smart_night_dialog.dart';

part 'projects_tab_content/project_header.dart';
part 'projects_tab_content/progress_widgets.dart';
part 'projects_tab_content/project_dialogs.dart';
part 'projects_tab_content/terminal_states.dart';

/// Projects tab body for the multi-night planner.
///
/// Surfaces the campaign layer of the planning stack:
///
///   * a project selector ([projectListProvider]) bound to
///     [activeProjectIdProvider], with create / edit / delete affordances;
///   * the active project's targets with an accrued-vs-remaining roll-up
///     ([activeProjectProgressProvider]) — a project-level bar, per-target
///     cards, and a per-filter captured/goal breakdown;
///   * an add-target flow that attaches catalog targets
///     ([allDbTargetsProvider]) to the project, and a per-target "Edit goals"
///     affordance that reuses the existing [IntegrationGoalsEditor] rather than
///     rebuilding per-filter goal UI.
///
/// All mutations route through [projectServiceProvider]; the derived providers
/// recompute off the service's change stream and the captures/goals streams, so
/// this widget never denormalizes progress.
class ProjectsTabContent extends ConsumerStatefulWidget {
  const ProjectsTabContent({super.key});

  @override
  ConsumerState<ProjectsTabContent> createState() => _ProjectsTabContentState();
}

class _ProjectsTabContentState extends ConsumerState<ProjectsTabContent> {
  bool _changingProject = false;
  bool _projectMutationInFlight = false;

  // Re-entrancy guard for the Smart Night handoff: it awaits the roll-up before
  // opening the (modal) wizard, so a rapid double-tap would otherwise stack two
  // dialogs. Every other mutation opens its dialog synchronously, so the modal
  // barrier already serializes them.
  bool _planningSmartNight = false;

  // Active-selection reconciliation bookkeeping. `_buildBody` visually falls
  // back to `projects.first` when the persisted id is absent or stale, but the
  // progress roll-up, Smart Night handoff, week forecast, and scheduler engine
  // all read the raw persisted id — so a null/stale value makes them disagree
  // with the header. We write the resolved id back post-frame; these guard that
  // write against build-time writes, hydration races, and persistence loops.
  bool _reconcileScheduled = false;
  int? _reconcileFailedFor;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final projectsAsync = ref.watch(projectListProvider);

    return projectsAsync.when(
      loading: () => const _ProjectsSkeleton(),
      error: (err, _) => _ProjectsError(
        error: err,
        onRetry: () => ref.invalidate(projectListProvider),
      ),
      data: (projects) {
        if (projects.isEmpty) {
          return _NoProjectsState(
            onCreate: _openCreateDialog,
            creating: _projectMutationInFlight,
          );
        }
        return _buildBody(
          colors: colors,
          projects: projects,
          onCreate: _openCreateDialog,
        );
      },
    );
  }

  /// Projects are host-owned: a remote slave reads the campaign list + progress
  /// over REST but cannot mutate it (there is no project-write endpoint, and
  /// the local DB write would be lost). Gate the mutation affordances on a
  /// slave with a clear notice instead of letting ProjectService throw.
  bool _blockedOnRemote() {
    if (ref.read(backendProvider) is! NetworkBackend) return false;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Projects are managed on the imaging host.'),
        ),
      );
    }
    return true;
  }

  Future<void> _selectProject(int id) async {
    if (_changingProject || _projectMutationInFlight) return;
    setState(() => _changingProject = true);
    try {
      await ref.read(activeProjectIdProvider.notifier).setActiveProject(id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save the active project.')),
        );
      }
    } finally {
      if (mounted) setState(() => _changingProject = false);
    }
  }

  void _showProjectError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  bool _beginProjectMutation() {
    if (_projectMutationInFlight || !mounted) return false;
    setState(() => _projectMutationInFlight = true);
    return true;
  }

  void _finishProjectMutation() {
    if (mounted) setState(() => _projectMutationInFlight = false);
  }

  bool _backendIs(Object backend) =>
      identical(ref.read(backendProvider), backend);

  int? _effectiveActiveProjectId() {
    final projects = ref.read(projectListProvider).valueOrNull;
    if (projects == null || projects.isEmpty) return null;
    final selected = ref.read(activeProjectIdProvider);
    for (final project in projects) {
      if (project.id == selected) return selected;
    }
    return projects.first.id;
  }

  void _showConnectionChanged(String action) {
    _showProjectError(
      'The imaging-host connection changed while $action. Try again on the '
      'current host.',
    );
  }

  // Create / edit / delete project

  Future<void> _openCreateDialog() async {
    if (_projectMutationInFlight || _changingProject) return;
    if (_blockedOnRemote()) return;
    final backend = ref.read(backendProvider);
    final result = await showDialog<_ProjectFormResult>(
      context: context,
      builder: (_) => const _ProjectFormDialog(),
    );
    if (result == null || !mounted) return;
    if (!_backendIs(backend)) {
      _showConnectionChanged('creating the project');
      return;
    }
    // The backend can switch host<->slave while the dialog is open; re-check so a
    // now-remote client surfaces the accurate notice instead of a generic error
    // from ProjectService's local-write assertion.
    if (_blockedOnRemote()) return;
    if (!_beginProjectMutation()) return;
    final service = ref.read(projectServiceProvider);
    try {
      final int newId;
      try {
        newId = await service.createProject(
          name: result.name,
          description: result.description,
        );
      } catch (_) {
        if (_backendIs(backend)) {
          _showProjectError('Could not create the project.');
        } else {
          _showConnectionChanged('creating the project');
        }
        return;
      }
      if (!mounted) return;
      if (!_backendIs(backend)) {
        _showConnectionChanged('creating the project');
        return;
      }
      try {
        await ref
            .read(activeProjectIdProvider.notifier)
            .setActiveProject(newId);
      } catch (_) {
        _showProjectError(
          'The project was created, but its active selection could not be '
          'saved.',
        );
      }
    } finally {
      _finishProjectMutation();
    }
  }

  Future<void> _openEditDialog(Project project) async {
    if (_projectMutationInFlight || _changingProject) return;
    if (_blockedOnRemote()) return;
    final backend = ref.read(backendProvider);
    final result = await showDialog<_ProjectFormResult>(
      context: context,
      builder: (_) => _ProjectFormDialog(existing: project),
    );
    if (result == null || !mounted) return;
    if (!_backendIs(backend)) {
      _showConnectionChanged('editing the project');
      return;
    }
    if (_blockedOnRemote()) return;
    if (_effectiveActiveProjectId() != project.id) {
      _showProjectError('The active project changed. Reopen the editor.');
      return;
    }
    if (!_beginProjectMutation()) return;
    final service = ref.read(projectServiceProvider);
    try {
      await service.updateProject(
        project.copyWith(
          name: result.name,
          description: result.description,
          clearDescription: result.description == null,
        ),
      );
    } catch (_) {
      if (_backendIs(backend)) {
        _showProjectError('Could not update the project.');
      } else {
        _showConnectionChanged('editing the project');
      }
    } finally {
      _finishProjectMutation();
    }
  }

  Future<void> _confirmDelete(Project project) async {
    if (_projectMutationInFlight || _changingProject) return;
    if (_blockedOnRemote()) return;
    final backend = ref.read(backendProvider);
    final colors = SkotiqColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: SkotiqTokens.borderRadiusMd,
            side: BorderSide(color: colors.border),
          ),
          title: Text(
            'Delete project?',
            style: SkotiqTypography.bodyStrong
                .copyWith(color: colors.textPrimary),
          ),
          content: Text(
            'Deleting "${project.name}" removes the project and detaches its '
            'targets. Your captured frames and integration goals are kept — '
            'only the project grouping is removed.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
              height: 1.45,
            ),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(dialogContext).pop(false),
            ),
            SkotiqButton(
              label: 'Delete',
              icon: LucideIcons.trash2,
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(dialogContext).pop(true),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    if (!_backendIs(backend)) {
      _showConnectionChanged('deleting the project');
      return;
    }
    if (_blockedOnRemote()) return;

    final id = project.id;
    if (id == null) {
      throw StateError('Cannot delete a project with no persisted id');
    }
    if (!_beginProjectMutation()) return;
    final service = ref.read(projectServiceProvider);
    try {
      try {
        await service.deleteProject(id);
      } catch (_) {
        if (_backendIs(backend)) {
          _showProjectError('Could not delete the project.');
        } else {
          _showConnectionChanged('deleting the project');
        }
        return;
      }
      if (!mounted) return;
      if (!_backendIs(backend)) {
        _showConnectionChanged('deleting the project');
        return;
      }

      // If the deleted project was active, fall back to the most-recent
      // remaining project (or clear the selection when none remain) so the
      // body never points at a dangling id.
      final activeId = ref.read(activeProjectIdProvider);
      if (activeId == id) {
        final List<Project> remaining;
        try {
          remaining = await service.listProjects();
        } catch (_) {
          _showProjectError(
            'The project was deleted, but the project list could not be '
            'refreshed.',
          );
          return;
        }
        final next = remaining.isEmpty ? null : remaining.first.id;
        if (!mounted) return;
        try {
          await ref
              .read(activeProjectIdProvider.notifier)
              .setActiveProject(next);
        } catch (_) {
          _showProjectError(
            'The project was deleted, but the replacement selection could not '
            'be saved.',
          );
        }
      }
    } finally {
      _finishProjectMutation();
    }
  }

  // Add target

  Future<void> _openAddTargetDialog(int projectId, Set<int> attachedIds) async {
    if (_projectMutationInFlight || _changingProject) return;
    if (_blockedOnRemote()) return;
    final backend = ref.read(backendProvider);
    final result = await showDialog<int>(
      context: context,
      builder: (_) => _AddTargetDialog(attachedTargetIds: attachedIds),
    );
    if (result == null || !mounted) return;
    if (!_backendIs(backend)) {
      _showConnectionChanged('adding the target');
      return;
    }
    if (_blockedOnRemote()) return;
    if (_effectiveActiveProjectId() != projectId) {
      _showProjectError('The active project changed. Add the target again.');
      return;
    }
    if (!_beginProjectMutation()) return;
    final service = ref.read(projectServiceProvider);
    try {
      await service.addTarget(projectId: projectId, targetId: result);
    } catch (_) {
      if (_backendIs(backend)) {
        _showProjectError('Could not add the target to this project.');
      } else {
        _showConnectionChanged('adding the target');
      }
    } finally {
      _finishProjectMutation();
    }
  }

  Future<void> _removeTarget(
      int projectId, int targetId, String targetName) async {
    if (_projectMutationInFlight || _changingProject) return;
    if (_blockedOnRemote()) return;
    final backend = ref.read(backendProvider);
    final colors = SkotiqColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: SkotiqTokens.borderRadiusMd,
            side: BorderSide(color: colors.border),
          ),
          title: Text(
            'Remove from project?',
            style: SkotiqTypography.bodyStrong
                .copyWith(color: colors.textPrimary),
          ),
          content: Text(
            'Removing "$targetName" detaches it from this project. Your '
            'captured frames and integration goals are kept — only the '
            'project grouping is removed.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
              height: 1.45,
            ),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(dialogContext).pop(false),
            ),
            SkotiqButton(
              label: 'Remove',
              icon: LucideIcons.trash2,
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(dialogContext).pop(true),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    if (!_backendIs(backend)) {
      _showConnectionChanged('removing the target');
      return;
    }
    if (_blockedOnRemote()) return;
    if (_effectiveActiveProjectId() != projectId) {
      _showProjectError('The active project changed. Remove the target again.');
      return;
    }
    if (!_beginProjectMutation()) return;
    final service = ref.read(projectServiceProvider);
    try {
      await service.removeTarget(projectId: projectId, targetId: targetId);
    } catch (_) {
      if (_backendIs(backend)) {
        _showProjectError('Could not remove the target from this project.');
      } else {
        _showConnectionChanged('removing the target');
      }
    } finally {
      _finishProjectMutation();
    }
  }

  // Edit goals

  Future<void> _openGoalsDialog(int targetId, String targetName) async {
    final profile = ref.read(activeEquipmentProfileProvider);
    final availableFilters =
        profile != null ? List<String>.from(profile.filterNames) : <String>[];
    await showDialog<void>(
      context: context,
      builder: (_) => SkotiqDialog(
        title: 'Integration goals — $targetName',
        icon: LucideIcons.target,
        width: 720,
        child: IntegrationGoalsEditor(
          targetId: targetId,
          targetName: targetName,
          availableFilters: availableFilters,
        ),
      ),
    );
  }

  // Smart night handoff (component C11)

  /// One-click handoff of the active project's still-incomplete targets into
  /// the Smart Night planner. Reads the active project's roll-up, pulls out the
  /// targets that still need data, and opens [SmartNightDialog] seeded with
  /// those ids so the wizard plans the campaign rather than the generic
  /// "best of everything tonight" set.
  ///
  /// Fail-loud: if the roll-up is unavailable (provider error / no active
  /// project) we surface a snackbar rather than opening an empty wizard, and if
  /// the project has no incomplete targets we tell the operator there is
  /// nothing left to plan instead of opening an unseeded dialog that would
  /// silently fall back to the generic set.
  Future<void> _planInSmartNight(Project active) async {
    if (_planningSmartNight || _projectMutationInFlight || _changingProject) {
      return;
    }
    final backend = ref.read(backendProvider);
    final projectId = active.id;
    setState(() => _planningSmartNight = true);
    try {
      final CampaignProgress? progress;
      try {
        progress = await ref.read(activeProjectProgressProvider.future);
      } catch (_) {
        _showProjectError('Could not load this project\'s planning progress.');
        return;
      }
      if (!mounted) return;
      if (!_backendIs(backend)) {
        _showConnectionChanged('loading the project plan');
        return;
      }
      if (_effectiveActiveProjectId() != projectId) {
        _showProjectError(
          'The active project changed while its plan was loading. Try again.',
        );
        return;
      }

      if (progress == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Select a project before planning in Smart Night.'),
          ),
        );
        return;
      }
      if (progress.project.id != projectId) {
        _showProjectError(
          'The project progress changed while its plan was loading. Try again.',
        );
        return;
      }

      final incompleteIds = progress.incompleteTargets
          .map((t) => t.targetId)
          .toList(growable: false);
      if (incompleteIds.isEmpty) {
        final colors = SkotiqColors.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"${active.name}" has no incomplete targets left to '
                'plan — every target has met its integration goals.'),
            backgroundColor: colors.success,
          ),
        );
        return;
      }

      // The awaited work is complete and the modal barrier itself prevents a
      // second launch. Stop the header spinner before awaiting the dialog's
      // eventual close; otherwise an indeterminate animation behind the modal
      // keeps widget tests and accessibility settle detection perpetually busy.
      setState(() => _planningSmartNight = false);
      await showSmartNightDialog(
        context,
        seedTargetIds: incompleteIds,
        seedSourceLabel: active.name,
      );
    } finally {
      if (mounted && _planningSmartNight) {
        setState(() => _planningSmartNight = false);
      }
    }
  }

  // Body

  Widget _buildBody({
    required SkotiqColors colors,
    required List<Project> projects,
    required Future<void> Function() onCreate,
  }) {
    final activeId = ref.watch(activeProjectIdProvider);
    // Resolve the active project. When the persisted id is absent or stale,
    // fall back to the first (most-recently-updated) project so the tab always
    // shows something actionable; the selector reflects that resolved choice.
    Project? matched;
    for (final p in projects) {
      if (p.id == activeId) {
        matched = p;
        break;
      }
    }
    if (matched != null) {
      // The persisted selection resolves to a real project. Clear any stale
      // reconcile-failure record so a transient settings error can be retried
      // if the selection later goes stale again.
      _reconcileFailedFor = null;
    } else {
      // The header is about to fall back to projects.first, but every OTHER
      // consumer of activeProjectIdProvider (progress roll-up, Smart Night
      // handoff, week forecast, scheduler scope) still reads the null/stale id
      // and would disagree with what we display. Persist the resolved id so
      // they converge on the same project.
      _scheduleActiveIdReconcile(projects.first.id);
    }
    final active = matched ?? projects.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ProjectHeaderBar(
          colors: colors,
          projects: projects,
          active: active,
          onSelect: _selectProject,
          interactionBusy: _changingProject || _projectMutationInFlight,
          mutatingProject: _projectMutationInFlight,
          planningSmartNight: _planningSmartNight,
          onCreate: onCreate,
          onEdit: () => _openEditDialog(active),
          onDelete: () => _confirmDelete(active),
          onPlanInSmartNight: () => _planInSmartNight(active),
        ),
        Expanded(
          child: _ActiveProjectProgress(
            colors: colors,
            onAddTarget: _openAddTargetDialog,
            onRemoveTarget: _removeTarget,
            onEditGoals: _openGoalsDialog,
            mutationsEnabled: !_projectMutationInFlight && !_changingProject,
          ),
        ),
      ],
    );
  }

  // Active-selection reconciliation

  /// Schedule a write of [fallbackId] into the persisted active-project id.
  ///
  /// Called from `build` when the header resolved to `projects.first` because
  /// the persisted id was null or stale. Deferred to a post-frame callback so we
  /// never mutate a provider mid-build; guarded so at most one write is in
  /// flight, and so a fallback whose persistence just failed is not retried on
  /// every rebuild (which would spin the tab against a wedged settings write).
  void _scheduleActiveIdReconcile(int? fallbackId) {
    if (fallbackId == null) return; // nothing persistable to converge on
    if (_reconcileScheduled) return; // one write in flight is enough
    if (_reconcileFailedFor == fallbackId) {
      return; // don't respin a failed write
    }
    _reconcileScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _reconcileScheduled = false;
        return;
      }
      // Hold the guard until the async reconcile settles so rebuilds during the
      // hydration wait don't stack redundant writes.
      _applyActiveIdReconcile(fallbackId)
          .whenComplete(() => _reconcileScheduled = false);
    });
  }

  /// Persist [fallbackId] as the active project, re-checking coherence first.
  Future<void> _applyActiveIdReconcile(int fallbackId) async {
    final notifier = ref.read(activeProjectIdProvider.notifier);
    // Gate on hydration: if the persisted selection has not been read yet, wait
    // for it rather than clobbering a legitimate late-loaded preference with the
    // fallback. `isLoaded`/`loaded` are owned by ActiveProjectNotifier.
    if (!notifier.isLoaded) {
      await notifier.loaded;
      if (!mounted) return;
    }

    // Re-resolve against the latest list + selection — both may have moved while
    // we waited for the frame or for hydration.
    final projects = ref.read(projectListProvider).valueOrNull;
    if (projects == null || projects.isEmpty) return;
    final validIds = projects.map((p) => p.id).whereType<int>().toSet();
    final activeId = ref.read(activeProjectIdProvider);
    if (activeId != null && validIds.contains(activeId)) return; // now coherent

    final resolved = projects.first.id;
    if (resolved == null || resolved == activeId) return;

    try {
      await notifier.setActiveProject(resolved);
    } catch (e) {
      // The header still shows projects.first via the fallback above, so the tab
      // stays usable; we simply could not persist the coherence write. Record the
      // target so we don't respin it every rebuild — an explicit selection, or a
      // change to the resolved fallback, retries it. This arm is the one place
      // in this file with no snackbar (it is a repair the operator never asked
      // for), so the log is the only signal that the selection on screen is not
      // the one that will come back after a restart.
      developer.log(
        'Could not persist the reconciled active project ($resolved); the tab '
        'shows it but the selection was not saved: $e',
        name: 'ProjectsTab',
        level: 900,
      );
      _reconcileFailedFor = resolved;
    }
  }
}
