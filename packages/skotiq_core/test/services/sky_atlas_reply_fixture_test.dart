// The sky-atlas reply decoders read the replies the native atlas writes:
// test_fixtures/ffi_replies/sky_atlas_<action>.json are serialized by Rust
// tests from the reply types, so a key renamed in Rust shows up here as a key
// no decoder reads (and the decoded value as its default). Replies the
// service reads inline (tilePng, exportDelta, mergeDelta, queryCutout) are
// held to the same samples in sky_atlas_service_test.dart. Nothing in the app
// reads the regionInfo reply.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

import '../harness/reply_fixture.dart';

/// Every reply carries `ok: true`; a failed call is an error, not `ok: false`,
/// so no decoder reads it.
const _ok = {'ok'};

Set<String> _unread(
  String name,
  Object? Function(Map<String, dynamic>) decode,
) {
  final (_, unread) = decodeRecordingReads(replyFixtureObject(name), decode);
  return unread;
}

void main() {
  test('the compaction result reads every native key', () {
    expect(_unread('sky_atlas_compact', AtlasCompactionResult.fromJson), _ok);
  });

  test('the fold summary reads every native key', () {
    expect(_unread('sky_atlas_fold', AtlasFoldSummary.fromJson), _ok);
  });

  test('the coverage rows read every native key', () {
    expect(
      _unread(
        'sky_atlas_coverage',
        (json) => [
          for (final tile in json['tiles'] as List)
            AtlasTileCoverage.fromJson(tile as Map<String, dynamic>),
        ],
      ),
      _ok,
    );
  });

  test('the growth curve reads every native key', () {
    expect(_unread('sky_atlas_growth', AtlasGrowthCurve.fromJson), _ok);
  });

  test('the tile provenance reads every key the native info reply writes, '
      'its snake-case provenance counts included', () {
    expect(
      _unread('sky_atlas_info', (json) => TileProvenanceView.fromJson(1, json)),
      _ok,
    );
    final view = TileProvenanceView.fromJson(
      1,
      replyFixtureObject('sky_atlas_info'),
    );
    expect(view.totalFrames, 42);
    expect(view.totalIntegrationSeconds, 7560.0);
    expect(view.folds.map((f) => f.framesAdded), [3]);
  });
}
