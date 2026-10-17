import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../run_status_presentation.dart';
import '../sequencer_screen.dart';
import 'sequence_library_tab.dart';
import '../widgets/notes_panel.dart';
import '../widgets/pending_session_reports_card.dart';
import '../widgets/post_session_stats_dialog.dart';
import '../widgets/replay_debug_screen.dart';
import '../widgets/sequence_diff_dialog.dart';

/// One-shot "open this run on first paint" hint for the history tab.
///
/// The Run Dashboard idle-state's "Jump to last run" button writes a run
/// id here and switches the active tab to History. The history tab
/// reads + clears this provider the first time it builds with a value,
/// then opens the post-session stats dialog for that run.
///
/// Cleared to `null` immediately after consumption so re-entering the
/// History tab doesn't re-open the dialog.
final historyOpenRunIdProvider = StateProvider<int?>((ref) => null);

/// Active status filter for the history list. Empty = no status filter
/// (show all). Backed by a set so multiple statuses can be toggled on.
final historyStatusFilterProvider =
    StateProvider.autoDispose<Set<String>>((ref) => <String>{});

/// Free-text search over `run.sequenceName` and the run's target
/// breakdown keys.
final historySearchProvider = StateProvider.autoDispose<String>((ref) => '');

/// A run paired with its parsed stats (decoded once) plus the local
/// observing-night bucket label used for grouping.
typedef _RunRow = ({SequenceRun run, ParsedRunStats? stats});

/// Derived, filtered + parsed run list. Decodes each run's statsJson
/// exactly once (rather than per `_RunCard` build) and applies the
/// status / search / sequence-id filters. Grouping by observing night is
/// done at render time from this list.
final filteredRunsProvider =
    Provider.autoDispose<AsyncValue<List<_RunRow>>>((ref) {
  final runsAsync = ref.watch(sequenceRunsProvider);
  final statusFilter = ref.watch(historyStatusFilterProvider);
  final query = ref.watch(historySearchProvider).trim().toLowerCase();
  final sequenceId = ref.watch(historyFilterSequenceIdProvider);

  return runsAsync.whenData((runs) {
    final out = <_RunRow>[];
    for (final run in runs) {
      if (sequenceId != null && run.sequenceId != sequenceId) continue;
      if (statusFilter.isNotEmpty && !statusFilter.contains(run.status)) {
        continue;
      }
      ParsedRunStats? stats;
      try {
        stats = ParsedRunStats.fromJson(run.statsJson);
      } catch (_) {
        // Malformed stats — keep the run but with null stats.
      }
      if (query.isNotEmpty) {
        final inName = run.sequenceName.toLowerCase().contains(query);
        final inTargets = stats != null &&
            stats.targetBreakdown.keys
                .any((k) => k.toLowerCase().contains(query));
        if (!inName && !inTargets) continue;
      }
      out.add((run: run, stats: stats));
    }
    return out;
  });
});

class HistoryTab extends ConsumerStatefulWidget {
  const HistoryTab({super.key});

