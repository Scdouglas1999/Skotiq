// The First Light decoders read the difference reply the native side writes:
// test_fixtures/ffi_replies/difference_image.json is serialized by a Rust
// test from the reply type with every field set, so a key renamed in Rust
// fails here instead of decoding as a default.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

import '../../harness/reply_fixture.dart';

void main() {
  final reply = replyFixtureObject('difference_image');

  test('each candidate decodes every field of the native reply', () {
    final candidates = (reply['candidates'] as List)
        .cast<Map<String, dynamic>>();
    expect(candidates, isNotEmpty);
    for (final raw in candidates) {
      final (candidate, unread) = decodeRecordingReads(
        raw,
        TransientCandidate.fromBridgeJson,
      );
      expect(unread, isEmpty);
      expect(candidate.tileId, raw['tileId']);
      expect(candidate.tileX, raw['tileX']);
      expect(candidate.residualFlux, raw['residualFlux']);
      expect(candidate.deltaMag, raw['deltaMag']);
      expect(candidate.positionAngleDeg, raw['positionAngleDeg']);
      expect(candidate.kind.wire, raw['kind']);
    }
  });

  test('the coverage reads the tile lists and the rejections it reports', () {
    final (coverage, unread) = decodeRecordingReads(
      reply,
      FirstLightCoverage.fromBridgeJson,
    );
    // The candidates have their own decoder; `ok` is checked by the seam;
    // the other rejection counts are not shown.
    expect(unread.where((k) => !k.startsWith('candidates')).toSet(), {
      'ok',
      'rejected.edge',
      'rejected.saturated',
      'rejected.sharp',
      'rejected.brightStar',
      'rejected.dipole',
      'rejected.elongated',
      'rejected.insignificant',
      'rejected.smallChange',
    });
    final rejected = reply['rejected'] as Map<String, dynamic>;
    expect(coverage.unmeasuredPsf, rejected['unmeasuredPsf']);
    expect(coverage.misregistered, rejected['misregistered']);
    expect(coverage.inconsistentScale, rejected['inconsistentScale']);
    expect(coverage.tilesChecked, (reply['tilesChecked'] as List).length);
    expect(
      coverage.tilesSkippedThin,
      (reply['tilesSkippedThin'] as List).length,
    );
    expect(coverage.tilesNoTemplate, (reply['tilesNoTemplate'] as List).length);
    expect(
      coverage.tilesUnnormalized,
      (reply['tilesUnnormalized'] as List).length,
    );
  });
}
