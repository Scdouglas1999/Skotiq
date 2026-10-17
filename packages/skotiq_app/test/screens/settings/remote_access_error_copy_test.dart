// Remote Access must hand the operator the one detail they need to fix a
// failed start.
//
// Audit 2026-07-29: enabling remote access on a port another process held showed
// "Remote access failed to start: SocketException: Failed to create server
// socket (OS Error: Address already in use, errno = 98), address = 0.0.0...." —
// ellipsised after two lines, cutting off the port. The row now shows a
// plain-language summary (and keeps the raw text copyable).

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/remote_access_settings.dart';

void main() {
  group('explainRemoteAccessError', () {
    test('names the busy port instead of quoting the SocketException', () {
      const raw =
          'Remote access failed to start: SocketException: Failed to create '
          'server socket (OS Error: Address already in use, errno = 98), '
          'address = 0.0.0.0, port = 8080';

      final explained = explainRemoteAccessError(raw, 8080);

      expect(explained, contains('8080'));
      expect(explained, contains('already in use'));
      expect(explained, isNot(contains('SocketException')));
      expect(explained, isNot(contains('errno')));
    });

    test('handles the Windows in-use errno as well', () {
      final explained = explainRemoteAccessError(
        'OS Error: Only one usage of each socket address is normally '
        'permitted, errno = 10048',
        9090,
      );

      expect(explained, contains('9090'));
      expect(explained, contains('already in use'));
    });

    test('explains a privileged-port refusal', () {
      final explained = explainRemoteAccessError(
        'SocketException: Permission denied (OS Error: Permission denied, '
        'errno = 13)',
        80,
      );

      expect(explained, contains('80'));
      expect(explained.toLowerCase(), contains('privileges'));
    });

    test('passes an unrecognised error through unchanged', () {
      const raw = 'Something nobody has seen before';
      expect(explainRemoteAccessError(raw, 8080), raw);
    });
  });
}
