part of 'plan_targets_tab.dart';

/// How many saved targets have no frames, no sessions and no goal; null while
/// the host has not answered.
final unusedTargetsCountProvider = FutureProvider<int?>((ref) async {
  ref.watch(allDbTargetsProvider);
  ref.watch(allSessionsProvider);
  return ref.watch(targetLibraryProvider).countUntrackedTargets();
});

/// What the group menu can ask for.
sealed class _GroupChoice {
  const _GroupChoice();
}

class _ShowGroup extends _GroupChoice {
  const _ShowGroup(this.id);
  final int? id;
}

class _ShowMosaics extends _GroupChoice {
  const _ShowMosaics();
}

class _NewGroup extends _GroupChoice {
  const _NewGroup();
}

class _RenameGroup extends _GroupChoice {
  const _RenameGroup();
}

class _DeleteGroup extends _GroupChoice {
  const _DeleteGroup();
}

class _CleanUp extends _GroupChoice {
  const _CleanUp(this.count);
  final int count;
}

/// The group filter: which group the list and the autopilot are narrowed to,
/// the mosaics, and the edits to the groups themselves.
class _GroupChip extends ConsumerWidget {
  const _GroupChip({
    required this.groups,
    required this.group,
    required this.showMosaics,
    required this.onSelectGroup,
    required this.onShowMosaics,
    required this.onNewGroup,
    required this.onRenameGroup,
    required this.onDeleteGroup,
    required this.onCleanUp,
  });

  final List<Project> groups;
  final Project? group;
  final bool showMosaics;
  final ValueChanged<int?> onSelectGroup;
  final VoidCallback onShowMosaics;
  final VoidCallback onNewGroup;
  final ValueChanged<Project> onRenameGroup;
  final ValueChanged<Project> onDeleteGroup;
  final ValueChanged<int> onCleanUp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unused = ref.watch(unusedTargetsCountProvider).valueOrNull ?? 0;
    final current = group;
    return SkotiqMenuChip<_GroupChoice>(
      key: const ValueKey('plan-targets-group-chip'),
      label: showMosaics ? 'Mosaics' : current?.name ?? 'All targets',
      name: 'Group',
      entries: [
        SkotiqMenuChoice(
          const _ShowGroup(null),
          'All targets',
          checked: !showMosaics && current == null,
        ),
        for (final g in groups)
          SkotiqMenuChoice(
            _ShowGroup(g.id),
            g.name,
            checked: !showMosaics && g.id == current?.id,
          ),
        SkotiqMenuChoice(
          const _ShowMosaics(),
          'Mosaics',
          checked: showMosaics,
        ),
        const SkotiqMenuDivider(),
        const SkotiqMenuChoice(_NewGroup(), 'New group…'),
        if (current != null && !showMosaics) ...[
          SkotiqMenuChoice(const _RenameGroup(), 'Rename "${current.name}"…'),
          SkotiqMenuChoice(
            const _DeleteGroup(),
            'Delete "${current.name}"…',
            destructive: true,
          ),
        ],
        if (unused > 0)
          SkotiqMenuChoice(_CleanUp(unused), 'Clean up unused targets…'),
      ],
      onSelected: (choice) => switch (choice) {
        _ShowGroup(:final id) => onSelectGroup(id),
        _ShowMosaics() => onShowMosaics(),
        _NewGroup() => onNewGroup(),
        _RenameGroup() => onRenameGroup(current!),
        _DeleteGroup() => onDeleteGroup(current!),
        _CleanUp(:final count) => onCleanUp(count),
      },
    );
  }
}

/// Opens the mosaic wizard and re-reads the list when it closes, so a mosaic
/// made there is listed on return.
Future<void> _newMosaic(BuildContext context, WidgetRef ref) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const MosaicWizardDialog(),
  );
  ref.invalidate(mosaicProjectsListProvider);
}

/// The mosaics, as rows that open each mosaic's page.
class _MosaicRows extends ConsumerWidget {
  const _MosaicRows({required this.scrolls});

  /// False inside a tab that scrolls as one.
  final bool scrolls;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Mosaic panels, masters and stitched outputs live on the imaging
    // computer and are worked on there.
    if (ref.watch(isRemoteModeProvider)) {
      return const EmptyState.compact(
        icon: SkotiqIcons.device,
        title: 'Mosaics are on the imaging host',
        body: 'Their panels and stitched images are stored and built on the '
            'imaging computer. Open them there.',
      );
    }
    final mosaics = ref.watch(mosaicProjectsListProvider);
    return mosaics.when(
      loading: () => const ShimmerLoading(
        child: Padding(
          padding: EdgeInsets.all(SkotiqTokens.spaceSm),
          child: SkeletonText(width: 200, height: 14),
        ),
      ),
      error: (error, _) => EmptyState.error(
        title: 'Could not load the mosaics',
        body: userFacingError(error),
        onRetry: () => ref.invalidate(mosaicProjectsListProvider),
      ),
      data: (list) {
        if (list.isEmpty) {
          return EmptyState.compact(
            icon: SkotiqIcons.grid,
            title: 'No mosaics yet',
            body: 'A mosaic is one target imaged as a grid of panels.',
            action: SkotiqButton(
              label: 'New mosaic',
              icon: LucideIcons.plus,
              size: ButtonSize.small,
              variant: ButtonVariant.secondary,
              onPressed: () => _newMosaic(context, ref),
            ),
          );
        }
        return ListView.builder(
          shrinkWrap: !scrolls,
          physics: scrolls ? null : const NeverScrollableScrollPhysics(),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final mosaic = list[i];
            return ListRow(
              key: ValueKey('plan-mosaic-row-${mosaic.id}'),
              icon: SkotiqIcons.grid,
              title: mosaic.name.isEmpty ? 'Mosaic' : mosaic.name,
              subtitle:
                  '${formatMosaicGrid(cols: mosaic.cols, rows: mosaic.rows)}'
                  ' · ${mosaic.totalPanels} panels',
              trailingWidget: Text(
                mosaicProjectStatusLabel(mosaic.status),
                style: SkotiqTypography.bodySm.copyWith(
                  color: mosaic.isComplete
                      ? SkotiqColors.of(context).success
                      : SkotiqColors.of(context).textMuted,
                ),
              ),
              showDivider: i < list.length - 1,
              // Rows come from the database, so they always carry an id.
              onTap: () async {
                await context.push<void>(AppRoutes.mosaicProject(mosaic.id!));
                ref.invalidate(mosaicProjectsListProvider);
              },
            );
          },
        );
      },
    );
  }
}
