import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../utils/transient_bottom_inset.dart';

/// One rendered toast: the newest notification of its kind, plus every id
/// collapsed into it.
///
/// A single failed connect of the built-in guider raises the SAME refusal twice
/// — once from the Dart connect path via `ErrorService.log`, once from the
/// backend's error event via `event_provider`. Two producers for one condition
/// is a fact of this architecture (the backend is allowed to report what it
/// refused); stacking their identical words for the operator is not.
class _ToastGroup {
  /// The de-duplication key every member shares — see
  /// [notificationContentSignature]. Also the widget identity and the timer
  /// key, so a repeat lifts the count on the card the operator is already
  /// reading instead of replacing it with a fresh one.
  final String key;

  /// The most recent notification in the group — the one actually rendered.
  final UiNotification latest;

  /// Every notification id folded into this group, newest last. All of them
  /// are dismissed together, otherwise dismissing the visible one would just
  /// re-render its twin.
  final List<String> ids;

  const _ToastGroup({
    required this.key,
    required this.latest,
    required this.ids,
  });

  int get count => ids.length;
}

/// Overlay widget that displays toast notifications from [uiNotificationProvider].
///
/// Features:
/// - Positioned at bottom-right on desktop, bottom-center on mobile
/// - Auto-dismiss with configurable duration
/// - Stacking (max 3 visible at a time)
/// - Identical toasts collapse into one row with a "xN" count
/// - Click to dismiss
/// - Color-coded by severity (info=blue, success=green, warning=amber, error=red)
/// - Animated entrance/exit
class NotificationToastOverlay extends ConsumerStatefulWidget {
  const NotificationToastOverlay({super.key});

  @override
  ConsumerState<NotificationToastOverlay> createState() =>
      _NotificationToastOverlayState();
}

