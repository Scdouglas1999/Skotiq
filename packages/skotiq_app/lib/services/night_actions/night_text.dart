import 'package:flutter/foundation.dart';

import '../../localization/skotiq_localizations.dart';

/// Copy produced away from a BuildContext.
///
/// Either a translations.dart key with `{name}` parameters, or a literal that
/// is already final (a target name, a filter, a device name, a number with
/// its unit).
@immutable
class NightText {
  const NightText(this.key, {this.params = const <String, String>{}})
      : literal = null;

  const NightText.literal(String text)
      : key = '',
        literal = text,
        params = const <String, String>{};

  /// The translations.dart key. Empty for a literal.
  final String key;

  /// The text itself, when it needs no translation.
  final String? literal;

  /// Values substituted for `{name}` in the translated string.
  final Map<String, String> params;

  String resolve(SkotiqLocalizations l10n) =>
      literal ?? l10n.text(key, params: params);

  @override
  bool operator ==(Object other) =>
      other is NightText &&
      other.key == key &&
      other.literal == literal &&
      mapEquals(other.params, params);

  @override
  int get hashCode => Object.hash(
        key,
        literal,
        Object.hashAllUnordered(
          params.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      );

  @override
  String toString() => literal ?? 'NightText($key, $params)';
}
