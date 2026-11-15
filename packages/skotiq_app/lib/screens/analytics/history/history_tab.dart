import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../router/analytics_route.dart';
import '../../../router/app_routes.dart';
import '../../../utils/count_label.dart';
import '../../../widgets/run_status/run_status_presentation.dart';
import '../../darkroom/targets/nights_strip.dart' show darkroomNightLabel;
import '../../sequencer/widgets/notes_panel.dart';
import '../../sequencer/widgets/pending_session_reports_card.dart';
import '../analytics_providers.dart';
import '../quick_capture_selection.dart';
import '../session_elapsed.dart';
import '../widgets/analytics_empty_state.dart';
import 'filter_menu_chip.dart';
import 'night_entry.dart';

/// Below this width a History row stacks its figures under the name.
const double _stackedRowBelow = 720;

const double _statusColumn = 168;
const double _elapsedColumn = 76;
const double _framesColumn = 64;
const double _integrationColumn = 92;
const double _hfrColumn = 76;
const double _chevronColumn = SkotiqTokens.iconSm + SkotiqTokens.spaceMd;

/// The label of an observing night, which spans two dates and names both:
/// `Night of Oct 31 to Nov 1`, with the year when it is not [now]'s.
String observingNightLabel(DateTime night, {required DateTime now}) {
  final label = 'Night of ${darkroomNightLabel(night)}';
  return night.year == now.year ? label : '$label, ${night.year}';
}

/// Analytics > History: every night on record, one row per run, grouped by
/// observing night, under the lifetime totals.
class HistoryTab extends ConsumerStatefulWidget {
  const HistoryTab({super.key, this.sequenceId});

  /// Narrows the list to one saved sequence's runs (Saved > View runs).
  final int? sequenceId;

