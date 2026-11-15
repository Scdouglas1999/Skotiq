part of 'plan_targets_tab.dart';

/// How a row's status reads.
enum _StatusTone { quiet, plain, good, active }

/// One target as the list shows it: its progress joined with tonight's window
/// and what the autopilot makes of it.
@immutable
class _TargetRow {
  const _TargetRow({
    required this.target,
    required this.status,
    required this.tone,
    required this.rank,
    this.window,
    this.score,
  });

  final PlanTarget target;
  final _TonightWindow? window;
  final TargetScore? score;
  final String status;
  final _StatusTone tone;

  /// Order under "Next up": the target being imaged, the autopilot's pick,
  /// the rest it could take by score, then everything else.
  final double rank;

  bool get upTonight => window?.isUp ?? false;
}

/// Joins [targets] with tonight's windows and the autopilot's view of each.
List<_TargetRow> _rows(
  List<PlanTarget> targets,
  _AutopilotView autopilot,
  Map<int, _TonightWindow> windows,
) {
  final now = DateTime.now();
  final decision = autopilot.decision;
  final scores = {
    for (final s in decision?.scoredCandidates ?? const <TargetScore>[])
      s.targetId: s,
  };
  final currentId = autopilot.status?.currentTargetId;
  final nextId = decision?.chosenTargetId;

  return [
    for (final target in targets)
      () {
        final window = windows[target.id];
        final score = scores[target.id];
        final (String status, _StatusTone tone, double rank) = () {
          if (target.id == currentId) {
            return ('Imaging now', _StatusTone.active, 0.0);
          }
          if (!target.inAutopilot) {
            return ('Off autopilot', _StatusTone.quiet, 6.0);
          }
          if (target.progress.isCompleted) {
            return ('Goal met', _StatusTone.good, 5.0);
          }
          if (target.id == nextId) return ('Next up', _StatusTone.good, 1.0);
          final rises = window?.start;
          if (score != null && score.hardConstraintFailed) {
            final reason = score.rejectionReasons.firstOrNull;
            final kind =
                reason == null ? null : classifySchedulerRejection(reason);
            // Rising cures being too low or the sky being too bright; it
            // does not cure the moon, a missing filter or a time window.
            final waitsForSky = switch (kind) {
              null ||
              SchedulerRejectionKind.belowHorizon ||
              SchedulerRejectionKind.tooLowForSite ||
              SchedulerRejectionKind.behindHorizonProfile ||
              SchedulerRejectionKind.other =>
                true,
              _ => false,
            };
            if (waitsForSky && rises != null && rises.isAfter(now)) {
              return (
                'Up ${ClockFormat.hm(rises.toLocal())}',
                _StatusTone.quiet,
                3.0,
              );
            }
            return (
              kind == null || kind == SchedulerRejectionKind.other
                  ? (window != null && !window.isUp
                      ? 'Too low tonight'
                      : 'Not now')
                  : schedulerRejectionChipLabel(reason!),
              _StatusTone.quiet,
              4.0,
            );
          }
          if (score != null) {
            // A higher score sorts earlier inside the band.
            return ('Ready', _StatusTone.plain, 2.0 - score.totalScore / 1e3);
          }
          if (window == null) return ('—', _StatusTone.quiet, 4.5);
          if (window.upAt(now)) return ('Up now', _StatusTone.plain, 2.5);
          if (rises != null && rises.isAfter(now)) {
            return (
              'Up ${ClockFormat.hm(rises.toLocal())}',
              _StatusTone.quiet,
              3.0,
            );
          }
          return (
            window.isUp ? 'Set' : 'Too low tonight',
            _StatusTone.quiet,
            4.0,
          );
        }();
        return _TargetRow(
          target: target,
          window: window,
          score: score,
          status: status,
          tone: tone,
          rank: rank,
        );
      }(),
  ]..sort(_byNextUp);
}

int _byNextUp(_TargetRow a, _TargetRow b) {
  final byRank = a.rank.compareTo(b.rank);
  if (byRank != 0) return byRank;
  final aStart = a.window?.start, bStart = b.window?.start;
  if (aStart != null && bStart != null && aStart != bStart) {
    return aStart.compareTo(bStart);
  }
  return a.target.name.toLowerCase().compareTo(b.target.name.toLowerCase());
}

