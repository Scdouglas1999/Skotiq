import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  group('LinkVersion', () {
    test('the same release links', () {
      expect(LinkVersion.check(host: '8.2.1', client: '8.2.1'), isNull);
      expect(LinkVersion.check(host: ' 8.2.1 ', client: '8.2.1'), isNull);
    });

    test('an older host is the side to update', () {
      final mismatch = LinkVersion.check(host: '8.2.0', client: '8.2.1')!;
      expect(mismatch.older, LinkSide.host);
      expect(
        mismatch.message,
        'The host runs Skotiq 8.2.0 and this device runs Skotiq 8.2.1. '
        'Update the host to Skotiq 8.2.1, then connect again.',
      );
    });

    test('an older client is the side to update', () {
      final mismatch = LinkVersion.check(host: '8.10.0', client: '8.9.3')!;
      expect(mismatch.older, LinkSide.client);
      expect(
        mismatch.message,
        'The host runs Skotiq 8.10.0 and this device runs Skotiq 8.9.3. '
        'Update Skotiq on this device to 8.10.0, then connect again.',
      );
    });

    test('a host that does not say is the side to update', () {
      for (final host in [null, '', '  ']) {
        final mismatch = LinkVersion.check(host: host, client: '8.2.1')!;
        expect(mismatch.host, isNull);
        expect(mismatch.older, LinkSide.host);
        expect(
          mismatch.message,
          startsWith('The host did not say which Skotiq it runs'),
        );
      }
    });

    test('releases that cannot be ordered ask for the same on both', () {
      final mismatch = LinkVersion.check(host: '8.2.1-dev', client: '8.2.1')!;
      expect(mismatch.older, isNull);
      expect(mismatch.message, contains('Install the same Skotiq release'));
    });

    test('the refusal body carries both releases and reads back', () {
      final mismatch = LinkVersion.check(host: '8.2.0', client: '8.2.1')!;
      final json = mismatch.toErrorBody().toJson().cast<String, dynamic>();
      expect(json['code'], LinkVersion.mismatchCode);
      expect(json['message'], mismatch.message);
      expect(LinkVersionMismatch.fromErrorJson(json), mismatch);
      expect(
        LinkVersionMismatch.fromErrorJson({
          'code': 'invalid_token',
          'clientVersion': '8.2.1',
        }),
        isNull,
      );
    });

    test('the build release is the one version.yaml names', () {
      var dir = Directory.current;
      while (!File('${dir.path}/version.yaml').existsSync()) {
        dir = dir.parent;
      }
      final yaml = File('${dir.path}/version.yaml').readAsStringSync();
      final declared = RegExp(
        r'^version:\s*"([^"]+)"',
        multiLine: true,
      ).firstMatch(yaml)!.group(1);
      expect(skotiqRelease, declared);
    });
  });
}