  @override
  ConsumerState<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends ConsumerState<HistoryTab> {
  final _search = TextEditingController();
  late HistoryFilter _filter = HistoryFilter(sequenceId: widget.sequenceId);

  @override
  void didUpdateWidget(HistoryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sequenceId != oldWidget.sequenceId) {
      _filter = _filter.copyWith(sequenceId: () => widget.sequenceId);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _set(HistoryFilter filter) => setState(() => _filter = filter);

  void _clearFilters() {
    _search.clear();
    if (widget.sequenceId != null) {
      // The sequence filter lives in the location; clearing it goes there.
      context.go(AppRoutes.history());
    }
    _set(const HistoryFilter());
  }

  @override
  Widget build(BuildContext context) {
    final sessionsAsync = ref.watch(allSessionsProvider);
    final runsAsync = ref.watch(sequenceRunsProvider);
    final standalone = ref.watch(standaloneImagesProvider).valueOrNull ??
        const <DbCapturedImage>[];
    final targetNameById = {
      for (final target
          in ref.watch(allDbTargetsProvider).valueOrNull ?? const <DbTarget>[])
        target.id: target.name,
    };

    final error = sessionsAsync.error ?? runsAsync.error;
    if (error != null) {
      return EmptyState.error(
        title: 'History did not load',
        body: userFacingError(error),
        onRetry: () {
          ref.invalidate(allSessionsProvider);
          ref.invalidate(sequenceRunsProvider);
        },
      );
    }
    final sessions = sessionsAsync.valueOrNull;
    final runs = runsAsync.valueOrNull;
    if (sessions == null || runs == null) return const _HistorySkeleton();

    final entries = pairNightEntries(sessions, runs);
    final quickLights =
        standalone.where((image) => image.isLight).toList(growable: false);
    if (entries.isEmpty && quickLights.isEmpty) {
      return const AnalyticsEmptyState(
        icon: LucideIcons.history,
        title: 'No nights recorded yet',
        body: 'Run a sequence or take a frame and the night is listed here.',
      );
    }

    final now = DateTime.now();
    final shown = [
      for (final entry in entries)
        if (_filter.matches(entry, targetNameById: targetNameById, now: now))
          entry,
    ];
    final nights = groupByNight(
      shown,
      standaloneLights: _filter.admitsQuickCaptures
          ? [
              for (final image in quickLights)
                if (_filter.period.contains(image.capturedAt, now)) image,
            ]
          : const [],
    );

    final targetNames = <String>{
      for (final entry in entries) ...[
        if (targetNameById[entry.session?.targetId] case final String name
            when name.isNotEmpty)
          name,
        ...entry.runTargets,
      ],
    }.toList()
      ..sort();
    final hasUntargeted = entries.any((entry) {
      final name = targetNameById[entry.session?.targetId];
      return entry.session != null && (name == null || name.isEmpty);
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < BreakpointTokens.breakpointPhone;
        final stacked = constraints.maxWidth < _stackedRowBelow;
        final padding = compact
            ? SkotiqTokens.screenPaddingCompact
            : SkotiqTokens.screenPadding;
        final toolbar = _HistoryToolbar(
          search: _search,
          filter: _filter,
          compact: compact,
          targetNames: targetNames,
          offerUntargeted: hasUntargeted && targetNames.isNotEmpty,
          onChanged: _set,
          onClearSequence: () => context.go(AppRoutes.history()),
        );

        return ListView.builder(
          padding: padding,
          // Pending reports, totals, toolbar and column heads, then one block
          // per night (or the no-match state).
          itemCount: 4 + (nights.isEmpty ? 1 : nights.length),
          itemBuilder: (context, index) {
            switch (index) {
              case 0:
                return const PendingSessionReportsCard();
              case 1:
                return const Padding(
                  padding: EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
                  child: _TotalsStrip(),
                );
              case 2:
                return Padding(
                  padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
                  child: toolbar,
                );
              case 3:
                return stacked || nights.isEmpty
                    ? const SizedBox.shrink()
                    : const _ColumnHeads();
            }
            if (nights.isEmpty) {
              return Padding(
                padding: const EdgeInsets.only(top: SkotiqTokens.space3xl),
                child: EmptyState(
                  icon: LucideIcons.searchX,
                  title: 'No nights match',
                  body: 'Nothing on record fits the search and filters.',
                  action: SkotiqButton(
                    label: 'Clear filters',
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    onPressed: _clearFilters,
                  ),
                ),
              );
            }
            return _NightBlock(
              night: nights[index - 4],
              stacked: stacked,
              targetNameById: targetNameById,
              now: now,
              onOpen: (night) => context.go(
                AppRoutes.night(night, sequenceId: widget.sequenceId),
              ),
            );
          },
        );
      },
    );
  }
}

/// What the owner's equipment has done over every night on record.
class _TotalsStrip extends ConsumerWidget {
  const _TotalsStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final images = ref.watch(allDbImagesProvider).valueOrNull;
    final totals = images == null
        ? null
        : HistoryTotals.of(
            images: images,
            sessions: ref.watch(allSessionsProvider).valueOrNull,
            runs: ref.watch(sequenceRunsProvider).valueOrNull,
          );
    String? fixed(double? value, int digits) => value?.toStringAsFixed(digits);

    return SkotiqPanel(
      child: Semantics(
        container: true,
        label: 'Totals over every night on record',
        child: ReadoutRow(
          children: [
            Readout(
              size: ReadoutSize.sm,
              label: 'Exposures',
              value: totals == null
                  ? null
                  : QuantityFormat.grouped(totals.exposures),
            ),
            Readout(
              size: ReadoutSize.sm,
              label: 'Accepted integration',
              value: totals == null || totals.acceptedIntegrationSecs <= 0
                  ? null
                  : DurationFormat.decimalHours(totals.acceptedIntegrationSecs),
            ),
            Readout(
              size: ReadoutSize.sm,
              label: 'Meridian flips',
              value: totals?.meridianFlips?.toString(),
            ),
            Readout(
              size: ReadoutSize.sm,
              label: 'Autofocus runs',
              value: totals?.autofocusRuns?.toString(),
            ),
            Readout(
              size: ReadoutSize.sm,
              label: 'Avg HFR',
              unit: 'px',
              value: fixed(totals?.meanHfr, 2),
            ),
            Readout(
              size: ReadoutSize.sm,
              label: 'Avg guiding RMS',
              // ASCII, not U+2033: the bundled fonts have no prime glyph.
              unit: '"',
              value: fixed(totals?.meanGuidingRms, 2),
            ),
            Readout(
              size: ReadoutSize.sm,
              label: 'Avg sensor temp',
              unit: '°C',
              value: fixed(totals?.meanSensorTemp, 1),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryToolbar extends StatelessWidget {
  const _HistoryToolbar({
    required this.search,
    required this.filter,
    required this.compact,
    required this.targetNames,
    required this.offerUntargeted,
    required this.onChanged,
    required this.onClearSequence,
  });

  final TextEditingController search;
  final HistoryFilter filter;
  final bool compact;
  final List<String> targetNames;
  final bool offerUntargeted;
  final ValueChanged<HistoryFilter> onChanged;
  final VoidCallback onClearSequence;

  static const double _searchWidth = 280;

  /// One entry per way a run can end, then the live one; a paused run is live
  /// and is found under Running.
  static final List<SequenceRunStatus> _statuses = [
    ...SequenceRunStatus.values.where((status) => !status.isLive),
    SequenceRunStatus.running,
  ];

  static const String _untargeted = 'No target';

  @override
  Widget build(BuildContext context) {
    final searchField = SkotiqSearchField(
      controller: search,
      hint: 'Search nights and targets',
      onChanged: (value) => onChanged(filter.copyWith(query: value)),
    );
    final status = filter.status;
    final chips = <Widget>[
      FilterMenuChip<SequenceRunStatus?>(
        label: status == null ? 'Status: any' : runStatusLabel(status),
        name: 'Status filter',
        roomy: compact,
        entries: [
          (null, 'Any status'),
          for (final status in _statuses) (status, runStatusLabel(status)),
        ],
        selected: status,
        onSelected: (value) => onChanged(filter.copyWith(status: () => value)),
      ),
      if (targetNames.isNotEmpty)
        FilterMenuChip<String?>(
          label: filter.untargeted
              ? _untargeted
              : filter.target ?? 'Target: any',
          name: 'Target filter',
          roomy: compact,
          entries: [
            (null, 'Any target'),
            for (final name in targetNames) (name, name),
            if (offerUntargeted) (_untargeted, _untargeted),
          ],
          selected: filter.untargeted ? _untargeted : filter.target,
          onSelected: (value) => onChanged(
            filter.copyWith(
              target: () => value == _untargeted ? null : value,
              untargeted: value == _untargeted,
            ),
          ),
        ),
      FilterMenuChip<HistoryPeriod>(
        label: filter.period.label,
        name: 'Period filter',
        roomy: compact,
        entries: [
          for (final period in HistoryPeriod.values) (period, period.label),
        ],
        selected: filter.period,
        onSelected: (value) => onChanged(filter.copyWith(period: value)),
      ),
      if (filter.sequenceId != null)
        SkotiqChip(
          label: 'One sequence',
          icon: LucideIcons.x,
          tone: ChipTone.primary,
          onTap: onClearSequence,
        ),
    ];
    final notes = compact
        ? SkotiqIconButton(
            icon: LucideIcons.bookOpen,
            tooltip: 'All notes',
            onPressed: () => GlobalNotesDialog.show(context),
          )
        : SkotiqButton(
            label: 'All notes',
            icon: LucideIcons.bookOpen,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: () => GlobalNotesDialog.show(context),
          );

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: searchField),
              const SizedBox(width: SkotiqTokens.spaceSm),
              notes,
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final chip in chips)
                  Padding(
                    padding: const EdgeInsets.only(right: SkotiqTokens.spaceSm),
                    child: chip,
                  ),
              ],
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: _searchWidth, child: searchField),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: chips,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        notes,
      ],
    );
  }
}

class _ColumnHeads extends StatelessWidget {
  const _ColumnHeads();

  @override
  Widget build(BuildContext context) {
    final style = SkotiqTypography.eyebrow
        .copyWith(color: SkotiqColors.of(context).textMuted);
    Widget head(String text, double width, {bool end = true}) => SizedBox(
          width: width,
          child: Text(
            text,
            style: style,
            textAlign: end ? TextAlign.end : TextAlign.start,
          ),
        );
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceLg),
        child: Row(
          children: [
            const Spacer(),
            head('STATUS', _statusColumn, end: false),
            head('ELAPSED', _elapsedColumn),
            head('FRAMES', _framesColumn),
            head('INTEGRATION', _integrationColumn),
            head('HFR', _hfrColumn),
            const SizedBox(width: _chevronColumn),
          ],
        ),
      ),
    );
  }
}

