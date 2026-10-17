part of '../settings_widgets.dart';

class SettingsTextInput extends StatefulWidget {
  final TextEditingController controller;

  /// Latest value owned by the settings provider.
  ///
  /// Supplying this keeps a long-lived controller in sync with server pushes
  /// and backend changes. A same-authority update does not overwrite text the
  /// user is actively editing, but it does become the rollback value if that
  /// edit fails to save.
  final String? authoritativeValue;

  /// Identity of the backend that owns [authoritativeValue].
  ///
  /// When this identity changes, any edit or queued save from the previous
  /// backend is discarded and the new authoritative value is shown
  /// immediately, even if the field still has focus.
  final Object? authorityKey;

  final String? hint;

  final double? width;

  final bool obscure;

  final TextInputType? keyboardType;

  /// Applied while the operator types, for the rules the field has to *show*
  /// rather than only enforce on commit — a length cap, or case folding on a
  /// code that is stored upper-case.
  final List<TextInputFormatter>? inputFormatters;

  /// May be asynchronous so failed persistence can restore the last confirmed
  /// value instead of leaving the field visually out of sync.
  final FutureOr<void> Function(String)? onChanged;

  final bool isMobile;

  /// If true, use flexible width (useful for stacked mobile layouts)

  final bool flexible;

  const SettingsTextInput({
    super.key,
    required this.controller,
    this.authoritativeValue,
    this.authorityKey,
    this.hint,
    this.width,
    this.obscure = false,
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
    this.isMobile = false,
    this.flexible = false,
  });

  @override
  State<SettingsTextInput> createState() => _SettingsTextInputState();
}

class _SettingsTextInputState extends State<SettingsTextInput> {
  bool _obscured = true;
  final FocusNode _focusNode = FocusNode();
  late String _confirmedValue;
  late String _lastSubmittedValue;
  int _editGeneration = 0;
  Future<void> _writeTail = Future<void>.value();

  @override
  void initState() {
    super.initState();
    final initial = widget.authoritativeValue ?? widget.controller.text;
    _setControllerText(initial);
    _confirmedValue = initial;
    _lastSubmittedValue = initial;
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant SettingsTextInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      final value = widget.authoritativeValue ?? widget.controller.text;
      _acceptAuthoritativeValue(value, forceVisible: true);
      return;
    }

