part of '../analytics_screen.dart';

class _ProjectsTab extends ConsumerWidget {
  const _ProjectsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isRemote = ref.watch(isRemoteModeProvider);
    return Padding(
      padding: const EdgeInsets.all(SkotiqTokens.space2xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Entry point into the multi-panel mosaic projects list (the durable
          // capture/integrate/stitch projects created from the Mosaic Wizard).
          // Always present, independent of the target-tracking data below, so
          // the list is reachable even before any single target is tracked.
          Align(
            alignment: Alignment.centerRight,
            child: SkotiqButton(
              key: const ValueKey('mosaic_projects_entry'),
              label: isRemote
                  ? 'Mosaic projects on imaging host'
                  : 'Mosaic projects',
              icon: LucideIcons.layoutGrid,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () {
                if (isRemote) {
                  context.showInfoSnackBar(
                    'Open Mosaic Projects on the imaging host.',
                  );
                  return;
                }
                context.push(AppRoute.mosaicProjects.path);
              },
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const Expanded(child: ProjectTrackingPanel()),
        ],
      ),
    );
  }
}
