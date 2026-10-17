part of '../design_reference_board.dart';

void _noop() {}
void _noopBool(bool _) {}
void _noopNullableBool(bool? _) {}

class _SubLabel extends StatelessWidget {
  const _SubLabel(this.text, {required this.colors});

  final String text;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: SkotiqTypography.label.copyWith(color: colors.textSecondary),
    );
  }
}

class _GradientBar extends StatelessWidget {
  const _GradientBar({
    required this.label,
    required this.stops,
    required this.colors,
  });

  final String label;
  final List<Color> stops;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          height: 18,
          decoration: BoxDecoration(
            borderRadius: SkotiqTokens.borderRadiusSm,
            border: Border.all(color: colors.border),
            gradient: LinearGradient(colors: stops),
          ),
        ),
      ],
    );
  }
}

class _DotChip extends StatelessWidget {
  const _DotChip({
    required this.label,
    required this.color,
    required this.colors,
  });

  final String label;
  final Color color;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: SkotiqTokens.borderRadiusSm,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            label,
            style: SkotiqTypography.captionSm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _CardSpecimen extends StatelessWidget {
  const _CardSpecimen({
    required this.title,
    required this.value,
    this.variant = CardVariant.standard,
    this.isSelected = false,
  });

  final String title;
  final String value;
  final CardVariant variant;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      variant: variant,
      isSelected: isSelected,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: SkotiqTypography.overline.copyWith(
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            value,
            style: SkotiqTypography.h4.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}
