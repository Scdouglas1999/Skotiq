import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A row of selectable chips for choosing which driver backend to use.
///
/// Shows all available backends for a device, with the recommended one
/// marked with a star icon. The selected backend is highlighted.
class BackendSelectorChips extends StatelessWidget {
  /// List of available backends for this device
  final List<DriverType> availableBackends;

  /// Currently selected backend
  final DriverType selectedBackend;

  /// The recommended backend (usually Native or best available)
  final DriverType recommendedBackend;

  /// Called when user selects a different backend
  final ValueChanged<DriverType> onBackendSelected;

  /// Whether the selector is enabled
  final bool isEnabled;

  /// Current platform for launch-time backend availability checks.
  ///
  /// Pass [Platform.operatingSystem] from UI code that can import `dart:io`.
  /// Tests may pass a normalized platform string directly.
  final String? currentPlatform;

  const BackendSelectorChips({
    super.key,
    required this.availableBackends,
    required this.selectedBackend,
    required this.recommendedBackend,
    required this.onBackendSelected,
    this.isEnabled = true,
    this.currentPlatform,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    if (availableBackends.isEmpty) {
      return const SizedBox.shrink();
    }

    // Sort backends by priority (Native first)
    final sortedBackends = List<DriverType>.from(availableBackends);
    sortedBackends
        .sort((a, b) => _backendPriority(a).compareTo(_backendPriority(b)));

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Driver:',
          style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(width: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: sortedBackends.map((backend) {
            final isSelected = backend == selectedBackend;
            final isRecommended = backend == recommendedBackend;
            final unsupportedReason =
                _unsupportedReasonFor(backend, currentPlatform);
            final backendEnabled = isEnabled && unsupportedReason == null;

            return _BackendChip(
              backend: backend,
              isSelected: isSelected,
              isRecommended: isRecommended,
              isEnabled: backendEnabled,
              unsupportedReason: unsupportedReason,
              onTap: () => onBackendSelected(backend),
            );
          }).toList(),
        ),
      ],
    );
  }

  int _backendPriority(DriverType backend) {
    switch (backend) {
      case DriverType.native:
        return 0;
      case DriverType.ascom:
        return 1;
      case DriverType.alpaca:
        return 2;
      case DriverType.indi:
        return 3;
      case DriverType.simulator:
        return 4;
    }
  }

  String? _unsupportedReasonFor(DriverType backend, String? platform) =>
      unsupportedBackendReasonFor(backend, platform);
}

class _BackendChip extends StatefulWidget {
  final DriverType backend;
  final bool isSelected;
  final bool isRecommended;
  final bool isEnabled;
  final String? unsupportedReason;
  final VoidCallback onTap;

  const _BackendChip({
    required this.backend,
    required this.isSelected,
    required this.isRecommended,
    required this.isEnabled,
    required this.unsupportedReason,
    required this.onTap,
  });

  @override
  State<_BackendChip> createState() => _BackendChipState();
}

class _BackendChipState extends State<_BackendChip> {
  bool _isHovered = false;

  Color _getBackendColor(SkotiqColors colors) {
    return BackendProtocolColors.forBackend(widget.backend, colors);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final backendColor = _getBackendColor(colors);

    final backgroundColor = widget.isSelected
        ? backendColor.withValues(alpha: 0.2)
        : _isHovered
            ? colors.surfaceHover
            : colors.well;

    final borderColor =
        widget.isSelected ? backendColor.withValues(alpha: 0.5) : colors.border;

    final textColor = widget.isSelected
        ? backendColor
        : widget.isEnabled
            ? colors.textSecondary
            : colors.textMuted;
    final unsupportedReason = widget.unsupportedReason;
    final tooltipMessage = unsupportedReason == null
        ? widget.backend.description
        : '${widget.backend.description}\nUnsupported: $unsupportedReason';

    // The ban icon and muted text refuse only to a sighted operator; this is
    // the same refusal, with its reason, reaching assistive tech. No `label`:
    // the chip's own Text supplies the name, and a second one is announced twice.
    return Semantics(
      button: true,
      enabled: widget.isEnabled,
      selected: widget.isSelected,
      hint: unsupportedReason == null
          ? widget.backend.description
          : 'Unsupported on this platform: $unsupportedReason',
      child: Tooltip(
        message: tooltipMessage,
        waitDuration: const Duration(milliseconds: 500),
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          cursor: widget.isEnabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.forbidden,
          child: GestureDetector(
            onTap: widget.isEnabled ? widget.onTap : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
                border: Border.all(color: borderColor, width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.isRecommended) ...[
                    Icon(
                      SkotiqIcons.star,
                      size: 10,
                      color: widget.isSelected ? backendColor : colors.warning,
                    ),
                    const SizedBox(width: 3),
                  ],
                  Text(
                    widget.backend.shortLabel,
                    style: SkotiqTypography.eyebrow.copyWith(
                      letterSpacing: 0,
                      fontWeight:
                          widget.isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: textColor,
                    ),
                  ),
                  if (unsupportedReason != null) ...[
                    const SizedBox(width: 3),
                    Icon(
                      LucideIcons.ban,
                      size: 10,
                      color: colors.textMuted,
                    ),
                  ],
                  if (widget.isSelected) ...[
                    const SizedBox(width: 3),
                    Icon(
                      SkotiqIcons.check,
                      size: 10,
                      color: backendColor,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
String? unsupportedBackendReasonFor(DriverType backend, String? platform) {
  if (platform == null || platform.trim().isEmpty) {
    return null;
  }
  for (final capability in PlatformCapabilityMatrix.rows) {
    if (capability.backend != backend.name) {
      continue;
    }
    if (capability.isAvailableOn(platform)) {
      return null;
    }
    return capability.reasonFor(platform);
  }
  return null;
}
