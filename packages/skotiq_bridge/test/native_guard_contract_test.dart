/// Contract tests for the `_nativeAvailable` guards on the bridge stub.
///
/// `_nativeBridgeRequired` throws "requires the native bridge", so it is only
/// ever truthful when the native library is ABSENT. An inverted guard makes a
/// method fail on exactly the builds that can serve it, and names a missing
/// bridge as the reason.
///
/// Two spellings put the throw on the bridge-absent path, and both are legal:
///
///   if (!_nativeAvailable) { _nativeBridgeRequired('op'); }
///
///   if (_nativeAvailable) { ...native call...; return; }
///   _nativeBridgeRequired('op');
///
/// The second is the shape the stub standardised on when the Dart fallback
/// device stack was deleted: Rust is the only device path, so every operation
/// is "do it natively or refuse". What is NOT legal is a `_nativeBridgeRequired`
/// sitting INSIDE a positive `if (_nativeAvailable)` block — that refuses on
/// precisely the builds that can serve the call.
///
/// The native branch itself cannot be driven from a unit test: it needs
/// `_nativeAvailable == true`, which needs a `libskotiq_bridge` whose
/// content hash matches the checked-in `frb_generated.dart`, and `flutter test`
/// has no such library on its loader path. So the polarity of every guard is
/// pinned by reading the source.

library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Strip string literals so braces inside them do not skew the depth count.
final _stringLiteral = RegExp("'[^']*'|\"[^\"]*\"");

int _braceDelta(String line) {
  final code = line.replaceAll(_stringLiteral, '');
  return '{'.allMatches(code).length - '}'.allMatches(code).length;
}

void main() {
  group('native-availability guard polarity', () {
    test('no _nativeBridgeRequired sits inside a positive guard', () {
      final stubDir = Directory('lib/src/bridge_stub');
      final sources = stubDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(sources, isNotEmpty, reason: 'run from the package root');

      final calls = <String>[];
      final inverted = <String>[];

      for (final source in sources) {
        final lines = source.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('_nativeBridgeRequired(')) continue;
          calls.add('${source.path}:${i + 1}');

          // Nearest enclosing/preceding `_nativeAvailable` guard.
          var guard = -1;
          for (var j = i - 1; j >= 0; j--) {
            final line = lines[j];
            if (line.contains('if (') && line.contains('_nativeAvailable')) {
              guard = j;
              break;
            }
            // Stop at the previous method declaration in the extension.
            if (RegExp(r'^  [A-Za-z_(<].*\($').hasMatch(line)) break;
          }

          if (guard < 0) {
            inverted.add(
              '${source.path}:${i + 1}: no _nativeAvailable guard in scope',
            );
            continue;
          }

          if (lines[guard].contains('!_nativeAvailable')) continue;

          // Positive guard: the throw is only correct if the guarded block has
          // already closed, i.e. it is on the fall-through path.
          var depth = 0;
          for (var j = guard; j < i; j++) {
            depth += _braceDelta(lines[j]);
          }
          if (depth > 0) {
            inverted.add(
              '${source.path}:${guard + 1}: ${lines[guard].trim()} '
              '(throw at line ${i + 1} is inside this block)',
            );
          }
        }
      }

      expect(
        calls,
        isNotEmpty,
        reason: 'the scan found no _nativeBridgeRequired calls at all',
      );
      expect(
        inverted,
        isEmpty,
        reason:
            'these throw "requires the native bridge" on the builds '
            'where the native bridge IS available',
      );
    });
  });
}
