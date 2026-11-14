import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/guide_distance.dart';

/// Compact, honest "guiding active" indicator for the live-preview overlay.
///
/// A literal "registered guide box" overlay is not derivable from the data
/// available: PHD2's guide-star lock position is expressed in *guide-camera*
/// pixel coordinates ([lockPositionProvider]), which have no spatial mapping
/// onto the *main-camera* preview being displayed, so a box drawn there would
/// be fabricated. This surfaces the one thing that can be stated truthfully:
/// PHD2 is actively guiding right now, and here is its live RMS.
///
/// Visibility is deliberately strict so the chip can never claim guiding when
/// it is not:
/// * The guider must be [DeviceConnectionState.connected].
/// * PHD2 must be in [Phd2State.guiding], [Phd2State.settling] (locking on)
///   or [Phd2State.lostLock] (it *was* guiding and just dropped the star).
///
/// Any other state — stopped, looping, calibrating, paused, selected, or a
/// disconnected guider — collapses the chip to [SizedBox.shrink]. We never
/// render a stale "Guiding" pill while the rig is idle.
///
/// The RMS is [Phd2GuideStats.rmsTotal], which is in guide-camera pixels. It
/// is shown through [guideDistanceText]: in arcseconds when the guider has
/// reported the guide camera's scale, in pixels and labeled `px` otherwise.
///
/// The host widget positions this chip at the bottom-left of the preview.
class GuidingActiveChip extends ConsumerWidget {
  const GuidingActiveChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(
      guiderStateProvider.select(
        (s) => s.connectionState == DeviceConnectionState.connected,
      ),
    );
    final phd2State = ref.watch(phd2StateProvider);

    // Honest gate: only show while the guider is connected AND PHD2 is in a
    // guiding-related state. Everything else collapses to nothing.
    if (!connected || !_isVisibleState(phd2State)) {
      return const SizedBox.shrink();
    }

    final colors = SkotiqColors.of(context);
    final stats = ref.watch(guideStatsProvider);
    final scale = ref.watch(guideScaleProvider);

    final lostLock = phd2State == Phd2State.lostLock;
    final settling = phd2State == Phd2State.settling;

    // Dot semantics, matching the design system's documented motion language
    // (status_dot.dart): the slow `urgent` pulse is reserved for error/recovery
    // urgency, so a healthy, working guider must NOT use it.
    // * lost lock -> warning color, slow `urgent` pulse — needs attention.
    // * settling  -> success color, one-shot `attention` flash as it locks on.
    // * guiding    -> success color, `static` solid dot — live and steady.
    final Color dotColor = lostLock ? colors.warning : colors.success;
    final StatusDotVariant dotVariant = lostLock
        ? StatusDotVariant.urgent
        : settling
            ? StatusDotVariant.attention
            : StatusDotVariant.static;

    final label = lostLock
        ? 'Star lost'
        : settling
            ? 'Settling'
            : 'Guiding';

    final tooltip = SkotiqTooltip(
      message: lostLock
          ? 'PHD2 lost the guide star — guiding paused'
          : 'PHD2 guiding active — total RMS shown in '
              '${scale == null ? 'guide-camera pixels' : 'arcseconds'}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: SkotiqTokens.opacityStrong),
          borderRadius: SkotiqTokens.borderRadiusFull,
          border: Border.all(color: colors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceMd,
            vertical: SkotiqTokens.spaceXs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusDot(color: dotColor, variant: dotVariant),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                label,
                style: SkotiqTypography.labelSm
                    .copyWith(color: colors.textPrimary),
              ),
              // RMS / SNR only mean something while we hold the star.
              if (!lostLock) ..._telemetry(stats, scale, colors),
            ],
          ),
        ),
      ),
    );

    return tooltip;
  }

  /// Trailing RMS (and SNR when present) telemetry, in tabular mono so the
  /// digits don't jitter the pill width as values tick.
  List<Widget> _telemetry(
    Phd2GuideStats stats,
    double? scale,
    SkotiqColors colors,
  ) {
    final monoStyle = SkotiqTypography.withTabular(
      SkotiqTypography.monoSm,
    ).copyWith(color: colors.textSecondary);

    final widgets = <Widget>[
      const SizedBox(width: SkotiqTokens.spaceSm),
      Text(
        'RMS ${guideDistanceText(stats.rmsTotal, scale)}',
        style: monoStyle,
      ),
    ];

    // SNR is optional context; PHD2 reports 0.0 as its "no sample yet"
    // sentinel, so suppress it until a real value arrives rather than show a
    // misleading "SNR 0".
    if (stats.snr > 0) {
      widgets
        ..add(const SizedBox(width: SkotiqTokens.spaceSm))
        ..add(Text('SNR ${stats.snr.toStringAsFixed(0)}', style: monoStyle));
    }

    return widgets;
  }

  static bool _isVisibleState(Phd2State state) =>
      state == Phd2State.guiding ||
      state == Phd2State.settling ||
      state == Phd2State.lostLock;
}