/// What the autopilot will do next, in one line.
String _nextLine(_AutopilotView view, List<_TargetRow> rows, Project? group) {
  final status = view.status;
  if (status == null) {
    return view.error != null
        ? 'Could not read the autopilot: ${userFacingError(view.error!)}'
        : 'Reading the autopilot';
  }
  final current = status.currentTargetName;
  switch (status.state) {
    case SchedulerState.running:
      return current != null
          ? 'Imaging $current'
          : 'Waiting, nothing can be imaged right now';
    case SchedulerState.paused:
      return current != null ? 'Paused on $current' : 'Paused';
    case SchedulerState.idle:
      final chosen = view.decision?.chosenTargetName;
      if (chosen != null) return 'Next: $chosen';
      if (rows.isEmpty) {
        return group == null
            ? 'Add a target to give it something to shoot'
            : 'No targets in this group';
      }
      final now = DateTime.now();
      final later = [
        for (final r in rows)
          if (r.target.inAutopilot &&
              !r.target.progress.isCompleted &&
              (r.window?.start?.isAfter(now) ?? false))
            r,
      ]..sort((a, b) => a.window!.start!.compareTo(b.window!.start!));
      if (rows.every((r) => !r.target.inAutopilot)) {
        return 'Every target here is off its list';
      }
      if (later.isNotEmpty) {
        final first = later.first;
        return 'Nothing can be imaged until '
            '${ClockFormat.hm(first.window!.start!.toLocal())} '
            '(${first.target.name} rises)';
      }
      return 'Nothing can be imaged right now';
  }
}

/// The list side of the tab: toolbar, count, the rows and the week ahead.
class _TargetListColumn extends ConsumerWidget {
  const _TargetListColumn({
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.rows,
    required this.libraryEmpty,
    required this.groups,
    required this.group,
    required this.showMosaics,
    required this.query,
    required this.sort,
    required this.statusFilter,
    required this.selectedId,
    required this.compact,
    required this.scrolls,
    required this.busy,
    required this.onQuery,
    required this.onSort,
    required this.onStatusFilter,
    required this.onSelectGroup,
    required this.onShowMosaics,
    required this.onNewGroup,
    required this.onRenameGroup,
    required this.onDeleteGroup,
    required this.onCleanUp,
    required this.onAddTarget,
    required this.onPlanTonight,
    required this.onOpen,
  });

  final bool loading;
  final Object? error;
  final VoidCallback onRetry;
  final List<_TargetRow> rows;
  final bool libraryEmpty;
  final List<Project> groups;
  final Project? group;
  final bool showMosaics;
  final String query;
  final PlanTargetSort sort;
  final PlanTargetStatusFilter statusFilter;
  final int? selectedId;
  final bool compact;

  /// False when the tab around the list scrolls as one, so the rows are laid
  /// out in full.
  final bool scrolls;
  final bool busy;
  final ValueChanged<String> onQuery;
  final ValueChanged<PlanTargetSort> onSort;
  final ValueChanged<PlanTargetStatusFilter> onStatusFilter;
  final ValueChanged<int?> onSelectGroup;
  final VoidCallback onShowMosaics;
  final VoidCallback onNewGroup;
  final ValueChanged<Project> onRenameGroup;
  final ValueChanged<Project> onDeleteGroup;
  final ValueChanged<int> onCleanUp;
  final VoidCallback onAddTarget;
  final VoidCallback? onPlanTonight;
  final ValueChanged<_TargetRow> onOpen;

