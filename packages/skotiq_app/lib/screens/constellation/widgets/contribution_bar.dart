import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../constellation_format.dart';

/// A slim two-tone bar showing the local imaging depth you could still add to a
/// shared target: your local depth filled in the accent against the swarm's
/// fused total, with a `2.1h available to contribute` caption beneath. This is
/// what you hold locally — not an already-donated share (contributing is a
/// separate, explicit step).
///
/// Pure presentation — the seconds are resolved by the caller's provider.
class ContributionBar extends StatelessWidget {
  final double yourSeconds;
  final double swarmSeconds;

  const ContributionBar({
    super.key,
    required this.yourSeconds,
    required this.swarmSeconds,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final fraction = yourContributionFraction(
      yourSeconds: yourSeconds,
      swarmSeconds: swarmSeconds,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Your local depth',
              style: SkotiqTypography.labelSm.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              formatYourContribution(
                yourSeconds: yourSeconds,
                swarmSeconds: swarmSeconds,
              ),
              style: SkotiqTypography.labelSm.copyWith(
                color: yourSeconds > 0 ? colors.accent : colors.textMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        ClipRRect(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusFull),
          child: SizedBox(
            height: 6,
            child: Stack(
              children: [
                Container(color: colors.well),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fraction == 0 ? 0.0 : fraction.clamp(0.04, 1.0),
                  child: Container(color: colors.accent),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
