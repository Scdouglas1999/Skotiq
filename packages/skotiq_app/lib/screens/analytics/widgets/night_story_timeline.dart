import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/narrator/narrator_card.dart';
import '../../../widgets/narrator/narrator_detail_sheet.dart';

/// Surface #3 of the Night Narrator: the Analytics "Night Story" timeline.
///
/// A vertical, *chronological* (oldest → newest, reading like a story) timeline
/// of a session's narrator events, grouped under local-time hour headers
/// ("21:00", "22:00"). Each entry shows an absolute HH:MM time, the category
/// icon, the headline, an optional one-line body and an inline micro-viz; a
/// thin severity-coloured rail runs down the left with a node per event
/// (discovery/celebrate nodes are larger and carry the sparkles glyph).
///
/// Consumes the frozen core layer (`narratorFeedProvider`) and the frozen card
/// library (`NarratorVisuals` / `NarratorEvidenceViz` / `showNarratorDetailSheet`)
/// — it reimplements none of it. The grouping and filter logic live in plain
/// pure functions at file scope so they are unit-testable without a widget.

/// A category filter token for the chip row. [NightStoryFilter.all] is the
/// implicit "show everything" state and is never combined with the others.
enum NightStoryFilter {
  all,
  discovery,
  milestone,
  conditions,
  equipment,
  quality
}

/// Map a filter token to the underlying [NarratorCategory] it selects.
/// [NightStoryFilter.all] has no single category and returns `null`.
NarratorCategory? nightStoryFilterCategory(NightStoryFilter filter) {
  return switch (filter) {
    NightStoryFilter.all => null,
    NightStoryFilter.discovery => NarratorCategory.discovery,
    NightStoryFilter.milestone => NarratorCategory.milestone,
    NightStoryFilter.conditions => NarratorCategory.conditions,
    NightStoryFilter.equipment => NarratorCategory.equipment,
    NightStoryFilter.quality => NarratorCategory.quality,
  };
}

/// Filter [events] by the active category selection. An empty [active] set, or
/// one containing [NightStoryFilter.all], passes everything through; otherwise
/// only events whose category matches one of the selected tokens survive.
///
/// Pure: no clock, no I/O. Preserves input order.
List<NarratorEvent> filterNightStoryEvents(
  List<NarratorEvent> events,
  Set<NightStoryFilter> active,
) {
  if (active.isEmpty || active.contains(NightStoryFilter.all)) {
    return List<NarratorEvent>.unmodifiable(events);
  }
  final categories = <NarratorCategory>{};
  for (final token in active) {
    final category = nightStoryFilterCategory(token);
    if (category != null) categories.add(category);
  }
  return events
      .where((e) => categories.contains(e.category))
      .toList(growable: false);
}

/// One hour-bucket of the night story: the local "HH:00" header label, the
/// hour key it groups on, and the events that fall in it (chronological).
class NightStoryHourGroup {
  /// Display label for the hour header, e.g. `"21:00"` (local time).
  final String label;

  /// The truncated-to-the-hour local timestamp this group keys on. Stable
  /// across events in the same hour; used for ordering and as a list key.
  final DateTime hourStart;

  /// Events in this hour, oldest → newest.
  final List<NarratorEvent> events;

  const NightStoryHourGroup({
    required this.label,
    required this.hourStart,
    required this.events,
  });
}

/// Bucket [events] into per-hour groups for the timeline.
///
/// Sorts everything chronologically (oldest → newest) first — so the story
/// reads top-to-bottom in time regardless of the feed's pinned-first ordering —
/// then groups consecutive events sharing the same local hour under one header.
/// Hours with no events produce no group (the timeline is dense, not a ruler).
///
/// Pure: the only time reading is `event.timestamp.toLocal()`.
List<NightStoryHourGroup> groupNightStoryByHour(List<NarratorEvent> events) {
  if (events.isEmpty) return const [];

  final sorted = events.toList(growable: false)
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  final groups = <NightStoryHourGroup>[];
  DateTime? currentHour;
  var bucket = <NarratorEvent>[];

  void flush() {
    final hour = currentHour;
    if (hour != null && bucket.isNotEmpty) {
      groups.add(
        NightStoryHourGroup(
          label: _hourLabel(hour),
          hourStart: hour,
          events: List<NarratorEvent>.unmodifiable(bucket),
        ),
      );
    }
  }

  for (final event in sorted) {
    final local = event.timestamp.toLocal();
    final hour = DateTime(local.year, local.month, local.day, local.hour);
    if (currentHour == null || hour != currentHour) {
      flush();
      currentHour = hour;
      bucket = <NarratorEvent>[event];
    } else {
      bucket.add(event);
    }
  }
  flush();

  return groups;
}

