import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Connection state for a profile
enum ProfileConnectionState {
  disconnected,
  connecting,
  connected,
  error,
  partiallyConnected,

  /// Devices are connected but don't match the profile's device IDs
  mismatch,
}

/// A chip widget representing an equipment profile
class ProfileChip extends ConsumerStatefulWidget {
  final DbEquipmentProfile profile;
  final bool isSelected;
  final ProfileConnectionState connectionState;
  final int connectedDevices;
  final int totalDevices;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const ProfileChip({
    super.key,
    required this.profile,
    required this.isSelected,
    required this.connectionState,
    required this.connectedDevices,
    required this.totalDevices,
    this.onTap,
    this.onLongPress,
  });

  @override
  ConsumerState<ProfileChip> createState() => _ProfileChipState();
}

class _ProfileChipState extends ConsumerState<ProfileChip>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.connectionState == ProfileConnectionState.connecting) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(ProfileChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.connectionState == ProfileConnectionState.connecting) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final onPrimary = Theme.of(context).colorScheme.onPrimary;

    final (indicatorColor, indicatorIcon) = _getIndicatorStyle(colors);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onSecondaryTap: widget.onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? colors.surface
                : _isHovered
                    ? colors.well
                    : colors.background,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(
              color: widget.isSelected
                  ? colors.primary
                  : _isHovered
                      ? colors.primary.withValues(alpha: 0.3)
                      : colors.border,
              width: widget.isSelected ? 2 : 1,
            ),
            boxShadow: widget.isSelected
                ? [
                    BoxShadow(
                      color: colors.primary.withValues(alpha: 0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Connection indicator
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  return Transform.scale(
                    scale: widget.connectionState ==
                            ProfileConnectionState.connecting
                        ? _pulseAnimation.value
                        : 1.0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: indicatorColor,
                      ),
                      child: widget.connectionState ==
                              ProfileConnectionState.connecting
                          ? SizedBox(
                              width: 10,
                              height: 10,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    indicatorColor),
                              ),
                            )
                          : indicatorIcon != null
                              ? Icon(indicatorIcon, size: 6, color: onPrimary)
                              : null,
                    ),
                  );
                },
              ),
              const SizedBox(width: 10),

              // Profile name
              Text(
                widget.profile.name,
                style: SkotiqTypography.buttonSm.copyWith(
                  fontWeight:
                      widget.isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: widget.isSelected
                      ? colors.textPrimary
                      : colors.textSecondary,
                ),
              ),

              const SizedBox(width: 8),

              // Device count
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: _getCountBadgeDecoration(colors),
                child: Text(
                  _getDeviceCountText(),
                  style: SkotiqTypography.monoCaption.copyWith(
                    color: _getCountTextColor(colors),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  (Color, IconData?) _getIndicatorStyle(SkotiqColors colors) {
    switch (widget.connectionState) {
      case ProfileConnectionState.disconnected:
        return (colors.textMuted.withValues(alpha: 0.5), null);
      case ProfileConnectionState.connecting:
        return (colors.warning, null);
      case ProfileConnectionState.connected:
        return (colors.success, LucideIcons.check);
      case ProfileConnectionState.partiallyConnected:
        return (colors.warning, null);
      case ProfileConnectionState.error:
        return (colors.error, LucideIcons.x);
      case ProfileConnectionState.mismatch:
        return (colors.warning, LucideIcons.alertTriangle);
    }
  }

  BoxDecoration _getCountBadgeDecoration(SkotiqColors colors) {
    switch (widget.connectionState) {
      case ProfileConnectionState.connected:
        return SkotiqDecorations.statusChip(
          colors.success,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          bordered: false,
        );
      case ProfileConnectionState.partiallyConnected:
      case ProfileConnectionState.connecting:
      case ProfileConnectionState.mismatch:
        return SkotiqDecorations.statusChip(
          colors.warning,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          bordered: false,
        );
      case ProfileConnectionState.error:
        return SkotiqDecorations.statusChip(
          colors.error,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          bordered: false,
        );
      case ProfileConnectionState.disconnected:
        return BoxDecoration(
          color: colors.well,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        );
    }
  }

  Color _getCountTextColor(SkotiqColors colors) {
    switch (widget.connectionState) {
      case ProfileConnectionState.connected:
        return colors.success;
      case ProfileConnectionState.partiallyConnected:
      case ProfileConnectionState.connecting:
      case ProfileConnectionState.mismatch:
        return colors.warning;
      case ProfileConnectionState.error:
        return colors.error;
      case ProfileConnectionState.disconnected:
        return colors.textMuted;
    }
  }

  String _getDeviceCountText() {
    if (widget.connectionState == ProfileConnectionState.disconnected) {
      return '${widget.totalDevices} devices';
    }
    return '${widget.connectedDevices}/${widget.totalDevices}';
  }
}
