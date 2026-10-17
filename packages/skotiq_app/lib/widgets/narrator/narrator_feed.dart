import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'narrator_card.dart';

/// Reusable Night Narrator feed list.
///
/// Renders a list of [NarratorEvent]s newest-first with pinned events bubbled
/// to the top — the providers already order them this way, so the feed trusts
/// the incoming order and does not re-sort. New events animate in with a subtle
/// slide + fade. Relative timestamps ("4m ago") are driven by a single shared
/// [Timer] living here, never per-card, so a long feed stays cheap.
///
/// Empty state: a small icon + "The Narrator is watching — insights appear as
/// your frames come in".
///
/// Surfaces that own scrolling (the Analytics timeline) pass [shrinkWrap] +
/// [physics]; the cockpit tile uses [NarratorFeed.compact] to cap the list at
/// [maxEvents] with internal scrolling.
class NarratorFeed extends StatefulWidget {
  final List<NarratorEvent> events;

  /// Cap the number of rendered events (newest/pinned kept). `null` = no cap.
  final int? maxEvents;

  /// When true the list sizes to its content (for embedding in another
  /// scrollable). When false it scrolls internally.
  final bool shrinkWrap;

  /// Scroll physics override. `null` lets the framework decide.
  final ScrollPhysics? physics;

  /// Outer padding around the list.
  final EdgeInsets padding;

  const NarratorFeed({
    super.key,
    required this.events,
    this.maxEvents,
    this.shrinkWrap = false,
    this.physics,
    this.padding = EdgeInsets.zero,
  });

  /// Compact variant for the cockpit tile: caps at [maxEvents] (default 8) and
  /// scrolls internally.
  const NarratorFeed.compact({
    super.key,
    required this.events,
    this.maxEvents = 8,
    this.padding = EdgeInsets.zero,
  })  : shrinkWrap = false,
        physics = null;

  @override
  State<NarratorFeed> createState() => _NarratorFeedState();
}

class _NarratorFeedState extends State<NarratorFeed> {
  /// Single shared ticker for relative-time refresh. One timer for the whole
  /// feed — cards receive their pre-formatted string and never tick themselves.
  Timer? _timer;

  /// Bumped each tick to force the time labels to recompute. Cheap: the only
  /// thing that changes is the relative-time strings.
  int _tick = 0;

  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();

  /// The events currently rendered, in display order. Diffed against incoming
  /// updates so [AnimatedList] can animate insertions of genuinely new events.
  late List<NarratorEvent> _visible;

  @override
  void initState() {
    super.initState();
    _visible = _capped(widget.events);
    // Relative times only need ~minute granularity to stay honest; 30s keeps
    // "just now" → "1m ago" transitions feeling live without burning cycles.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _tick++);
    });
  }

  @override
  void didUpdateWidget(NarratorFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.events, widget.events) ||
        oldWidget.maxEvents != widget.maxEvents) {
      _reconcile(_capped(widget.events));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  List<NarratorEvent> _capped(List<NarratorEvent> events) {
    final max = widget.maxEvents;
    if (max == null || events.length <= max) return List.of(events);
    return events.sublist(0, max);
  }

  /// Reconcile [_visible] with [next], animating in events whose ids weren't
  /// present before. Removals (events scrolling off the cap) are applied
  /// without an exit animation to keep the cockpit tile calm. Falls back to a
  /// plain swap if the animated-list state isn't available yet.
  void _reconcile(List<NarratorEvent> next) {
    final listState = _listKey.currentState;
    if (listState == null) {
      setState(() => _visible = next);
      return;
    }
    final oldIds = _visible.map((e) => e.id).toSet();

    // Remove anything no longer present (from the end of the list).
    for (var i = _visible.length - 1; i >= 0; i--) {
      if (!next.any((e) => e.id == _visible[i].id)) {
        final removed = _visible.removeAt(i);
        listState.removeItem(
          i,
          (context, animation) => _AnimatedRow(
            animation: animation,
            child: _buildCard(removed),
          ),
          duration: const Duration(milliseconds: 180),
        );
      }
    }

    // Insert genuinely-new events at their target index (top for newest).
    for (var i = 0; i < next.length; i++) {
      final event = next[i];
      if (!oldIds.contains(event.id)) {
        final insertAt = i.clamp(0, _visible.length);
        _visible.insert(insertAt, event);
        listState.insertItem(insertAt,
            duration: const Duration(milliseconds: 260));
      }
    }

    // Order/content of surviving rows may have shifted (e.g. a pin toggled);
    // sync the backing list so indexes line up, then repaint.
    setState(() => _visible = next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    if (_visible.isEmpty) {
      return _NarratorEmptyState(colors: colors);
    }
    return AnimatedList(
      key: _listKey,
      padding: widget.padding,
      shrinkWrap: widget.shrinkWrap,
      physics: widget.physics,
      initialItemCount: _visible.length,
      itemBuilder: (context, index, animation) {
        if (index >= _visible.length) return const SizedBox.shrink();
        return _AnimatedRow(
          animation: animation,
          child: Padding(
            padding: EdgeInsets.only(
              bottom:
                  index == _visible.length - 1 ? 0 : SkotiqTokens.spaceSm,
            ),
            child: _buildCard(_visible[index]),
          ),
        );
      },
    );
  }

  Widget _buildCard(NarratorEvent event) {
    return NarratorCard(
      // Keyed by id so card identity survives reordering and the AnimatedList
      // animates the right rows. `_tick` is read implicitly via relativeTime.
      key: ValueKey<int>(event.id),
      event: event,
      relativeTime: formatNarratorRelativeTime(event.timestamp),
    );
  }
}

/// Subtle slide + fade insertion/removal wrapper for a feed row.
class _AnimatedRow extends StatelessWidget {
  final Animation<double> animation;
  final Widget child;

  const _AnimatedRow({required this.animation, required this.child});

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    return FadeTransition(
      opacity: curved,
      child: SizeTransition(
        sizeFactor: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.06),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      ),
    );
  }
}

/// Empty state per spec — a small sparkles icon and the watcher line.
class _NarratorEmptyState extends StatelessWidget {
  final SkotiqColors colors;

  const _NarratorEmptyState({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceXl,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.sparkles, size: 16, color: colors.textMuted),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Text(
              'The Narrator is watching — insights appear as your '
              'frames come in.',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: SkotiqTypography.fontSize12_5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Format a Narrator event timestamp as a compact relative label, e.g.
/// "just now", "4m ago", "2h ago", "3d ago". Shared so the card, ticker, and
/// timeline read identically.
String formatNarratorRelativeTime(DateTime timestamp, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  var delta = reference.difference(timestamp);
  if (delta.isNegative) delta = Duration.zero;
  if (delta.inSeconds < 45) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}
