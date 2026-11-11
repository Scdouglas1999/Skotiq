part of '../settings_widgets.dart';

/// The one typed settings field: a text box bound to a stored value through a
/// [SettingCodec] and a [SettingWriter].
///
/// It owns its text controller and focus. Typing changes nothing until the
/// field is left or Enter is pressed; then the text is read by the codec.
/// Text the codec refuses is replaced by the last value and the reason is
/// shown under the field. An accepted value is shown at once and written; a
/// failed write restores the stored value and says so.
///
/// A stored value that changes while the field is not being edited (another
/// client, a profile switch) appears immediately. While the operator is
/// typing it only becomes the value a failed save falls back to.
class SettingsValueField<T> extends StatefulWidget {
  const SettingsValueField({
    super.key,
    required this.codec,
    this.value,
    this.hasValue = true,
    this.onChanged,
    this.controller,
    this.authorityKey,
    this.hint,
    this.width,
    this.defaultWidth = 160,
    this.defaultMobileWidth = 140,
    this.flexible = false,
    this.obscure = false,
    this.keyboardType,
    this.inputFormatters,
    this.isMobile,
    this.enabled = true,
    this.inputKey,
    this.builder,
  });

  final SettingCodec<T> codec;

  /// The stored value. Ignored when [hasValue] is false, in which case the
  /// field starts from its controller's text.
  final T? value;

  final bool hasValue;

  /// May be asynchronous; a failure restores the stored value.
  final FutureOr<void> Function(T value)? onChanged;

  /// Only for callers that edit the text from outside (splicing a variable in
  /// at the caret). Leave null and the field owns one.
  final TextEditingController? controller;

  /// Identity of the backend that owns [value]. Defaults to the enclosing
  /// [SettingsFormScope]'s. When it changes, an edit or queued save made for the
  /// previous backend is discarded and the new stored value is shown, even if
  /// the field has focus.
  final Object? authorityKey;

  final String? hint;
  final double? width;
  final double defaultWidth;
  final double defaultMobileWidth;

  /// Let the field take the width its parent offers.
  final bool flexible;

  final bool obscure;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  /// Overrides the enclosing [SettingsFormScope].
  final bool? isMobile;

  final bool enabled;

  /// Key for the text box itself, for tests that type into one of several.
  final Key? inputKey;

  /// Draws the text box, for places whose box does not look like the standard
  /// one (a table cell, a floating-label field). The field still owns the
  /// controller, focus, parsing, writing and messages; the builder only wires
  /// [SettingsFieldParts] into its own decoration.
  final Widget Function(BuildContext context, SettingsFieldParts parts)?
      builder;

  @override
  State<SettingsValueField<T>> createState() => _SettingsValueFieldState<T>();
}

/// What a custom-drawn settings text box has to connect. See
/// [SettingsValueField.builder].
class SettingsFieldParts {
  const SettingsFieldParts({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.keyboardType,
    required this.inputFormatters,
    required this.textAlign,
    required this.enabled,
    required this.hint,
    required this.unit,
    required this.inputKey,
    required this.hasProblem,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TextAlign textAlign;
  final bool enabled;
  final String? hint;
  final String unit;
  final Key? inputKey;

  /// True while a refused entry or a failed save is being reported, so the
  /// box can show its error border.
  final bool hasProblem;
}

class _SettingsValueFieldState<T> extends State<SettingsValueField<T>> {
  final FocusNode _focusNode = FocusNode();
  final SettingsNoticeController _notice = SettingsNoticeController();
  TextEditingController? _ownController;
  SettingWriter<T>? _writerOrNull;
  bool _obscured = true;

  TextEditingController get _controller =>
      widget.controller ?? (_ownController ??= TextEditingController());

  SettingWriter<T> get _writer => _writerOrNull!;

  Object? get _authority =>
      widget.authorityKey ?? SettingsFormScope.authorityOf(context);

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
    _notice.addListener(_onNoticeChanged);
  }

  void _onNoticeChanged() {
    if (mounted && widget.builder != null) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final authority = _authority;
    final writer = _writerOrNull;
    if (writer == null) {
      final initial = _storedValue();
      _writerOrNull = SettingWriter<T>(
        initial: initial,
        authority: authority,
        equals: widget.codec.same,
        onRollback: _onRollback,
      );
      _setText(widget.codec.format(initial));
    } else if (!identical(authority, _lastAuthority)) {
      _sync(force: false);
    }
    _lastAuthority = authority;
  }

  Object? _lastAuthority;

  @override
  void didUpdateWidget(covariant SettingsValueField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final authority = _authority;
    if (oldWidget.controller != widget.controller ||
        oldWidget.codec != widget.codec) {
      _sync(force: true);
    } else if (!identical(authority, _lastAuthority) ||
        oldWidget.hasValue != widget.hasValue ||
        (widget.hasValue && !_sameStored(oldWidget.value, widget.value))) {
      _sync(force: false);
    }
    _lastAuthority = authority;
  }

  bool _sameStored(T? a, T? b) =>
      a == null || b == null ? a == b : widget.codec.same(a, b);

  T _storedValue() {
    final codec = widget.codec;
    if (widget.hasValue) return codec.normalize(widget.value as T);
    final parsed = codec.parse(_controller.text);
    return parsed.isOk ? codec.normalize(parsed.value as T) : codec.fallback;
  }

  void _sync({required bool force}) {
    final codec = widget.codec;
    final prior = _writer.confirmed;
    final value = _storedValue();
    final typed = codec.parse(_controller.text);
    // A real edit in progress survives a same-backend push. A backend switch
    // does not: carrying host A's text into host B would make the next blur
    // write it to the wrong rig.
    final editing = _focusNode.hasFocus &&
        !(typed.isOk && codec.same(typed.value as T, prior));
    final show = _writer.accept(value, authority: _authority, editing: editing);
    if (show || force) _setText(codec.format(value));
  }

  void _setText(String value) {
    final controller = _controller;
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) _commit();
  }

