// Cross-package parity test for the Skotiq version-compatibility policy.
//
// Two halves of the mobile connect flow gate on the policy:
//   * the pre-flight check uses SkotiqServerCompatibility (in
//     skotiq_remote_protocol), and
//   * the NetworkBackend WS-handshake gate uses RemoteApiCompatibility (in
//     skotiq_core).
//
// RemoteApiCompatibility now delegates to SkotiqServerCompatibility, so the
// two are structurally a single source of truth. This test is the standing
// guard that the delegation stays faithful: if anyone re-forks the policy, the
// constants or per-version verdicts diverge and this test fails CI.
//
// The mobile package depends on both packages, so it is the natural home for a
// test that imports both (skotiq_remote_protocol must not depend on
// skotiq_core, so the parity test cannot live there).

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  group('RemoteApiCompatibility <-> SkotiqServerCompatibility parity', () {
    test('policy constants agree', () {
      expect(
        RemoteApiCompatibility.apiVersionHeader,
        SkotiqServerCompatibility.apiVersionHeader,
      );
      expect(
        RemoteApiCompatibility.minimumSupportedVersion.format(),
        SkotiqServerCompatibility.minimumSupportedVersion.format(),
      );
      expect(
        RemoteApiCompatibility.serverApiVersion.format(),
        SkotiqServerCompatibility.serverApiVersion.format(),
      );
      expect(
        RemoteApiCompatibility.clientApiVersion.format(),
        SkotiqServerCompatibility.clientApiVersion.format(),
      );
    });

    // A sweep that crosses every decision boundary: below-floor, exactly the
    // floor, in-band patch/minor, exactly the current, next-major, malformed,
    // and null.
    const versions = <String?>[
      null,
      '',
      'not-a-version',
      '1.9.9',
      '2.3.9',
      '2.4.0',
      '2.5.0',
      '2.6.0',
      '2.6.1',
      'v2.9.1+build.42',
      '3.0.0',
      '4.2.1',
    ];

    test('check() returns the same verdict + code for every version', () {
      for (final v in versions) {
        final core = RemoteApiCompatibility.check(v);
        final proto = SkotiqServerCompatibility.check(v);
        expect(
          core.isCompatible,
          proto.isCompatible,
          reason: 'isCompatible mismatch for server version "$v"',
        );
        expect(
          core.code,
          proto.code,
          reason: 'code mismatch for server version "$v"',
        );
        expect(
          core.message,
          proto.message,
          reason: 'message mismatch for server version "$v"',
        );
      }
    });

    test('checkClient() returns the same verdict + code for every version', () {
      for (final v in versions) {
        final core = RemoteApiCompatibility.checkClient(v);
        final proto = SkotiqServerCompatibility.checkClient(v);
        expect(
          core.isCompatible,
          proto.isCompatible,
          reason: 'isCompatible mismatch for client version "$v"',
        );
        expect(
          core.code,
          proto.code,
          reason: 'code mismatch for client version "$v"',
        );
        expect(
          core.message,
          proto.message,
          reason: 'message mismatch for client version "$v"',
        );
      }
    });
  });
}