class _NotificationToastOverlayState
    extends ConsumerState<NotificationToastOverlay> {
  /// Group key -> its auto-dismiss timer, and the id that timer was scheduled
  /// for. Keyed on the GROUP, not on the rendered notification's id: a repeat
  /// arriving seconds later joins the group and must restart the clock, rather
  /// than leaving an older member's timer to retire the card out from under the
  /// copy the operator is reading.
  final Map<String, Timer> _dismissTimers = {};
  final Map<String, String> _timerScheduledFor = {};
  final Map<String, Timer> _exitTimers = {};
  final Set<String> _dismissingKeys = {};

  static const int _maxVisibleToasts = 3;

  /// The de-duplication key for one notification.
  ///
  /// The level is the discriminator — a warning and an error saying the same
  /// words are two different statements — and the shared
  /// [normalizeNotificationSignature] rule decides the rest.
  static String signatureFor(UiNotification n) => notificationContentSignature(
        discriminator: n.level.name,
        title: n.title ?? '',
        body: n.message,
      );

  /// Collapse notifications that say the same thing at the same severity into
  /// one group, ordered by the newest member.
  ///
  /// Deliberately keyed on what the operator can SEE (level + title + body),
  /// not on the producer: the point is that the screen never states one fact
  /// twice, whichever code path raised it.
  ///
  /// Keying on the EXACT rendered strings is not enough: one producer appends a
  /// full stop, and one character defeats the match. These toasts do not pass
  /// through the NotificationRouter either — both producers call
  /// `UiNotificationNotifier.showError` directly — so the key is normalized
  /// here, by the same shared rule the router uses.
  static List<_ToastGroup> groupIdenticalNotifications(
    List<UiNotification> notifications,
  ) {
    final byKey = <String, List<UiNotification>>{};
    final order = <String>[];
    for (final n in notifications) {
      final key = signatureFor(n);
      final bucket = byKey.putIfAbsent(key, () => <UiNotification>[]);
      bucket.add(n);
      // Re-order so a repeat lifts the group back to the bottom of the stack;
      // a condition that is still firing should not scroll away under newer,
      // quieter toasts.
      order.remove(key);
      order.add(key);
    }
    return [
      for (final key in order)
        _ToastGroup(
          key: key,
          latest: byKey[key]!.last,
          ids: [for (final n in byKey[key]!) n.id],
        ),
    ];
  }

  @override
  void dispose() {
    for (final timer in _dismissTimers.values) {
      timer.cancel();
    }
    for (final timer in _exitTimers.values) {
      timer.cancel();
    }
    _dismissTimers.clear();
    _timerScheduledFor.clear();
    _exitTimers.clear();
    _dismissingKeys.clear();
    super.dispose();
  }

  void _scheduleDismiss(_ToastGroup group) {
    if (!mounted || _dismissingKeys.contains(group.key)) return;
    // A repeat that joins the group restarts its clock. Without this the card
    // the operator is reading — raised at +4 s — is retired by the timer of the
    // copy raised at 0 s.
    if (_timerScheduledFor[group.key] == group.latest.id &&
        _dismissTimers.containsKey(group.key)) {
      return;
    }
    _dismissTimers.remove(group.key)?.cancel();
    _timerScheduledFor[group.key] = group.latest.id;

    final duration = group.latest.duration ?? const Duration(seconds: 4);
    _dismissTimers[group.key] = Timer(duration, () {
      _dismiss(group);
    });
  }

  void _dismiss(_ToastGroup group) {
    final key = group.key;
    if (!mounted || _dismissingKeys.contains(key)) return;

    _dismissTimers.remove(key)?.cancel();
    _timerScheduledFor.remove(key);

    setState(() {
      _dismissingKeys.add(key);
    });

    // Allow exit animation to complete before removing
    _exitTimers[key] = Timer(const Duration(milliseconds: 300), () {
      _exitTimers.remove(key);
      if (!mounted) return;
      final notifier = ref.read(uiNotificationProvider.notifier);
      // Retire the whole group, read from CURRENT state rather than from the
      // membership captured when the timer was set: a copy that arrived during
      // the 300 ms exit belongs to the same statement and would otherwise pop
      // straight back up as a brand-new toast.
      for (final n in ref.read(uiNotificationProvider)) {
        if (signatureFor(n) == key) notifier.dismiss(n.id);
      }
      setState(() {
        _dismissingKeys.remove(key);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final notifications = ref.watch(uiNotificationProvider);
    final groups = groupIdenticalNotifications(notifications);

    // Take only the most recent groups up to max
    final visibleGroups = groups.length > _maxVisibleToasts
        ? groups.sublist(groups.length - _maxVisibleToasts)
        : groups;

    // Schedule (or re-schedule, when a repeat joined) each visible group.
    for (final group in visibleGroups) {
      if (_timerScheduledFor[group.key] != group.latest.id) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scheduleDismiss(group);
        });
      }
    }
    // Drop timers for groups that are gone, so a long night cannot grow them.
    final liveKeys = {for (final g in groups) g.key};
    for (final key in _dismissTimers.keys.toList()) {
      if (!liveKeys.contains(key)) {
        _dismissTimers.remove(key)?.cancel();
        _timerScheduledFor.remove(key);
      }
    }

    if (visibleGroups.isEmpty) {
      return const SizedBox.shrink();
    }

    // Honours the screen's declared transient bottom inset, the same
    // declaration the SnackBar path reads: a hardcoded offset lets the one
    // toast surface that carries errors paint over a card that reserved space.
    //
    // The inset is measured from the declaring card's top edge to the bottom of
    // the WINDOW, while this overlay's `bottom` is relative to the shell's
    // content Stack, which sits above the status bar. Using the window-relative
    // number here therefore lifts slightly further than strictly required —
    // deliberately, because over-clearing is invisible and under-clearing is
    // the defect.
    return ValueListenableBuilder<double>(
      valueListenable: TransientBottomInset.currentInset,
      builder: (context, inset, _) => Positioned(
        bottom: inset > 0 ? inset + 8 : 56,
        right: 16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: visibleGroups.map((group) {
            return _NotificationToast(
              // Keyed on the GROUP, not the newest member: a repeat lifts the
              // count on the card already on screen instead of replacing it
              // with a fresh one that replays the entrance animation.
              key: ValueKey(group.key),
              notification: group.latest,
              repeatCount: group.count,
              isDismissing: _dismissingKeys.contains(group.key),
              onDismiss: () => _dismiss(group),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _NotificationToast extends StatefulWidget {
  final UiNotification notification;

  /// How many identical notifications this toast stands for (1 = just itself).
  final int repeatCount;
  final bool isDismissing;
  final VoidCallback onDismiss;

  const _NotificationToast({
    super.key,
    required this.notification,
    this.repeatCount = 1,
    required this.isDismissing,
    required this.onDismiss,
  });

  @override
  State<_NotificationToast> createState() => _NotificationToastState();
}

class _NotificationToastState extends State<_NotificationToast>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );

    _slideAnimation = Tween<double>(begin: 50.0, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _controller.forward();
  }

  @override
  void didUpdateWidget(covariant _NotificationToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isDismissing && !oldWidget.isDismissing) {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  IconData _getIcon() {
    switch (widget.notification.level) {
      case UiNotificationLevel.info:
        return LucideIcons.info;
      case UiNotificationLevel.success:
        return LucideIcons.checkCircle;
      case UiNotificationLevel.warning:
        return LucideIcons.alertTriangle;
      case UiNotificationLevel.error:
        return LucideIcons.xCircle;
    }
  }

  Color _getColor(SkotiqColors colors) {
    switch (widget.notification.level) {
      case UiNotificationLevel.info:
        return colors.info;
      case UiNotificationLevel.success:
        return colors.success;
      case UiNotificationLevel.warning:
        return colors.warning;
      case UiNotificationLevel.error:
        return colors.error;
    }
  }

  Color _getBackgroundColor(SkotiqColors colors) {
    final baseColor = _getColor(colors);
    return Color.lerp(colors.surface, baseColor, 0.15)!;
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final accentColor = _getColor(colors);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(_slideAnimation.value, 0),
          child: Opacity(
            opacity: _fadeAnimation.value,
            child: child,
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Colors.transparent,
          // The tap lived on a bare gesture wrapper, which publishes an action
          // and no role, so assistive tech read a live control as an inert
          // disabled panel. The flags are only published when given.
          child: Semantics(
              button: true,
              enabled: true,
              child: InkWell(
                onTap: widget.onDismiss,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                child: Container(
                  constraints: const BoxConstraints(
                    maxWidth: 360,
                    minWidth: 280,
                  ),
                  decoration: BoxDecoration(
                    color: _getBackgroundColor(colors),
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                    border: Border.all(
                      color: accentColor.withValues(alpha: 0.3),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Accent bar
                        Container(
                          width: 4,
                          constraints: const BoxConstraints(minHeight: 48),
                          color: accentColor,
                        ),
                        // Content
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _getIcon(),
                                  color: accentColor,
                                  size: 18,
                                ),
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (widget.notification.title !=
                                          null) ...[
                                        Text(
                                          // A repeated condition is reported
                                          // once with a count, never as N
                                          // identical stacked toasts.
                                          widget.repeatCount > 1
                                              ? '${widget.notification.title!} '
                                                  '(x${widget.repeatCount})'
                                              : widget.notification.title!,
                                          style: TextStyle(
                                            color: colors.textPrimary,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                      ],
                                      Text(
                                        widget.notification.message,
                                        style: TextStyle(
                                          color: colors.textSecondary,
                                          fontSize: 11,
                                        ),
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Dismiss button
                                MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  // The tap lived on a bare gesture wrapper, which publishes an action
                                  // and no role, so assistive tech read a live control as an inert
                                  // disabled panel. The flags are only published when given.
                                  child: Semantics(
                                      button: true,
                                      enabled: true,
                                      label: 'Dismiss',
                                      child: GestureDetector(
                                        onTap: widget.onDismiss,
                                        child: Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: Icon(
                                            LucideIcons.x,
                                            color: colors.textMuted,
                                            size: 14,
                                          ),
                                        ),
                                      )),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )),
        ),
      ),
    );
  }
}
