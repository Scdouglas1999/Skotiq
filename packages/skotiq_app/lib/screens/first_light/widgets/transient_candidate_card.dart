import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../services/mount_command_service.dart';
import '../../../utils/snackbar_helper.dart';
import '../first_light_detail_screen.dart';
import 'cutout_strip.dart';
import 'transient_submit_dialog.dart';

/// One difference-imaging transient candidate, the heart of the First Light
/// discovery surface.
///
/// Top to bottom: the verdict header (named known source vs. the headline
/// *possible unknown transient*), the side-by-side template / frame / residual
/// [CutoutStrip], a metrics row (SNR, Δmag, FWHM, confidence, shape class), and
/// the triage / submit actions. Triage routes through [FirstLightTriage] so it
/// works identically on desktop (local DB) and mobile (NetworkBackend → host).
class TransientCandidateCard extends ConsumerWidget {
  const TransientCandidateCard({super.key, required this.detection});

  final TransientDetectionRow detection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);

    return SkotiqCard(
      variant: CardVariant.subtle,
      borderRadius: SkotiqTokens.radiusLg,
      padding: SkotiqTokens.cardPadding,
      // Tap opens the multi-night detail / light-curve view: the same source
      // seen across nights groups into one Δmag-vs-time history so the core
      // question — "is it real and changing?" — becomes answerable.
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FirstLightDetailScreen(detection: detection),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(detection: detection, colors: colors),
          const SizedBox(height: SkotiqTokens.spaceMd),
          CutoutStrip(detection: detection),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _MetricsRow(detection: detection, colors: colors),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _ActionsRow(detection: detection, ref: ref, colors: colors),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.detection, required this.colors});

  final TransientDetectionRow detection;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final isUnknown = detection.catalogMatch == null;
    final kind = TransientKind.fromWire(detection.kind);
    final verdictColor = isUnknown ? colors.accent : colors.info;
    final title =
        isUnknown ? 'Possible unknown transient' : detection.catalogMatch!;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
          decoration: SkotiqDecorations.tintedBadge(verdictColor),
          child: Icon(
            _kindIcon(kind),
            size: SkotiqTokens.iconMd,
            color: verdictColor,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: SkotiqTypography.h4.copyWith(
                  color: colors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SkotiqTokens.spaceXs),
              Row(
                children: [
                  Icon(
                    SkotiqIcons.crosshair,
                    size: SkotiqTokens.iconXs,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceXs),
                  Flexible(
                    child: Text(
                      '${CoordinateFormat.ra(detection.raDeg / 15.0)}  '
                      '${CoordinateFormat.dec(detection.decDeg)}',
                      style: SkotiqTypography.monoSm.copyWith(
                        color: colors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        _VerdictBadge(detection: detection, colors: colors),
      ],
    );
  }

  IconData _kindIcon(TransientKind kind) {
    switch (kind) {
      case TransientKind.newSource:
        return SkotiqIcons.sparkle;
      case TransientKind.pointBrightening:
        return SkotiqIcons.sun;
      case TransientKind.movingStreak:
        return LucideIcons.orbit;
      case TransientKind.dipole:
        return LucideIcons.circleDot;
      case TransientKind.unknown:
        return LucideIcons.helpCircle;
    }
  }
}

/// The triage-state / catalog-verdict badge.
class _VerdictBadge extends StatelessWidget {
  const _VerdictBadge({required this.detection, required this.colors});

  final TransientDetectionRow detection;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final (label, color) = _info();
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

  (String, Color) _info() {
    if (detection.dismissed) return ('Dismissed', colors.textMuted);
    if (detection.reviewed) return ('Confirmed', colors.success);
    if (detection.catalogMatch == null) return ('Unnamed', colors.accent);
    return ('Matched', colors.info);
  }
}

/// Compact metrics chips: SNR, Δmag, FWHM, confidence, and the shape class.
class _MetricsRow extends StatelessWidget {
  const _MetricsRow({required this.detection, required this.colors});

  final TransientDetectionRow detection;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final dm = detection.deltaMag;
    final chips = <Widget>[
      _MetricChip(
        icon: SkotiqIcons.activity,
        label: 'SNR ${detection.snr.toStringAsFixed(1)}',
        color: colors.textSecondary,
        colors: colors,
      ),
      if (dm != null && dm.isFinite)
        _MetricChip(
          icon: dm <= 0 ? LucideIcons.trendingUp : LucideIcons.trendingDown,
          // Print the real signed magnitude delta as stored (native convention:
          // negative = brighter). A brightening shows "-0.50 mag", a fading
          // "+0.50 mag" — matching how astronomers read Δmag.
          label: '${dm <= 0 ? '' : '+'}${dm.toStringAsFixed(2)} mag',
          color: dm <= 0 ? colors.accent : colors.info,
          colors: colors,
        ),
      _MetricChip(
        icon: SkotiqIcons.circle,
        label: 'FWHM ${detection.fwhm.toStringAsFixed(1)} px',
        color: colors.textSecondary,
        colors: colors,
      ),
      _MetricChip(
        icon: LucideIcons.gauge,
        label: 'Conf ${(detection.confidence * 100).round()}%',
        color: _confidenceColor(detection.confidence),
        colors: colors,
      ),
      _MetricChip(
        icon: LucideIcons.shapes,
        label: _kindLabel(TransientKind.fromWire(detection.kind)),
        color: colors.textSecondary,
        colors: colors,
      ),
    ];

    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      children: chips,
    );
  }

  Color _confidenceColor(double c) {
    if (c >= 0.7) return colors.success;
    if (c >= 0.45) return colors.warning;
    return colors.textMuted;
  }

  String _kindLabel(TransientKind kind) {
    switch (kind) {
      case TransientKind.newSource:
        return 'New source';
      case TransientKind.pointBrightening:
        return 'Brightening';
      case TransientKind.movingStreak:
        return 'Moving streak';
      case TransientKind.dipole:
        return 'Dipole';
      case TransientKind.unknown:
        return 'Unclassified';
    }
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.colors,
  });

  final IconData icon;
  final String label;
  final Color color;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: SkotiqTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: SkotiqTokens.borderRadiusSm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: SkotiqTokens.iconXs, color: color),
          const SizedBox(width: SkotiqTokens.spaceXs),
          Text(
            label,
            style: SkotiqTypography.labelSm.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _ActionsRow extends StatelessWidget {
  const _ActionsRow({
    required this.detection,
    required this.ref,
    required this.colors,
  });

  final TransientDetectionRow detection;
  final WidgetRef ref;
  final SkotiqColors colors;

  Future<void> _triage(BuildContext context, {required bool dismiss}) async {
    final triage = ref.read(firstLightTriageProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (dismiss) {
        await triage.dismiss(detection.id);
      } else {
        await triage.review(detection.id);
      }
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            dismiss
                ? 'Dismissed as an artefact — it will not resurface.'
                : 'Marked as confirmed.',
          ),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not update detection: $e')),
      );
    }
  }

  bool _runBlocksChase(BuildContext context) {
    // A run that owns the mount is never interrupted from here: the slew would
    // pull the scope off the run's target in the middle of its exposures.
    final runState = ref.read(sequenceExecutionStateProvider);
    if (runState.ownsHardware) {
      final target = ref.read(sequenceProgressProvider).currentTarget?.trim();
      final runLabel = target == null || target.isEmpty
          ? 'A sequence is running'
          : 'A sequence is running on $target';
      context.showWarningSnackBar(
        '$runLabel. Chase is unavailable until the run ends or is stopped, '
        'because the slew would move the mount away from it.',
      );
      return true;
    }
    return false;
  }

  /// Slew the mount to the candidate so the user can grab confirmation frames
  /// before it fades — the "Re-image to confirm" loop the Narrator copy promises.
  /// Routes through [mountCommandServiceProvider], which is backend-routed: on a
  /// companion tablet (slave) the slew is forwarded to the imaging host. Refused
  /// while a sequence owns the mount; otherwise confirms first because moving the
  /// mount is consequential.
  Future<void> _chase(BuildContext context) async {
    if (_runBlocksChase(context)) return;

    final mount = ref.read(mountCommandServiceProvider);
    if (!mount.isConnected) {
      context.showWarningSnackBar(
        'No mount connected — connect a mount to chase.',
      );
      return;
    }

    final coords = '${CoordinateFormat.ra(detection.raDeg / 15.0)}  '
        '${CoordinateFormat.dec(detection.decDeg)}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => SkotiqDialog(
        title: 'Chase this candidate?',
        icon: SkotiqIcons.crosshair,
        width: 420,
        actions: [
          SkotiqButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            label: 'Cancel',
            variant: ButtonVariant.outline,
            size: ButtonSize.small,
          ),
          SkotiqButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            label: 'Slew',
            icon: SkotiqIcons.crosshair,
            size: ButtonSize.small,
          ),
        ],
        child: Text(
          'Slew the mount to $coords to re-image and confirm it before it '
          'fades. This interrupts the current pointing.',
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;
    if (_runBlocksChase(context)) return;

    // RA stored in degrees on the row; slewTo expects hours.
    final result = await mount.slewTo(
      detection.raDeg / 15.0,
      detection.decDeg,
    );
    if (!context.mounted) return;
    context.showCommandActionResult(result);
  }

  @override
  Widget build(BuildContext context) {
    // A low-confidence artefact / unreviewed candidate must not one-tap a TNS
    // "possible SN" false alarm. Submit is enabled only for a reviewed
    // detection whose class is one the pipeline actually reports as a
    // transient; otherwise it is disabled and says which of the two blockers
    // applies. The refusal quotes the class's own reason, so an unrecognised
    // token is never described to the user as a measured dipole.
    final kind = TransientKind.fromWire(detection.kind);
    final kindBlocker = kind.submissionBlockedReason;
    final canSubmit = detection.reviewed && kindBlocker == null;

    final primary = Row(
      children: [
        Expanded(
          child: SkotiqButton(
            label: 'Submit',
            icon: SkotiqIcons.upload,
            size: ButtonSize.small,
            variant: ButtonVariant.primary,
            onPressed: canSubmit
                ? () => TransientSubmitDialog.show(context, detection)
                : () {
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      SnackBar(
                        content: Text(
                          kindBlocker ??
                              'Not yet confirmed — mark this detection as '
                                  'confirmed before submitting.',
                        ),
                      ),
                    );
                  },
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: detection.reviewed
              ? _ConfirmedPill(colors: colors)
              : SkotiqButton(
                  label: 'Confirm',
                  icon: SkotiqIcons.check,
                  size: ButtonSize.small,
                  variant: ButtonVariant.outline,
                  onPressed: () => _triage(context, dismiss: false),
                ),
        ),
      ],
    );

    final dismissAction = ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: SkotiqTokens.minTouchTarget,
        minHeight: SkotiqTokens.minTouchTarget,
      ),
      child: IconButton(
        icon: Icon(
          SkotiqIcons.close,
          size: SkotiqTokens.iconMd,
          color: detection.dismissed ? colors.textMuted : colors.textSecondary,
        ),
        tooltip: detection.dismissed ? 'Already dismissed' : 'Dismiss artefact',
        onPressed:
            detection.dismissed ? null : () => _triage(context, dismiss: true),
        style: IconButton.styleFrom(
          backgroundColor: colors.surfaceAlt,
          shape: RoundedRectangleBorder(
            borderRadius: SkotiqTokens.borderRadiusSm,
          ),
        ),
      ),
    );

    // "Chase" closes the discovery loop: slew there now and re-image before the
    // candidate fades, instead of hand-copying sexagesimal coords in the dark.
    final chaseAction = SkotiqButton(
      label: 'Chase',
      icon: SkotiqIcons.crosshair,
      size: ButtonSize.small,
      variant: ButtonVariant.outline,
      onPressed: () => _chase(context),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < SkotiqTokens.breakpointMobile) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              primary,
              const SizedBox(height: SkotiqTokens.spaceSm),
              Row(
                children: [
                  Expanded(child: chaseAction),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  dismissAction,
                ],
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: primary),
            const SizedBox(width: SkotiqTokens.spaceSm),
            chaseAction,
            const SizedBox(width: SkotiqTokens.spaceSm),
            dismissAction,
          ],
        );
      },
    );
  }
}

class _ConfirmedPill extends StatelessWidget {
  const _ConfirmedPill({required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: SkotiqDecorations.tintedBadge(
        colors.success,
        borderRadius: SkotiqTokens.borderRadiusSm,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            SkotiqIcons.check,
            size: SkotiqTokens.iconSm,
            color: colors.success,
          ),
          const SizedBox(width: SkotiqTokens.spaceXs),
          Text(
            'Confirmed',
            style: SkotiqTypography.labelSm.copyWith(color: colors.success),
          ),
        ],
      ),
    );
  }
}
