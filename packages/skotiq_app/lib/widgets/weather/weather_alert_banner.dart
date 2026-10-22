import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Global weather alert banner that appears at the top of the app
/// when weather conditions reach warning or critical levels.
///
/// Features:
/// - Animated entrance/exit
/// - Color-coded by severity (warning = orange, critical = red)
/// - Shows alert message and ETA if available
/// - Snooze button for temporary dismissal
/// - Tap to navigate to weather screen
class WeatherAlertBanner extends ConsumerStatefulWidget {
  const WeatherAlertBanner({super.key});

  @override
  ConsumerState<WeatherAlertBanner> createState() => _WeatherAlertBannerState();
}

class _WeatherAlertBannerState extends ConsumerState<WeatherAlertBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOut,
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final safetyState = ref.watch(weatherSafetyProvider);
    final status = safetyState.status;
    // A forecast is advisory: it is shown as a warning, never as critical.
    final alertLevel = safetyState.advisoryOnly &&
            safetyState.currentAlertLevel == AlertLevel.critical
        ? AlertLevel.warning
        : safetyState.currentAlertLevel;

    // Only show the banner for warning or critical levels while the verdict
    // is unsafe, and only while weather safety is actually monitoring: with
    // the switch off there is no verdict to raise a global alert with (the
    // Weather screen's own chip already says "Not monitored"), and a cloudy
    // forecast outweighed by frames full of stars or set aside by the
    // operator is not an alert.
    final shouldShow = safetyState.monitoringEnabled &&
        (alertLevel == AlertLevel.warning ||
            alertLevel == AlertLevel.critical) &&
        status == WeatherSafetyStatus.unsafe;

    // Animate in/out
    if (shouldShow) {
      _animationController.forward();
    } else {
      _animationController.reverse();
    }

    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        if (_animationController.isDismissed) {
          return const SizedBox.shrink();
        }

        return ClipRect(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: SlideTransition(
              position:
                  Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
                      .animate(_animationController),
              child: _BannerContent(
                colors: colors,
                alertLevel: alertLevel,
                actions: safetyState.actions,
                onSnooze: () {
                  ref.read(weatherSafetyProvider.notifier).snooze(
                        const Duration(minutes: 15),
                        reason: 'Operator snoozed the weather banner',
                      );
                },
                onTap: () => context.go('/weather'),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The actual banner content
class _BannerContent extends StatelessWidget {
  final SkotiqColors colors;
  final AlertLevel alertLevel;
  final WeatherSafetyActions actions;
  final VoidCallback onSnooze;
  final VoidCallback onTap;

  const _BannerContent({
    required this.colors,
    required this.alertLevel,
    required this.actions,
    required this.onSnooze,
    required this.onTap,
  });

  Color _getAccentColor() {
    switch (alertLevel) {
      case AlertLevel.warning:
        return colors.warning;
      case AlertLevel.critical:
        return colors.error;
      default:
        return colors.warning;
    }
  }

  IconData _getIcon() {
    switch (alertLevel) {
      case AlertLevel.warning:
        return LucideIcons.alertTriangle;
      case AlertLevel.critical:
        return LucideIcons.alertOctagon;
      default:
        return LucideIcons.cloud;
    }
  }

  String _getTitle() {
    if (actions.advisoryOnly) return 'Weather forecast';
    switch (alertLevel) {
      case AlertLevel.warning:
        return 'Weather Warning';
      case AlertLevel.critical:
        return 'Weather Critical';
      default:
        return 'Weather Alert';
    }
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = _getAccentColor();
    final icon = _getIcon();
    final title = _getTitle();
    final message = actions.reason ?? 'Adverse weather conditions detected';
    final isCritical = alertLevel == AlertLevel.critical;

    final onAccent =
        isCritical ? accentColor : Theme.of(context).colorScheme.onError;
    final titleColor = isCritical ? colors.textPrimary : onAccent;
    final messageColor =
        isCritical ? colors.textSecondary : Colors.white.withValues(alpha: 0.9);
    final chevronColor =
        isCritical ? colors.textMuted : Colors.white.withValues(alpha: 0.7);

    // The tap lived on a bare gesture wrapper, which publishes an action
    // and no role, so assistive tech read a live control as an inert
    // disabled panel. The flags are only published when given.
    return Semantics(
        button: true,
        enabled: true,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: isCritical
                ? BoxDecoration(
                    color: accentColor.withValues(alpha: 0.20),
                    border: Border(
                      top: BorderSide(color: accentColor, width: 1.8),
                      bottom: BorderSide(
                        color: accentColor.withValues(alpha: 0.7),
                      ),
                    ),
                  )
                : BoxDecoration(
                    color: accentColor,
                    boxShadow: [
                      BoxShadow(
                        color: accentColor.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: onAccent,
                ),

                const SizedBox(width: 12),

                // Title and message
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: titleColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        message,
                        style: TextStyle(
                          fontSize: 11,
                          color: messageColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 12),

                // Snooze button
                _SnoozeButton(
                  onPressed: onSnooze,
                  inverted: isCritical,
                ),

                const SizedBox(width: 8),

                // Navigate arrow
                Icon(
                  LucideIcons.chevronRight,
                  size: 18,
                  color: chevronColor,
                ),
              ],
            ),
          ),
        ));
  }
}

/// Snooze button
class _SnoozeButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool inverted;

  const _SnoozeButton({
    required this.onPressed,
    this.inverted = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final background = inverted
        ? colors.error.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.2);
    final foreground =
        inverted ? colors.textPrimary : Colors.white.withValues(alpha: 0.9);

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      // The tap lived on a bare gesture wrapper, which publishes an action
      // and no role, so assistive tech read a live control as an inert
      // disabled panel. The flags are only published when given.
      child: Semantics(
          button: true,
          enabled: true,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.bellOff,
                    size: 12,
                    color: foreground,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Snooze',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: foreground,
                    ),
                  ),
                ],
              ),
            ),
          )),
    );
  }
}
