import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/transient_type_style.dart';

/// A badge widget that displays the count of unacknowledged transient alerts.
class TransientAlertBadge extends ConsumerStatefulWidget {
  /// Callback when the badge is tapped (if [showDropdown] is false)
  final VoidCallback? onTap;

  /// Whether to show a dropdown menu on tap instead of calling [onTap]
  final bool showDropdown;

  const TransientAlertBadge({
    super.key,
    this.onTap,
    this.showDropdown = false,
  });

  @override
  ConsumerState<TransientAlertBadge> createState() =>
      _TransientAlertBadgeState();
}

class _TransientAlertBadgeState extends ConsumerState<TransientAlertBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  int _previousCount = 0;
  Timer? _pulseStopTimer;

  @visibleForTesting
  AnimationController get debugPulseControllerForTesting => _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _pulseAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.2)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.2, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 50,
      ),
    ]).animate(_pulseController);
  }

  @override
  void dispose() {
    _pulseStopTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  void _handleCountChange(int newCount) {
    if (newCount > _previousCount && newCount > 0) {
      _pulseController.repeat(
        reverse: false,
        period: const Duration(milliseconds: 1200),
      );

      // Stop after 3 pulses (3.6 seconds)
      _pulseStopTimer?.cancel();
      _pulseStopTimer = Timer(const Duration(milliseconds: 3600), () {
        if (mounted && _pulseController.isAnimating) {
          _pulseController.stop();
          _pulseController.reset();
        }
      });
    }
    _previousCount = newCount;
  }

  void _showDropdownMenu(BuildContext context) {
    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final Offset offset = renderBox.localToGlobal(Offset.zero);
    final Size size = renderBox.size;

    // DELIBERATELY not [menuPositionBelowWidget], unlike every other showMenu
    // call site in the app.
    //
    // Those need it because their menus open inside the nested `Navigator`
    // go_router's `ShellRoute` hands `AppShell`, whose overlay starts at the
    // shell's content edge — so a global coordinate passed straight through
    // counts that origin twice. THIS badge is built by `TitleBar`, which sits
    // in the shell `Column` ABOVE that `Navigator`. `showMenu` therefore
    // resolves the ROOT navigator, whose overlay is the whole window at
    // (0, 0), and global coordinates already ARE overlay-local here.
    //
    // Left as it is because switching is not free: the insets below are not
    // the ones [menuPositionBelowWidget] computes (`right` is
    // `offset.dx + size.width`, not the distance from the window's right
    // edge), so the helper would change which side the menu aligns to. There
    // is no live defect to justify that in the title bar.
    //
    // The assumption this depends on: the badge stays outside the ShellRoute
    // navigator. Move it under the shell's routed content and the menu will
    // start opening a rail-width away — switch to [menuPositionBelowWidget]
    // then.
    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx,
        offset.dy + size.height,
        offset.dx + size.width,
        0,
      ),
      items: [
        PopupMenuItem<void>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: _TransientAlertDropdownContent(
            onViewAll: () {
              Navigator.of(context).pop();
              widget.onTap?.call();
            },
          ),
        ),
      ],
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final alertsAsync = ref.watch(activeTransientAlertsProvider);
    final unacknowledgedCount = ref.watch(unacknowledgedAlertCountProvider);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleCountChange(unacknowledgedCount);
    });

    // A bell in the window chrome promises the app's notification centre. This
    // is a transient-alert feed — supernovae and other targets of opportunity —
    // and it read "No active alerts" while the Equipment screen was showing an
    // unresolved device-health issue. Same glyph as the popup it opens, and a
    // name that says which alerts it means.
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: 'Transient alerts: targets of opportunity',
        child: Semantics(
          button: true,
          // Without an enabled state a button node reads as disabled to
          // assistive tech (Linux reported "Transient alerts [DISABLED]").
          enabled: true,
          label: unacknowledgedCount > 0
              ? 'Transient alerts, $unacknowledgedCount new'
              : 'Transient alerts',
          child: InkWell(
            onTap: () {
              if (widget.showDropdown) {
                _showDropdownMenu(context);
              } else {
                widget.onTap?.call();
              }
            },
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  alertsAsync.when(
                    data: (_) => Icon(
                      LucideIcons.radio,
                      size: 20,
                      color: colors.textSecondary,
                    ),
                    loading: () => _LoadingIcon(colors: colors),
                    error: (_, __) => _ErrorIcon(colors: colors),
                  ),
                  if (unacknowledgedCount > 0)
                    Positioned(
                      right: -6,
                      top: -6,
                      child: AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (context, child) {
                          return Transform.scale(
                            scale: _pulseAnimation.value,
                            child: child,
                          );
                        },
                        child: _CountBadge(
                          count: unacknowledgedCount,
                          colors: colors,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingIcon extends StatelessWidget {
  final SkotiqColors colors;

  const _LoadingIcon({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Icon(
          LucideIcons.radio,
          size: 20,
          color: colors.textMuted,
        ),
        Positioned(
          right: 0,
          top: 0,
          child: SizedBox(
            width: 8,
            height: 8,
            child: SkotiqSpinner(size: 8, color: colors.textMuted),
          ),
        ),
      ],
    );
  }
}

class _ErrorIcon extends StatelessWidget {
  final SkotiqColors colors;

  const _ErrorIcon({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Icon(
          LucideIcons.radio,
          size: 20,
          color: colors.textSecondary,
        ),
        Positioned(
          right: -2,
          top: -2,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: colors.warning,
              shape: BoxShape.circle,
              border: Border.all(
                color: colors.surface,
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int count;
  final SkotiqColors colors;

  const _CountBadge({
    required this.count,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final displayText = count > 9 ? '9+' : count.toString();
    final onError = Theme.of(context).colorScheme.onError;

    return Container(
      constraints: const BoxConstraints(
        minWidth: 16,
        minHeight: 16,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: colors.error,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(
          color: colors.surface,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.error.withValues(alpha: 0.4),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Center(
        child: Text(
          displayText,
          style: TextStyle(
            color: onError,
            fontSize: SkotiqTypography.fontSize10,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _TransientAlertDropdownContent extends ConsumerWidget {
  final VoidCallback onViewAll;

  static const double _width = 340;

  const _TransientAlertDropdownContent({
    required this.onViewAll,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final alertsAsync = ref.watch(activeTransientAlertsProvider);
    final states = ref.watch(transientAlertStatesProvider);
    final dropdownConstraints = AdaptiveDialogConstraints.hybrid(
      context,
      designMaxWidth: _width,
      designMaxHeight: 440,
    );
    final newCount = ref.watch(unacknowledgedAlertCountProvider);

    return Container(
      width: dropdownConstraints.maxWidth,
      constraints: BoxConstraints(maxHeight: dropdownConstraints.maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SkotiqTokens.spaceLg,
              SkotiqTokens.spaceMd,
              SkotiqTokens.spaceLg,
              SkotiqTokens.spaceMd,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(
                    'Transient alerts',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.sectionTitle.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                if (newCount > 0) ...[
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Text(
                    '$newCount new',
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: colors.border),
          alertsAsync.when(
            data: (alerts) => _buildAlertList(context, alerts, states, colors),
            loading: () => _buildLoadingState(colors),
            error: (error, _) => _buildErrorState(error, colors),
          ),
          Divider(height: 1, color: colors.border),
          Padding(
            padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
            child: Center(
              child: SkotiqButton(
                label: 'View all alerts',
                icon: SkotiqIcons.arrowRight,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: onViewAll,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlertList(
    BuildContext context,
    List<TransientAlert> alerts,
    Map<String, TransientAlertState> states,
    SkotiqColors colors,
  ) {
    if (alerts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Icon(
              LucideIcons.bellOff,
              size: 32,
              color: colors.textMuted,
            ),
            const SizedBox(height: 8),
            Text(
              'No active alerts',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.textMuted,
              ),
            ),
          ],
        ),
      );
    }

    final displayedAlerts = alerts.take(5).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: displayedAlerts.map((alert) {
        // Resolve through the alert's own state, not the overrides map alone.
        // That map only ever holds the queue/dismiss actions taken on THIS
        // surface, so reading it bare re-badged a First Light detection the
        // user had already confirmed as "new" here.
        final isNew = resolveTransientAlertState(alert, states) ==
            TransientAlertState.newAlert;

        return _AlertListItem(
          alert: alert,
          isNew: isNew,
          colors: colors,
        );
      }).toList(),
    );
  }

  Widget _buildLoadingState(SkotiqColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 24),
          ),
          const SizedBox(height: 8),
          Text(
            'Loading alerts...',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(Object error, SkotiqColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        children: [
          Icon(
            LucideIcons.alertTriangle,
            size: 24,
            color: colors.warning,
          ),
          const SizedBox(height: 8),
          Text(
            'Failed to load alerts',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              fontWeight: FontWeight.w500,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            userFacingError(error),
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textMuted,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _AlertListItem extends StatelessWidget {
  final TransientAlert alert;
  final bool isNew;
  final SkotiqColors colors;

  const _AlertListItem({
    required this.alert,
    required this.isNew,
    required this.colors,
  });

  static const double _markerSize = 6;

  @override
  Widget build(BuildContext context) {
    final typeColor = TransientTypeStyle.color(alert.type, colors);
    final typeLabel = TransientTypeStyle.label(alert.type);
    final magnitude = alert.magnitude == null
        ? null
        : 'mag ${alert.magnitude!.toStringAsFixed(1)}';
    final facts = [typeLabel, if (magnitude != null) magnitude].join(' · ');
    final factStyle = SkotiqTypography.bodySm.copyWith(
      color: colors.textSecondary,
    );
    return Semantics(
      container: true,
      label: '${isNew ? 'New: ' : ''}${alert.name}, $facts',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceLg,
          vertical: SkotiqTokens.spaceSm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                TransientTypeStyle.icon(alert.type),
                size: SkotiqTokens.iconXs,
                color: typeColor,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alert.name,
                    style: SkotiqTypography.bodyStrong.copyWith(
                      color: colors.textPrimary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // The type is its own text so every alert surface names
                  // it with the same words.
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          typeLabel,
                          style: factStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (magnitude != null)
                        Flexible(
                          child: Text(
                            ' · $magnitude',
                            style: factStyle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (isNew) ...[
              const SizedBox(width: SkotiqTokens.spaceSm),
              Padding(
                padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
                child: Container(
                  width: _markerSize,
                  height: _markerSize,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
