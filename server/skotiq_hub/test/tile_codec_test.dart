import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:skotiq_hub/skotiq_hub.dart';
import 'package:test/test.dart';

void main() {
  group('TileAccumulator serialize/deserialize', () {
    test('round-trips a synthetic tile bit-for-bit', () {
      final tile = TileBuilder.synthetic(
        tileId: 42,
        order: 9,
        value: 1234.5,
        frames: 3,
        channels: 1,
        width: 8,
        height: 8,
        contributor: 'alice',
      );
      final bytes = tile.serialize();
      final restored = TileAccumulator.deserialize(bytes);

      expect(restored.tileId, 42);
      expect(restored.order, 9);
      expect(restored.channels, 1);
      expect(restored.width, 8);
      expect(restored.height, 8);
      expect(restored.slotCount, 64);
      expect(restored.totalFrames, 3);
      expect(restored.contributors, <String>['alice']);
      // Re-serializing the restored tile yields identical bytes.
      expect(restored.serialize(), bytes);
    });

    test('finalized mean equals the synthetic constant', () {
      final tile = TileBuilder.synthetic(
        tileId: 1,
        order: 9,
        value: 500.0,
        frames: 4,
        width: 4,
        height: 4,
      );
      final mean = tile.finalizeMean();
      for (final v in mean) {
        expect(v, closeTo(500.0, 1e-9));
      }
    });

    test('rejects bad magic', () {
      final bytes = TileBuilder.synthetic(
        tileId: 1,
        order: 9,
        value: 1.0,
        width: 2,
        height: 2,
      ).serialize();
      bytes[0] = 0x00;
      expect(
        () => TileAccumulator.deserialize(bytes),
        throwsA(
          isA<TileCodecException>().having((e) => e.code, 'code', 'badMagic'),
        ),
      );
    });

    test('rejects unsupported version', () {
      final bytes = TileBuilder.synthetic(
        tileId: 1,
        order: 9,
        value: 1.0,
        width: 2,
        height: 2,
      ).serialize();
      // version is at bytes[4..8] LE.
      bytes[4] = 99;
      expect(
        () => TileAccumulator.deserialize(bytes),
        throwsA(
          isA<TileCodecException>().having(
            (e) => e.code,
            'code',
            'unsupportedVersion',
          ),
        ),
      );
    });

    test('rejects a truncated payload', () {
      final bytes = TileBuilder.synthetic(
        tileId: 1,
        order: 9,
        value: 1.0,
        width: 4,
        height: 4,
      ).serialize();
      final truncated = bytes.sublist(0, bytes.length - 16);
      expect(
        () => TileAccumulator.deserialize(truncated),
        throwsA(
          isA<TileCodecException>().having((e) => e.code, 'code', 'corrupt'),
        ),
      );
    });
  });

  group('mergeSigned additivity (the federation primitive)', () {
    test('merging two contributors equals one co-add of both', () {
      // Two contributors image the same tile: A folds 2 frames at value 100,
      // B folds 3 frames at value 200, each at unit weight. The fused mean must
      // equal the weighted mean of all 5 frames: (2*100 + 3*200) / 5 = 160.
      final a = TileBuilder.synthetic(
        tileId: 7,
        order: 9,
        value: 100.0,
        frames: 2,
        width: 4,
        height: 4,
        contributor: 'A',
      );
      final b = TileBuilder.synthetic(
        tileId: 7,
        order: 9,
        value: 200.0,
        frames: 3,
        width: 4,
        height: 4,
        contributor: 'B',
      );

      final fused = mergeSigned(a.clone(), b, 1.0, 1.0);
      final mean = fused.finalizeMean();
      for (final v in mean) {
        expect(v, closeTo(160.0, 1e-9));
      }
      expect(fused.totalFrames, 5);
      expect(fused.contributors..sort(), <String>['A', 'B']);
      // Coverage tallies add.
      expect(fused.coverage.every((c) => c == 5), isTrue);
    });

    test('trust scales a contributor down', () {
      final a = TileBuilder.synthetic(
        tileId: 7,
        order: 9,
        value: 100.0,
        frames: 1,
        width: 2,
        height: 2,
      );
      final b = TileBuilder.synthetic(
        tileId: 7,
        order: 9,
        value: 200.0,
        frames: 1,
        width: 2,
        height: 2,
      );
      // trust 0.5 on B: weighted mean = (1*100 + 0.5*200) / (1 + 0.5) = 133.33
      final fused = mergeSigned(a.clone(), b, 0.5, 1.0);
      for (final v in fused.finalizeMean()) {
        expect(v, closeTo(200.0 / 1.5 * 0.5 + 100.0 / 1.5, 1e-9));
      }
    });

    test('subtract exactly retracts an added contributor', () {
      final base = TileBuilder.synthetic(
        tileId: 7,
        order: 9,
        value: 100.0,
        frames: 4,
        width: 4,
        height: 4,
        contributor: 'base',
      );
      final extra = TileBuilder.synthetic(
        tileId: 7,
        order: 9,
        value: 999.0,
        frames: 1,
        width: 4,
        height: 4,
        contributor: 'extra',
      );
      final original = base.serialize();
      final fused = mergeSigned(base.clone(), extra, 1.0, 1.0);
      final retracted = mergeSigned(fused, extra, 1.0, -1.0);
      // Means and counts return to the original.
      final baseMean = TileAccumulator.deserialize(original).finalizeMean();
      final retractedMean = retracted.finalizeMean();
      for (var i = 0; i < baseMean.length; i++) {
        expect(retractedMean[i], closeTo(baseMean[i], 1e-9));
      }
      expect(retracted.totalFrames, 4);
    });

    test('mismatched tile ids are a geometry conflict', () {
      final a = TileBuilder.synthetic(
        tileId: 7,
        order: 9,
        value: 1.0,
        width: 2,
        height: 2,
      );
      final b = TileBuilder.synthetic(
        tileId: 8,
        order: 9,
        value: 1.0,
        width: 2,
        height: 2,
      );
      expect(
        () => mergeSigned(a, b, 1.0, 1.0),
        throwsA(
          isA<TileCodecException>().having(
            (e) => e.code,
            'code',
            'geometryMismatch',
          ),
        ),
      );
    });

    test('mismatched orders are an order conflict', () {
      final a = TileBuilder.synthetic(
        tileId: 7,
        order: 9,
        value: 1.0,
        width: 2,
        height: 2,
      );
      final b = TileBuilder.synthetic(
        tileId: 7,
        order: 8,
        value: 1.0,
        width: 2,
        height: 2,
      );
      expect(
        () => mergeSigned(a, b, 1.0, 1.0),
        throwsA(
          isA<TileCodecException>().having(
            (e) => e.code,
            'code',
            'orderMismatch',
          ),
        ),
      );
    });
  });

  // The integrity keystone: the Dart codec claims to be bit-for-bit compatible
  // with the Rust `SkyTileAccumulator::serialize`/`merge_signed`. These fixtures
  // are GROUND TRUTH emitted by the Rust imaging crate
  // (`sky_atlas::tests::emit_hub_parity_fixtures`, regenerate with
  // `SKOTIQ_EMIT_FIXTURES=1 cargo test emit_hub_parity_fixtures`). If either
  // language's layout or merge math drifts, these tests FAIL — a silent
  // corruption of every community stack becomes a loud red test instead.
  group('cross-language parity (Rust-produced .nst fixtures)', () {
    final fixturesDir = Directory('test/fixtures');
    final tileAFile = File('${fixturesDir.path}/tile_a.nst');
    final tileBFile = File('${fixturesDir.path}/tile_b.nst');
    final expectedFile = File('${fixturesDir.path}/merge_expected.json');

    setUpAll(() {
      // Fail loudly if the fixtures are missing rather than silently skipping
      // the highest-integrity test in the suite.
      expect(
        tileAFile.existsSync() &&
            tileBFile.existsSync() &&
            expectedFile.existsSync(),
        isTrue,
        reason:
            'Rust parity fixtures missing under ${fixturesDir.absolute.path}; '
            'regenerate with SKOTIQ_EMIT_FIXTURES=1 cargo test '
            'emit_hub_parity_fixtures',
      );
    });

    TileAccumulator readTile(File f) =>
        TileAccumulator.deserialize(f.readAsBytesSync());

    Map<String, Object?> readExpected() =>
        (jsonDecode(expectedFile.readAsStringSync()) as Map)
            .cast<String, Object?>();

    List<double> doubles(Object? raw) =>
        (raw as List).map((Object? e) => (e as num).toDouble()).toList();

    List<int> ints(Object? raw) =>
        (raw as List).map((Object? e) => (e as num).toInt()).toList();

    test('Dart decodes the Rust-produced tile headers exactly', () {
      final a = readTile(tileAFile);
      final expected = readExpected();
      expect(a.tileId, (expected['tileId'] as num).toInt());
      expect(a.order, (expected['order'] as num).toInt());
      expect(a.channels, 1);
      expect(a.width, 4);
      expect(a.height, 4);
      expect(a.slotCount, 16);
      // Re-serializing the decoded tile reproduces the Rust bytes verbatim:
      // header JSON key order + payload layout must match byte-for-byte.
      expect(a.serialize(), tileAFile.readAsBytesSync());
    });

    test('mergeSigned(a, b, trust) matches Rust merge_signed exactly', () {
      final a = readTile(tileAFile);
      final b = readTile(tileBFile);
      final expected = readExpected();
      final trust = (expected['trust'] as num).toDouble();

      final merged = mergeSigned(a.clone(), b, trust, 1.0);

      // The six running vectors must equal the Rust-computed ground truth to
      // full f64 precision (the merge is exact linear arithmetic).
      void expectF64(Float64List got, List<double> want, String name) {
        expect(got.length, want.length, reason: '$name length');
        for (var i = 0; i < want.length; i++) {
          expect(got[i], closeTo(want[i], 1e-9), reason: '$name[$i]');
        }
      }

      void expectU32(Uint32List got, List<int> want, String name) {
        expect(got.length, want.length, reason: '$name length');
        for (var i = 0; i < want.length; i++) {
          expect(got[i], want[i], reason: '$name[$i]');
        }
      }

      expectF64(merged.sumW, doubles(expected['sum_w']), 'sum_w');
      expectF64(merged.sumW2, doubles(expected['sum_w2']), 'sum_w2');
      expectF64(merged.sumWx, doubles(expected['sum_wx']), 'sum_wx');
      expectF64(merged.sumWx2, doubles(expected['sum_wx2']), 'sum_wx2');
      expectU32(merged.coverage, ints(expected['coverage']), 'coverage');
      expectU32(merged.rejected, ints(expected['rejected']), 'rejected');

      // Finalized mean matches (Rust emits the f32-precision finalize value).
      final mean = merged.finalizeMean();
      final wantMean = doubles(expected['mean']);
      for (var i = 0; i < wantMean.length; i++) {
        expect(mean[i], closeTo(wantMean[i], 1e-3), reason: 'mean[$i]');
      }

      // Provenance totals fuse the way Rust's merge does.
      expect(merged.totalFrames, (expected['total_frames'] as num).toInt());
      expect(
        merged.contributors.length,
        (expected['contributors'] as num).toInt(),
      );
    });

    test('a transposed payload would FAIL parity (guard is real)', () {
      // Sanity: corrupt the decoded sum_w vs sum_wx ordering and confirm the
      // assertion the parity test relies on would catch it.
      final a = readTile(tileAFile);
      final b = readTile(tileBFile);
      final merged = mergeSigned(a.clone(), b, 0.5, 1.0);
      final expected = readExpected();
      final wantSumW = doubles(expected['sum_w']);
      // sum_wx != sum_w for these fixtures (distinct values), so a swap is
      // observable — this is what makes the parity assertions meaningful.
      expect(merged.sumWx[5], isNot(closeTo(wantSumW[5], 1e-6)));
    });
  });
}
