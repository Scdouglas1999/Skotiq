part of '../projects_tab_content.dart';

class _NoProjectsState extends StatelessWidget {
  final Future<void> Function() onCreate;
  final bool creating;

  const _NoProjectsState({required this.onCreate, required this.creating});

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: LucideIcons.folderOpen,
      title: 'No projects yet',
      body: 'Create a multi-night project to track targets and integration '
          'goals across clear nights.',
      action: SkotiqButton(
        label: 'New project',
        icon: LucideIcons.folderPlus,
        variant: ButtonVariant.primary,
        isLoading: creating,
        onPressed: creating ? null : () => onCreate(),
      ),
    );
  }
}

class _ProjectsError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ProjectsError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SkotiqTokens.space2xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SkotiqBanner(
              title: 'Failed to load projects',
              message: userFacingError(error),
              tone: BannerTone.error,
              action: SkotiqButton(
                label: 'Retry',
                icon: LucideIcons.refreshCw,
                size: ButtonSize.small,
                onPressed: onRetry,
              )),
        ),
      ),
    );
  }
}

class _ProjectsSkeleton extends StatelessWidget {
  const _ProjectsSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return ShimmerLoading(
      child: ListView.separated(
        padding: SkotiqTokens.screenPadding,
        itemCount: 4,
        separatorBuilder: (_, __) =>
            const SizedBox(height: SkotiqTokens.spaceSm),
        itemBuilder: (_, __) => Container(
          padding: SkotiqTokens.cardPadding,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: SkotiqTokens.borderRadiusLg,
            border: Border.all(color: colors.border),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonText(width: 180, height: 14),
              SizedBox(height: SkotiqTokens.spaceMd),
              SkeletonBox(height: 8),
              SizedBox(height: SkotiqTokens.spaceMd),
              Row(
                children: [
                  SkeletonBox(width: 64, height: 20),
                  SizedBox(width: SkotiqTokens.spaceSm),
                  SkeletonBox(width: 64, height: 20),
                  SizedBox(width: SkotiqTokens.spaceSm),
                  SkeletonBox(width: 64, height: 20),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

