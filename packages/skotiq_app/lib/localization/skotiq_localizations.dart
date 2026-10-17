import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

part 'skotiq_localizations/translations.dart';

class SkotiqLocalizations {
  final Locale locale;

  SkotiqLocalizations(this.locale);

  static const supportedLocales = [
    Locale('en'),
    Locale('es'),
  ];

  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = [
    _SkotiqLocalizationsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  /// The raw locale -> key -> value table, exposed only for the translation
  /// completeness test (every key in `en` must exist in every other locale).
  @visibleForTesting
  static Map<String, Map<String, String>> get debugLocalizedValues =>
      _localizedValues;

  static SkotiqLocalizations of(BuildContext context) {
    final localizations = Localizations.of<SkotiqLocalizations>(
      context,
      SkotiqLocalizations,
    );
    return localizations ?? SkotiqLocalizations(const Locale('en'));
  }

  String text(String key, {Map<String, String> params = const {}}) {
    final languageCode = _localizedValues.containsKey(locale.languageCode)
        ? locale.languageCode
        : 'en';
    var value = _localizedValues[languageCode]?[key] ??
        _localizedValues['en']?[key] ??
        key;
    params.forEach((paramKey, paramValue) {
      value = value.replaceAll('{$paramKey}', paramValue);
    });
    return value;
  }
}

class _SkotiqLocalizationsDelegate
    extends LocalizationsDelegate<SkotiqLocalizations> {
  const _SkotiqLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => SkotiqLocalizations.supportedLocales
      .any((supported) => supported.languageCode == locale.languageCode);

  @override
  Future<SkotiqLocalizations> load(Locale locale) async {
    return SkotiqLocalizations(locale);
  }

  @override
  bool shouldReload(_SkotiqLocalizationsDelegate old) => false;
}

extension SkotiqLocalizationsContext on BuildContext {
  SkotiqLocalizations get l10n => SkotiqLocalizations.of(this);
}
