import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_exception.dart'
    show ConnectionException;

/// `DisconnectedBackend.noSuchMethod` answers with a failed future, which is
/// only a valid answer for members that return a future. Every other member
/// of the backend contract needs its own override.
void main() {
  final notConnected = throwsA(
    isA<ConnectionException>()
        .having(
          (e) => e.message,
          'message',
          'Not connected to server. Please connect to a Skotiq Headless '
              'Server first.',
        )
        .having(
          (e) => e.userMessage,
          'userMessage',
          'Not connected to a Skotiq Headless Server',
        ),
  );

  test('operations across every role fail with the not-connected error', () {
    final backend = DisconnectedBackend();
    addTearDown(backend.dispose);

    expect(backend.discoverDevices(DeviceType.camera), notConnected);
    expect(backend.mountPark('mount'), notConnected);
    expect(backend.focuserHalt('focuser'), notConnected);
    expect(backend.autofocusCancel(), notConnected);
    expect(backend.phd2GetStatus(), notConnected);
    expect(backend.sequencerStart(), notConnected);
    expect(backend.sequencerGetStatus(), notConnected);
    expect(backend.getProfiles(), notConnected);
    expect(backend.getSettings(), notConnected);
    expect(backend.getImageThumbnail(1), notConnected);
    expect(backend.depthLockStatus(), notConnected);
    expect(backend.stopDeviceHeartbeat('camera'), notConnected);
  });

  test('a failing operation fails through its future, never synchronously', () {
    final backend = DisconnectedBackend();
    addTearDown(backend.dispose);

    late Future<void> pending;
    expect(() => pending = backend.mountPark('mount'), returnsNormally);
    expect(pending, notConnected);
  });

  test('members that are not futures keep their own behavior', () {
    final backend = DisconnectedBackend();
    expect(backend.dispatchPluginNodesLocally, isTrue);
    expect(backend.eventStream, isA<Stream<SkotiqEvent>>());
    expect(backend.polarAlignmentEvents, isA<Stream<Map<String, dynamic>>>());
    expect(
      () => backend.autoStretchImage(width: 1, height: 1, data: const [0]),
      notConnected,
    );
    backend.dispose();
  });

  test('every non-future member of the contract is overridden', () {
    final sources = [
      ...Directory(
        'lib/src/backend/roles',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart')),
      File('lib/src/backend/skotiq_backend.dart'),
      // SequencerBackend implements AdaptiveSwapBackend.
      File('lib/src/services/adaptive_swap_service.dart'),
    ];
    final disconnected = File(
      'lib/src/backend/disconnected_backend.dart',
    ).readAsStringSync();

    // An abstract member: a declaration at class-member indent that ends in
    // `;` with no body. Fields and constructors of the data classes that
    // share these files are not at this indent with this shape.
    final member = RegExp(
      r'^  (?!static |final |const |factory |return |//)'
      r'([A-Za-z_][\w<>?,. ()]*?)\s+(?:get\s+)?(\w+)\s*(?:\(|;|=>)',
      multiLine: true,
    );
    final missing = <String>[];
    var abstractMembers = 0;
    for (final source in sources) {
      final text = source.readAsStringSync();
      for (final interface in RegExp(
        r'abstract (?:interface )?class (\w+)[^{]*\{(.*?)^\}',
        multiLine: true,
        dotAll: true,
      ).allMatches(text)) {
        for (final match in member.allMatches(interface.group(2)!)) {
          final returnType = match.group(1)!.trim();
          final name = match.group(2)!;
          abstractMembers++;
          if (returnType.startsWith('Future<')) continue;
          if (!RegExp('\\b$name\\b').hasMatch(disconnected)) {
            missing.add('${interface.group(1)}.$name returns $returnType');
          }
        }
      }
    }

    expect(
      abstractMembers,
      greaterThan(150),
      reason: 'the scan found the roles',
    );
    expect(
      missing,
      isEmpty,
      reason:
          'noSuchMethod returns a failed Future; give these members an '
          'explicit override in DisconnectedBackend',
    );
  });
}
