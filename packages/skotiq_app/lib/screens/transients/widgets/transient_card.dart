import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/transient_type_style.dart';

/// Card widget displaying a transient alert with its details and actions.
///
/// Shows:
/// - Type icon and alert name
/// - Coordinates (RA/Dec)
/// - Magnitude and brightness indicator
/// - Discovery info (source, time)
/// - State badge (New, Queued, Observed, Dismissed)
/// - Action buttons (Queue, View in Framing, Dismiss)
class TransientCard extends StatefulWidget {
  final TransientAlert alert;
  final TransientAlertState? state;
  final Future<void> Function() onQueue;
  final VoidCallback onPlan;
  final VoidCallback onViewInFraming;
  final VoidCallback onOpenScience;
  final VoidCallback onDismiss;

  const TransientCard({
    super.key,
    required this.alert,
    required this.state,
    required this.onQueue,
    required this.onPlan,
    required this.onViewInFraming,
    required this.onOpenScience,
    required this.onDismiss,
  });

  @override
  State<TransientCard> createState() => _TransientCardState();
}

class _TransientCardState extends State<TransientCard> {
  bool _isExpanded = false;
  bool _isQueueing = false;

  Future<void> _queue() async {
    if (_isQueueing) return;
    setState(() => _isQueueing = true);
    try {
      await widget.onQueue();
    } finally {
      if (mounted) setState(() => _isQueueing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final effectiveState = widget.state ?? TransientAlertState.newAlert;

    return SkotiqCard(
      variant: CardVariant.subtle,
      borderRadius: SkotiqTokens.radiusLg,
      padding: SkotiqTokens.cardPadding,
      onTap: () => setState(() => _isExpanded = !_isExpanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(colors, effectiveState),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _buildInfoRow(colors),
          if (_isExpanded) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            _buildExpandedDetails(colors),
          ],
          const SizedBox(height: SkotiqTokens.spaceMd),
          _buildActionsRow(colors, effectiveState),
        ],
      ),
    );
  }

  Widget _buildHeader(SkotiqColors colors, TransientAlertState effectiveState) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Type icon
        Container(
          padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
          decoration: SkotiqDecorations.tintedBadge(
            TransientTypeStyle.color(widget.alert.type, colors),
          ),
          child: Icon(
            TransientTypeStyle.icon(widget.alert.type),
            size: SkotiqTokens.iconMd,
            color: TransientTypeStyle.color(widget.alert.type, colors),
          ),
        ),

        const SizedBox(width: SkotiqTokens.spaceMd),

