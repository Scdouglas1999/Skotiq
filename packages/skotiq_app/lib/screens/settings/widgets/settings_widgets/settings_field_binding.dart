part of '../settings_widgets.dart';

/// The optimistic-write state machine behind every settings input.
///
/// An input shows the operator's choice at once, then this writes it. Writes
/// run one at a time in the order they were made. A choice that is replaced
/// before its write starts is skipped, because the newer write carries the
/// intent. A write that fails while it is still the latest choice rolls the
/// input back to [confirmed] and reports the failure through [onRollback].
///
/// [confirmed] follows two sources: a successful write, and the stored value
/// the owner passes to [accept] (a host push, a provider rebuild). A change of
/// authority (a different backend) retires everything queued for the old one:
/// a value chosen for host A must never be written to host B.
class SettingWriter<T> {
  SettingWriter({
    required T initial,
    Object? authority,
    bool Function(T a, T b)? equals,
    required this.onRollback,
  })  : _confirmed = initial,
        _target = initial,
        _authority = authority,
        _equals = equals ?? _plainEquals;

  static bool _plainEquals(Object? a, Object? b) => a == b;

  /// Called when a failed write restored [confirmed]. Not called for a write
  /// that was already replaced or retired.
  final void Function(T restored, T attempted, Object error) onRollback;

  final bool Function(T a, T b) _equals;

  T _confirmed;
  T _target;
  Object? _authority;
  int _generation = 0;
  int _epoch = 0;
  int _active = 0;
  Future<void> _tail = Future<void>.value();
  Timer? _debounce;
  void Function()? _flushDebounce;

  /// The last value known to be stored.
  T get confirmed => _confirmed;

  /// The value the operator last asked for, or [confirmed] when idle.
  T get target => _target;

  /// True while a write is waiting, debouncing, or in flight.
  bool get busy => _active > 0 || _debounce != null;

  /// Take the owner's stored value. Returns true when the input should now
  /// display it: always after an authority change, otherwise only when no
  /// write is pending and the operator is not in the middle of an [editing].
  bool accept(T value, {Object? authority, bool editing = false}) {
    if (!identical(authority, _authority)) {
      _authority = authority;
      _epoch++;
      _generation++;
      _debounce?.cancel();
      _debounce = null;
      _flushDebounce = null;
      _confirmed = value;
      _target = value;
      return true;
    }
    _confirmed = value;
    if (busy) return false;
    _target = value;
    return !editing;
  }

  /// Queue [value] to be written with [write].
  ///
  /// With a [debounce], quick successive submits collapse to the last one, and
  /// a submit that returns to [confirmed] before anything was sent writes
  /// nothing.
  void submit(
    T value,
    FutureOr<void> Function(T value)? write, {
    Duration debounce = Duration.zero,
  }) {
    final generation = ++_generation;
    _target = value;
    _debounce?.cancel();
    _debounce = null;
    _flushDebounce = null;

    if (write == null) {
      _confirmed = value;
      return;
    }
    if (_active == 0 && _equals(value, _confirmed)) return;

    if (debounce == Duration.zero) {
      _enqueue(value, write, generation);
      return;
    }
    void flush() {
      _debounce = null;
      _flushDebounce = null;
      _enqueue(value, write, generation);
    }

    _flushDebounce = flush;
    _debounce = Timer(debounce, flush);
  }