  void _commit() {
    final codec = widget.codec;
    final result = codec.parse(_controller.text);
    if (!result.isOk) {
      _setText(codec.format(_writer.target));
      _notice.show(result.invalid!);
      return;
    }
    final value = result.value as T;
    _setText(codec.format(value));
    final note = result.note;
    if (note != null) _notice.show(note);
    // Enter commits and then drops focus, which commits again with the text
    // already settled: that second pass must not wipe the message the first
    // one raised.
    if (codec.same(value, _writer.target)) return;
    if (note == null) _notice.clear();
    _writer.submit(value, widget.onChanged);
  }

  void _onRollback(T restored, T attempted, Object error) {
    if (!mounted) return;
    _setText(widget.codec.format(restored));
    settingsReportRollback(context, _notice, error);
  }

  @override
  void dispose() {
    _writerOrNull?.close();
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    _ownController?.dispose();
    _notice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final codec = widget.codec;
    final isMobile = widget.isMobile ?? SettingsFormScope.isMobileOf(context);
    final designWidth = widget.width ??
        (isMobile ? widget.defaultMobileWidth : widget.defaultWidth);
    final unit = codec.unit;

    final builder = widget.builder;
    if (builder != null) {
      return SettingsFieldNotice(
        controller: _notice,
        child: builder(
          context,
          SettingsFieldParts(
            controller: _controller,
            focusNode: _focusNode,
            onChanged: (_) => _notice.clear(),
            onSubmitted: (_) => _commit(),
            keyboardType: widget.keyboardType ?? codec.keyboardType,
            inputFormatters: widget.inputFormatters ?? codec.inputFormatters,
            textAlign: codec.textAlign,
            enabled: widget.enabled,
            hint: widget.hint,
            unit: unit,
            inputKey: widget.inputKey,
            hasProblem: _notice.message != null,
          ),
        ),
      );
    }

    final Widget input = SettingsFieldNotice(
      controller: _notice,
      child: SkotiqTextField(
        key: widget.inputKey,
        controller: _controller,
        focusNode: _focusNode,
        hint: widget.hint,
        enabled: widget.enabled,
        keyboardType: widget.keyboardType ?? codec.keyboardType,
        inputFormatters: widget.inputFormatters ?? codec.inputFormatters,
        textAlign: codec.textAlign,
        suffix: unit.isEmpty ? null : unit,
        onChanged: (_) => _notice.clear(),
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
      ),
    );

    if (widget.flexible) return input;
    return SizedBox(width: dialogMaxWidth(context, designWidth), child: input);
  }
}

/// A free-text settings field. See [SettingsValueField].
class SettingsTextInput extends StatelessWidget {
  /// Only needed when the caller edits the text itself; see
  /// [SettingsValueField.controller].
  final TextEditingController? controller;

  /// Latest value owned by the settings provider. When null the field starts
  /// from [controller]'s text.
  final String? authoritativeValue;