        // Name and type
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.alert.name,
                style: SkotiqTypography.h4.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: SkotiqTokens.spaceXs),
              // One wrapping paragraph, not a Row of unconstrained Texts,
              // which clips whatever runs past the card's width — most of it on
              // a phone. A First Light detection has no apparent magnitude, so
              // its measured brightness CHANGE ("Δ2.35 mag brighter than
              // template") rides in the classification.
              Text.rich(
                TextSpan(
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                  children: [
                    TextSpan(text: TransientTypeStyle.label(widget.alert.type)),
                    if (widget.alert.classification != null)
                      TextSpan(
                        text: ' - ${widget.alert.classification}',
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textMuted),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // State badge
        _StateBadge(state: effectiveState, colors: colors),
      ],
    );
  }

  Widget _buildInfoRow(SkotiqColors colors) {
    return Row(
      children: [
        // Coordinates
        Expanded(
          child: Row(
            children: [
              Icon(
                SkotiqIcons.crosshair,
                size: SkotiqTokens.iconXs,
                color: colors.textMuted,
              ),
              const SizedBox(width: SkotiqTokens.spaceXs),
              Flexible(
                child: Text(
                  '${CoordinateFormat.ra(widget.alert.raHours, seconds: SecondsPrecision.integerFloored)}  '
                  '${CoordinateFormat.dec(widget.alert.decDegrees, seconds: SecondsPrecision.integerFloored)}',
                  style: SkotiqTypography.monoSm
                      .copyWith(color: colors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),

        // Magnitude
        if (widget.alert.magnitude != null) ...[
          const SizedBox(width: SkotiqTokens.spaceMd),
          _MagnitudeIndicator(
            magnitude: widget.alert.magnitude!,
            colors: colors,
          ),
        ],
      ],
    );
  }

  Widget _buildExpandedDetails(SkotiqColors colors) {
    return Container(
      padding: SkotiqTokens.paddingMd,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: SkotiqTokens.borderRadiusMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Discovery info
          _DetailRow(
            icon: SkotiqIcons.search,
            label: 'Source',
            value: _getSourceLabel(widget.alert.source),
            colors: colors,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _DetailRow(
            icon: SkotiqIcons.clock,
            label: 'Discovered',
            value: _formatDateTime(widget.alert.discoveryTime),
            colors: colors,
          ),
          if (widget.alert.peakMagnitude != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            _DetailRow(
              icon: LucideIcons.trendingUp,
              label: 'Peak magnitude',
              value: 'mag ${widget.alert.peakMagnitude!.toStringAsFixed(1)}',
              colors: colors,
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceSm),
          _DetailRow(
            icon: SkotiqIcons.refresh,
            label: 'Last updated',
            value: _formatDateTime(widget.alert.lastUpdated),
            colors: colors,
          ),
          if (widget.alert.notes != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            _DetailRow(
              icon: SkotiqIcons.file,
              label: 'Notes',
              value: widget.alert.notes!,
              colors: colors,
              isMultiLine: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionsRow(
      SkotiqColors colors, TransientAlertState effectiveState) {
    final isQueued = effectiveState == TransientAlertState.queued;
    final isDismissed = effectiveState == TransientAlertState.dismissed;
    final isObserved = effectiveState == TransientAlertState.observed;

    final primaryButtons = Row(
      children: [
        Expanded(child: _buildPrimaryAction(colors, isQueued, isObserved)),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: SkotiqButton(
            label: 'Framing',
            icon: SkotiqIcons.frame,
            size: ButtonSize.small,
            variant: ButtonVariant.outline,
            onPressed: widget.onViewInFraming,
          ),
        ),
      ],
    );

    final iconActions = [
      _iconAction(
        icon: SkotiqIcons.science,
        color: colors.info,
        background: colors.surfaceAlt,
        tooltip: 'Open Science tab',
        onPressed: widget.onOpenScience,
      ),
      if (!isDismissed && !isObserved) ...[
        const SizedBox(width: SkotiqTokens.spaceSm),
        _iconAction(
          icon: SkotiqIcons.close,
          color: colors.textMuted,
          background: colors.surfaceAlt,
          tooltip: 'Dismiss',
          onPressed: widget.onDismiss,
        ),
      ],
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < SkotiqTokens.breakpointMobile) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              primaryButtons,
              const SizedBox(height: SkotiqTokens.spaceSm),
              Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: iconActions),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: primaryButtons),
            const SizedBox(width: SkotiqTokens.spaceSm),
            ...iconActions,
          ],
        );
      },
    );
  }

  Widget _buildPrimaryAction(
    SkotiqColors colors,
    bool isQueued,
    bool isObserved,
  ) {
    if (isQueued) {
      // Queuing only adds the target to the library; this deep-links to the
      // scheduler so the user can actually place it on tonight's plan.
      return SkotiqButton(
        label: 'Plan it',
        icon: SkotiqIcons.calendar,
        size: ButtonSize.small,
        variant: ButtonVariant.outline,
        onPressed: widget.onPlan,
      );
    }
    if (isObserved) {
      return _statusBadge(
        colors.success,
        SkotiqIcons.check,
        'Observed',
      );
    }
    return SkotiqButton(
      label: 'Queue',
      icon: SkotiqIcons.add,
      size: ButtonSize.small,
      variant: ButtonVariant.primary,
      isLoading: _isQueueing,
      onPressed: _isQueueing ? null : _queue,
    );
  }

  Widget _statusBadge(Color color, IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: SkotiqDecorations.tintedBadge(
        color,
        borderRadius: SkotiqTokens.borderRadiusSm,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: SkotiqTokens.iconSm, color: color),
          const SizedBox(width: SkotiqTokens.spaceXs),
          Text(label, style: SkotiqTypography.labelSm.copyWith(color: color)),
        ],
      ),
    );
  }

  Widget _iconAction({
    required IconData icon,
    required Color color,
    required Color background,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: SkotiqTokens.minTouchTarget,
        minHeight: SkotiqTokens.minTouchTarget,
      ),
      child: IconButton(
        icon: Icon(icon, size: SkotiqTokens.iconMd, color: color),
        onPressed: onPressed,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          backgroundColor: background,
          shape: RoundedRectangleBorder(
            borderRadius: SkotiqTokens.borderRadiusSm,
          ),
        ),
      ),
    );
  }

  String _getSourceLabel(TransientSource source) {
    switch (source) {
      case TransientSource.aavso:
        return 'AAVSO';
      case TransientSource.tns:
        return 'Transient Name Server';
      case TransientSource.mpec:
        return 'Minor Planet Electronic Circulars';
      case TransientSource.cbat:
        return 'Central Bureau for Astronomical Telegrams';
      case TransientSource.manual:
        return 'Manual Entry';
    }
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inDays > 7) {
      return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
    } else if (diff.inDays > 0) {
      return '${diff.inDays}d ago';
    } else if (diff.inHours > 0) {
      return '${diff.inHours}h ago';
    } else if (diff.inMinutes > 0) {
      return '${diff.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }
}