  void _enqueue(
    T value,
    FutureOr<void> Function(T value) write,
    int generation,
  ) {
    final epoch = _epoch;
    _active++;
    final operation = _tail.then((_) async {
      try {
        if (epoch != _epoch || generation != _generation) return;
        await Future<void>.sync(() => write(value));
        if (epoch == _epoch && generation == _generation) _confirmed = value;
      } catch (error, stackTrace) {
        developer.log(
          'Settings write failed; the input shows the last confirmed value',
          name: 'SettingsInput',
          level: 900,
          error: error,
          stackTrace: stackTrace,
        );
        if (epoch != _epoch || generation != _generation) return;
        _target = _confirmed;
        onRollback(_confirmed, value, error);
      } finally {
        _active--;
      }
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    unawaited(operation);
  }

  /// The owning input is going away. A debounced choice is sent now so the
  /// last toggle before leaving the page is not lost.
  void close() {
    final flush = _flushDebounce;
    _debounce?.cancel();
    flush?.call();
  }
}

/// The result of reading what the operator typed.
class SettingParse<T> {
  /// [value] is acceptable. [note] says what was adjusted (a clamp).
  const SettingParse.ok(T this.value, {this.note})
      : invalid = null,
        isOk = true;

  /// The text is not a value; [invalid] tells the operator what is expected.
  const SettingParse.invalid(String this.invalid)
      : value = null,
        note = null,
        isOk = false;

  final bool isOk;
  final T? value;
  final String? note;
  final String? invalid;
}

/// How one kind of value is typed, shown and checked.
///
/// A codec is the whole of a text-like field's rules: the settings registry
/// can build one from an entry's type and bounds.
abstract class SettingCodec<T> {
  const SettingCodec();

  String format(T value);

  SettingParse<T> parse(String text);

  bool same(T a, T b) => a == b;

  /// Brings a stored value into the field's rules before it is shown.
  T normalize(T value) => value;

  /// The value to show when the owner supplied none and the field's own text
  /// does not parse.
  T get fallback;

  String get unit => '';

  TextInputType? get keyboardType => null;

  List<TextInputFormatter>? get inputFormatters => null;

  TextAlign get textAlign => TextAlign.start;
}

/// Free text. [validate] returns a message for text that must not be saved.
class TextCodec extends SettingCodec<String> {
  const TextCodec({this.validate, this.trim = false});

  final String? Function(String text)? validate;
  final bool trim;

  @override
  String format(String value) => value;

  @override
  SettingParse<String> parse(String text) {
    final value = trim ? text.trim() : text;
    final problem = validate?.call(value);
    return problem == null
        ? SettingParse.ok(value)
        : SettingParse.invalid(problem);
  }

  @override
  String get fallback => '';

  // [validate] is usually a closure rebuilt with its page, so it cannot take
  // part in equality without making every rebuild look like a new codec.
  @override
  bool operator ==(Object other) => other is TextCodec && other.trim == trim;

  @override
  int get hashCode => Object.hash(TextCodec, trim);
}

/// A number between [min] and [max] with at most [decimals] decimal places.
///
/// Text that is not a number is refused with a message naming the range. A
/// number outside the range is brought to the nearest bound, and the message
/// says so.
class NumberCodec extends SettingCodec<double> {
  const NumberCodec({
    required this.min,
    required this.max,
    this.decimals = 0,
    this.unit = '',
    this.customParse,
    this.fixedDecimals = false,
  })  : assert(min <= max),
        assert(decimals >= 0);

  final double min;
  final double max;
  final int decimals;

  @override
  final String unit;

  /// Show every decimal place ("2.50") instead of trimming zeros ("2.5").
  final bool fixedDecimals;

  /// Reads notations plain digits cannot express (degrees-minutes-seconds).
  /// Supplying it lifts the digits-only keyboard and input filter.
  final double? Function(String text)? customParse;

  @override
  double get fallback => min;

  @override
  double normalize(double value) =>
      value.isFinite ? value.clamp(min, max).toDouble() : min;

  @override
  String format(double value) {
    if (decimals == 0) return value.round().toString();
    if (fixedDecimals) return value.toStringAsFixed(decimals);
    return value
        .toStringAsFixed(decimals)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String _withUnit(double value) =>
      unit.isEmpty ? format(value) : '${format(value)} $unit';

  /// "0.5 to 600 s", for messages.
  String get rangeText => '${format(min)} to ${_withUnit(max)}';

  @override
  SettingParse<double> parse(String text) {
    final custom = customParse;
    final parsed = custom != null ? custom(text) : double.tryParse(text.trim());
    if (parsed == null || !parsed.isFinite) {
      return SettingParse.invalid('Enter a number from $rangeText.');
    }
    if (parsed < min) {
      return SettingParse.ok(
        min,
        note: 'The lowest allowed value is ${_withUnit(min)}.',
      );
    }
    if (parsed > max) {
      return SettingParse.ok(
        max,
        note: 'The highest allowed value is ${_withUnit(max)}.',
      );
    }
    return SettingParse.ok(parsed);
  }

  @override
  TextInputType? get keyboardType => customParse != null
      ? TextInputType.text
      : TextInputType.numberWithOptions(decimal: decimals > 0, signed: min < 0);

  @override
  List<TextInputFormatter>? get inputFormatters {
    if (customParse != null) return const [];
    final sign = min < 0 ? '-?' : '';
    final pattern = decimals == 0
        ? RegExp('^$sign\\d*\$')
        : RegExp('^$sign\\d*(?:\\.\\d{0,$decimals})?\$');
    return [
      TextInputFormatter.withFunction(
        (oldValue, newValue) =>
            pattern.hasMatch(newValue.text) ? newValue : oldValue,
      ),
    ];
  }

  @override
  TextAlign get textAlign => TextAlign.right;

  @override
  bool operator ==(Object other) =>
      other is NumberCodec &&
      other.min == min &&
      other.max == max &&
      other.decimals == decimals &&
      other.unit == unit &&
      other.fixedDecimals == fixedDecimals;

  @override
  int get hashCode => Object.hash(min, max, decimals, unit, fixedDecimals);
}

/// A whole number between [min] and [max].
class IntCodec extends SettingCodec<int> {
  const IntCodec({required this.min, required this.max, this.unit = ''})
      : assert(min <= max);

  final int min;
  final int max;

  @override
  final String unit;

  NumberCodec get _number =>
      NumberCodec(min: min.toDouble(), max: max.toDouble(), unit: unit);

  @override
  int get fallback => min;

  @override
  int normalize(int value) => value.clamp(min, max);

  @override
  String format(int value) => value.toString();

  @override
  SettingParse<int> parse(String text) {
    final result = _number.parse(text);
    return result.isOk
        ? SettingParse.ok(result.value!.round(), note: result.note)
        : SettingParse.invalid(result.invalid!);
  }

  @override
  TextInputType? get keyboardType => _number.keyboardType;

  @override
  List<TextInputFormatter>? get inputFormatters => _number.inputFormatters;

  @override
  TextAlign get textAlign => TextAlign.right;

  @override
  bool operator ==(Object other) =>
      other is IntCodec &&
      other.min == min &&
      other.max == max &&
      other.unit == unit;

  @override
  int get hashCode => Object.hash(min, max, unit);
}

/// Makes any codec optional: an empty field means "not set" (null).
class OptionalCodec<T extends Object> extends SettingCodec<T?> {
  const OptionalCodec(this.inner);

  final SettingCodec<T> inner;

  @override
  T? get fallback => null;

  @override
  String get unit => inner.unit;

  @override
  T? normalize(T? value) => value == null ? null : inner.normalize(value);

  @override
  String format(T? value) => value == null ? '' : inner.format(value);

  @override
  SettingParse<T?> parse(String text) {
    if (text.trim().isEmpty) return const SettingParse.ok(null);
    final result = inner.parse(text);
    return result.isOk
        ? SettingParse<T?>.ok(result.value, note: result.note)
        : SettingParse<T?>.invalid(result.invalid!);
  }

  @override
  bool same(T? a, T? b) => a == null || b == null ? a == b : inner.same(a, b);

  @override
  TextInputType? get keyboardType => inner.keyboardType;

  @override
  List<TextInputFormatter>? get inputFormatters => inner.inputFormatters;

  @override
  TextAlign get textAlign => inner.textAlign;

  @override
  bool operator ==(Object other) =>
      other is OptionalCodec<T> && other.inner == inner;

  @override
  int get hashCode => Object.hash(OptionalCodec, inner);
}

/// One editable setting: where its value is read from, how it is written, and
/// how it is typed and checked.
///
/// [S] is the state the page already watches (for example `AppSettingsState`);
/// [read] selects this field's value from it. [write] receives the page's
/// [WidgetRef] so it can reach whichever notifier owns the value. A settings
/// registry entry (key, type, default, bounds) carries everything needed to
/// build one of these, so the widgets never need to change when it does.
class SettingField<S, T> {
  const SettingField({
    required this.label,
    required this.read,
    required this.write,
    this.codec,
    this.choices,
    this.choiceLabel,
    this.hint,
  });

  /// The setting's name as the operator knows it; used in messages.
  final String label;

  final T Function(S state) read;

  final FutureOr<void> Function(WidgetRef ref, T value) write;

  /// Parser, formatter, bounds and unit, for a typed field.
  final SettingCodec<T>? codec;

  /// The allowed values, for a choice field.
  final List<T>? choices;

  /// What the operator reads for each of [choices].
  final String Function(T value)? choiceLabel;

  final String? hint;
}

/// What every settings input under a page reads from context instead of
/// taking as constructor arguments.
///
/// [isMobile] is the single-pane (phone) layout of the Settings screen, which
/// is a property of the screen and never changes inside one page. [embedded]
/// marks a page rendered inside another page's scroll view. [authority] is the
/// identity of the backend that owns the values on the page; inputs retire
/// pending edits when it changes.
class SettingsFormScope extends InheritedWidget {
  const SettingsFormScope({
    super.key,
    required this.isMobile,
    this.embedded = false,
    this.authority,
    required super.child,
  });

  final bool isMobile;
  final bool embedded;
  final Object? authority;

  static SettingsFormScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsFormScope>();

  /// Desktop layout when no Settings screen is above (a dialog, a panel on
  /// another screen).
  static bool isMobileOf(BuildContext context) =>
      maybeOf(context)?.isMobile ?? false;

  static bool embeddedOf(BuildContext context) =>
      maybeOf(context)?.embedded ?? false;

  static Object? authorityOf(BuildContext context) =>
      maybeOf(context)?.authority;

  /// The same scope with [embedded] or [authority] replaced, for a subtree.
  static Widget derive(
    BuildContext context, {
    bool? embedded,
    Object? authority,
    required Widget child,
  }) {
    final current = maybeOf(context);
    return SettingsFormScope(
      isMobile: current?.isMobile ?? false,
      embedded: embedded ?? current?.embedded ?? false,
      authority: authority ?? current?.authority,
      child: child,
    );
  }

  @override
  bool updateShouldNotify(SettingsFormScope oldWidget) =>
      oldWidget.isMobile != isMobile ||
      oldWidget.embedded != embedded ||
      !identical(oldWidget.authority, authority);
}
