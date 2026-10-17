import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/narrator/narrator_card.dart';
import '../../../widgets/narrator/narrator_feed.dart';

/// One-line Night Narrator strip for the imaging screen, sitting near the
/// Science HUD.
///
/// Surface #2 of the Night Narrator (see `docs/night_narrator_design.md`). It
/// is the eyepiece-level glance at "the story of your night": the most recent
/// event headline with its category icon and severity accent, auto-advancing
/// through any events from the last ~10 minutes so a glance keeps up with what
/// just happened. Tapping opens a bottom sheet with the full [NarratorFeed].
///
/// Visibility mirrors the other imaging HUD chrome:
///   * Session id comes from [sessionStateProvider] (the same source
///     `SubQualityBadge` / the Science HUD use). It is null for every manual
///     capture on this screen — `SessionStateNotifier.startSession` is only
///     ever called by the sequencer — and reading only the session feed made
///     the strip permanently invisible for anyone driving the imaging screen by
///     hand: a whole night of manual frames, autofocus runs and cooldowns and
///     not one line. `NarratorService` deliberately runs sessionless in that
///     case (its guiding / weather / autofocus / last-image detectors still
///     fire and persist with a null `session_id`), so the sessionless bucket is
///     read from [recentNarratorFeedProvider] instead.
///   * Like [SubQualityBadge] it renders [SizedBox.shrink] when there is
///     nothing honest to show — here, when the feed is empty — so the canvas
///     gains no idle clutter before the first insight fires.
///
/// Cost: the widget watches only the feed provider. A single [Timer] drives the
/// rotation (cancelled on dispose); relative-time labels refresh on the same
/// rotation cadence rather than a second timer.
class NarratorTicker extends ConsumerWidget {
  const NarratorTicker({super.key});

  /// Clock used to age events out of the rotation window. Overridable so a
  /// test can move time forward without sleeping — production is
  /// [DateTime.now]. Mirrors `NarratorService.setClock`.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = ref.watch(sessionStateProvider).dbSessionId;
    // No DB session (every manual capture on this screen) → the sessionless
    // bucket, which is where the narrator writes for those frames.
    final feed = sessionId == null
        ? ref.watch(recentNarratorFeedProvider)
        : ref.watch(narratorFeedProvider(sessionId));
    final events = feed.valueOrNull ?? const <NarratorEvent>[];
    if (events.isEmpty) return const SizedBox.shrink();

    return _NarratorTickerView(sessionId: sessionId, events: events);
  }
}

/// The animated strip itself, separated from the provider watch so the rotation
/// [Timer] lives in a [State] without forcing the consumer to be stateful.
class _NarratorTickerView extends StatefulWidget {
  /// Null when the frames being narrated belong to no DB session (manual
  /// captures). Decides which feed the sheet reads and whether a stale event
  /// may be used as the resting headline.
  final int? sessionId;
  final List<NarratorEvent> events;

  const _NarratorTickerView({required this.sessionId, required this.events});

  @override
  State<_NarratorTickerView> createState() => _NarratorTickerViewState();
}

class _NarratorTickerViewState extends State<_NarratorTickerView> {
  /// Events younger than this auto-advance in the rotation; older ones are
  /// pinned in only as the single resting headline once the recent ones drain.
  static const Duration _recentWindow = Duration(minutes: 10);

  /// How long each event holds the strip before advancing to the next.
  static const Duration _advanceInterval = Duration(seconds: 6);

  Timer? _timer;

  /// Index into [_rotation] of the event currently on screen.
  int _index = 0;

  /// The events eligible for auto-advance (recent, capped), newest/pinned
  /// first. Always at least one entry while the strip is visible.
  late List<NarratorEvent> _rotation;

  @override
  void initState() {
    super.initState();
    _rotation = _buildRotation(widget.events);
    _restartTimer();
  }

