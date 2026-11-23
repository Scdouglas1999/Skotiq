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

  test('the tile provenance reads the native keys except the provenance '
      'counts, which the native side writes in snake case', () {
    // Drift, recorded and not fixed here: the native TileProvenance and
    // TileFoldRecord have no camelCase rename, so `info` answers
    // `total_frames`, `frames_added` and so on, while TileProvenanceView reads
    // `totalFrames`, `framesAdded`. The region provenance trail shows zero
    // frames and seconds for every fold. The list only shrinks: a fix on
    // either side fails this test until it is updated.
    expect(
      _unread('sky_atlas_info', (json) => TileProvenanceView.fromJson(1, json)),
      {
        ..._ok,
        'provenance.total_frames',
        'provenance.total_integration_seconds',
        'provenance.folds[].frames_added',
        'provenance.folds[].weight_added',
        'provenance.folds[].integration_seconds_added',
      },
    );
  });
}
