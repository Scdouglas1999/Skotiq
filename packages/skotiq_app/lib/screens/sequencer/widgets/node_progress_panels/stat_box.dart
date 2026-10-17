part of '../node_progress_panels.dart';

class _StatBox extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;
  final String unit;
  final Color color;

  const _StatBox({
    required this.colors,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: SkotiqDecorations.tintedBadge(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize9,
                color: colors.textMuted),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize16,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 2),
                Text(
                  unit,
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: colors.textMuted),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
