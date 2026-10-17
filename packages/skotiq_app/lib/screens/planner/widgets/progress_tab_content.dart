import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../accessible_dropdown.dart';

/// Sort options for the Progress tab. Persisted via [_progressSortProvider]
/// so a user's preference survives flipping back and forth between tabs.
enum ProgressSort {
  percentComplete,
  eta,
  framesCaptured,
}

/// Local sort preference for the Progress tab. `autoDispose` so the
/// default re-asserts when the tab is closed and re-opened from a fresh
/// session.
final _progressSortProvider = StateProvider.autoDispose<ProgressSort>(
    (_) => ProgressSort.percentComplete);

/// Tracks which target row currently has its per-filter breakdown expanded.
/// Only one row at a time to keep the page tidy.
final _progressExpandedRowProvider =
    StateProvider.autoDispose<int?>((_) => null);

/// Progress tab body for Plan Tonight.
///
/// Lists every target in the catalog with its imaging progress: total %,
/// total integration captured vs goal, ETA in nights (or em-dash when not
/// projectable), and last-imaged-at relative time. Tapping a row reveals
/// per-filter `FilterProgress` rows.
class ProgressTabContent extends ConsumerWidget {
  const ProgressTabContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final progressAsync = ref.watch(allTargetProgressProvider);
    final sort = ref.watch(_progressSortProvider);

    return progressAsync.when(
      loading: () => const _ProgressSkeletonList(),
      error: (err, _) => _ProgressErrorState(
        colors: colors,
        error: err,
        onRetry: () => ref.invalidate(allTargetProgressProvider),
      ),
      data: (progressMap) {
        if (progressMap.isEmpty) {
          return _ProgressEmptyState(colors: colors);
        }
        final rows = _sortRows(progressMap.values.toList(), sort);
        return _ProgressList(
          rows: rows,
          sort: sort,
          onSortChanged: (s) =>
              ref.read(_progressSortProvider.notifier).state = s,
        );
      },
    );
  }
}

List<TargetProgress> _sortRows(
  List<TargetProgress> rows,
  ProgressSort sort,
) {
  // Stable secondary key: target name, so two equal primary keys retain a
  // predictable order between rebuilds.
  final sorted = List<TargetProgress>.of(rows);
  switch (sort) {
    case ProgressSort.percentComplete:
      sorted.sort((a, b) {
        final c = b.percentComplete.compareTo(a.percentComplete);
        if (c != 0) return c;
        return a.targetName.toLowerCase().compareTo(b.targetName.toLowerCase());
      });
      break;
    case ProgressSort.eta:
      sorted.sort((a, b) {
        // Null ETAs sort last regardless of direction — they represent
        // "no signal", not "infinitely far away".
        final ae = a.estimatedNightsRemaining;
        final be = b.estimatedNightsRemaining;
        if (ae == null && be == null) {
          return a.targetName
              .toLowerCase()
              .compareTo(b.targetName.toLowerCase());
        }
        if (ae == null) return 1;
        if (be == null) return -1;
        final c = ae.compareTo(be);
        if (c != 0) return c;
        return a.targetName.toLowerCase().compareTo(b.targetName.toLowerCase());
      });
      break;
    case ProgressSort.framesCaptured:
      sorted.sort((a, b) {
        final c = b.totalCapturedFrames.compareTo(a.totalCapturedFrames);
        if (c != 0) return c;
        return a.targetName.toLowerCase().compareTo(b.targetName.toLowerCase());
      });
      break;
  }
  return sorted;
}

class _ProgressList extends ConsumerWidget {
  final List<TargetProgress> rows;
  final ProgressSort sort;
  final ValueChanged<ProgressSort> onSortChanged;

