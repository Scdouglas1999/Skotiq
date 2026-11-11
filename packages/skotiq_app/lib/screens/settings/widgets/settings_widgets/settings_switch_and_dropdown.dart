part of '../settings_widgets.dart';

/// A toggle for a [SettingRow]'s trailing slot.
///
/// The switch flips at once; the write follows 300 ms later so rapid toggles
/// collapse to the last one. A failed write flips it back and says so.
///
/// For a self-contained label + switch row use [SkotiqSwitchRow]; for a bare
/// toggle with no stored setting behind it use [SkotiqSwitch].
class SettingsSwitch extends StatefulWidget {
  final bool value;

  /// May be asynchronous. Keeping the Future in the callback type prevents
  /// `async` call sites from becoming uncatchable `async void` handlers.
  final FutureOr<void> Function(bool) onChanged;
  final bool enabled;

  const SettingsSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  static const Duration writeDelay = Duration(milliseconds: 300);

  @override
  State<SettingsSwitch> createState() => _SettingsSwitchState();
}

class _SettingsSwitchState extends State<SettingsSwitch> {
  final SettingsNoticeController _notice = SettingsNoticeController();
  late bool _value = widget.value;
  late final SettingWriter<bool> _writer = SettingWriter<bool>(
    initial: widget.value,
    onRollback: _onRollback,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SettingsSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    // The stored value is adopted only when no local toggle is pending, so an
    // optimistic flip is not undone by a rebuild that predates the write.
    final show = _writer.accept(
      widget.value,
      authority: SettingsFormScope.authorityOf(context),
    );
    if (show || !widget.enabled) _value = widget.value;
  }

  void _onRollback(bool restored, bool attempted, Object error) {
    if (!mounted) return;
    setState(() => _value = restored);
    settingsReportRollback(context, _notice, error);
  }

  void _onTap() {
    if (!widget.enabled) return;
    _notice.clear();
    setState(() => _value = !_value);
    _writer.submit(
      _value,
      widget.onChanged,
      debounce: SettingsSwitch.writeDelay,
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
    return SettingsFieldNotice(
      controller: _notice,
      child: SkotiqSwitch(
        value: _value,
        enabled: widget.enabled,
        onChanged: widget.enabled ? (_) => _onTap() : null,
      ),
    );
  }
}

/// A one-of-many settings control over typed values.
///
/// The selection is a value of [T], never a display string: [labelOf] only
/// says what the operator reads. The choice shows at once and is written in
/// order; a failed write restores the stored selection and says so.
class SettingsChoice<T> extends StatefulWidget {
  const SettingsChoice({
    super.key,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.onChanged,
    this.width,
    this.isMobile,
    this.flexible = false,
  });

  final T value;
  final List<T> values;
  final String Function(T value) labelOf;

  /// May be asynchronous; a failure restores the stored selection.
  final FutureOr<void> Function(T value) onChanged;

  final double? width;

  /// Overrides the enclosing [SettingsFormScope].
  final bool? isMobile;

  /// Let the control take the width its parent offers.
  final bool flexible;

  @override
  State<SettingsChoice<T>> createState() => _SettingsChoiceState<T>();
}

class _SettingsChoiceState<T> extends State<SettingsChoice<T>> {
  final SettingsNoticeController _notice = SettingsNoticeController();
  late T _value = _storedValue;
  late final SettingWriter<T> _writer = SettingWriter<T>(
    initial: _storedValue,
    onRollback: _onRollback,
  );

  T get _storedValue =>
      widget.values.contains(widget.value) ? widget.value : widget.values.first;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant SettingsChoice<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final show = _writer.accept(
      _storedValue,
      authority: SettingsFormScope.authorityOf(context),
    );
    if (show) _value = _storedValue;
  }

  void _onRollback(T restored, T attempted, Object error) {
    if (!mounted) return;
    setState(() => _value = restored);
    settingsReportRollback(context, _notice, error);
  }

  void _select(T value) {
    if (value == _value) return;
    _notice.clear();
    setState(() => _value = value);
    _writer.submit(value, widget.onChanged);
  }

  // SkotiqDropdown speaks strings. String values pass straight through;
  // anything else is addressed by position so two values with the same label
  // stay distinct.
  String _idOf(int index) {
    final value = widget.values[index];
    return value is String ? value : '$index';
  }

  /// Width the longest option needs at the text scale in force.
  ///
  /// "UI scale" is applied as a text scaler, so at Extra Large every label
  /// grows 40% inside a box that does not. Measuring the widest option, not
  /// the selected one, keeps the control from resizing under the pointer.
  double _widestLabelWidth(BuildContext context, List<String> labels) {
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    var widest = 0.0;
    for (final label in labels) {
      painter.text = TextSpan(text: label, style: SkotiqDropdown.labelStyle);
      painter.layout();
      if (painter.width > widest) widest = painter.width;
    }
    painter.dispose();
    return widest;
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = widget.isMobile ?? SettingsFormScope.isMobileOf(context);
    final designWidth = widget.width ?? (isMobile ? 120.0 : 140.0);
    final effectiveWidth = dialogMaxWidth(context, designWidth);

    final values = widget.values;
    final ids = [for (var i = 0; i < values.length; i++) _idOf(i)];
    final labels = [for (final value in values) widget.labelOf(value)];
    final shown = values.contains(_value) ? _value : _storedValue;

    final Widget dropdown = SettingsFieldNotice(
      controller: _notice,
      child: SkotiqDropdown(
        value: ids[values.indexOf(shown)],
        items: ids,
        itemLabels: labels,
        onChanged: (id) {
          if (id == null) return;
          final index = ids.indexOf(id);
          if (index >= 0) _select(values[index]);
        },
        isExpanded: true,
        isDense: true,
      ),
    );

    if (widget.flexible) return dropdown;

    final needed =
        _widestLabelWidth(context, labels) + SkotiqDropdown.chromeWidth;
    return LayoutBuilder(
      builder: (context, constraints) {
        var width = math.max(effectiveWidth, needed);
        // Never take more than the row offers: growing past it would trade an
        // ellipsis for an overflow stripe.
        if (constraints.hasBoundedWidth && width > constraints.maxWidth) {
          width = constraints.maxWidth;
        }
        return SizedBox(width: width, child: dropdown);
      },
    );
  }

  @override
  void dispose() {
    _writer.close();
    _notice.dispose();
    super.dispose();
  }
}

/// A [SettingsChoice] over plain strings, with optional display labels.
///
/// Prefer [SettingsChoice] for enums: this one exists for lists that really
/// are strings (camera names, time zones).
class SettingsDropdown extends StatelessWidget {
  final String value;
  final List<String> items;
  final FutureOr<void> Function(String) onChanged;
  final double? width;
  final bool? isMobile;
  final bool flexible;

  /// Display labels for [items], same length and order.
  final List<String>? itemLabels;

  const SettingsDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.width,
    this.isMobile,
    this.flexible = false,
    this.itemLabels,
  });

  @override
  Widget build(BuildContext context) {
    final labels = itemLabels;
    return SettingsChoice<String>(
      value: value,
      values: items,
      labelOf: labels == null
          ? (item) => item
          : (item) {
              final index = items.indexOf(item);
              return index >= 0 && index < labels.length ? labels[index] : item;
            },
      onChanged: onChanged,
      width: width,
      isMobile: isMobile,
      flexible: flexible,
    );
  }
}