  @override
  ConsumerState<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends ConsumerState<HistoryTab> {
  bool _consumedOpenHint = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final runsAsync = ref.watch(sequenceRunsProvider);
    final openRunId = ref.watch(historyOpenRunIdProvider);

    // If the dashboard asked us to open a specific run, honor it once.
    // We schedule the dialog via post-frame because we cannot call
    // showDialog during a build.
    if (openRunId != null && !_consumedOpenHint && runsAsync.hasValue) {
      _consumedOpenHint = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Re-verify the History tab is still the active sequencer tab so we
        // don't pop a dialog over a tab the user navigated away from before
        // the frame completed.
        if (ref.read(sequencerTabProvider) != SequencerTab.history.index) {
          return;
        }
        // Re-read colors inside the callback rather than closing over the
        // build-time value (theme may have changed between build and frame).
        final colors = SkotiqColors.of(context);
        final runs = runsAsync.value!;
        // Reset the hint regardless so a subsequent open clears.
        ref.read(historyOpenRunIdProvider.notifier).state = null;
        SequenceRun? match;
        for (final r in runs) {
          if (r.id == openRunId) {
            match = r;
            break;
          }
        }
        if (match == null) return;
        ParsedRunStats? stats;
        try {
          stats = ParsedRunStats.fromJson(match.statsJson);
        } on Object catch (e) {
          // Why: legacy/corrupted statsJson should not block the rest of the
          // history-tab open flow. We log so the user-visible "no stats"
          // outcome is traceable to a parse error in diagnostics.
          debugPrint('history_tab: ParsedRunStats.fromJson failed: $e');
        }
        if (stats == null) return;
        showDialog(
          context: context,
          builder: (_) => PostSessionStatsDialog(
            colors: colors,
            sequenceName: match!.sequenceName,
            startedAt: match.startedAt,
            endedAt: match.endedAt,
            status: match.status,
            stats: stats!,
          ),
        );
      });
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Reports from an unattended night queue here rather than opening as
          // a modal. Renders nothing when the queue is empty.
          const PendingSessionReportsCard(),
          // No title block: the page header names the screen and the
          // underline tab names the tab. This row is the tab's actions.
          Row(
            children: [
              const Spacer(),
              SkotiqButton(
                label: 'Browse all notes',
                icon: LucideIcons.bookOpen,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () => GlobalNotesDialog.show(context),
              ),
            ],
          ),
          const SizedBox(height: 16),

          _HistoryFilterBar(colors: colors),

          const SizedBox(height: 16),

          // Content
          Expanded(
            child: ref.watch(filteredRunsProvider).when(
                  data: (rows) {
                    final hasFilter = ref
                            .watch(historyStatusFilterProvider)
                            .isNotEmpty ||
                        ref.watch(historySearchProvider).trim().isNotEmpty ||
                        ref.watch(historyFilterSequenceIdProvider) != null;
                    if (rows.isEmpty) {
                      return EmptyState(
                        icon: hasFilter
                            ? LucideIcons.searchX
                            : LucideIcons.history,
                        title: hasFilter ? 'No matching runs' : 'No runs yet',
                        body: hasFilter
                            ? 'Try clearing the status or search filters.'
                            : 'Execute a sequence to see its history here.',
                        action: hasFilter
                            ? SkotiqButton(
                                label: 'Clear filters',
                                icon: LucideIcons.x,
                                variant: ButtonVariant.ghost,
                                size: ButtonSize.small,
                                onPressed: () {
                                  ref
                                      .read(
                                          historyStatusFilterProvider.notifier)
                                      .state = <String>{};
                                  ref
                                      .read(historySearchProvider.notifier)
                                      .state = '';
                                  ref
                                      .read(historyFilterSequenceIdProvider
                                          .notifier)
                                      .state = null;
                                },
                              )
                            : null,
                      );
                    }
                    return _GroupedRunList(colors: colors, rows: rows);
                  },
                  loading: () => const Center(
                      child: const SkotiqMark(
                          motion: SkotiqMarkMotion.loading, size: 36)),
                  error: (err, _) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.alertTriangle,
                            size: 48, color: colors.error),
                        const SizedBox(height: 16),
                        Text(
                          'Failed to load history',
                          style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: SkotiqTypography.fontSize16),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          err.toString(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: colors.textMuted,
                              fontSize: SkotiqTypography.fontSize12),
                        ),
                        const SizedBox(height: 16),
                        SkotiqButton(
                          label: 'Retry',
                          icon: LucideIcons.refreshCw,
                          onPressed: () => ref.invalidate(sequenceRunsProvider),
                        ),
                      ],
                    ),
                  ),
                ),
          ),
        ],
      ),
    );
  }
}

