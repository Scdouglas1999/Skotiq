import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'run_dashboard/frame_detail_dialog.dart';

/// The window the time-range slider scrubs, as the UNION of the run's
/// wall-clock span and the decisions actually on record.
///
/// A row the screen knows about must always be reachable, so the span stretches
/// to hold every decision: the run row's `started_at`/`ended_at` alone excludes
/// any decision written outside it — most commonly the completion decision,
/// persisted a beat after the run row is closed — which the header still counts.
///
/// Pure and public so the claim can be pinned without driving the screen.
(DateTime, DateTime) replayScrubSpan(
  List<ReplayDecision> decisions, {
  DateTime? startedAt,
  DateTime? endedAt,
}) {
  var start = startedAt ?? decisions.first.timestamp;
  var end = endedAt ?? decisions.last.timestamp;
  for (final d in decisions) {
    if (d.timestamp.isBefore(start)) start = d.timestamp;
    if (d.timestamp.isAfter(end)) end = d.timestamp;
  }
  return (start, end);
}

/// Replay Debug — retrospective decision-tree scrubber.
///
/// Opened from the history tab via "Replay" on each run row. Renders every
/// persisted [ReplayDecision] for the run in chronological order with filter
/// chips (by category), full-text search, and a time-range slider that zooms
/// into a specific window.
///
/// Each row exposes a "View details" expansion that pretty-prints the
/// structured `details` map. The "Add note at this time" action pre-fills a
/// [NotesService] note with the row's timestamp + summary.
class ReplayDebugScreen extends ConsumerStatefulWidget {
  const ReplayDebugScreen({
    required this.sequenceRunId,
    required this.sequenceName,
    this.startedAt,
    this.endedAt,
    super.key,
  });

  /// `sequence_runs.id` of the run to scrub.
  final int sequenceRunId;

  /// Display label for the app bar.
  final String sequenceName;

  /// Wall-clock anchors used by the time-range slider. Optional because
  /// older runs may not have populated the `ended_at` column.
  final DateTime? startedAt;
  final DateTime? endedAt;

  /// The router location for one run's replay, query-encoded so a deep link
  /// (and the back stack) carries the header label and the scrub window.
  static String locationFor({
    required int sequenceRunId,
    required String sequenceName,
    DateTime? startedAt,
    DateTime? endedAt,
  }) {
    final query = <String, String>{
      'name': sequenceName,
      if (startedAt != null) 'started': startedAt.toIso8601String(),
      if (endedAt != null) 'ended': endedAt.toIso8601String(),
    };
    return Uri(
      path: '/replay/$sequenceRunId',
      queryParameters: query,
    ).toString();
  }

  /// Convenience launcher.
  ///
  /// Goes through the ROUTER, not `Navigator.push`: a [MaterialPageRoute] lands
  /// ABOVE the page go_router owns inside the shell, so a nav-rail click would
  /// change the location — and the rail's own highlight — while this screen
  /// stayed on top. One navigation stack means a rail click replaces this
  /// screen like every other page.
  static Future<void> push(
    BuildContext context, {
    required int sequenceRunId,
    required String sequenceName,
    DateTime? startedAt,
    DateTime? endedAt,
  }) {
    final location = locationFor(
      sequenceRunId: sequenceRunId,
      sequenceName: sequenceName,
      startedAt: startedAt,
      endedAt: endedAt,
    );
    final router = GoRouter.maybeOf(context);
    if (router != null) return router.push<void>(location);
    // No router above us (widget tests, embedded hosts): fall back to the
    // imperative push so the screen is still reachable.
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReplayDebugScreen(
          sequenceRunId: sequenceRunId,
          sequenceName: sequenceName,
          startedAt: startedAt,
          endedAt: endedAt,
        ),
      ),
    );
  }

  @override
  ConsumerState<ReplayDebugScreen> createState() => _ReplayDebugScreenState();
}

class _ReplayDebugScreenState extends ConsumerState<ReplayDebugScreen> {
  /// User-selected category filter. `null` = show all.
  DecisionCategory? _categoryFilter;

  /// Free-text search in the summary field.
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchTerm = '';

