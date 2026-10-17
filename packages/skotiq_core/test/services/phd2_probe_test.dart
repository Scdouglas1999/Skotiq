import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A stand-in for PHD2's event server.
///
/// [versionLine] is what it emits the moment a client connects (PHD2 sends its
/// `Version` event unprompted); [profileName] is what it answers `get_profile`
/// with, or null to stay silent so the probe's partial-answer path is covered.
class _FakePhd2Server {
  _FakePhd2Server._(this._socket);

  final ServerSocket _socket;
  final List<String> received = [];

  int get port => _socket.port;

  static Future<_FakePhd2Server> start({
    String? versionLine,
    String? profileName,
    bool answerProfile = true,
  }) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = _FakePhd2Server._(socket);
    socket.listen((client) {
      if (versionLine != null) {
        client.write('$versionLine\r\n');
      }
      client
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              server.received.add(line);
              final request = jsonDecode(line) as Map<String, dynamic>;
              if (request['method'] == 'get_profile' && answerProfile) {
                client.write(
                  '${jsonEncode({
                    'jsonrpc': '2.0',
                    'result': {'id': 1, 'name': profileName},
                    'id': request['id'],
                  })}\r\n',
                );
              }
            },
            onError: (_) {},
            cancelOnError: true,
          );
    });
    return server;
  }

  Future<void> close() => _socket.close();
}

String _versionEvent({String version = '2.6.13', String subVersion = ''}) =>
    jsonEncode({
      'Event': 'Version',
      'Timestamp': 1234567890.0,
      'Host': 'rig',
      'Inst': 1,
      'PHDVersion': version,
      'PHDSubver': subVersion,
      'OverlapSupport': true,
    });

void main() {
  test(
    'a real PHD2 handshake yields the version and the active profile',
    () async {
      final server = await _FakePhd2Server.start(
        versionLine: _versionEvent(),
        profileName: 'Main rig',
      );
      addTearDown(server.close);

      final result = await probePhd2(host: '127.0.0.1', port: server.port);

      expect(result.outcome, Phd2ProbeOutcome.identified);
      expect(result.version, '2.6.13');
      expect(result.profile, 'Main rig');
      expect(result.isPhd2, isTrue);
      // The probe must actually ask; a hardcoded profile would pass otherwise.
      expect(server.received.single, contains('get_profile'));
    },
  );

  test('PHD2 dev builds render as version+subver', () async {
    final server = await _FakePhd2Server.start(
      versionLine: _versionEvent(version: '2.6.13', subVersion: 'dev4'),
      profileName: 'Widefield',
    );
    addTearDown(server.close);

    final result = await probePhd2(host: '127.0.0.1', port: server.port);

    expect(result.fullVersion, '2.6.13dev4');
  });

  test(
    'a socket that never identifies itself is not reported as PHD2',
    () async {
      // A bare TCP connect proves only that *something* holds the port, so
      // anything else listening on 4400 must not be reported as "PHD2
      // answered".
      final server = await _FakePhd2Server.start(versionLine: null);
      addTearDown(server.close);

      final result = await probePhd2(
        host: '127.0.0.1',
        port: server.port,
        timeout: const Duration(milliseconds: 300),
      );

      expect(result.outcome, Phd2ProbeOutcome.unidentified);
      expect(result.isPhd2, isFalse);
      expect(result.version, isNull);
    },
  );

  test('PHD2 that ignores get_profile still reports its version', () async {
    final server = await _FakePhd2Server.start(
      versionLine: _versionEvent(),
      answerProfile: false,
    );
    addTearDown(server.close);

    final result = await probePhd2(
      host: '127.0.0.1',
      port: server.port,
      timeout: const Duration(milliseconds: 400),
    );

    expect(result.outcome, Phd2ProbeOutcome.identified);
    expect(result.version, '2.6.13');
    expect(result.profile, isNull);
  });

  test('a closed port is reported unreachable with the socket cause', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = probe.port;
    await probe.close();

    final result = await probePhd2(
      host: '127.0.0.1',
      port: deadPort,
      timeout: const Duration(milliseconds: 500),
    );

    expect(result.outcome, Phd2ProbeOutcome.unreachable);
    expect(result.error, isNotNull);
  });

  test('localhost is normalised to IPv4 the way the native client does', () {
    // PHD2 binds IPv4 only; on Windows `localhost` resolves to ::1 first, which
    // made a healthy PHD2 look absent.
    expect(normalizePhd2ProbeHost('localhost'), '127.0.0.1');
    expect(normalizePhd2ProbeHost(''), '127.0.0.1');
    expect(normalizePhd2ProbeHost('::1'), '127.0.0.1');
    expect(normalizePhd2ProbeHost(' 192.168.1.47 '), '192.168.1.47');
  });

  test('the probe survives a wire round-trip for the remote backend', () {
    const original = Phd2ProbeResult(
      outcome: Phd2ProbeOutcome.identified,
      version: '2.6.13',
      subVersion: 'dev4',
      profile: 'Main rig',
    );

    final restored = Phd2ProbeResult.fromJson(original.toJson());

    expect(restored.outcome, Phd2ProbeOutcome.identified);
    expect(restored.fullVersion, '2.6.13dev4');
    expect(restored.profile, 'Main rig');
  });
}
