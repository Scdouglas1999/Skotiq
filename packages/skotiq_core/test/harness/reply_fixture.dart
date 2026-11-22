import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// A native reply sample from `test_fixtures/ffi_replies/[name].json`, which a
/// Rust test serializes from the reply type itself.
Object? replyFixture(String name) => jsonDecode(
  File('../../test_fixtures/ffi_replies/$name.json').readAsStringSync(),
);

/// A reply sample as a map, for a reply that is one JSON object.
Map<String, dynamic> replyFixtureObject(String name) =>
    replyFixture(name)! as Map<String, dynamic>;

/// Decodes [reply] with [decode] while recording every key the decoder reads,
/// and returns the decoded value with the keys of [reply] the decoder never
/// read (as paths: `perFrameStats[].weight`).
///
/// A key renamed on the native side then shows up twice: the new name is
/// unread here, and the decoder's value for the old one is its default.
(T, Set<String>) decodeRecordingReads<T>(
  Map<String, dynamic> reply,
  T Function(Map<String, dynamic>) decode,
) {
  final reads = <String>{};
  final value = decode(_ReadRecorder(reply, '', reads));
  final unread = _paths(reply, '').difference(reads);
  return (value, unread);
}

Set<String> _paths(Object? value, String prefix) {
  if (value is Map) {
    return {
      for (final entry in value.entries) ...{
        '$prefix${entry.key}',
        ..._paths(entry.value, '$prefix${entry.key}.'),
      },
    };
  }
  if (value is List) {
    final stem = prefix.endsWith('.')
        ? prefix.substring(0, prefix.length - 1)
        : prefix;
    return {for (final item in value) ..._paths(item, '$stem[].')};
  }
  return const {};
}

Object? _wrap(Object? value, String path, Set<String> reads) {
  if (value is Map<String, dynamic>) return _ReadRecorder(value, path, reads);
  if (value is List) {
    final stem = path.endsWith('.') ? path.substring(0, path.length - 1) : path;
    return [for (final item in value) _wrap(item, '$stem[].', reads)];
  }
  return value;
}

class _ReadRecorder extends MapBase<String, dynamic> {
  _ReadRecorder(this._inner, this._prefix, this._reads);

  final Map<String, dynamic> _inner;
  final String _prefix;
  final Set<String> _reads;

  @override
  dynamic operator [](Object? key) {
    if (key is! String) return null;
    _reads.add('$_prefix$key');
    return _wrap(_inner[key], '$_prefix$key.', _reads);
  }

  @override
  void operator []=(String key, dynamic value) => _inner[key] = value;

  @override
  void clear() => _inner.clear();

  @override
  Iterable<String> get keys => _inner.keys;

  @override
  dynamic remove(Object? key) => _inner.remove(key);
}