  /// See [SettingsValueField.authorityKey].
  final Object? authorityKey;

  final String? hint;
  final double? width;
  final bool obscure;
  final TextInputType? keyboardType;

  /// Applied while the operator types, for rules the field has to show rather
  /// than only enforce on commit: a length cap, or case folding on a code that
  /// is stored upper-case.
  final List<TextInputFormatter>? inputFormatters;

  final FutureOr<void> Function(String)? onChanged;

  /// Returns a message for text that must not be saved, or null.
  final String? Function(String text)? validate;

  final bool? isMobile;
  final bool flexible;

  const SettingsTextInput({
    super.key,
    this.controller,
    this.authoritativeValue,
    this.authorityKey,
    this.hint,
    this.width,
    this.obscure = false,
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
    this.validate,
    this.isMobile,
    this.flexible = false,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsValueField<String>(
      codec: TextCodec(validate: validate),
      value: authoritativeValue,
      hasValue: authoritativeValue != null,
      controller: controller,
      authorityKey: authorityKey,
      hint: hint,
      width: width,
      obscure: obscure,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      onChanged: onChanged,
      isMobile: isMobile,
      flexible: flexible,
    );
  }
}

/// A bounded number settings field. See [SettingsValueField] and
/// [NumberCodec].
class SettingsNumberInput extends StatelessWidget {
  final TextEditingController? controller;

  /// Latest numeric value owned by the settings provider.
  final double? authoritativeValue;

  final Object? authorityKey;

  /// The unit, shown after the number and named in messages.
  final String suffix;

  final double min;
  final double max;
  final int decimals;

  final FutureOr<void> Function(double) onChanged;

  final double? width;
  final bool? isMobile;
  final bool flexible;

  /// See [NumberCodec.customParse]. Used by the site latitude and longitude
  /// rows, where degrees-minutes-seconds is as common as decimal degrees.
  final double? Function(String)? parse;

  const SettingsNumberInput({
    super.key,
    this.controller,
    this.authoritativeValue,
    this.authorityKey,
    required this.suffix,
    required this.min,
    required this.max,
    required this.decimals,
    required this.onChanged,
    this.width,
    this.isMobile,
    this.flexible = false,
    this.parse,
  })  : assert(min <= max),
        assert(decimals >= 0);

  @override
  Widget build(BuildContext context) {
    return SettingsValueField<double>(
      codec: NumberCodec(
        min: min,
        max: max,
        decimals: decimals,
        unit: suffix,
        customParse: parse,
      ),
      value: authoritativeValue,
      hasValue: authoritativeValue != null,
      controller: controller,
      authorityKey: authorityKey,
      onChanged: onChanged,
      width: width,
      defaultWidth: 120,
      defaultMobileWidth: 100,
      isMobile: isMobile,
      flexible: flexible,
    );
  }
}

/// A settings field described by a [SettingField]: the control is chosen from
/// the descriptor (choice list, switch, or typed field), and its value is read
/// from [state].
class SettingsField<S, T> extends ConsumerWidget {
  const SettingsField({
    super.key,
    required this.field,
    required this.state,
    this.width,
    this.flexible = false,
    this.enabled = true,
  });

  final SettingField<S, T> field;
  final S state;
  final double? width;
  final bool flexible;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = field.read(state);
    FutureOr<void> write(T next) => field.write(ref, next);

    final Widget control;
    final choices = field.choices;
    final codec = field.codec;
    if (choices != null) {
      control = SettingsChoice<T>(
        value: value,
        values: choices,
        labelOf: field.choiceLabel ?? (v) => v.toString(),
        onChanged: write,
        width: width,
        flexible: flexible,
      );
    } else if (codec != null) {
      control = SettingsValueField<T>(
        codec: codec,
        value: value,
        onChanged: write,
        hint: field.hint,
        width: width,
        defaultWidth: codec.textAlign == TextAlign.right ? 120 : 160,
        defaultMobileWidth: codec.textAlign == TextAlign.right ? 100 : 140,
        flexible: flexible,
        enabled: enabled,
      );
    } else if (value is bool) {
      control = SettingsSwitch(
        value: value,
        enabled: enabled,
        onChanged: (next) => write(next as T),
      );
    } else {
      throw FlutterError(
        'SettingField "${field.label}" has neither a codec nor choices, '
        'and is not a bool.',
      );
    }
    return SettingRowLabel(title: field.label, child: control);
  }
}
