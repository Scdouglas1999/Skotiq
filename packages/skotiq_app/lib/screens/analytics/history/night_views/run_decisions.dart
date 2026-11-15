import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../utils/snackbar_helper.dart';
import '../../../sequencer/widgets/run_dashboard/frame_detail_dialog.dart';
import '../filter_menu_chip.dart';

/// The first and last instant the decisions of a run span, widened to the
/// run's own start and end when they are known.
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

ChipTone _categoryTone(DecisionCategory category) => switch (category) {
      DecisionCategory.schedulerPick ||
      DecisionCategory.adaptiveSwap ||
      DecisionCategory.manualIntervention =>
        ChipTone.primary,
      DecisionCategory.triggerFired ||
      DecisionCategory.frameRejected =>
        ChipTone.warning,
      DecisionCategory.recoveryEntered => ChipTone.error,
      DecisionCategory.budgetMet ||
      DecisionCategory.frameAccepted =>
        ChipTone.success,
      DecisionCategory.pluginNodeInvoked ||
      DecisionCategory.systemEvent ||
      DecisionCategory.unknown =>
        ChipTone.neutral,
    };

/// What narrows the decision list of a run.
class RunDecisionFilter {
  const RunDecisionFilter({
    this.category,
    this.query = '',
    this.range = const RangeValues(0, 1),
  });

  final DecisionCategory? category;
  final String query;

  /// The part of the run's span shown, as fractions of it.
  final RangeValues range;

  bool get isEmpty =>
      category == null && query.isEmpty && range.start <= 0 && range.end >= 1;

  List<ReplayDecision> apply(
    List<ReplayDecision> all,
    DateTime spanStart,
    DateTime spanEnd,
  ) {
    final startMs = spanStart.millisecondsSinceEpoch;
    final spanMs = spanEnd.millisecondsSinceEpoch - startMs;
    final whole = spanMs <= 0 || (range.start <= 0 && range.end >= 1);
    final minMs = startMs + (spanMs * range.start).round();
    final maxMs = startMs + (spanMs * range.end).round();
    final needle = query.toLowerCase();
    return [
      for (final d in all)
        if ((category == null || d.category == category) &&
            (needle.isEmpty || d.summary.toLowerCase().contains(needle)) &&
            (whole ||
                (d.timestamp.millisecondsSinceEpoch >= minMs &&
                    d.timestamp.millisecondsSinceEpoch <= maxMs)))
          d,
    ];
  }
}

/// The decisions the sequencer logged during one run, as slivers: a head with
/// the search, the category filter and the time range, then one row per
/// decision. A row opens to its details, from where a note can be filed
/// against it or its frame opened.
class RunDecisionsSliver extends ConsumerStatefulWidget {
  const RunDecisionsSliver({
    super.key,
    required this.runId,
    this.startedAt,
    this.endedAt,
  });

  final int runId;
  final DateTime? startedAt;
  final DateTime? endedAt;

  @override
  ConsumerState<RunDecisionsSliver> createState() => _RunDecisionsSliverState();
}

class _RunDecisionsSliverState extends ConsumerState<RunDecisionsSliver> {
  final _search = TextEditingController();
  RunDecisionFilter _filter = const RunDecisionFilter();

  static const double _searchWidth = 240;
  static const double _rangeTrackHeight = 2;
  static const double _rangeThumbRadius = 6;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clear() {
    _search.clear();
    setState(() => _filter = const RunDecisionFilter());
  }

