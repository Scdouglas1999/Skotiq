import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart';

/// The host/client settings document, key by key: its default, and what the
/// wire model reads each kind of JSON value as (the value it writes back, or
/// the error it throws). Pinned in `fixtures/settings/wire_model.json`,
/// recorded on the hand-written model. `SKOTIQ_RECORD_REPLIES=1` rewrites
/// the fixture.
final _fixture = File('test/fixtures/settings/wire_model.json');

const Map<String, Object?> _candidates = {
  'null': null,
  'true': true,
  'int': 3,
  'negative int': -2,
  'double': 3.75,
  'string': 'text',
  'empty string': '',
  'enum name': 'failOpen',
  'bool map': {'a': true},
  'double map': {'a': 1.5},
  'int map': {'a': 2},
  'location': {'latitude': 1.5, 'longitude': -2.25, 'elevation': 300.0},
  'list': [1],
};

String _encode(Object? value) =>
    jsonEncode(value, toEncodable: (Object? v) => (v as dynamic).toJson());

String _read(String key, Object? value) {
  try {
    final json = AppSettings.fromJson({key: value}).toJson();
    return _encode(json[key]);
  } on Object catch (error) {
    return 'throws ${error.runtimeType}';
  }
}

Map<String, Object?> _snapshot() {
  final defaults = const AppSettings().toJson();
  return {
    'order': defaults.keys.toList(),
    'keys': {
      for (final key in defaults.keys)
        key: {
          'default': _encode(defaults[key]),
          'absent': _encode(AppSettings.fromJson(const {}).toJson()[key]),
          for (final MapEntry(key: label, value: value) in _candidates.entries)
            label: _read(key, value),
        },
    },
  };
}

void main() {
  test('the wire model reads and writes every key as pinned', () {
    final snapshot = _snapshot();
    if (Platform.environment['SKOTIQ_RECORD_REPLIES'] == '1') {
      _fixture.parent.createSync(recursive: true);
      _fixture.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(snapshot)}\n',
      );
      return;
    }
    final pinned = jsonDecode(_fixture.readAsStringSync()) as Map;
    expect(snapshot['order'], pinned['order']);
    final keys = snapshot['keys']! as Map<String, Object?>;
    final pinnedKeys = pinned['keys'] as Map<String, Object?>;
    expect(keys.keys.toSet(), pinnedKeys.keys.toSet());
    for (final key in keys.keys) {
      expect(keys[key], pinnedKeys[key], reason: key);
    }
  });

  test('two documents with the same values are equal', () {
    final a = AppSettings.fromJson({
      'conditionsScoreWeights': {'cloud': 1.0},
      'adaptiveExposurePerFilterEnabled': {'Ha': true},
      'location': {'latitude': 1.0, 'longitude': 2.0, 'elevation': 3.0},
    });
    final b = AppSettings.fromJson(
      jsonDecode(_encode(a.toJson())) as Map<String, dynamic>,
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == b.copyWith(theme: 'light'), isFalse);
    expect(b.copyWith(theme: 'light').theme, 'light');
    expect(a.copyWith(location: null).location, isNull);
    expect(
      a
          .copyWith(imageGradingStarCountMin: 4)
          .copyWith(imageGradingStarCountMin: null),
      a,
    );
  });

  test('toJson keeps the location as its model', () {
    final json = AppSettings.fromJson({
      'location': {'latitude': 1.0, 'longitude': 2.0, 'elevation': 3.0},
    }).toJson();
    expect(json['location'], isA<ObserverLocation>());
  });
}