/// Status filter chips + search field for the history list.
class _HistoryFilterBar extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const _HistoryFilterBar({required this.colors});

  // 'interrupted' is what a run becomes when the process died mid-flight (a
  // crash or a power cut) and the next startup reconciled the stale row. It
  // needs a chip of its own: without one, the runs an operator most wants to
  // find after a bad night are the only ones no filter can select.
  // Every status the executor can durably write needs a chip, or the runs
  // carrying it become unreachable by any filter. `stopped` /
  // `paused-stopped` are what an operator Stop produces (the latter when a
  // checkpoint was preserved, so the run is resumable) — on the live database
  // that was 15 runs no filter could select.
  static const _statuses = [
    'completed',
    'failed',
    'aborted',
    'stopped',
    'paused-stopped',
    'interrupted',
    'running',
  ];

  @override
  ConsumerState<_HistoryFilterBar> createState() => _HistoryFilterBarState();
}

class _HistoryFilterBarState extends ConsumerState<_HistoryFilterBar> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final selected = ref.watch(historyStatusFilterProvider);
    final sequenceFilter = ref.watch(historyFilterSequenceIdProvider);

    // Keep the text field in sync when the search query is cleared from
    // elsewhere (e.g. the filtered empty-state "Clear filters" action).
    ref.listen<String>(historySearchProvider, (previous, next) {
      if (next.isEmpty && _searchController.text.isNotEmpty) {
        _searchController.clear();
      }
    });

    // On a screen whose own empty state says "No runs yet", seven live filter
    // chips would invite the operator to narrow a set with nothing in it. The
    // UNFILTERED run list is the honest test — not `filteredRunsProvider`,
    // which is empty whenever the current filter matches nothing and would
    // disable the very chips needed to widen it again.
    final hasAnyRuns =
        ref.watch(sequenceRunsProvider).valueOrNull?.isNotEmpty ?? false;
    const noRunsReason = 'No runs yet — there is nothing to filter.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Tooltip(
                message: hasAnyRuns ? '' : noRunsReason,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final status in _HistoryFilterBar._statuses)
                      Tooltip(
                        // One vocabulary, defined once in
                        // run_status_presentation.dart: five of these chips
                        // mean "did not finish" and nothing on screen said how
                        // they differ.
                        message: hasAnyRuns
                            ? runStatusMeaning(status)
                            : noRunsReason,
                        child: Semantics(
                          enabled: hasAnyRuns,
                          label: hasAnyRuns
                              ? null
                              : '${runStatusLabel(status)}, unavailable. '
                                  '$noRunsReason',
                          excludeSemantics: !hasAnyRuns,
                          child: FilterChip(
                            label: Text(runStatusLabel(status)),
                            selected: selected.contains(status),
                            visualDensity: VisualDensity.compact,
                            onSelected: hasAnyRuns
                                ? (on) {
                                    final next = {...selected};
                                    if (on) {
                                      next.add(status);
                                    } else {
                                      next.remove(status);
                                    }
                                    ref
                                        .read(historyStatusFilterProvider
                                            .notifier)
                                        .state = next;
                                  }
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 220,
              child: TextField(
                controller: _searchController,
                enabled: hasAnyRuns,
                decoration: InputDecoration(
                  hintText: hasAnyRuns
                      ? 'Search by sequence / target'
                      : 'No runs to search',
                  isDense: true,
                  prefixIcon: Icon(LucideIcons.search,
                      size: 16, color: colors.textMuted),
                ),
                onChanged: (v) =>
                    ref.read(historySearchProvider.notifier).state = v,
              ),
            ),
          ],
        ),
        if (sequenceFilter != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(LucideIcons.filter, size: 13, color: colors.primary),
              const SizedBox(width: 6),
              Text(
                'Filtered to one sequence',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => ref
                    .read(historyFilterSequenceIdProvider.notifier)
                    .state = null,
                child: Text(
                  'Clear',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Renders the filtered runs grouped by observing night (local date),
/// newest night first, with a sticky-style section header per night.
class _GroupedRunList extends StatelessWidget {
  final SkotiqColors colors;
  final List<_RunRow> rows;

  const _GroupedRunList({required this.colors, required this.rows});

  /// Bucket a run into an observing night. Runs after local midnight but
  /// before ~midday are attributed to the previous calendar day so a
  /// single overnight session groups together.
  DateTime _observingNight(DateTime startedAt) {
    final local = startedAt.toLocal();
    final shifted =
        local.hour < 12 ? local.subtract(const Duration(days: 1)) : local;
    return DateTime(shifted.year, shifted.month, shifted.day);
  }

  @override
  Widget build(BuildContext context) {
    final groups = <DateTime, List<_RunRow>>{};
    for (final row in rows) {
      groups.putIfAbsent(_observingNight(row.run.startedAt), () => []).add(row);
    }
    final nights = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    final nightFormat = DateFormat('EEEE, MMM d, yyyy');

    return ListView.builder(
      itemCount: nights.length,
      itemBuilder: (context, index) {
        final night = nights[index];
        final nightRows = groups[night]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 16, bottom: 8),
              child: Row(
                children: [
                  Icon(LucideIcons.moon, size: 13, color: colors.textMuted),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      nightFormat.format(night),
                      style: SkotiqTypography.labelStrongSm
                          .copyWith(color: colors.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${nightRows.length} '
                    'run${nightRows.length == 1 ? '' : 's'}',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            for (final row in nightRows) ...[
              _RunCard(colors: colors, run: row.run, stats: row.stats),
              const SizedBox(height: 8),
            ],
          ],
        );
      },
    );
  }
}

class _RunCard extends ConsumerWidget {
  final SkotiqColors colors;
  final SequenceRun run;

  /// Stats parsed once by [filteredRunsProvider]; avoids re-decoding the
  /// JSON blob on every card build (and again when opening notes).
  final ParsedRunStats? stats;

  const _RunCard({required this.colors, required this.run, this.stats});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dateFormat = DateFormat('MMM d, yyyy HH:mm');
    final status = run.status;
    final statusColor = _statusColor(status);
    final statusIcon = _statusIcon(status);
    // Promote to a local so the null-checks below flow-analyze correctly
    // (a public field can't be promoted).
    final stats = this.stats;

    final durationStr = run.endedAt != null
        ? DurationFormat.of(run.endedAt!.difference(run.startedAt),
            style: DurationStyle.hoursMinutes)
        : 'In progress';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        // Legacy/corrupt runs parse to null stats; there is no dialog to open,
        // so leave onTap null rather than rippling on a hollow control.
        onTap: stats == null
            ? null
            : () {
                showDialog(
                  context: context,
                  builder: (_) => PostSessionStatsDialog(
                    colors: colors,
                    sequenceName: run.sequenceName,
                    startedAt: run.startedAt,
                    endedAt: run.endedAt,
                    status: run.status,
                    stats: stats,
                  ),
                );
              },
        child: SkotiqCard(
          variant: CardVariant.subtle,
          padding: const EdgeInsets.all(16),
          borderRadius: SkotiqTokens.radiusLg,
          child: Row(
            children: [
              // Status icon
              Container(
                width: 40,
                height: 40,
                decoration: SkotiqDecorations.tintedBadge(
                  statusColor,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                ),
                child: Icon(statusIcon, size: 20, color: statusColor),
              ),
              const SizedBox(width: 16),

              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      run.sequenceName,
                      style: SkotiqTypography.h5
                          .copyWith(color: colors.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${dateFormat.format(run.startedAt)}  |  $durationStr',
                      style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.textMuted),
                    ),
                  ],
                ),
              ),

              // Quick stats
              if (stats != null) ...[
                _StatChip(
                  colors: colors,
                  icon: LucideIcons.camera,
                  label: '${stats.framesCaptured}',
                ),
                const SizedBox(width: 8),
                _StatChip(
                  colors: colors,
                  icon: LucideIcons.clock,
                  label: stats.formatDuration(stats.integrationSecs),
                ),
                const SizedBox(width: 8),
                // Campaign rollup badge. Resolves the per-run
                // primary target (the first key of the targetBreakdown
                // blob) into a [CampaignRollup] via the all-targets
                // provider. Hidden when (a) the run has no target
                // breakdown, (b) the target has no other sessions
                // (rollup.sessionCount <= 1), or (c) the lookup fails.
                if (stats.targetBreakdown.isNotEmpty)
                  _CampaignBadge(
                    targetName: stats.targetBreakdown.keys.first,
                  ),
              ],

              const SizedBox(width: 8),

              // "Diff vs previous" affordance. Opens
              // the structural diff between the sequence backing this
              // run and its previous run. Disabled (via tooltip-only
              // hint) when the run has no linked sequence id; the
              // dialog itself also guards for that case.
              if (run.sequenceId != null)
                IconButton(
                  onPressed: () => SequenceDiffDialog.showForRun(
                    context,
                    ref,
                    run: run,
                  ),
                  icon: const Icon(LucideIcons.gitCompare, size: 16),
                  tooltip: 'Diff vs previous run',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                ),

              // Replay Debug — open the chronological decision
              // feed for this run. The badge surfaces the count so the
              // user can see at a glance whether the run has any
              // recorded decisions before opening (older runs that
              // pre-date decision logging will show 0).
              Consumer(builder: (context, ref, _) {
                final countAsync = ref.watch(
                  decisionCountForRunProvider(run.id),
                );
                if (countAsync.isLoading) {
                  return const SizedBox(
                    width: 28,
                    height: 28,
                    child: Padding(
                      padding: EdgeInsets.all(7),
                      child: SkotiqMark(size: 14),
                    ),
                  );
                }
                if (countAsync.hasError) {
                  return IconButton(
                    onPressed: () => ref.invalidate(
                      decisionCountForRunProvider(run.id),
                    ),
                    icon: Icon(
                      LucideIcons.alertTriangle,
                      size: 16,
                      color: colors.warning,
                    ),
                    tooltip: 'Could not load replay count — retry',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                  );
                }
                final count = countAsync.requireValue;
                return IconButton(
                  onPressed: () => ReplayDebugScreen.push(
                    context,
                    sequenceRunId: run.id,
                    sequenceName: run.sequenceName,
                    startedAt: run.startedAt,
                    endedAt: run.endedAt,
                  ),
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(LucideIcons.history, size: 16),
                      if (count > 0)
                        Positioned(
                          right: -4,
                          top: -4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: colors.primary,
                              borderRadius: BorderRadius.circular(
                                  SkotiqTokens.radiusInline8),
                            ),
                            child: Text(
                              '$count',
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize9,
                                color: colors.onPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  tooltip: count == 0
                      ? 'Open replay (no decisions recorded)'
                      : 'Open replay ($count decisions)',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                );
              }),

              // Quick "open notes" affordance keyed
              // on this run id. Notes attached to the run from any
              // surface (target card, session report) appear here
              // because the underlying provider streams from a single
              // database row set.
              Consumer(builder: (context, ref, _) {
                final notesAsync = ref.watch(notesForRunProvider(run.id));
                final count = notesAsync.maybeWhen(
                  data: (notes) => notes.length,
                  orElse: () => 0,
                );
                return IconButton(
                  onPressed: () => _openNotesForRun(context, ref, run, stats),
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(LucideIcons.bookOpen, size: 16),
                      if (count > 0)
                        Positioned(
                          right: -4,
                          top: -4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: colors.primary,
                              borderRadius: BorderRadius.circular(
                                  SkotiqTokens.radiusInline8),
                            ),
                            child: Text(
                              '$count',
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize9,
                                color: colors.onPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  tooltip: count == 0 ? 'Add note' : 'Notes ($count)',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                );
              }),

              const SizedBox(width: 4),

              // Status badge. Declared as a live status rather than left as a
              // bare coloured label: without the declaration the AT-SPI tree
              // publishes these as `Stopped (resumable) [DISABLED]` /
              // `Completed [DISABLED]`, announcing every run outcome as if the
              // row were dimmed out.
              Semantics(
                container: true,
                enabled: true,
                label: 'Run status: ${runStatusLabel(status)}',
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: SkotiqDecorations.tintedBadge(
                    statusColor,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                  ),
                  child: Text(
                    runStatusLabel(status),
                    style: SkotiqTypography.labelStrongSm
                        .copyWith(color: statusColor),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Resolve the primary target name for the run (best-effort: the
  /// stats blob's first target breakdown key) and pop the per-run
  /// notes drawer.
  Future<void> _openNotesForRun(
    BuildContext context,
    WidgetRef ref,
    SequenceRun run,
    ParsedRunStats? stats,
  ) async {
    final colors = SkotiqColors.of(context);
    // Reuse the stats parsed once in `build` rather than re-decoding the
    // JSON blob here.
    String? primaryTarget;
    if (stats != null && stats.targetBreakdown.isNotEmpty) {
      primaryTarget = stats.targetBreakdown.keys.first;
    }
    primaryTarget ??= run.sequenceName;
    final dialogSize = AdaptiveDialogConstraints.dialogSize(
      context,
      designWidth: 640,
      designHeight: 600,
    );
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          side: BorderSide(color: colors.border),
        ),
        child: SizedBox(
          width: dialogSize.width,
          height: dialogSize.height,
          child: Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: colors.border)),
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.bookOpen, size: 20, color: colors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Notes — ${run.sequenceName}',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize16,
                          fontWeight: FontWeight.w700,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(LucideIcons.x, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: RunNotesSection(
                    sequenceRunId: run.id,
                    targetId: primaryTarget!,
                    colors: colors,
                    embedded: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'completed':
        return colors.success;
      case 'failed':
        return colors.error;
      case 'aborted':
        return colors.warning;
      case 'running':
        return colors.info;
      default:
        return colors.textMuted;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'completed':
        return LucideIcons.checkCircle2;
      case 'failed':
        return LucideIcons.xCircle;
      case 'aborted':
        return LucideIcons.alertTriangle;
      case 'running':
        return LucideIcons.play;
      default:
        return LucideIcons.circle;
    }
  }
}

/// Per-run campaign rollup badge.
///
/// Surfaces "Campaign: 6h total across 3 sessions" when the target has
/// been imaged on more than one night. Silently hides when the target
/// is unknown, has only one session, or the rollup lookup fails.
class _CampaignBadge extends ConsumerWidget {
  final String targetName;

  const _CampaignBadge({required this.targetName});

  String _formatHours(double seconds) {
    final hours = seconds / 3600.0;
    return '${hours.toStringAsFixed(1)}h';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final rollupAsync = ref.watch(campaignRollupByNameProvider(targetName));
    return rollupAsync.maybeWhen(
      data: (rollup) {
        if (rollup == null || rollup.sessionCount <= 1) {
          return const SizedBox.shrink();
        }
        final total = _formatHours(rollup.totalCapturedIntegrationSecs);
        return Tooltip(
          message: 'Campaign: $total across ${rollup.sessionCount} sessions',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            margin: const EdgeInsets.only(right: 4),
            decoration: SkotiqDecorations.emphasisSurface(
              colors.primary,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.layers, size: 12, color: colors.primary),
                const SizedBox(width: 4),
                Text(
                  '$total / ${rollup.sessionCount}',
                  style: SkotiqTypography.labelStrongSm
                      .copyWith(color: colors.primary),
                ),
              ],
            ),
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _StatChip extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;

  const _StatChip({
    required this.colors,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: colors.textMuted),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