  @override
  void didUpdateWidget(_NarratorTickerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.events, widget.events)) {
      final next = _buildRotation(widget.events);
      // Keep the strip pinned to the newest event when fresh insight arrives so
      // the user sees the latest happening, rather than mid-rotation drift.
      final newestId = next.isEmpty ? null : next.first.id;
      final hadNewest = _rotation.isNotEmpty && _rotation.first.id == newestId;
      _rotation = next;
      if (!hadNewest) {
        _index = 0;
        _restartTimer();
      } else if (_index >= _rotation.length) {
        _index = 0;
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// The events that participate in the auto-advance rotation: those within
  /// [_recentWindow] of now, newest/pinned-first (the provider already orders
  /// the feed that way, so we keep its order). Capped so a long burst of events
  /// doesn't make the rotation crawl.
  ///
  /// With a session, falling back to the single newest event keeps the strip
  /// resting on the latest thing this run said. Without one there is no run to
  /// scope it to: the sessionless bucket outlives the app, so its newest entry
  /// could be from a previous night — nothing honest to rest on, so stay quiet.
  List<NarratorEvent> _buildRotation(List<NarratorEvent> events) {
    final now = NarratorTicker.clock();
    final recent = events
        .where((e) => now.difference(e.timestamp).abs() <= _recentWindow)
        .take(6)
        .toList(growable: false);
    if (recent.isNotEmpty) return recent;
    if (widget.sessionId == null) return const <NarratorEvent>[];
    return events.isEmpty ? const <NarratorEvent>[] : [events.first];
  }

  /// Drives both the auto-advance and the re-evaluation of [_recentWindow].
  ///
  /// The window has to be re-checked on a clock, not only when the feed
  /// changes. `recentNarratorFeedProvider` is a DB watch, so on a hand-driven
  /// night it emits when an insight is written and then stays silent — one
  /// event at 22:00 and nothing after would leave that headline (and its
  /// "2m ago" label) pinned over the canvas for the rest of the night, which
  /// is the same stale-headline failure the sessionless window exists to
  /// prevent, only displaced in time. So the timer runs for a single event
  /// too, and each tick rebuilds the rotation before advancing.
  void _restartTimer() {
    _timer?.cancel();
    if (_rotation.isEmpty) return;
    _timer = Timer.periodic(_advanceInterval, (_) {
      if (!mounted) return;
      setState(() {
        _rotation = _buildRotation(widget.events);
        if (_rotation.isEmpty) {
          _index = 0;
          _timer?.cancel();
          _timer = null;
          return;
        }
        _index = (_index + 1) % _rotation.length;
      });
    });
  }

  Future<void> _openFeed() {
    final colors = SkotiqColors.of(context);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(SkotiqTokens.radiusLg),
        ),
      ),
      builder: (sheetContext) =>
          _NarratorFeedSheet(sessionId: widget.sessionId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    if (_rotation.isEmpty) return const SizedBox.shrink();

    final index = _index.clamp(0, _rotation.length - 1);
    final event = _rotation[index];
    final accent = NarratorVisuals.accentFor(event.severity, colors);
    final icon = NarratorVisuals.iconFor(event.category);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: SkotiqTokens.opacityStrong),
        borderRadius: SkotiqTokens.borderRadiusMd,
        border: Border.all(color: colors.border),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: _openFeed,
          borderRadius: SkotiqTokens.borderRadiusMd,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceMd,
              vertical: SkotiqTokens.spaceSm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Thin severity dot leading the strip — the "subtle accent"
                // idiom, never a filled alarm box.
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Icon(icon, size: 14, color: accent),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Flexible(
                  child: AnimatedSwitcher(
                    duration: SkotiqTokens.durationNormal,
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.25),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: _TickerLine(
                      // Key by event id so the switcher animates only on a real
                      // advance, not on an unrelated rebuild.
                      key: ValueKey<int>(event.id),
                      event: event,
                      colors: colors,
                    ),
                  ),
                ),
                if (_rotation.length > 1) ...[
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  _CountChip(count: _rotation.length, colors: colors),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The headline + relative-time pair shown for the current event. Kept as its
/// own widget so the [AnimatedSwitcher] has a clean keyed child to transition.
class _TickerLine extends StatelessWidget {
  final NarratorEvent event;
  final SkotiqColors colors;

  const _TickerLine({super.key, required this.event, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            event.headline,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.caption.copyWith(
                fontWeight: FontWeight.w600, color: colors.textPrimary),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Text(
          formatNarratorRelativeTime(event.timestamp),
          style: SkotiqTypography.withTabular(
            SkotiqTypography.labelQuiet.copyWith(color: colors.textMuted),
          ),
        ),
      ],
    );
  }
}

/// Small "N" counter chip shown when more than one event is in rotation, so the
/// glance knows the strip is cycling through several recent happenings.
class _CountChip extends StatelessWidget {
  final int count;
  final SkotiqColors colors;

  const _CountChip({required this.count, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        '$count',
        style: SkotiqTypography.withTabular(
          SkotiqTypography.labelQuiet.copyWith(color: colors.textSecondary),
        ),
      ),
    );
  }
}

/// Bottom sheet host for the full session feed. Reuses the shared [NarratorFeed]
/// so the cards open their own detail sheets on tap. Capped height so the sheet
/// never swallows the whole screen on a tall feed.
class _NarratorFeedSheet extends ConsumerWidget {
  /// Null for manual captures; the sheet then shows the sessionless bucket, so
  /// it never contradicts the strip that opened it.
  final int? sessionId;

  const _NarratorFeedSheet({required this.sessionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final id = sessionId;
    final feed = id == null
        ? ref.watch(recentNarratorFeedProvider)
        : ref.watch(narratorFeedProvider(id));
    final events = feed.valueOrNull ?? const <NarratorEvent>[];
    final maxHeight = MediaQuery.of(context).size.height * 0.7;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SkotiqTokens.spaceLg,
                SkotiqTokens.spaceMd,
                SkotiqTokens.spaceLg,
                SkotiqTokens.spaceSm,
              ),
              child: Row(
                children: [
                  Icon(
                    NarratorVisuals.iconFor(NarratorCategory.discovery),
                    size: 16,
                    color: colors.accent,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Text(
                    'Night narrator',
                    style: SkotiqTypography.labelStrong
                        .copyWith(color: colors.textPrimary),
                  ),
                ],
              ),
            ),
            Flexible(
              child: NarratorFeed(
                events: events,
                padding: const EdgeInsets.fromLTRB(
                  SkotiqTokens.spaceLg,
                  0,
                  SkotiqTokens.spaceLg,
                  SkotiqTokens.spaceLg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