  List<_TargetRow> _visible() {
    final q = query.toLowerCase();
    final kept = [
      for (final r in rows)
        if ((q.isEmpty ||
                r.target.name.toLowerCase().contains(q) ||
                (r.target.progress.target.catalogId
                        ?.toLowerCase()
                        .contains(q) ??
                    false)) &&
            switch (statusFilter) {
              PlanTargetStatusFilter.any => true,
              PlanTargetStatusFilter.upTonight => r.upTonight,
              PlanTargetStatusFilter.needsData =>
                !r.target.progress.isCompleted,
              PlanTargetStatusFilter.done => r.target.progress.isCompleted,
            })
          r,
    ];
    int byName(_TargetRow a, _TargetRow b) =>
        a.target.name.toLowerCase().compareTo(b.target.name.toLowerCase());
    switch (sort) {
      case PlanTargetSort.nextUp:
        break;
      case PlanTargetSort.name:
        kept.sort(byName);
      case PlanTargetSort.leastDone:
        // Targets with a goal first, the least complete at the top.
        kept.sort((a, b) {
          final ap = a.target.progress, bp = b.target.progress;
          if (ap.isTracked != bp.isTracked) return ap.isTracked ? -1 : 1;
          final c = ap.completionFraction.compareTo(bp.completionFraction);
          return c != 0 ? c : byName(a, b);
        });
      case PlanTargetSort.mostTime:
        kept.sort(
          (a, b) => b.target.integratedSecs.compareTo(a.target.integratedSecs),
        );
      case PlanTargetSort.lastImaged:
        kept.sort((a, b) {
          final at = a.target.progress.lastImagedAt;
          final bt = b.target.progress.lastImagedAt;
          if (at == null || bt == null) {
            return at == bt ? byName(a, b) : (at == null ? 1 : -1);
          }
          return bt.compareTo(at);
        });
    }
    return kept;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    // A whole-area state needs a height of its own inside a scrolling tab.
    Widget area(Widget child) =>
        scrolls ? child : SizedBox(height: 360, child: child);
    if (error != null) {
      return area(
        EmptyState.error(
          title: 'Could not load your targets',
          body: userFacingError(error!),
          onRetry: onRetry,
        ),
      );
    }
    if (loading) return area(const _ListSkeleton());

    // An empty page shows its one way forward and no filters.
    if (libraryEmpty && !showMosaics && groups.isEmpty) {
      return area(EmptyState(
        icon: LucideIcons.target,
        title: 'No targets yet',
        body: 'Add what you want to image and set a goal for each. The '
            'autopilot works through them.',
        action: SkotiqButton(
          key: const ValueKey('plan-targets-add-first'),
          label: 'Add target',
          icon: LucideIcons.plus,
          variant: ButtonVariant.secondary,
          onPressed: onAddTarget,
        ),
      ));
    }

    final visible = _visible();
    final upTonight = rows.where((r) => r.upTonight).length;
    final filtered =
        query.isNotEmpty || statusFilter != PlanTargetStatusFilter.any;

    final Widget body;
    if (showMosaics) {
      body = _MosaicRows(scrolls: scrolls);
    } else if (rows.isEmpty) {
      body = EmptyState.compact(
        icon: LucideIcons.target,
        title:
            group == null ? 'No targets yet' : 'No targets in "${group!.name}"',
        body: 'Add a target, then set how much you want of each filter.',
        action: SkotiqButton(
          label: 'Add target',
          icon: LucideIcons.plus,
          size: ButtonSize.small,
          variant: ButtonVariant.secondary,
          onPressed: onAddTarget,
        ),
      );
    } else if (visible.isEmpty) {
      body = EmptyState.compact(
        icon: LucideIcons.searchX,
        title: 'No targets match',
        body: 'Nothing here fits the search and status you chose.',
        action: SkotiqButton(
          label: 'Clear filters',
          size: ButtonSize.small,
          variant: ButtonVariant.secondary,
          onPressed: () {
            onQuery('');
            onStatusFilter(PlanTargetStatusFilter.any);
          },
        ),
      );
    } else {
      Widget tile(int i) => _TargetRowTile(
            key: ValueKey('plan-target-row-${visible[i].target.id}'),
            row: visible[i],
            selected: visible[i].target.id == selectedId,
            compact: compact,
            showGroup: group == null,
            showDivider: i < visible.length - 1,
            onTap: () => onOpen(visible[i]),
          );
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!compact) const _ColumnHeads(),
          if (scrolls)
            Expanded(
              child: ListView.builder(
                itemCount: visible.length,
                itemBuilder: (context, i) => tile(i),
              ),
            )
          else
            for (var i = 0; i < visible.length; i++) tile(i),
        ],
      );
    }

    // An empty group shows its one way forward and no filters or count.
    final bare = !showMosaics && rows.isEmpty;
    final count = '${rows.length} ${rows.length == 1 ? 'target' : 'targets'}'
        '${filtered ? ' · ${visible.length} shown' : ''}'
        ' · $upTonight up tonight';
    final panel = SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
      child: body,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: scrolls ? MainAxisSize.max : MainAxisSize.min,
      children: [
        _toolbar(context, ref, bare: bare),
        if (!bare && !showMosaics) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          Text(
            count.toUpperCase(),
            style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
        ] else
          const SizedBox(height: SkotiqTokens.spaceMd),
        if (scrolls) Expanded(child: panel) else panel,
        if (!showMosaics) _WeekAhead(collapsed: rows.length > 8 || compact),
      ],
    );
  }

  Widget _toolbar(BuildContext context, WidgetRef ref, {required bool bare}) {
    // Mosaics and an empty group have nothing to search, filter or sort.
    final plain = showMosaics || bare;
    final groupChip = _GroupChip(
      groups: groups,
      group: group,
      showMosaics: showMosaics,
      onSelectGroup: onSelectGroup,
      onShowMosaics: onShowMosaics,
      onNewGroup: onNewGroup,
      onRenameGroup: onRenameGroup,
      onDeleteGroup: onDeleteGroup,
      onCleanUp: onCleanUp,
    );
    final statusChip = SkotiqMenuChip<PlanTargetStatusFilter>(
      key: const ValueKey('plan-targets-status-chip'),
      label: statusFilter == PlanTargetStatusFilter.any
          ? 'Status'
          : statusFilter.label,
      name: statusFilter == PlanTargetStatusFilter.any ? null : 'Status',
      entries: [
        for (final f in PlanTargetStatusFilter.values)
          SkotiqMenuChoice(f, f.label, checked: f == statusFilter),
      ],
      onSelected: onStatusFilter,
    );
    final sortChip = SkotiqMenuChip<PlanTargetSort>(
      key: const ValueKey('plan-targets-sort-chip'),
      label: 'Sort: ${sort.label}',
      entries: [
        for (final s in PlanTargetSort.values)
          SkotiqMenuChoice(s, s.label, checked: s == sort),
      ],
      onSelected: onSort,
    );
    final search = SkotiqSearchField(
      key: const ValueKey('plan-targets-search'),
      hint: 'Search targets',
      onChanged: onQuery,
    );
    final add = showMosaics
        ? SkotiqButton(
            key: const ValueKey('plan-targets-new-mosaic'),
            label: 'New mosaic',
            icon: LucideIcons.plus,
            size: ButtonSize.small,
            variant: ButtonVariant.secondary,
            onPressed: ref.watch(isRemoteModeProvider)
                ? null
                : () => _newMosaic(context, ref),
          )
        : SkotiqButton(
            key: const ValueKey('plan-targets-add'),
            label: 'Add target',
            icon: LucideIcons.plus,
            size: ButtonSize.small,
            variant: ButtonVariant.secondary,
            onPressed: busy ? null : onAddTarget,
          );
    final planTonight = onPlanTonight == null || plain
        ? null
        : SkotiqButton(
            key: const ValueKey('plan-targets-plan-tonight'),
            label: 'Plan tonight',
            size: ButtonSize.small,
            variant: ButtonVariant.ghost,
            onPressed: onPlanTonight,
          );

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (!plain) ...[
                Expanded(child: search),
                const SizedBox(width: SkotiqTokens.spaceSm),
              ] else
                const Spacer(),
              add,
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                groupChip,
                if (!plain) ...[
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  statusChip,
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  sortChip,
                  if (planTonight != null) ...[
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    planTonight,
                  ],
                ],
              ],
            ),
          ),
        ],
      );
    }
    // The filters wrap to a second line before they push the buttons out.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!plain) SizedBox(width: 240, child: search),
              groupChip,
              if (!plain) ...[statusChip, sortChip],
            ],
          ),
        ),
        if (planTonight != null) ...[
          const SizedBox(width: SkotiqTokens.spaceSm),
          planTonight,
        ],
        const SizedBox(width: SkotiqTokens.spaceSm),
        add,
      ],
    );
  }
}

