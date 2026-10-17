part of '../settings_widgets.dart';

class SettingsCompactSlider extends StatelessWidget {
  final double value;

  final double min;

  final double max;

  final int divisions;

  final String label;

  final ValueChanged<double> onChanged;

  final bool isMobile;

  const SettingsCompactSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
    this.isMobile = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final sliderWidth = isMobile ? 100.0 : 120.0;

    final labelWidth = isMobile ? 45.0 : 50.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: sliderWidth,
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        SizedBox(
          width: labelWidth,
          child: Text(
            label,
            style: (isMobile
                    ? SkotiqTypography.captionSm
                    : SkotiqTypography.caption)
                .copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}

/// Toggle widget for object type filters in annotation settings.

class ObjectTypeToggle extends StatelessWidget {
  final String title;

  final IconData icon;

  final Color color;

  final bool isEnabled;

  final ValueChanged<bool> onChanged;

  final bool isLast;

  final bool isMobile;

  const ObjectTypeToggle({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.isEnabled,
    required this.onChanged,
    this.isLast = false,
    this.isMobile = false,
  });

  @override
  Widget build(BuildContext context) {
    return SettingRow(
      icon: icon,
      iconColor: color,
      title: title,
      subtitle: isEnabled ? 'Visible' : 'Hidden',
      trailing: SettingsSwitch(
        value: isEnabled,
        onChanged: onChanged,
      ),
      isLast: isLast,
      isMobile: isMobile,
    );
  }
}
