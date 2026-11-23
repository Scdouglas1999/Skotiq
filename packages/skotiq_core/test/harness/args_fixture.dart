import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The keys a native request type reads, from
/// `test_fixtures/ffi_args/[name].json`, which a Rust test traces from the
/// type's `Deserialize` implementation: an object per struct, `[element]` per
/// list, `{"*": value}` per map, and a word per value.
Object? argsFixture(String name) => jsonDecode(
  File('../../test_fixtures/ffi_args/$name.json').readAsStringSync(),
);

/// The keys of [args] none of the native request types [names] reads, as
/// paths (`config.polyDegree`, `panels[].path`).
///
/// The native side reads its requests with a default for every absent key,
/// so a key it does not know is dropped without an error. Keys the native
/// side reads that [args] leaves out take their defaults on purpose and are
/// not reported.
Set<String> unreadArgKeys(Map<String, dynamic> args, List<String> names) {
  final schema = <String, Object?>{};
  for (final name in names) {
    schema.addAll((argsFixture(name)! as Map).cast<String, Object?>());
  }
  final unread = <String>{};
  _walk(args, schema, '', unread);
  return unread;
}

/// Fails the test when [args] carries a key the native request types
/// [names] do not read.
///
/// [notRead] names keys the app is known to send that the native side drops;
/// each caller says why. A key that is no longer sent fails too, so the list
/// only shrinks.
void expectNativeReadsEveryKey(
  Map<String, dynamic> args,
  List<String> names, {
  Set<String> notRead = const {},
}) {
  final unread = unreadArgKeys(args, names);
  expect(
    unread.difference(notRead),
    isEmpty,
    reason: 'keys ${names.join(' / ')} does not read, from $args',
  );
  expect(
    notRead.difference(unread),
    isEmpty,
    reason: 'keys listed as dropped that are now read or no longer sent',
  );
}

void _walk(Object? value, Object? schema, String path, Set<String> unread) {
  if (schema == 'any' || schema == null) return;
  if (value is Map && schema is Map) {
    final anyKey = schema['*'];
    for (final entry in value.entries) {
      final key = '${entry.key}';
      final keyPath = path.isEmpty ? key : '$path.$key';
      if (schema.containsKey('*')) {
        _walk(entry.value, anyKey, keyPath, unread);
      } else if (!schema.containsKey(key)) {
        unread.add(keyPath);
      } else {
        _walk(entry.value, schema[key], keyPath, unread);
      }
    }
    return;
  }
  if (value is List && schema is List && schema.isNotEmpty) {
    for (final item in value) {
      _walk(item, schema.first, '$path[]', unread);
    }
  }
}