/// Column widths shared by the heads and every row.
const double _kTonightColumn = 132;
const double _kProgressColumn = 172;
const double _kStatusColumn = 112;

class _ColumnHeads extends StatelessWidget {
  const _ColumnHeads();

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final style = SkotiqTypography.eyebrow.copyWith(color: colors.textMuted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceXs,
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceSm,
      ),
      child: Row(
        children: [
          Expanded(child: Text('TARGET', style: style)),
          const SizedBox(width: ListRow.gap),
          SizedBox(
            width: _kTonightColumn,
            child: Text('TONIGHT', style: style),
          ),
          const SizedBox(width: SkotiqTokens.spaceLg),
          SizedBox(
            width: _kProgressColumn,
            child: Text('PROGRESS', style: style),
          ),
          const SizedBox(width: SkotiqTokens.spaceLg),
          SizedBox(
            width: _kStatusColumn,
            child: Text('STATUS', style: style),
          ),
        ],
      ),
    );
  }
}

class _TargetRowTile extends StatelessWidget {
  const _TargetRowTile({
    super.key,
    required this.row,
    required this.selected,
    required this.compact,
    required this.showGroup,
    required this.showDivider,
    required this.onTap,
  });

  final _TargetRow row;
  final bool selected;
  final bool compact;
  final bool showGroup;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final progress = row.target.progress;
    final target = progress.target;
    final statusStyle = SkotiqTypography.bodySm.copyWith(
      color: switch (row.tone) {
        _StatusTone.quiet => colors.textMuted,
        _StatusTone.plain => colors.textPrimary,
        _StatusTone.good => colors.success,
        _StatusTone.active => colors.primary,
      },
    );
    final bar = row.window?.bar(DateTime.now());
    final windowBar = bar == null
        ? const SizedBox(height: CandidateWindowBar.trackHeight)
        : CandidateWindowBar(window: bar);
    final status = Text(
      row.status,
      style: statusStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    // The row reads as one button: name, progress, status.
    Widget named(Widget child) => Semantics(
          container: true,
          button: true,
          enabled: true,
          selected: selected,
          label: '${target.name}, ${_progressText(progress)}, ${row.status}',
          onTap: onTap,
          excludeSemantics: true,
          child: child,
        );

    if (compact) {
      return named(ListRow(
        title: target.name,
        subtitle: _progressText(progress),
        selected: selected,
        showDivider: showDivider,
        onTap: onTap,
        trailingWidget: SizedBox(
          width: 96,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              status,
              const SizedBox(height: SkotiqTokens.spaceSm),
              windowBar,
            ],
          ),
        ),
      ));
    }

    final facts = [
      if (target.objectType?.isNotEmpty ?? false) target.objectType!,
      if (showGroup && row.target.groups.isNotEmpty)
        row.target.groups.map((g) => g.name).join(', '),
      if (progress.filters.isNotEmpty)
        (progress.filters.map((f) => f.filter).toList()
              ..sort(compareDarkroomFilters))
            .join(' '),
    ].join(' · ');

    return named(ListRow(
      title: target.name,
      subtitle: facts.isEmpty ? null : facts,
      selected: selected,
      showDivider: showDivider,
      onTap: onTap,
      trailingWidget: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: _kTonightColumn, child: windowBar),
          const SizedBox(width: SkotiqTokens.spaceLg),
          SizedBox(
            width: _kProgressColumn,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _progressText(progress),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.readoutXs.copyWith(
                    color: progress.integratedSecs > 0
                        ? colors.textPrimary
                        : colors.textMuted,
                  ),
                ),
                if (progress.goal.isSet) ...[
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  SkotiqProgressBar(
                    value: progress.completionFraction,
                    state: progress.isCompleted
                        ? SkotiqProgressState.success
                        : SkotiqProgressState.normal,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceLg),
          SizedBox(width: _kStatusColumn, child: status),
        ],
      ),
    ));
  }
}

