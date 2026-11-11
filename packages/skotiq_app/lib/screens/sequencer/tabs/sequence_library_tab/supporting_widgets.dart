part of '../sequence_library_tab.dart';

class _StatChip extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;

  const _StatChip({
    required this.colors,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: colors.textMuted),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }
}