  /// Time-range filter (0.0..1.0 fraction of the run span). `null` =
  /// no clamp. Initialised lazily once we know the run span.
  RangeValues? _timeRange;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final decisionsAsync =
        ref.watch(decisionsForRunProvider(widget.sequenceRunId));

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        title: Text('Replay — ${widget.sequenceName}'),
        backgroundColor: colors.surface,
        actions: [
          // A bare ✕ in the top-right of a full-screen route reads as CLOSE,
          // and this control only resets the filters — so the screen would look
          // like it refused to close. The filter-clear glyph and the
          // spelled-out label say which of the two it is; leaving is the
          // AppBar's own back control.
          IconButton(
            tooltip: 'Clear filters',
            icon: const Icon(LucideIcons.filterX, size: 18),
            onPressed: _resetFilters,
          ),
        ],
      ),
      body: decisionsAsync.when(
        loading: () => const Center(
            child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
        error: (err, _) => EmptyState(
          icon: LucideIcons.alertTriangle,
          title: 'Could not load replay log',
          body: '$err',
          action: SkotiqButton(
            label: 'Retry',
            icon: SkotiqIcons.refresh,
            onPressed: () => ref.invalidate(
              decisionsForRunProvider(widget.sequenceRunId),
            ),
          ),
        ),
        data: (decisions) {
          if (decisions.isEmpty) {
            return _emptyState(colors);
          }
          return _buildBody(colors, decisions);
        },
      ),
    );
  }

  Widget _emptyState(SkotiqColors colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.fileSearch, size: 56, color: colors.textMuted),
          const SizedBox(height: 12),
          Text(
            'No decisions recorded for this run.',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize14, color: colors.textMuted),
          ),
          const SizedBox(height: 4),
          Text(
            'Older runs may pre-date the replay log.',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize12, color: colors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    SkotiqColors colors,
    List<ReplayDecision> all,
  ) {
    final (spanStart, spanEnd) = replayScrubSpan(
      all,
      startedAt: widget.startedAt,
      endedAt: widget.endedAt,
    );
    final spanMillis =
        spanEnd.millisecondsSinceEpoch - spanStart.millisecondsSinceEpoch;
    _timeRange ??= const RangeValues(0, 1);
    final filtered = _applyFilters(all, spanStart, spanMillis);

    return Column(
      children: [
        _filterBar(colors),
        if (spanMillis > 0) _timeRangeSlider(colors, spanStart, spanEnd),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(LucideIcons.list, size: 14, color: colors.textMuted),
              const SizedBox(width: 6),
              Text(
                '${filtered.length} of ${all.length} decisions',
                style: SkotiqTypography.h6.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: filtered.length,
            itemBuilder: (context, i) {
              final d = filtered[i];
              return _DecisionTile(
                decision: d,
                colors: colors,
                searchTerm: _searchTerm,
                onAddNote: () => _addNoteForDecision(d),
                onJumpToForensics: () => _jumpToForensicsForDecision(d),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _filterBar(SkotiqColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search.
          TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search summary…',
              prefixIcon:
                  Icon(LucideIcons.search, size: 16, color: colors.textMuted),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _searchTerm.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(LucideIcons.x, size: 14),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _searchTerm = '');
                      },
                    ),
            ),
            onChanged: (v) => setState(() => _searchTerm = v.trim()),
          ),
          const SizedBox(height: 12),
          // Category chips.
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilterChip(
                label: const Text('All'),
                selected: _categoryFilter == null,
                onSelected: (sel) => setState(() => _categoryFilter = null),
              ),
              ...DecisionCategory.values
                  .where((c) => c != DecisionCategory.unknown)
                  .map(
                    (c) => FilterChip(
                      label: Text(c.displayLabel),
                      selected: _categoryFilter == c,
                      selectedColor:
                          _categoryColor(c, colors).withValues(alpha: 0.3),
                      onSelected: (sel) =>
                          setState(() => _categoryFilter = sel ? c : null),
                    ),
                  ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _timeRangeSlider(
    SkotiqColors colors,
    DateTime spanStart,
    DateTime spanEnd,
  ) {
    final range = _timeRange ?? const RangeValues(0, 1);
    final startLabel = DateFormat('HH:mm:ss')
        .format(_offsetFromFraction(spanStart, spanEnd, range.start));
    final endLabel = DateFormat('HH:mm:ss')
        .format(_offsetFromFraction(spanStart, spanEnd, range.end));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Time range: $startLabel — $endLabel',
                style: SkotiqTypography.labelStrongSm
                    .copyWith(color: colors.textMuted),
              ),
              if (range.start > 0 || range.end < 1)
                TextButton(
                  onPressed: () =>
                      setState(() => _timeRange = const RangeValues(0, 1)),
                  child: const Text('Reset',
                      style: TextStyle(fontSize: SkotiqTypography.fontSize11)),
                ),
            ],
          ),
          RangeSlider(
            values: range,
            divisions: 100,
            onChanged: (v) => setState(() => _timeRange = v),
          ),
        ],
      ),
    );
  }

  DateTime _offsetFromFraction(
    DateTime spanStart,
    DateTime spanEnd,
    double frac,
  ) {
    final span =
        spanEnd.millisecondsSinceEpoch - spanStart.millisecondsSinceEpoch;
    final off = (span * frac).round();
    return DateTime.fromMillisecondsSinceEpoch(
      spanStart.millisecondsSinceEpoch + off,
      isUtc: spanStart.isUtc,
    );
  }

  List<ReplayDecision> _applyFilters(
    List<ReplayDecision> all,
    DateTime spanStart,
    int spanMillis,
  ) {
    final range = _timeRange;
    // At full extent the slider is not a filter at all. Say so explicitly
    // rather than relying on the fraction arithmetic landing exactly on the
    // endpoints — a row the header counts must be on screen.
    final unclamped = range == null || (range.start <= 0.0 && range.end >= 1.0);
    final minMillis = (range == null || spanMillis <= 0)
        ? spanStart.millisecondsSinceEpoch
        : spanStart.millisecondsSinceEpoch + (spanMillis * range.start).round();
    final maxMillis = (range == null || spanMillis <= 0)
        ? spanStart.millisecondsSinceEpoch + spanMillis
        : spanStart.millisecondsSinceEpoch + (spanMillis * range.end).round();

    final term = _searchTerm.toLowerCase();
    return all.where((d) {
      if (_categoryFilter != null && d.category != _categoryFilter) {
        return false;
      }
      if (term.isNotEmpty &&
          !d.summary.toLowerCase().contains(term) &&
          !(d.nodeId?.toLowerCase().contains(term) ?? false)) {
        return false;
      }
      if (unclamped) return true;
      final ms = d.timestamp.millisecondsSinceEpoch;
      if (ms < minMillis || ms > maxMillis) return false;
      return true;
    }).toList(growable: false);
  }

  void _resetFilters() {
    setState(() {
      _categoryFilter = null;
      _searchCtrl.clear();
      _searchTerm = '';
      _timeRange = const RangeValues(0, 1);
    });
  }

  /// Notes cross-link — pre-fill a journal note with the
  /// decision's timestamp + summary. The note is saved immediately
  /// (silent insert) so the operator's next visit to the run's notes
  /// list shows the entry; a snackbar confirms.
  Future<void> _addNoteForDecision(ReplayDecision d) async {
    final notesService = ref.read(notesRepositoryProvider);
    final body = StringBuffer()
      ..writeln(
          'At ${DateFormat.yMd().add_Hms().format(d.timestamp.toLocal())}: ${d.summary}')
      ..writeln()
      ..writeln('Category: ${d.category.displayLabel}');
    if (d.nodeId != null) body.writeln('Node: ${d.nodeId}');
    if (d.details.isNotEmpty) {
      body.writeln();
      body.writeln('Details:');
      body.writeln(const JsonEncoder.withIndent('  ').convert(d.details));
    }
    // Target id is not part of a decision row; we file the note
    // against a synthetic "run-${runId}" target so the run-scoped
    // view (notesForRunProvider) surfaces it. The NotesService
    // requires a non-empty target id, so we use the run wrapper.
    await notesService.addNote(
      targetId: 'run-${widget.sequenceRunId}',
      title: 'Replay: ${d.category.displayLabel}',
      body: body.toString(),
      sequenceRunId: widget.sequenceRunId,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Note added for this decision'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Forensics cross-link — open the same Frame Detail dialog
  /// used by the run dashboard when a replayed FrameRejected decision
  /// carries a captured-image id.
  Future<void> _jumpToForensicsForDecision(ReplayDecision d) async {
    final imageId = _readImageId(d.details['captured_image_id']) ??
        _readImageId(d.details['image_id']);
    if (!mounted) return;
    if (imageId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No captured image id is linked to this row'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    await FrameDetailDialog.showForFrame(context, imageId: imageId);
  }

  int? _readImageId(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// Category-coded badge color. Stays consistent between the filter
/// chip and the row badge for visual continuity.
Color _categoryColor(DecisionCategory c, SkotiqColors colors) {
  switch (c) {
    case DecisionCategory.schedulerPick:
      return colors.primary;
    case DecisionCategory.triggerFired:
      return colors.warning;
    case DecisionCategory.recoveryEntered:
      return colors.error;
    case DecisionCategory.budgetMet:
      return colors.success;
    case DecisionCategory.adaptiveSwap:
      return colors.primary;
    case DecisionCategory.frameAccepted:
      return colors.success;
    case DecisionCategory.frameRejected:
      return colors.warning;
    case DecisionCategory.pluginNodeInvoked:
      return colors.textMuted;
    case DecisionCategory.manualIntervention:
      return colors.primary;
    case DecisionCategory.systemEvent:
      return colors.textMuted;
    case DecisionCategory.unknown:
      return colors.textMuted;
  }
}

class _DecisionTile extends StatefulWidget {
  const _DecisionTile({
    required this.decision,
    required this.colors,
    required this.searchTerm,
    required this.onAddNote,
    required this.onJumpToForensics,
  });

  final ReplayDecision decision;
  final SkotiqColors colors;
  final String searchTerm;
  final VoidCallback onAddNote;
  final VoidCallback onJumpToForensics;

  @override
  State<_DecisionTile> createState() => _DecisionTileState();
}

class _DecisionTileState extends State<_DecisionTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final badgeColor = _categoryColor(widget.decision.category, c);
    final tsLocal = widget.decision.timestamp.toLocal();
    final timeLabel = DateFormat('HH:mm:ss').format(tsLocal);
    final isForensicsLinked =
        widget.decision.category == DecisionCategory.frameRejected ||
            widget.decision.details.containsKey('captured_image_id') ||
            widget.decision.details.containsKey('reject_path');

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: c.border.withValues(alpha: 0.5)),
          left: BorderSide(color: badgeColor, width: 3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 76,
                  child: Text(
                    timeLabel,
                    style: TextStyle(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontSize: SkotiqTypography.fontSize12,
                      color: c.textMuted,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: SkotiqDecorations.statusChip(
                    badgeColor,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                    bordered: false,
                  ),
                  child: Text(
                    widget.decision.category.displayLabel,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      fontWeight: FontWeight.w700,
                      color: badgeColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.decision.summary,
                    style:
                        SkotiqTypography.label.copyWith(color: c.textPrimary),
                  ),
                ),
                IconButton(
                  tooltip: _expanded ? 'Hide details' : 'View details',
                  icon: Icon(
                    _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                    size: 16,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  border: Border.all(color: c.border),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.decision.nodeId != null)
                      Text('Node: ${widget.decision.nodeId}',
                          style: TextStyle(
                              fontSize: SkotiqTypography.fontSize11,
                              color: c.textMuted)),
                    if (widget.decision.details.isEmpty)
                      Text(
                        'No extra details.',
                        style: TextStyle(
                            fontSize: SkotiqTypography.fontSize11,
                            color: c.textMuted),
                      )
                    else
                      Text(
                        const JsonEncoder.withIndent('  ')
                            .convert(widget.decision.details),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: SkotiqTypography.fontSize11,
                          color: c.textPrimary,
                        ),
                      ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      children: [
                        TextButton.icon(
                          onPressed: widget.onAddNote,
                          icon: const Icon(LucideIcons.bookOpen, size: 12),
                          label: const Text('Add note',
                              style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize11)),
                        ),
                        if (isForensicsLinked)
                          TextButton.icon(
                            onPressed: widget.onJumpToForensics,
                            icon: const Icon(LucideIcons.fileSearch, size: 12),
                            label: const Text('Forensics',
                                style: TextStyle(
                                    fontSize: SkotiqTypography.fontSize11)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