/// One observing night: its label and count, then its rows in one panel.
class _NightBlock extends StatelessWidget {
  const _NightBlock({
    required this.night,
    required this.stacked,
    required this.targetNameById,
    required this.now,
    required this.onOpen,
  });

  final HistoryNight night;
  final bool stacked;
  final Map<int, String> targetNameById;

  /// Decides whether the night's label needs its year.
  final DateTime now;
  final ValueChanged<NightRef> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final runs = night.entries.length;
    final count = [
      if (runs > 0) countLabel(runs, 'run'),
      if (night.quickCaptures != null) 'quick captures',
    ].join(' · ');
    final rows = <Widget>[
      for (final entry in night.entries)
        _NightRow(
          entry: entry,
          stacked: stacked,
          targetName: targetNameById[entry.session?.targetId],
          onOpen: onOpen,
        ),
      if (night.quickCaptures case final quick?)
        _QuickCaptureRow(quick: quick, stacked: stacked),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: SkotiqTokens.spaceLg,
              bottom: SkotiqTokens.spaceSm,
            ),
            child: Semantics(
              header: true,
              child: Text(
                '${observingNightLabel(night.night, now: now)} · $count'
                    .toUpperCase(),
                style:
                    SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          SkotiqPanel(
            flush: true,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Container(height: 1, color: colors.border),
                  rows[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The figures a History row shows, in column order. Null is unknown.
class _RowFigures {
  const _RowFigures({
    required this.elapsed,
    required this.frames,
    required this.integration,
    required this.hfr,
  });

  final String? elapsed;
  final String? frames;
  final String? integration;
  final String? hfr;
}

class _NightRow extends ConsumerWidget {
  const _NightRow({
    required this.entry,
    required this.stacked,
    required this.targetName,
    required this.onOpen,
  });

  final NightEntry entry;
  final bool stacked;
  final String? targetName;
  final ValueChanged<NightRef> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final session = entry.session;
    final run = entry.run;
    final stats = entry.stats;

    final String statusLabel;
    final ChipTone tone;
    if (session != null) {
      statusLabel = sessionStatusLabel(session.status);
      tone = sessionStatusTone(session.status);
    } else {
      statusLabel = runStatusTokenLabel(run!.status);
      tone = runStatusTone(run.runStatus);
    }

    final String? elapsed;
    // Says what an unclosed session's elapsed time was measured to.
    String? elapsedBasis;
    if (session != null) {
      final sessionState = ref.watch(sessionStateProvider);
      final value = sessionElapsed(
        session,
        isLive: sessionState.isActive && sessionState.dbSessionId == session.id,
        lastFrameAt: ref.watch(lastFrameBySessionProvider)[session.id],
      );
      elapsed = value.duration == null ? null : value.valueLabel;
      if (value.isUnfinished) elapsedBasis = value.captionLabel;
    } else {
      final ended = run!.endedAt;
      elapsed = ended == null
          ? null
          : DurationFormat.of(
              ended.difference(run.startedAt),
              style: DurationStyle.coarse,
            );
    }
    // A run whose record cannot be read has no session to fall back on: its
    // figures are unknown, not zero.
    final frames = session?.totalExposures ?? stats?.framesCaptured;
    final integrationSecs =
        session?.totalIntegrationSecs ?? stats?.integrationSecs;
    final figures = _RowFigures(
      elapsed: elapsed,
      frames: frames?.toString(),
      integration: integrationSecs != null && integrationSecs > 0
          ? DurationFormat.seconds(integrationSecs, style: DurationStyle.coarse)
          : null,
      hfr: session?.avgHfr?.toStringAsFixed(2),
    );

    final rejected = session == null
        ? stats?.framesRejected
        : ref.watch(gradingBySessionProvider)?[session.id]?.rejected;
    final notes = run == null
        ? null
        : ref.watch(notesForRunProvider(run.id)).valueOrNull?.length;
    final sessionTarget = targetName;
    final target = sessionTarget != null && sessionTarget.isNotEmpty
        ? sessionTarget
        : entry.runTargets.firstOrNull;
    final name = entry.name ?? 'Unnamed session';
    final facts = [
      ClockFormat.hm(entry.startedAt.toLocal()),
      if (target != null && !name.contains(target)) target,
      if (elapsedBasis != null)
        elapsed == null ? elapsedBasis : '$elapsed $elapsedBasis',
      if (notes != null && notes > 0) countLabel(notes, 'note'),
    ];

    return _RowShell(
      semanticLabel: '$name, $statusLabel',
      onTap: () => onOpen(
        session != null ? NightRef.session(session.id) : NightRef.run(run!.id),
      ),
      stacked: stacked,
      title: name,
      facts: facts,
      warning: rejected != null && rejected > 0 ? '$rejected rejected' : null,
      statusLabel: statusLabel,
      statusTone: tone,
      statusColor: tone.resolve(colors) ?? colors.textSecondary,
      figures: figures,
    );
  }
}

class _QuickCaptureRow extends ConsumerWidget {
  const _QuickCaptureRow({required this.quick, required this.stacked});

  final QuickCaptureNight quick;
  final bool stacked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final times = quick.lights.map((image) => image.capturedAt).toList()
      ..sort();
    final first = ClockFormat.hm(times.first.toLocal());
    final last = ClockFormat.hm(times.last.toLocal());
    final hfrs = [
      for (final image in quick.lights)
        if (image.hfr case final double hfr when hfr.isFinite && hfr >= 0) hfr,
    ];
    return _RowShell(
      semanticLabel: 'Quick captures',
      // Quick captures have no session row; Analytics > Session charts them.
      onTap: () {
        ref.read(analyticsSessionPickProvider.notifier).state =
            kQuickCaptureSessionSelection;
        context.go(AppRoutes.session());
      },
      stacked: stacked,
      title: 'Quick captures',
      facts: [
        first == last ? first : '$first to $last',
        'taken outside a sequence',
      ],
      warning: null,
      statusLabel: null,
      statusTone: ChipTone.neutral,
      statusColor: colors.textSecondary,
      figures: _RowFigures(
        elapsed: null,
        frames: '${quick.lights.length}',
        integration: quick.integrationSecs > 0
            ? DurationFormat.seconds(
                quick.integrationSecs,
                style: DurationStyle.coarse,
              )
            : null,
        hfr: hfrs.isEmpty
            ? null
            : (hfrs.reduce((a, b) => a + b) / hfrs.length).toStringAsFixed(2),
      ),
    );
  }
}

/// The layout of one History row: a wide row with aligned figure columns, or
/// below [_stackedRowBelow] the name over one line of facts.
class _RowShell extends StatefulWidget {
  const _RowShell({
    required this.semanticLabel,
    required this.onTap,
    required this.stacked,
    required this.title,
    required this.facts,
    required this.warning,
    required this.statusLabel,
    required this.statusTone,
    required this.statusColor,
    required this.figures,
  });

  final String semanticLabel;
  final VoidCallback onTap;
  final bool stacked;
  final String title;
  final List<String> facts;

  /// A fact drawn in the warning color after [facts], or null.
  final String? warning;

  /// Null for a row with no outcome (quick captures).
  final String? statusLabel;
  final ChipTone statusTone;
  final Color statusColor;
  final _RowFigures figures;

  /// Keeps a stacked row a comfortable touch target.
  static const double _stackedMinHeight = 56;

  @override
  State<_RowShell> createState() => _RowShellState();
}

class _RowShellState extends State<_RowShell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final muted = SkotiqTypography.bodySm.copyWith(color: colors.textSecondary);
    final title = Text(
      widget.title,
      style: SkotiqTypography.bodyStrong.copyWith(color: colors.textPrimary),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final chevron = Icon(
      LucideIcons.chevronRight,
      size: SkotiqTokens.iconSm,
      color: colors.textMuted,
    );
    final figures = widget.figures;

    Widget factsLine(List<InlineSpan> lead, List<String> facts) => Text.rich(
          TextSpan(
            children: [
              ...lead,
              TextSpan(
                text: [if (lead.isNotEmpty) '', ...facts].join(' · '),
              ),
              if (widget.warning != null)
                TextSpan(
                  text: ' · ${widget.warning}',
                  style: TextStyle(color: colors.warning),
                ),
            ],
          ),
          style: muted,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );

    final Widget content;
    if (widget.stacked) {
      final hfr = figures.hfr;
      content = ConstrainedBox(
        constraints:
            const BoxConstraints(minHeight: _RowShell._stackedMinHeight),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  title,
                  const SizedBox(height: ListRow.lineGap),
                  factsLine(
                    [
                      if (widget.statusLabel != null)
                        TextSpan(
                          text: widget.statusLabel,
                          style: TextStyle(color: widget.statusColor),
                        ),
                    ],
                    [
                      ...widget.facts.take(1),
                      if (figures.elapsed != null) figures.elapsed!,
                      if (figures.frames != null) '${figures.frames} fr',
                      if (hfr != null) '$hfr px',
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            chevron,
          ],
        ),
      );
    } else {
      Widget figure(String? value, double width, {String? unit}) => SizedBox(
            width: width,
            child: Text(
              value == null
                  ? kReadoutUnknown
                  : unit == null
                      ? value
                      : '$value $unit',
              textAlign: TextAlign.end,
              style: SkotiqTypography.monoSm.copyWith(
                color: value == null ? colors.textMuted : colors.textPrimary,
              ),
            ),
          );
      content = Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: ListRow.lineGap),
                factsLine(const [], widget.facts),
              ],
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          SizedBox(
            width: _statusColumn,
            child: widget.statusLabel == null
                ? null
                : Align(
                    alignment: Alignment.centerLeft,
                    child: SkotiqChip(
                      label: widget.statusLabel!,
                      tone: widget.statusTone,
                    ),
                  ),
          ),
          figure(figures.elapsed, _elapsedColumn),
          figure(figures.frames, _framesColumn),
          figure(figures.integration, _integrationColumn),
          figure(figures.hfr, _hfrColumn, unit: 'px'),
          const SizedBox(width: SkotiqTokens.spaceMd),
          chevron,
        ],
      );
    }

    return Semantics(
      container: true,
      button: true,
      enabled: true,
      label: widget.semanticLabel,
      onTap: widget.onTap,
      child: ExcludeSemantics(
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: ColoredBox(
              color: _hovered ? colors.surfaceHover : Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: SkotiqTokens.spaceLg,
                  vertical: SkotiqTokens.spaceSm,
                ),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistorySkeleton extends StatelessWidget {
  const _HistorySkeleton();

  static const double _rowHeight = 40;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: SkotiqTokens.screenPadding,
      children: [
        for (var i = 0; i < 6; i++)
          const Padding(
            padding: EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
            child: ShimmerLoading(
              child: SkotiqPanel(
                child: SizedBox(
                  height: _rowHeight,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SkeletonBox(width: 180, height: 14),
                            SizedBox(height: SkotiqTokens.spaceSm),
                            SkeletonBox(width: 120, height: 12),
                          ],
                        ),
                      ),
                      SkeletonBox(width: 220, height: 20),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