/// The seven-night outlook under the list: one line that opens to the strip
/// when the list is long or the screen narrow.
class _WeekAhead extends ConsumerStatefulWidget {
  const _WeekAhead({required this.collapsed});

  final bool collapsed;

  @override
  ConsumerState<_WeekAhead> createState() => _WeekAheadState();
}

class _WeekAheadState extends ConsumerState<_WeekAhead> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final forecast = ref.watch(weekForecastProvider).valueOrNull;
    if (forecast == null || !forecast.available || forecast.nights.isEmpty) {
      return const SizedBox.shrink();
    }
    final colors = SkotiqColors.of(context);
    final expanded = !widget.collapsed || _open;
    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.collapsed)
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                key: const ValueKey('plan-targets-week-toggle'),
                label: _open ? 'Hide this week' : 'This week',
                icon:
                    _open ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                size: ButtonSize.small,
                variant: ButtonVariant.ghost,
                onPressed: () => setState(() => _open = !_open),
              ),
            )
          else
            Text(
              'THIS WEEK',
              style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
            ),
          if (expanded) const WeekForecastStrip(),
        ],
      ),
    );
  }
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: SkotiqPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < 6; i++) ...[
              const SkeletonText(width: 160, height: 14),
              const SizedBox(height: SkotiqTokens.spaceSm),
              const SkeletonBox(height: 8),
              const SizedBox(height: SkotiqTokens.spaceLg),
            ],
          ],
        ),
      ),
    );
  }
}