  const _ProgressList({
    required this.rows,
    required this.sort,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final expandedId = ref.watch(_progressExpandedRowProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SortBar(
          colors: colors,
          sort: sort,
          onSortChanged: onSortChanged,
          totalCount: rows.length,
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              SkotiqTokens.spaceLg,
              SkotiqTokens.spaceSm,
              SkotiqTokens.spaceLg,
              SkotiqTokens.space2xl,
            ),
            itemCount: rows.length,
            separatorBuilder: (_, __) =>
                const SizedBox(height: SkotiqTokens.spaceSm),
            itemBuilder: (context, index) {
              final row = rows[index];
              final isExpanded = expandedId == row.targetId;
              return _ProgressRow(
                key: ValueKey('progress-row-${row.targetId}'),
                progress: row,
                colors: colors,
                isExpanded: isExpanded,
                onToggleExpand: () {
                  ref.read(_progressExpandedRowProvider.notifier).state =
                      isExpanded ? null : row.targetId;
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SortBar extends StatelessWidget {
  final SkotiqColors colors;
  final ProgressSort sort;
  final ValueChanged<ProgressSort> onSortChanged;
  final int totalCount;

  const _SortBar({
    required this.colors,
    required this.sort,
    required this.onSortChanged,
    required this.totalCount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceSm,
      ),
      child: Row(
        children: [
          Text(
            '$totalCount target${totalCount == 1 ? '' : 's'}',
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
          const Spacer(),
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusXl),
              border: Border.all(color: colors.border),
            ),
            child: DropdownButtonHideUnderline(
              child: AccessibleDropdown<ProgressSort>(
                value: sort,
                isDense: true,
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textPrimary),
                dropdownColor: colors.surface,
                iconSize: 14,
                items: const [
                  DropdownMenuItem(
                    value: ProgressSort.percentComplete,
                    child: Text('Sort: % complete'),
                  ),
                  DropdownMenuItem(
                    value: ProgressSort.eta,
                    child: Text('Sort: ETA'),
                  ),
                  DropdownMenuItem(
                    value: ProgressSort.framesCaptured,
                    child: Text('Sort: Frames captured'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) onSortChanged(v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final TargetProgress progress;
  final SkotiqColors colors;
  final bool isExpanded;
  final VoidCallback onToggleExpand;

  const _ProgressRow({
    super.key,
    required this.progress,
    required this.colors,
    required this.isExpanded,
    required this.onToggleExpand,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (progress.percentComplete * 100).clamp(0.0, 100.0);
    final etaLabel = _formatEta(progress.estimatedNightsRemaining);
    final lastImagedLabel = _formatLastImaged(progress.lastImagedAt);
    final integrationLabel =
        '${_formatHours(progress.totalIntegrationCaptured)} / ${_formatHours(progress.totalIntegrationGoal)}';
    final framesLabel =
        '${progress.totalCapturedFrames} / ${progress.totalGoalFrames}';

    return SkotiqPanel(
        child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        onTap: onToggleExpand,
        child: Padding(
          padding: SkotiqTokens.cardPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          progress.targetName,
                          style: SkotiqTypography.bodyStrong.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        if (!progress.hasGoals)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              'No integration goals set',
                              style: SkotiqTypography.caption
                                  .copyWith(color: colors.textMuted),
                            ),
                          )
                        else if (!progress.hasCaptures)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              'No frames captured yet',
                              style: SkotiqTypography.caption
                                  .copyWith(color: colors.textMuted),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Expanded(
                    flex: 6,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final metrics = Row(
                          children: [
                            Flexible(
                              flex: 4,
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(minWidth: 100),
                                child: _ProgressBar(
                                  percent: progress.percentComplete,
                                  colors: colors,
                                  label: '${pct.toStringAsFixed(0)}%',
                                ),
                              ),
                            ),
                            const SizedBox(width: SkotiqTokens.spaceMd),
                            Flexible(
                              flex: 3,
                              child: Text(
                                integrationLabel,
                                textAlign: TextAlign.right,
                                overflow: TextOverflow.ellipsis,
                                style: SkotiqTypography.caption.copyWith(
                                    color: colors.textSecondary,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ]),
                              ),
                            ),
                            const SizedBox(width: SkotiqTokens.spaceMd),
                            Flexible(
                              flex: 2,
                              child: Text(
                                etaLabel,
                                textAlign: TextAlign.right,
                                overflow: TextOverflow.ellipsis,
                                style: SkotiqTypography.caption.copyWith(
                                    color: colors.textSecondary,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ]),
                              ),
                            ),
                            const SizedBox(width: SkotiqTokens.spaceMd),
                            Flexible(
                              flex: 3,
                              child: Text(
                                lastImagedLabel,
                                textAlign: TextAlign.right,
                                overflow: TextOverflow.ellipsis,
                                style: SkotiqTypography.caption
                                    .copyWith(color: colors.textMuted),
                              ),
                            ),
                          ],
                        );
                        if (constraints.maxWidth < 420) {
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minWidth: constraints.maxWidth,
                              ),
                              child: metrics,
                            ),
                          );
                        }
                        return metrics;
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    isExpanded
                        ? LucideIcons.chevronUp
                        : LucideIcons.chevronDown,
                    size: 14,
                    color: colors.textMuted,
                  ),
                ],
              ),
              if (isExpanded) ...[
                const SizedBox(height: SkotiqTokens.spaceMd),
                Divider(color: colors.border, height: 1),
                const SizedBox(height: SkotiqTokens.spaceMd),
                _PerFilterTable(
                  rows: progress.perFilter,
                  colors: colors,
                  totalFramesLabel: framesLabel,
                ),
              ],
            ],
          ),
        ),
      ),
    ));
  }

  String _formatEta(int? nights) {
    if (nights == null) return '—';
    if (nights == 0) return 'tonight';
    if (nights == 1) return '1 night';
    return '$nights nights';
  }

  String _formatLastImaged(DateTime? when) {
    if (when == null) return 'never';
    final now = DateTime.now();
    final delta = now.difference(when);
    if (delta.isNegative) return 'tonight';
    if (delta.inHours < 18) return 'tonight';
    final nights = (delta.inHours / 24).round();
    if (nights <= 0) return 'tonight';
    if (nights == 1) return '1 night ago';
    return '$nights nights ago';
  }

