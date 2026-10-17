import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../sequencer/widgets/mosaic_wizard_dialog.dart';
import 'mosaic_format.dart';
import 'mosaic_project_controller.dart';
import 'mosaic_project_screen.dart';

/// A simple list of every durable mosaic project, reachable from nav / analytics.
///
/// Each row opens [MosaicProjectScreen] at `/mosaic/:id`. Design-system pure:
/// rows are [SkotiqCard]s with a status pill and the grid summary.
class MosaicProjectsListScreen extends ConsumerWidget {
  const MosaicProjectsListScreen({super.key});

  /// Open the wizard and re-read the list when it closes.
  ///
  /// The wizard creates the project and pushes its detail screen, but this
  /// list stays mounted underneath, so its `autoDispose` provider is never
  /// disposed and never re-runs on its own. Without this re-read, Back lands on
  /// the state the list held before the create — on a first run, the "No mosaic
  /// projects yet" empty state, one route above the project just made.
  static Future<void> _newMosaic(BuildContext context, WidgetRef ref) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const MosaicWizardDialog(),
    );
    ref.invalidate(mosaicProjectsListProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    if (ref.watch(backendProvider) is NetworkBackend) {
      return Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const PageHeader(
                icon: SkotiqIcons.grid,
                title: 'Mosaic projects',
                actions: [_MosaicBackAction()],
              ),
              const Expanded(
                child: EmptyState(
                  icon: SkotiqIcons.device,
                  title: 'Open mosaic projects on the imaging host',
                  body: 'Durable mosaic projects, panel masters, and stitched '
                      'outputs are stored and processed on the imaging '
                      'computer. Remote project control is unavailable in '
                      'this release.',
                ),
              ),
            ],
          ),
        ),
      );
    }
    final projectsAsync = ref.watch(mosaicProjectsListProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              icon: SkotiqIcons.grid,
              // No subtitle. "Multi-panel mosaics: capture, integrate, stitch"
              // described the screen to someone who has already opened it;
              // 02's fifth rule sends that to the help popover.
              title: 'Mosaic projects',
              actions: [
                const _MosaicBackAction(),
                // The page's ONE primary (02, rule 4).
                SkotiqButton(
                  label: 'New mosaic',
                  icon: SkotiqIcons.add,
                  size: ButtonSize.small,
                  onPressed: () => _newMosaic(context, ref),
                ),
              ],
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(mosaicProjectsListProvider);
                  await ref.read(mosaicProjectsListProvider.future);
                },
                child: projectsAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => _refreshableCenter(
                    EmptyState(
                      icon: SkotiqIcons.warning,
                      title: 'Could not load mosaic projects',
                      body: '$e',
                    ),
                  ),
                  data: (projects) => projects.isEmpty
                      ? _refreshableCenter(
                          // Lead with the control that is on this screen —
                          // "New mosaic" sits in the header — and keep the
                          // Framing and Planetarium routes as the aside they
                          // are.
                          EmptyState(
                            icon: SkotiqIcons.grid,
                            title: 'No mosaic projects yet',
                            body:
                                'Start one with "New mosaic" above, or design '
                                'a mosaic in Framing or the Planetarium and '
                                'save it as a project.',
                            // The page's one primary is the header's "New
                            // mosaic" (02, rule 4); the empty state repeats
                            // the action as a secondary, never a second
                            // primary.
                            action: SkotiqButton(
                              label: 'New mosaic',
                              icon: SkotiqIcons.add,
                              variant: ButtonVariant.secondary,
                              size: ButtonSize.small,
                              onPressed: () => _newMosaic(context, ref),
                            ),
                          ),
                        )
                      : ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding:
                              const EdgeInsets.all(SkotiqTokens.spaceLg),
                          itemCount: projects.length,
                          separatorBuilder: (_, __) => const SizedBox(
                            height: SkotiqTokens.spaceSm,
                          ),
                          itemBuilder: (context, index) => _ProjectRow(
                            project: projects[index],
                            // A project can be renamed, integrated or deleted
                            // on its own screen; the list underneath must not
                            // keep describing the state it was built with.
                            onReturn: () =>
                                ref.invalidate(mosaicProjectsListProvider),
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "leave this screen" bar.
///
/// The list is always reached by a push (Analytics → Projects → Mosaic
/// projects), and it hosts no navigation chrome of its own, so without this an
/// operator who opened it had no control that led anywhere except into a
/// project. Mirrors the bar the project screen and the collaborative mosaic
/// detail screen already carry.
/// The way out, in the page header.
///
/// This was a full-width "< Back" bar ABOVE the header — a second header row
/// on a screen 04-shell §4 gives one. The affordance stays (the mosaic routes
/// are pushed, and the rail highlights Darkroom while they are up); it is a
/// header action now, the same shape the Darkroom editor uses.
class _MosaicBackAction extends StatelessWidget {
  const _MosaicBackAction();

  @override
  Widget build(BuildContext context) {
    return SkotiqIconButton(
      icon: SkotiqIcons.arrowLeft,
      tooltip: 'Back to where the mosaic list was opened from',
      onPressed: () => _leave(context),
    );
  }

  /// Pop when this screen sits on a stack (the normal case). A deep link that
  /// left nothing beneath it falls back to Analytics, where the entry point
  /// lives, so the control is never inert.
  static void _leave(BuildContext context) {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    context.go('/analytics');
  }
}

/// Wraps a centered empty/error [child] in an always-scrollable viewport so the
/// enclosing [RefreshIndicator] can still be pulled when there is no list to
/// scroll.
Widget _refreshableCenter(Widget child) {
  return LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: child,
      ),
    ),
  );
}

class _ProjectRow extends StatelessWidget {
  final MosaicProject project;
  final VoidCallback onReturn;

  const _ProjectRow({required this.project, required this.onReturn});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqCard(
      enableHover: true,
      onTap: () async {
        await context.push<void>('/mosaic/${project.id}');
        onReturn();
      },
      child: Row(
        children: [
          Icon(SkotiqIcons.grid,
              size: SkotiqTokens.iconMd, color: colors.textSecondary),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  project.name.isEmpty ? 'Mosaic project' : project.name,
                  style: SkotiqTypography.body
                      .copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  '${formatMosaicGrid(cols: project.cols, rows: project.rows)}'
                  '  ·  ${project.totalPanels} panels',
                  style: SkotiqTypography.captionSm
                      .copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          StatusPill(
            icon: project.isComplete
                ? SkotiqIcons.success
                : SkotiqIcons.clock,
            label: '',
            value: mosaicProjectStatusLabel(project.status),
            status: project.isComplete
                ? StatusPillStatus.success
                : StatusPillStatus.inactive,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Icon(SkotiqIcons.chevronRight,
              size: SkotiqTokens.iconSm, color: colors.textMuted),
        ],
      ),
    );
  }
}
