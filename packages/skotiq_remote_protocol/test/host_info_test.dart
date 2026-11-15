import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

Future<HostInfoRead> _read(
  FutureOr<http.Response> Function(http.Request) answer,
) => readHostInfo(
  scheme: 'http',
  host: '192.168.50.9',
  port: 8080,
  client: MockClient((request) async => answer(request)),
  timeout: const Duration(milliseconds: 200),
);

void main() {
  group('reading a host', () {
    test('a host of this release answers and can be linked', () async {
      late http.Request seen;
      final read = await _read((request) {
        seen = request;
        return http.Response(jsonEncode({'version': skotiqRelease}), 200);
      });
      expect(read, isA<HostInfoAnswer>());
      expect(read.problem, isNull);
      expect(seen.url.path, '/api/info');
      expect(seen.headers[LinkVersion.header], skotiqRelease);
    });

    test('a host of another release is a mismatch naming both', () async {
      final read = await _read(
        (_) => http.Response(jsonEncode({'version': '1.0.0'}), 200),
      );
      expect(read.problem!.kind, LinkProblemKind.mismatch);
      expect(read.problem!.mismatch!.host, '1.0.0');
      expect(read.problem!.message, contains('The host runs Skotiq 1.0.0'));
      expect(read.problem!.message, contains('Update the host'));
    });

    test('no answer is unreachable, never a release mismatch', () async {
      final timedOut = await _read((_) => Completer<http.Response>().future);
      final noRoute = await _read(
        (_) => throw const SocketException(
          'No route to host',
          osError: OSError('No route to host', 113),
        ),
      );
      for (final read in [timedOut, noRoute]) {
        expect(read.problem!.kind, LinkProblemKind.unreachable);
        expect(read.problem!.mismatch, isNull);
        expect(
          read.problem!.message,
          startsWith('No answer from 192.168.50.9:8080'),
        );
        expect(read.problem!.message, isNot(contains('Update')));
      }
    });

    test('a closed port is refused', () async {
      for (final code in [111, 61, 10061]) {
        final read = await _read(
          (_) => throw SocketException(
            'Connection refused',
            osError: OSError('Connection refused', code),
          ),
        );
        expect(read.problem!.kind, LinkProblemKind.refused, reason: '$code');
        expect(read.problem!.message, contains('Skotiq is not listening'));
      }
    });

    test('a name that does not resolve is a wrong address', () async {
      final read = await _read(
        (_) => throw const SocketException("Failed host lookup: 'obsy.local'"),
      );
      expect(read.problem!.kind, LinkProblemKind.wrongAddress);
      expect(read.problem!.message, contains('could not be found'));
    });

    test('something that is not a Skotiq host is a wrong address', () async {
      final answers = [
        http.Response('<html>router</html>', 200),
        http.Response('Not found', 404),
        http.Response(jsonEncode({'name': 'printer'}), 200),
        http.Response(jsonEncode(['version']), 200),
        http.Response(jsonEncode({'version': ''}), 200),
      ];
      for (final answer in answers) {
        final read = await _read((_) => answer);
        expect(
          read.problem!.kind,
          LinkProblemKind.wrongAddress,
          reason: answer.body,
        );
        expect(read.problem!.message, contains('is not a Skotiq host'));
      }
    });

    test('the four problems read differently', () {
      const address = 'rig:8080';
      final messages = {
        const LinkProblem.unreachable(address).message,
        const LinkProblem.refused(address).message,
        const LinkProblem.wrongAddress(address).message,
        LinkProblem.mismatch(
          address,
          LinkVersion.check(host: '9.0.0', client: '9.0.1')!,
        ).message,
      };
      expect(messages, hasLength(4));
    });
  });

  test('a server that never said its release is not a mismatch', () {
    final typed = DiscoveredServer(host: 'rig', webPort: 8080, name: 'rig');
    expect(typed.version, isNull);
    expect(typed.linkMismatch, isNull);
    expect(typed.copyWith(version: '1.0.0').linkMismatch, isNotNull);
    expect(typed.copyWith(version: skotiqRelease).linkMismatch, isNull);
  });
}
