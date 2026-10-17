import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  group('SkotiqServerCompatibility', () {
    test('accepts same-major supported server versions', () {
      expect(SkotiqServerCompatibility.check('2.4.0').isCompatible, isTrue);
      expect(SkotiqServerCompatibility.check('2.5.0').isCompatible, isTrue);
      expect(
        SkotiqServerCompatibility.check('v2.9.1+build.42').isCompatible,
        isTrue,
      );
    });

    test('rejects old servers with a clear code and message', () {
      final result = SkotiqServerCompatibility.check('1.9.9');

      expect(result.isCompatible, isFalse);
      expect(result.code, 'server_too_old');
      expect(result.message, contains('too old'));
      expect(result.message, contains('2.4.0'));
    });

    test('rejects newer major servers with a clear code and message', () {
      final result = SkotiqServerCompatibility.check('3.0.0');

      expect(result.isCompatible, isFalse);
      expect(result.code, 'server_too_new');
      expect(result.message, contains('newer than this client supports'));
    });

    test('rejects missing or malformed versions', () {
      expect(
        SkotiqServerCompatibility.check(null).code,
        'server_version_unknown',
      );
      expect(
        SkotiqServerCompatibility.check('not-a-version').code,
        'server_version_unknown',
      );
    });

    test('accepts same-major supported client versions', () {
      final result = SkotiqServerCompatibility.checkClient('2.4.0');

      expect(result.isCompatible, isTrue);
      expect(result.code, 'compatible');
      expect(result.serverVersion, '2.6.0');
      expect(result.clientVersion, '2.4.0');
    });

    test('rejects old clients with a clear code and message', () {
      final result = SkotiqServerCompatibility.checkClient('1.9.9');

      expect(result.isCompatible, isFalse);
      expect(result.code, 'client_too_old');
      expect(result.message, contains('too old'));
      expect(result.message, contains('2.4.0'));
    });

    test('rejects clients that require a newer server major', () {
      final result = SkotiqServerCompatibility.checkClient('3.0.0');

      expect(result.isCompatible, isFalse);
      expect(result.code, 'server_too_old');
      expect(result.message, contains('too old for this client'));
      expect(result.serverVersion, '2.6.0');
    });

    test('rejects missing or malformed client versions', () {
      expect(
        SkotiqServerCompatibility.checkClient(null).code,
        'client_version_unknown',
      );
      expect(
        SkotiqServerCompatibility.checkClient('not-a-version').code,
        'client_version_unknown',
      );
    });
  });
}
