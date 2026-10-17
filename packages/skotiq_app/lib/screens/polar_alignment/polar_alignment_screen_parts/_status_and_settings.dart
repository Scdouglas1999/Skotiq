// Labelled-setting row and tip-list item used across the polar alignment side panels.
part of '../polar_alignment_screen.dart';

class _SettingRow extends StatelessWidget {
  final String label;
  final String tooltip;
  final SkotiqColors colors;
  final Widget child;

  const _SettingRow({
    required this.label,
    required this.tooltip,
    required this.colors,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: tooltip,
              waitDuration: const Duration(milliseconds: 500),
              child: Icon(
                SkotiqIcons.help,
                size: 12,
                color: colors.textMuted.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

class _TipItem extends StatelessWidget {
  final SkotiqColors colors;
  final String text;

  const _TipItem({required this.colors, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              SkotiqIcons.check,
              size: 12,
              color: colors.success,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