/// Per-category counts for the summary strip. `warnings` folds together the
/// `warning` and `critical` severities (the strip speaks of "warnings", not
/// severities). Computed from the *unfiltered* session feed so the headline
/// numbers describe the whole night, not the current chip selection.
class NightStorySummary {
  final int discoveries;
  final int milestones;
  final int conditions;
  final int equipment;
  final int quality;

  /// `warning` + `critical` severity events, across all categories.
  final int warnings;

  /// Total events in the session.
  final int total;

  const NightStorySummary({
    required this.discoveries,
    required this.milestones,
    required this.conditions,
    required this.equipment,
    required this.quality,
    required this.warnings,
    required this.total,
  });
}

/// Tally [events] into a [NightStorySummary]. Pure.
NightStorySummary summarizeNightStory(List<NarratorEvent> events) {
  var discoveries = 0;
  var milestones = 0;
  var conditions = 0;
  var equipment = 0;
  var quality = 0;
  var warnings = 0;
  for (final e in events) {
    switch (e.category) {
      case NarratorCategory.discovery:
        discoveries++;
      case NarratorCategory.milestone:
        milestones++;
      case NarratorCategory.conditions:
        conditions++;
      case NarratorCategory.equipment:
        equipment++;
      case NarratorCategory.quality:
        quality++;
    }
    if (e.severity == NarratorSeverity.warning ||
        e.severity == NarratorSeverity.critical) {
      warnings++;
    }
  }
  return NightStorySummary(
    discoveries: discoveries,
    milestones: milestones,
    conditions: conditions,
    equipment: equipment,
    quality: quality,
    warnings: warnings,
    total: events.length,
  );
}

/// Two-digit-padded "HH:00" label for a local hour-start.
String _hourLabel(DateTime hour) {
  final hh = hour.hour.toString().padLeft(2, '0');
  return '$hh:00';
}

/// Two-digit-padded "HH:MM" label for a local timestamp.
String _timeLabel(DateTime local) {
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

/// The Night Story timeline panel.
///
/// Watches [narratorFeedProvider] for [sessionId] (the same session the rest of
/// the science tab resolves), renders the summary strip + filter chips + the
/// grouped vertical timeline, and surfaces an empty state when the session has
/// no events (or the active filter hides them all).
class NightStoryTimeline extends ConsumerStatefulWidget {
  /// The session whose story to tell. When `null`, the panel shows the empty
  /// state (no session resolved → nothing to narrate).
  final int? sessionId;

  const NightStoryTimeline({super.key, required this.sessionId});

  @override
  ConsumerState<NightStoryTimeline> createState() => _NightStoryTimelineState();
}

class _NightStoryTimelineState extends ConsumerState<NightStoryTimeline> {
  // Multi-select chip state. Default {all}; toggling a category clears `all`,
  // and clearing the last category falls back to `all`. Persists nothing.
  Set<NightStoryFilter> _active = {NightStoryFilter.all};

  void _onChipTapped(NightStoryFilter tapped) {
    setState(() {
      if (tapped == NightStoryFilter.all) {
        _active = {NightStoryFilter.all};
        return;
      }
      final next = Set<NightStoryFilter>.from(_active)
        ..remove(NightStoryFilter.all);
      if (next.contains(tapped)) {
        next.remove(tapped);
      } else {
        next.add(tapped);
      }
      _active = next.isEmpty ? {NightStoryFilter.all} : next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final sessionId = widget.sessionId;

    if (sessionId == null) {
      return _StoryShell(
        colors: colors,
        child: _emptyState(),
      );
    }

    final feedAsync = ref.watch(narratorFeedProvider(sessionId));

    return feedAsync.when(
      loading: () => _StoryShell(
        colors: colors,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Center(
              child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
        ),
      ),
      error: (_, __) => _StoryShell(
        colors: colors,
        child: _errorState(colors, sessionId),
      ),
      data: (allEvents) {
        final summary = summarizeNightStory(allEvents);
        final filtered = filterNightStoryEvents(allEvents, _active);
        final groups = groupNightStoryByHour(filtered);

        return _StoryShell(
          colors: colors,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SummaryStrip(summary: summary, colors: colors),
              const SizedBox(height: 12),
              _FilterChipRow(active: _active, onTapped: _onChipTapped),
              const SizedBox(height: 12),
              if (allEvents.isEmpty)
                _emptyState()
              else if (groups.isEmpty)
                _filteredEmptyState(colors)
              else
                _Timeline(groups: groups, colors: colors),
            ],
          ),
        );
      },
    );
  }

  Widget _errorState(SkotiqColors colors, int sessionId) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.alertTriangle, color: colors.error, size: 20),
          const SizedBox(height: 8),
          Text(
            "Couldn't load the night story.",
            textAlign: TextAlign.center,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 12),
          SkotiqButton(
            label: 'Retry',
            icon: LucideIcons.refreshCw,
            size: ButtonSize.small,
            onPressed: () => ref.invalidate(narratorFeedProvider(sessionId)),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return const EmptyState.compact(
      icon: LucideIcons.bookOpen,
      title: 'No story yet for this session',
      body: 'Events appear as the Narrator interprets your data.',
    );
  }

  Widget _filteredEmptyState(SkotiqColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: Text(
          'No events in the selected categories.',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      ),
    );
  }
}