    final authorityChanged =
        !identical(oldWidget.authorityKey, widget.authorityKey);
    final authoritativeChanged =
        oldWidget.authoritativeValue != widget.authoritativeValue;
    if (authorityChanged || authoritativeChanged) {
      final value = widget.authoritativeValue ?? widget.controller.text;
      _acceptAuthoritativeValue(value, forceVisible: authorityChanged);
    }
  }

  void _setControllerText(String value) {
    if (widget.controller.text == value) return;
    widget.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _acceptAuthoritativeValue(
    String value, {
    required bool forceVisible,
  }) {
    final priorConfirmed = _confirmedValue;
    _editGeneration += 1;
    _confirmedValue = value;
    _lastSubmittedValue = value;

    // Preserve a real in-progress edit when another client changes the same
    // host setting. A backend switch is different: carrying host A's text into
    // host B would make the next blur write it to the wrong rig.
    final hasDirtyEdit =
        _focusNode.hasFocus && widget.controller.text != priorConfirmed;
    if (forceVisible || !hasDirtyEdit) {
      _setControllerText(value);
    }
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) _commit();
  }

  void _commit() {
    final value = widget.controller.text;
    if (value == _lastSubmittedValue) return;
    _lastSubmittedValue = value;
    final generation = ++_editGeneration;
    final callback = widget.onChanged;
    final authority = widget.authorityKey;
    if (callback == null) {
      _confirmedValue = value;
      return;
    }

    final operation = _writeTail.then((_) async {
      try {
        if (!mounted ||
            !identical(widget.authorityKey, authority) ||
            generation != _editGeneration) {
          return;
        }
        await Future<void>.sync(() => callback(value));
        if (!mounted ||
            !identical(widget.authorityKey, authority) ||
            generation != _editGeneration) {
          return;
        }
        _confirmedValue = value;
      } catch (e) {
        // The field snaps back to the confirmed value, which is the honest
        // rendering, but on its own it does not tell the operator a save was
        // attempted and refused. Log so a settings backend rejecting writes is
        // diagnosable rather than looking like a field that will not take input.
        developer.log(
          'Settings text write failed; reverted the field to the last '
          'confirmed value: $e',
          name: 'SettingsInput',
          level: 900,
        );
        if (!mounted ||
            !identical(widget.authorityKey, authority) ||
            generation != _editGeneration) {
          return;
        }
        _lastSubmittedValue = _confirmedValue;
        _setControllerText(_confirmedValue);
      }
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    unawaited(operation);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final designWidth = widget.width ?? (widget.isMobile ? 140.0 : 160.0);
    final effectiveWidth = dialogMaxWidth(context, designWidth);

    Widget input = SkotiqTextField(
      controller: widget.controller,
      focusNode: _focusNode,
      hint: widget.hint,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      onSubmitted: (_) => _commit(),
      obscureText: widget.obscure && _obscured,
      suffixWidget: widget.obscure
          ? GestureDetector(
              onTap: () => setState(() => _obscured = !_obscured),
              child: Padding(
                padding: const EdgeInsets.only(right: SkotiqTokens.spaceSm),
                child: Icon(
                  _obscured ? LucideIcons.eyeOff : LucideIcons.eye,
                  size: SkotiqTokens.iconXs,
                  color: context.skotiqColors.textMuted,
                ),
              ),
            )
          : null,
    );

    if (widget.flexible) {
      return input;
    }

    return SizedBox(
      width: effectiveWidth,
      child: input,
    );
  }
}

/// Number input field for settings.

class SettingsNumberInput extends StatefulWidget {
  final TextEditingController controller;

  /// Latest numeric value owned by the settings provider. See
  /// [SettingsTextInput.authoritativeValue].
  final double? authoritativeValue;

  /// Identity of the backend that owns [authoritativeValue].
  final Object? authorityKey;

  final String suffix;

  final double min;

  final double max;

  final int decimals;

  /// May be asynchronous so failed persistence can restore the last confirmed
  /// value instead of leaving a clamped-but-unsaved number visible.
  final FutureOr<void> Function(double) onChanged;

  final double? width;

  final bool isMobile;

  /// If true, let the input expand to constraints supplied by its parent.
  final bool flexible;

  /// Reads the field's text as a number, replacing plain [double.tryParse].
  ///
  /// Supplying this also LIFTS the digits-only input formatter, because a
  /// formatter that rejects every non-numeric keystroke makes the alternate
  /// notation unenterable and discards pasted coordinates.
  /// Returning null still means "not a number": the field snaps back to the
  /// last stored value exactly as it does for unparseable digits.
  ///
  /// Used by the site latitude/longitude rows, where degrees-minutes-seconds
  /// is as common a way to write the value as decimal degrees.
  final double? Function(String)? parse;

  const SettingsNumberInput({
    super.key,
    required this.controller,
    this.authoritativeValue,
    this.authorityKey,
    required this.suffix,
    required this.min,
    required this.max,
    required this.decimals,
    required this.onChanged,
    this.width,
    this.isMobile = false,
    this.flexible = false,
    this.parse,
  })  : assert(min <= max),
        assert(decimals >= 0);

  @override
  State<SettingsNumberInput> createState() => _SettingsNumberInputState();
}

class _SettingsNumberInputState extends State<SettingsNumberInput> {
  final FocusNode _focusNode = FocusNode();
  late double _confirmedValue;
  late double _lastSubmittedValue;
  bool _hasCommittedValue = false;
  int _editGeneration = 0;
  Future<void> _writeTail = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _resetCommittedValue(forceVisible: true);
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant SettingsNumberInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.min != widget.min ||
        oldWidget.max != widget.max ||
        oldWidget.decimals != widget.decimals) {
      _resetCommittedValue(forceVisible: true);
      return;
    }

    final authorityChanged =
        !identical(oldWidget.authorityKey, widget.authorityKey);
    final authoritativeChanged =
        oldWidget.authoritativeValue != widget.authoritativeValue;
    if (authorityChanged || authoritativeChanged) {
      _resetCommittedValue(forceVisible: authorityChanged);
    }
  }

  void _resetCommittedValue({required bool forceVisible}) {
    final priorConfirmed = _hasCommittedValue
        ? _confirmedValue
        : _parseControllerValue() ?? widget.min;
    final parsed = widget.authoritativeValue ?? _parseControllerValue();
    final value = (parsed != null && parsed.isFinite ? parsed : widget.min)
        .clamp(widget.min, widget.max)
        .toDouble();
    _editGeneration += 1;
    _confirmedValue = value;
    _lastSubmittedValue = value;
    _hasCommittedValue = true;

    final hasDirtyEdit = _focusNode.hasFocus &&
        (_parseControllerValue() != priorConfirmed ||
            widget.controller.text.trim().isEmpty);
    if (forceVisible || !hasDirtyEdit) {
      _setControllerText(_format(value));
    }
  }

  double? _parseControllerValue() => _parseText(widget.controller.text);

  double? _parseText(String text) {
    final parser = widget.parse;
    final parsed = parser != null ? parser(text) : double.tryParse(text.trim());
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  void _setControllerText(String value) {
    if (widget.controller.text == value) return;
    widget.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) _commit();
  }

  void _commit() {
    final parsed = _parseText(widget.controller.text);
    if (parsed == null || !parsed.isFinite) {
      widget.controller.text = _format(_lastSubmittedValue);
      return;
    }

    final value = parsed.clamp(widget.min, widget.max).toDouble();
    final formatted = _format(value);
    if (widget.controller.text != formatted) {
      widget.controller.value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
    }
    if (value == _lastSubmittedValue) return;
    _lastSubmittedValue = value;
    final generation = ++_editGeneration;
    final authority = widget.authorityKey;
    final operation = _writeTail.then((_) async {
      try {
        if (!mounted ||
            !identical(widget.authorityKey, authority) ||
            generation != _editGeneration) {
          return;
        }
        await Future<void>.sync(() => widget.onChanged(value));
        if (!mounted ||
            !identical(widget.authorityKey, authority) ||
            generation != _editGeneration) {
          return;
        }
        _confirmedValue = value;
      } catch (e) {
        // Same reasoning as the text input above: the revert is truthful about
        // the stored value but silent about the refused write.
        developer.log(
          'Settings number write failed; reverted the field to the last '
          'confirmed value: $e',
          name: 'SettingsInput',
          level: 900,
        );
        if (!mounted ||
            !identical(widget.authorityKey, authority) ||
            generation != _editGeneration) {
          return;
        }
        _lastSubmittedValue = _confirmedValue;
        final restored = _format(_confirmedValue);
        _setControllerText(restored);
      }
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    unawaited(operation);
  }

  String _format(double value) {
    if (widget.decimals == 0) return value.round().toString();
    return value
        .toStringAsFixed(widget.decimals)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  TextInputFormatter get _numberFormatter {
    final sign = widget.min < 0 ? '-?' : '';
    final pattern = widget.decimals == 0
        ? RegExp('^$sign\\d*\$')
        : RegExp('^$sign\\d*(?:\\.\\d{0,${widget.decimals}})?\$');
    return TextInputFormatter.withFunction((oldValue, newValue) {
      return pattern.hasMatch(newValue.text) ? newValue : oldValue;
    });
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final designWidth = widget.width ?? (widget.isMobile ? 100.0 : 120.0);
    final effectiveWidth = dialogMaxWidth(context, designWidth);

    final custom = widget.parse != null;
    final input = SkotiqTextField(
      controller: widget.controller,
      focusNode: _focusNode,
      // A custom parser exists precisely because the value can be written with
      // letters and punctuation (47 36 22 N), so the phone keyboard has to
      // offer them and the digits-only formatter has to stand down.
      keyboardType: custom
          ? TextInputType.text
          : TextInputType.numberWithOptions(
              decimal: widget.decimals > 0,
              signed: widget.min < 0,
            ),
      inputFormatters: custom ? const [] : [_numberFormatter],
      textAlign: TextAlign.right,
      suffix: widget.suffix,
      onSubmitted: (_) => _commit(),
    );

    if (widget.flexible) return input;
    return SizedBox(width: effectiveWidth, child: input);
  }
}

/// Color picker for accent color selection.