/// Badge showing the current state of the alert.
class _StateBadge extends StatelessWidget {
  final TransientAlertState state;
  final SkotiqColors colors;

  const _StateBadge({
    required this.state,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final (label, color) = _getStateInfo();

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: SkotiqTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: SkotiqTokens.borderRadiusFull,
      ),
      child: Text(
        label,
        style: SkotiqTypography.labelStrongSm.copyWith(color: color),
      ),
    );
  }

  (String, Color) _getStateInfo() {
    switch (state) {
      case TransientAlertState.newAlert:
        return ('New', colors.info);
      case TransientAlertState.acknowledged:
        return ('Seen', colors.textSecondary);
      case TransientAlertState.queued:
        return ('Queued', colors.warning);
      case TransientAlertState.observed:
        return ('Observed', colors.success);
      case TransientAlertState.dismissed:
        return ('Dismissed', colors.textMuted);
    }
  }
}

/// Magnitude indicator with brightness color coding.
class _MagnitudeIndicator extends StatelessWidget {
  final double magnitude;
  final SkotiqColors colors;

  const _MagnitudeIndicator({
    required this.magnitude,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final (label, color) = _getBrightnessInfo();

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: SkotiqTokens.spaceXs,
      ),
      decoration: SkotiqDecorations.emphasisSurface(
        color,
        borderRadius: SkotiqTokens.borderRadiusSm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            SkotiqIcons.sun,
            size: SkotiqTokens.iconXs,
            color: color,
          ),
          const SizedBox(width: SkotiqTokens.spaceXs),
          Text(
            'mag ${magnitude.toStringAsFixed(1)}',
            style: SkotiqTypography.labelStrongSm.copyWith(color: color),
          ),
          const SizedBox(width: SkotiqTokens.spaceXs),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceXs,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: SkotiqTokens.borderRadiusXs,
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize9,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  (String, Color) _getBrightnessInfo() {
    if (magnitude <= 6.0) {
      return ('NAKED EYE', colors.success);
    } else if (magnitude <= 10.0) {
      return ('BINOCULAR', colors.info);
    } else if (magnitude <= 14.0) {
      return ('SMALL SCOPE', colors.warning);
    } else {
      return ('FAINT', colors.textMuted);
    }
  }
}

/// Row for displaying a detail item in the expanded view.
class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final SkotiqColors colors;
  final bool isMultiLine;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.colors,
    this.isMultiLine = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isMultiLine) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: SkotiqTokens.iconXs, color: colors.textMuted),
              const SizedBox(width: SkotiqTokens.spaceXs),
              Text(
                label,
                style: SkotiqTypography.captionSm
                    .copyWith(color: colors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Padding(
            padding: const EdgeInsets.only(left: SkotiqTokens.spaceLg),
            child: Text(
              value,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Icon(icon, size: SkotiqTokens.iconXs, color: colors.textMuted),
        const SizedBox(width: SkotiqTokens.spaceXs),
        Text(
          '$label: ',
          style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
        ),
        Expanded(
          child: Text(
            value,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textSecondary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