/// Card chrome + "Night Story" panel wrapper shared by the populated and empty
/// states, so the panel keeps a consistent footprint in the tab.
class _StoryShell extends StatelessWidget {
  final SkotiqColors colors;
  final Widget child;

  const _StoryShell({required this.colors, required this.child});

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: child,
    );
  }
}

/// "2 discoveries · 5 milestones · 3 warnings" — a compact count strip. Only
/// non-zero buckets are shown; an all-zero session shows a quiet placeholder.
class _SummaryStrip extends StatelessWidget {
  final NightStorySummary summary;
  final SkotiqColors colors;

  const _SummaryStrip({required this.summary, required this.colors});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    void add(int count, String singular, String plural) {
      if (count > 0) parts.add('$count ${count == 1 ? singular : plural}');
    }

    add(summary.discoveries, 'discovery', 'discoveries');
    add(summary.milestones, 'milestone', 'milestones');
    add(summary.conditions, 'conditions note', 'conditions notes');
    add(summary.equipment, 'equipment note', 'equipment notes');
    add(summary.quality, 'quality note', 'quality notes');
    add(summary.warnings, 'warning', 'warnings');

    final text =
        parts.isEmpty ? 'No events yet this session.' : parts.join(' · ');

    return Text(
      text,
      style: SkotiqTypography.withTabular(
        SkotiqTypography.caption.copyWith(
            color: colors.textSecondary,
            height: 1.3,
            fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Multi-select category chip row (All / Discoveries / … / Quality), matching
/// the science tab's [ChoiceChip] idiom.
class _FilterChipRow extends StatelessWidget {
  final Set<NightStoryFilter> active;
  final ValueChanged<NightStoryFilter> onTapped;

  const _FilterChipRow({required this.active, required this.onTapped});

  static const _labels = <NightStoryFilter, String>{
    NightStoryFilter.all: 'All',
    NightStoryFilter.discovery: 'Discoveries',
    NightStoryFilter.milestone: 'Milestones',
    NightStoryFilter.conditions: 'Conditions',
    NightStoryFilter.equipment: 'Equipment',
    NightStoryFilter.quality: 'Quality',
  };

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in _labels.entries)
          _StoryFilterChip(
            label: entry.value,
            selected: active.contains(entry.key),
            onTap: () => onTapped(entry.key),
          ),
      ],
    );
  }
}

