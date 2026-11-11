part of '../settings_widgets.dart';

/// A slider for a [SettingRow]'s trailing slot, with the value beside it.
///
/// The thumb and the value follow the drag at once. The write is held until
/// the drag pauses or ends, so a sweep across the track is one write rather
/// than one per step. A failed write puts the thumb back and says so.
class SettingsCompactSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int divisions;

  /// What to show beside the slider for a value (unit included).
  final String Function(double value) format;

  /// May be asynchronous; a failure restores the stored value.
  final FutureOr<void> Function(double value) onChanged;

  /// Overrides the enclosing [SettingsFormScope].
  final bool? isMobile;

  const SettingsCompactSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChanged,
    this.isMobile,
  });

  static const Duration writeDelay = Duration(milliseconds: 250);

  @override
  State<SettingsCompactSlider> createState() => _SettingsCompactSliderState();
}

class _SettingsCompactSliderState extends State<SettingsCompactSlider> {
  final SettingsNoticeController _notice = SettingsNoticeController();
  late double _value = widget.value;
  late final SettingWriter<double> _writer = SettingWriter<double>(
    initial: widget.value,
    onRollback: _onRollback,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant SettingsCompactSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final show = _writer.accept(
      widget.value,
      authority: SettingsFormScope.authorityOf(context),
    );
    if (show) _value = widget.value;
  }

  void _onRollback(double restored, double attempted, Object error) {
    if (!mounted) return;
    setState(() => _value = restored);
    settingsReportRollback(context, _notice, error);
  }

  void _move(double value, {required bool ended}) {
    _notice.clear();
    setState(() => _value = value);
    _writer.submit(
      value,
      widget.onChanged,
      debounce: ended ? Duration.zero : SettingsCompactSlider.writeDelay,
    );
  }

  @override
  void dispose() {
    _writer.close();
    _notice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isMobile = widget.isMobile ?? SettingsFormScope.isMobileOf(context);
    final sliderWidth = isMobile ? 100.0 : 120.0;
    final labelWidth = isMobile ? 45.0 : 50.0;
    final shown = _value.clamp(widget.min, widget.max).toDouble();

    return SettingsFieldNotice(
      controller: _notice,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: sliderWidth,
            child: Slider(
              value: shown,
              min: widget.min,
              max: widget.max,
              divisions: widget.divisions,
              onChanged: (value) => _move(value, ended: false),
              onChangeEnd: (value) => _move(value, ended: true),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          SizedBox(
            width: labelWidth,
            child: Text(
              widget.format(shown),
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
      ),
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

  final bool? isMobile;

  const ObjectTypeToggle({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.isEnabled,
    required this.onChanged,
    this.isLast = false,
    this.isMobile,
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