  String _formatHours(Duration d) {
    final hours = d.inSeconds / 3600.0;
    if (hours < 0.05) return '0h';
    if (hours < 10) return '${hours.toStringAsFixed(1)}h';
    return '${hours.toStringAsFixed(0)}h';
  }
}

class _ProgressBar extends StatelessWidget {
  final double percent;
  final SkotiqColors colors;
  final String label;

  const _ProgressBar({
    required this.percent,
    required this.colors,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = percent.clamp(0.0, 1.0);
    final Color fill;
    if (clamped >= 1.0) {
      fill = colors.success;
    } else if (clamped >= 0.5) {
      fill = colors.primary;
    } else {
      fill = colors.accent;
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          height: 16,
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(color: colors.border),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: clamped,
                child: Container(
                  color: fill.withValues(alpha: 0.35),
                ),
              ),
            ),
          ),
        ),
        Text(
          label,
          style: SkotiqTypography.caption.copyWith(
              color: colors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _PerFilterTable extends StatelessWidget {
  final List<FilterProgress> rows;
  final SkotiqColors colors;
  final String totalFramesLabel;

  const _PerFilterTable({
    required this.rows,
    required this.colors,
    required this.totalFramesLabel,
  });

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
        child: Text(
          // Directions have to name a tab the operator can see: integration
          // goals are edited in Schedule.
          'No integration goals are defined for this target. Add filter '
          'goals in the Schedule tab to start tracking progress.',
          style: SkotiqTypography.caption
              .copyWith(color: colors.textSecondary),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'Per filter',
              style: SkotiqTypography.eyebrow
                  .copyWith(color: colors.textMuted),
            ),
            const Spacer(),
            Text(
              'Total frames $totalFramesLabel',
              style: SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        for (final filter in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _FilterProgressRow(filter: filter, colors: colors),
          ),
      ],
    );
  }
}

class _FilterProgressRow extends StatelessWidget {
  final FilterProgress filter;
  final SkotiqColors colors;

  const _FilterProgressRow({required this.filter, required this.colors});

  @override
  Widget build(BuildContext context) {
    final pct = (filter.percentComplete * 100).clamp(0.0, 100.0);
    return Row(
      children: [
        Flexible(
          flex: 2,
          child: Text(
            filter.filter,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.eyebrow.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          flex: 4,
          child: _ProgressBar(
            percent: filter.percentComplete,
            colors: colors,
            label: '${pct.toStringAsFixed(0)}%',
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Flexible(
          flex: 3,
          child: Text(
            '${filter.capturedFrames} / ${filter.goalFrames} frames',
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
      ],
    );
  }
}

class _ProgressEmptyState extends StatelessWidget {
  final SkotiqColors colors;

  const _ProgressEmptyState({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SkotiqTokens.space2xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.lineChart,
              size: SkotiqTokens.icon2xl,
              color: colors.textMuted,
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            Text(
              'No imaging history yet',
              style: SkotiqTypography.sectionTitle.copyWith(
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              'Capture frames in a sequence — they’ll show up here per '
              'target with integration totals and an ETA at your current '
              'pace.',
              textAlign: TextAlign.center,
              style: SkotiqTypography.bodySm
                  .copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressErrorState extends StatelessWidget {
  final SkotiqColors colors;
  final Object error;
  final VoidCallback onRetry;

  const _ProgressErrorState({
    required this.colors,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SkotiqTokens.space2xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.alertCircle,
              size: SkotiqTokens.icon2xl,
              color: colors.error,
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            Text(
              'Failed to load progress',
              style: SkotiqTypography.sectionTitle.copyWith(
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              error.toString(),
              textAlign: TextAlign.center,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            SkotiqButton(
              label: 'Retry',
              icon: LucideIcons.refreshCw,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressSkeletonList extends StatelessWidget {
  const _ProgressSkeletonList();

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: ListView.separated(
        padding: SkotiqTokens.screenPadding,
        itemCount: 6,
        separatorBuilder: (_, __) =>
            const SizedBox(height: SkotiqTokens.spaceSm),
        itemBuilder: (_, __) => Container(
          padding: SkotiqTokens.cardPadding,
          decoration: BoxDecoration(
            color: SkotiqColors.of(context).surface,
            borderRadius: SkotiqTokens.borderRadiusLg,
            border: Border.all(
              color: SkotiqColors.of(context).border,
            ),
          ),
          child: const Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonText(width: 160, height: 14),
                    SizedBox(height: 6),
                    SkeletonText(width: 100, height: 11),
                  ],
                ),
              ),
              SizedBox(width: 16),
              SkeletonBox(width: 160, height: 16),
              SizedBox(width: 12),
              SkeletonBox(width: 80, height: 12),
              SizedBox(width: 12),
              SkeletonBox(width: 80, height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
