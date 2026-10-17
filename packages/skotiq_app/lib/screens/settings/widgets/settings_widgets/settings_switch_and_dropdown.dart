part of '../settings_widgets.dart';

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

  @override
  State<SettingsSwitch> createState() => _SettingsSwitchState();
}

class _SettingsSwitchState extends State<SettingsSwitch> {
  Timer? _debounceTimer;

  late bool _value;
  int _editGeneration = 0;
  int _activeWrites = 0;
  Future<void> _writeTail = Future<void>.value();

  @override
  void initState() {
    super.initState();

    _value = widget.value;
  }

  @override
  void didUpdateWidget(SettingsSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Only adopt the parent's value when no local toggle is in flight, so an

    // optimistic flip isn't clobbered by a stale rebuild before the write lands

    if (!widget.enabled ||
        (!(_debounceTimer?.isActive ?? false) && _activeWrites == 0)) {
      _value = widget.value;
    }
  }

  @override
  void dispose() {
    // If there's a pending write, fire it now so the last toggle isn't lost

    if (_debounceTimer?.isActive ?? false) {
      _debounceTimer!.cancel();
      _enqueueCommit(_value, _editGeneration);
    }

    super.dispose();
  }

  void _onTap() {
    if (!widget.enabled) return;
    final generation = ++_editGeneration;
    setState(() => _value = !_value);

    // Cancel any previous pending write

    _debounceTimer?.cancel();

    // A quick on/off that returns to the confirmed parent value should not
    // generate a redundant database/network write.
    if (_activeWrites == 0 && _value == widget.value) {
      _debounceTimer = null;
      return;
    }

    // Delay the DB write by 300ms; rapid toggles coalesce to the final value

    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      _debounceTimer = null;
      _enqueueCommit(_value, generation);
    });
  }

  void _enqueueCommit(bool value, int generation) {
    _activeWrites++;
    final operation = _writeTail.then((_) => _commit(value, generation));
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    unawaited(operation);
  }

  Future<void> _commit(bool value, int generation) async {
    try {
      await Future<void>.sync(() => widget.onChanged(value));
    } catch (_) {
      // Roll back only if the failed write still represents the user's latest
      // intent. A newer toggle may already be pending and must stay visible.
      if (mounted && generation == _editGeneration) {
        setState(() => _value = widget.value);
      }
    } finally {
      _activeWrites--;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SkotiqSwitch(
      value: _value,
      enabled: widget.enabled,
      onChanged: widget.enabled ? (_) => _onTap() : null,
    );
  }
}

/// Dropdown selector for settings.

///

/// Compact trailing control sized for [SettingRow]. Styling mirrors

/// [SkotiqDropdown] / theme [InputDecorationTheme] but uses fixed widths

/// for settings layout — migrate to [SkotiqDropdown] when row sizing allows.

/// Dropdown selector for settings rows.
///
/// Compact trailing control for [SettingRow]. Styling mirrors
/// [SkotiqDropdown] (well fill, ring, chevron) with fixed widths
/// and optional [itemLabels] for value/label pairs.
class SettingsDropdown extends StatefulWidget {
  final String value;

  final List<String> items;

  /// May be asynchronous so failed persistence can restore the last
  /// confirmed selection without leaking an unhandled async error.
  final FutureOr<void> Function(String) onChanged;

  final double? width;

  final bool isMobile;

  /// If true, use flexible width (useful for stacked mobile layouts)

  final bool flexible;

  /// Optional display labels for items. When provided, must have same length

  /// as [items]. The dropdown shows these labels but emits the corresponding

  /// value from [items].

  final List<String>? itemLabels;

  const SettingsDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.width,
    this.isMobile = false,
    this.flexible = false,
    this.itemLabels,
  });

  @override
  State<SettingsDropdown> createState() => _SettingsDropdownState();
}

class _SettingsDropdownState extends State<SettingsDropdown> {
  late String _value;
  int _editGeneration = 0;
  int _activeWrites = 0;
  Future<void> _writeTail = Future<void>.value();

  String get _parentValue =>
      widget.items.contains(widget.value) ? widget.value : widget.items.first;

  @override
  void initState() {
    super.initState();
    _value = _parentValue;
  }

  @override
  void didUpdateWidget(covariant SettingsDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_activeWrites == 0) _value = _parentValue;
  }

  void _onChanged(String? value) {
    if (value == null || value == _value) return;
    final generation = ++_editGeneration;
    final callback = widget.onChanged;
    setState(() => _value = value);

    _activeWrites++;
    final operation = _writeTail.then((_) async {
      try {
        await Future<void>.sync(() => callback(value));
      } catch (_) {
        if (mounted && generation == _editGeneration) {
          setState(() => _value = _parentValue);
        }
      } finally {
        _activeWrites--;
      }
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    unawaited(operation);
  }

  /// Width the longest option needs, at the text scale in force right now.
  ///
  /// The design widths below are logical pixels, but "UI scale" is applied as a
  /// TEXT scaler (see `_calculateUiScaleFactor` in app.dart): at Extra Large
  /// (1.4x) every label grows 40% inside a box that does not, which is why the
  /// UI scale row itself rendered "Extra Lar...". Measuring the labels — rather
  /// than trusting a constant — is what keeps a dropdown able to show the value
  /// it holds. The widest option is used, not the selected one, so the control
  /// does not resize under the pointer when the selection changes.
  double _widestLabelWidth(BuildContext context) {
    final labels = widget.itemLabels ?? widget.items;
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    var widest = 0.0;
    for (final label in labels) {
      painter.text = TextSpan(
        text: label,
        style: SkotiqDropdown.labelStyle,
      );
      painter.layout();
      if (painter.width > widest) widest = painter.width;
    }
    painter.dispose();
    return widest;
  }

  @override
  Widget build(BuildContext context) {
    final designWidth = widget.width ?? (widget.isMobile ? 120.0 : 140.0);
    final effectiveWidth = dialogMaxWidth(context, designWidth);

    Widget dropdown = SkotiqDropdown(
      value: widget.items.contains(_value) ? _value : _parentValue,
      items: widget.items,
      itemLabels: widget.itemLabels,
      onChanged: _onChanged,
      isExpanded: true,
      isDense: true,
    );

    if (widget.flexible) {
      return dropdown;
    }

    final needed = _widestLabelWidth(context) + SkotiqDropdown.chromeWidth;

    return LayoutBuilder(
      builder: (context, constraints) {
        var width = math.max(effectiveWidth, needed);
        // Never take more than the row actually offers: growing past it would
        // trade an ellipsis for a yellow overflow stripe.
        if (constraints.hasBoundedWidth && width > constraints.maxWidth) {
          width = constraints.maxWidth;
        }
        return SizedBox(width: width, child: dropdown);
      },
    );
  }
}

/// Text input field for settings.

///

/// Compact trailing control for [SettingRow]. Styling mirrors

/// [SkotiqTextField] / theme [InputDecorationTheme] with fixed widths.