/// A single category chip. Mirrors `_QualityFilterChip` in the captures strip:
/// a [ChoiceChip] tinted by the primary accent when selected.
class _StoryFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _StoryFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return ChoiceChip(
      label: Text(
        label,
        style: SkotiqTypography.labelStrongSm.copyWith(
          color: selected ? colors.textPrimary : colors.textSecondary,
        ),
      ),
      selected: selected,
      selectedColor: colors.primary.withValues(alpha: 0.2),
      backgroundColor: colors.surfaceHover,
      side: BorderSide(color: selected ? colors.primary : colors.border),
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// The grouped vertical timeline: one hour header per group followed by its
/// event rows. A non-scrolling [Column] of slivers-free rows — the whole
/// science tab already lives in a single [SingleChildScrollView], so a nested
/// scroller would fight it. Rows are cheap (no per-row timers; absolute times).
class _Timeline extends StatelessWidget {
  final List<NightStoryHourGroup> groups;
  final SkotiqColors colors;

  const _Timeline({required this.groups, required this.colors});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var g = 0; g < groups.length; g++) {
      final group = groups[g];
      children.add(_HourHeader(label: group.label, colors: colors));
      for (var i = 0; i < group.events.length; i++) {
        final event = group.events[i];
        // The rail is continuous across the whole group *and* across the
        // header gap, except at the very top and very bottom of the timeline.
        final isFirstOverall = g == 0 && i == 0;
        final isLastOverall =
            g == groups.length - 1 && i == group.events.length - 1;
        children.add(
          _TimelineRow(
            event: event,
            colors: colors,
            railTop: !isFirstOverall,
            railBottom: !isLastOverall,
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// A local-time hour header ("21:00"). The rail continues through it.
class _HourHeader extends StatelessWidget {
  final String label;
  final SkotiqColors colors;

  const _HourHeader({required this.label, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Rail gutter: keep the header aligned with the row nodes below.
          SizedBox(
            width: _kRailWidth,
            child: Center(
              child: Container(
                width: 1.5,
                height: 18,
                color: colors.border,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: SkotiqTypography.withTabular(
              SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                  letterSpacing: 0.4,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

const double _kRailWidth = 18;

/// One timeline entry: the left rail (continuous line + a severity-coloured
/// node) and, to its right, a [NarratorCard] reused verbatim from the frozen
/// card library — so headline, body-via-detail, micro-viz, and the celebrate
/// gradient all stay consistent with the dashboard and ticker surfaces.
///
/// The card's relative-time slot is repurposed to carry the absolute HH:MM
/// time (the timeline reads as a clocked story, not "4m ago"), which is why we
/// build the card directly rather than letting it self-format.
class _TimelineRow extends StatelessWidget {
  final NarratorEvent event;
  final SkotiqColors colors;
  final bool railTop;
  final bool railBottom;

  const _TimelineRow({
    required this.event,
    required this.colors,
    required this.railTop,
    required this.railBottom,
  });

  @override
  Widget build(BuildContext context) {
    final accent = NarratorVisuals.accentFor(event.severity, colors);
    final isDiscovery = event.category == NarratorCategory.discovery ||
        event.severity == NarratorSeverity.celebrate;
    final local = event.timestamp.toLocal();

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Rail(
            accent: accent,
            colors: colors,
            emphasized: isDiscovery,
            top: railTop,
            bottom: railBottom,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: NarratorCard(
                event: event,
                relativeTime: _timeLabel(local),
                onTap: () => showNarratorDetailSheet(context, event),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The left rail for a single row: a thin vertical line spanning the row's
/// height with a node centred at the card. Discovery/celebrate nodes are larger
/// and carry the sparkles glyph.
class _Rail extends StatelessWidget {
  final Color accent;
  final SkotiqColors colors;
  final bool emphasized;
  final bool top;
  final bool bottom;

  const _Rail({
    required this.accent,
    required this.colors,
    required this.emphasized,
    required this.top,
    required this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    final nodeSize = emphasized ? 16.0 : 10.0;
    return SizedBox(
      width: _kRailWidth,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The continuous line. Two halves so the top/bottom ends can be
          // trimmed at the very start/end of the timeline.
          Positioned.fill(
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Container(
                      width: 1.5,
                      color: top ? colors.border : null,
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Container(
                      width: 1.5,
                      color: bottom ? colors.border : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // The node.
          Container(
            width: nodeSize,
            height: nodeSize,
            decoration: BoxDecoration(
              color: emphasized ? accent.withValues(alpha: 0.18) : accent,
              shape: BoxShape.circle,
              border: Border.all(
                color: accent,
                width: emphasized ? 1.5 : 1.0,
              ),
            ),
            child: emphasized
                ? Icon(LucideIcons.sparkles, size: 9, color: accent)
                : null,
          ),
        ],
      ),
    );
  }
}
