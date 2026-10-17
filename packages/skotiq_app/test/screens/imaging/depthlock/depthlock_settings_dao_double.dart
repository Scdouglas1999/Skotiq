import 'dart:async';

import 'package:skotiq_core/skotiq_core.dart';

/// A settings DAO that lives in a map, so one-shot UI flags can be asserted
/// without a database.
class RecordingSettingsDao implements SettingsDao {
  RecordingSettingsDao([Map<String, String>? seed])
      : store = <String, String>{...?seed};

  final Map<String, String> store;
  final Map<String, StreamController<String?>> _watchers =
      <String, StreamController<String?>>{};

  StreamController<String?> _controllerFor(String key) => _watchers.putIfAbsent(
        key,
        () => StreamController<String?>.broadcast(),
      );

  @override
  Future<String?> getSetting(String key) async => store[key];

  @override
  Stream<String?> watchSetting(String key) async* {
    yield store[key];
    yield* _controllerFor(key).stream;
  }

  @override
  Future<void> setSetting(String key, String value) async {
    store[key] = value;
    _controllerFor(key).add(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