  /// Files a note against the run that quotes the decision.
  Future<void> _addNote(ReplayDecision d) async {
    final body = StringBuffer()
      ..writeln(
          'At ${ClockFormat.dateHms(d.timestamp.toLocal())}: ${d.summary}')
      ..writeln()
      ..writeln('Category: ${d.category.displayLabel}');
    if (d.nodeId != null) body.writeln('Node: ${d.nodeId}');
    if (d.details.isNotEmpty) {
      body
        ..writeln()
        ..writeln('Details:')
        ..writeln(const JsonEncoder.withIndent('  ').convert(d.details));
    }
    try {
      // A decision names no target; the note is filed under the run so the
      // run's notes list shows it.
      await ref.read(notesJournalProvider).addNote(
            targetId: 'run-${widget.runId}',
            title: 'Replay: ${d.category.displayLabel}',
            body: body.toString(),
            sequenceRunId: widget.runId,
          );
      if (mounted) context.showInfoSnackBar('Note added for this decision');
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar(
          'The note was not saved: ${userFacingError(e)}',
        );
      }
    }
  }

  static int? _imageId(ReplayDecision d) {
    final value = d.details['captured_image_id'] ?? d.details['image_id'];
    return switch (value) {
      final int id => id,
      final num id => id.toInt(),
      final String id => int.tryParse(id),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final decisionsAsync = ref.watch(decisionsForRunProvider(widget.runId));
    const head = PanelHead(label: 'Decisions', icon: LucideIcons.listChecks);

    Widget panel(Widget body) => SliverToBoxAdapter(
          child: SkotiqPanel(head: head, child: body),
        );

    final all = decisionsAsync.valueOrNull;
    if (decisionsAsync.hasError) {
      return panel(
        EmptyState.error(
          title: 'The decision log did not load',
          body: userFacingError(decisionsAsync.error!),
          onRetry: () => ref.invalidate(decisionsForRunProvider(widget.runId)),
        ),
      );
    }
    if (all == null) {
      return panel(
        const ShimmerLoading(child: SkeletonBox(width: 320, height: 16)),
      );
    }
    if (all.isEmpty) {
      return panel(
        const EmptyState.compact(
          icon: LucideIcons.fileSearch,
          title: 'No decisions recorded for this run',
          body: 'Runs from before decision logging, or with logging turned '
              'off, have none.',
        ),
      );
    }

    final (spanStart, spanEnd) = replayScrubSpan(
      all,
      startedAt: widget.startedAt,
      endedAt: widget.endedAt,
    );
    final shown = _filter.apply(all, spanStart, spanEnd);
    DateTime at(double fraction) => DateTime.fromMillisecondsSinceEpoch(
          spanStart.millisecondsSinceEpoch +
              ((spanEnd.millisecondsSinceEpoch -
                          spanStart.millisecondsSinceEpoch) *
                      fraction)
                  .round(),
        );
    final muted = SkotiqTypography.bodySm.copyWith(color: colors.textSecondary);

    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        head,
        const SizedBox(height: SkotiqPanel.headGap),
        Wrap(
          spacing: SkotiqTokens.spaceSm,
          runSpacing: SkotiqTokens.spaceSm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: _searchWidth,
              child: SkotiqSearchField(
                controller: _search,
                hint: 'Search decisions',
                onChanged: (value) => setState(
                  () => _filter = RunDecisionFilter(
                    category: _filter.category,
                    query: value.trim(),
                    range: _filter.range,
                  ),
                ),
              ),
            ),
            FilterMenuChip<DecisionCategory?>(
              label: _filter.category?.displayLabel ?? 'Kind: any',
              name: 'Kind filter',
              entries: [
                (null, 'Any kind'),
                for (final c in DecisionCategory.values)
                  if (c != DecisionCategory.unknown) (c, c.displayLabel),
              ],
              selected: _filter.category,
              onSelected: (value) => setState(
                () => _filter = RunDecisionFilter(
                  category: value,
                  query: _filter.query,
                  range: _filter.range,
                ),
              ),
            ),
            Text('${shown.length} of ${all.length}', style: muted),
            if (!_filter.isEmpty)
              SkotiqButton(
                label: 'Clear filters',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: _clear,
              ),
          ],
        ),
        if (spanEnd.isAfter(spanStart)) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          Row(
            children: [
              Text(
                '${ClockFormat.hms(at(_filter.range.start).toLocal())} to '
                '${ClockFormat.hms(at(_filter.range.end).toLocal())}',
                style: SkotiqTypography.monoSm
                    .copyWith(color: colors.textSecondary),
              ),
              const SizedBox(width: SkotiqTokens.spaceLg),
              Expanded(
                child: Semantics(
                  label: 'Time range',
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: _rangeTrackHeight,
                      activeTrackColor: colors.primary,
                      inactiveTrackColor: colors.border,
                      thumbColor: colors.primary,
                      rangeThumbShape: const RoundRangeSliderThumbShape(
                        enabledThumbRadius: _rangeThumbRadius,
                      ),
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: RangeSlider(
                      values: _filter.range,
                      onChanged: (values) => setState(
                        () => _filter = RunDecisionFilter(
                          category: _filter.category,
                          query: _filter.query,
                          range: values,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceSm),
      ],
    );

    return DecoratedSliver(
      decoration: SkotiqDecorations.panel(colors),
      sliver: SliverPadding(
        padding: SkotiqTokens.paddingLg,
        sliver: SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(child: controls),
            if (shown.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: SkotiqTokens.spaceLg,
                  ),
                  child: Text('No decision matches.', style: muted),
                ),
              )
            else
              SliverList.builder(
                itemCount: shown.length,
                itemBuilder: (context, index) {
                  final decision = shown[index];
                  final imageId = _imageId(decision);
                  return _DecisionRow(
                    // Keyed by identity so an open row stays open when the
                    // filter changes the rows around it.
                    key: ValueKey(decision.id ?? index),
                    decision: decision,
                    onAddNote: () => _addNote(decision),
                    onOpenFrame: imageId == null
                        ? null
                        : () => FrameDetailDialog.showForFrame(
                              context,
                              imageId: imageId,
                            ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _DecisionRow extends StatefulWidget {
  const _DecisionRow({
    super.key,
    required this.decision,
    required this.onAddNote,
    required this.onOpenFrame,
  });

  final ReplayDecision decision;
  final VoidCallback onAddNote;

  /// Null when the decision names no frame.
  final VoidCallback? onOpenFrame;

  static const double _timeColumn = 72;
  static const double _kindColumn = 148;

  @override
  State<_DecisionRow> createState() => _DecisionRowState();
}

class _DecisionRowState extends State<_DecisionRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final decision = widget.decision;
    final narrow =
        MediaQuery.sizeOf(context).width < BreakpointTokens.breakpointPhone;
    final time = Text(
      ClockFormat.hms(decision.timestamp.toLocal()),
      style: SkotiqTypography.monoSm.copyWith(color: colors.textMuted),
    );
    final kind = SkotiqChip(
      label: decision.category.displayLabel,
      tone: _categoryTone(decision.category),
    );
    final summary = Text(
      decision.summary,
      style: SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
    );
    final toggle = SkotiqIconButton(
      icon: _open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
      tooltip: _open ? 'Hide details' : 'Show details',
      size: IconButtonSize.sm,
      onPressed: () => setState(() => _open = !_open),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (narrow) ...[
              Row(
                children: [
                  time,
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: Align(alignment: Alignment.centerLeft, child: kind),
                  ),
                  toggle,
                ],
              ),
              summary,
            ] else
              Row(
                children: [
                  SizedBox(width: _DecisionRow._timeColumn, child: time),
                  SizedBox(
                    width: _DecisionRow._kindColumn,
                    child: Align(alignment: Alignment.centerLeft, child: kind),
                  ),
                  Expanded(child: summary),
                  toggle,
                ],
              ),
            if (_open) ...[
              const SizedBox(height: SkotiqTokens.spaceSm),
              Container(
                padding: SkotiqTokens.paddingMd,
                decoration: SkotiqDecorations.well(colors),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (decision.nodeId != null)
                      Text(
                        'Step ${decision.nodeId}',
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textMuted),
                      ),
                    SelectableText(
                      decision.details.isEmpty
                          ? 'No further details were recorded.'
                          : const JsonEncoder.withIndent('  ')
                              .convert(decision.details),
                      style: SkotiqTypography.monoXs
                          .copyWith(color: colors.textSecondary),
                    ),
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    Wrap(
                      spacing: SkotiqTokens.spaceSm,
                      children: [
                        SkotiqButton(
                          label: 'Add note',
                          icon: LucideIcons.bookOpen,
                          variant: ButtonVariant.ghost,
                          size: ButtonSize.small,
                          onPressed: widget.onAddNote,
                        ),
                        if (widget.onOpenFrame != null)
                          SkotiqButton(
                            label: 'Open frame',
                            icon: LucideIcons.fileSearch,
                            variant: ButtonVariant.ghost,
                            size: ButtonSize.small,
                            onPressed: widget.onOpenFrame,
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
