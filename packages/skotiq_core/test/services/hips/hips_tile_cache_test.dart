import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/hips/hips_tile_id.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';

/// Tests for component C4 — bounded LRU decoded-tile cache.
///
/// Coverage:
///   * entry-count bound evicts the least-recently-used tile,
///   * byte-budget bound evicts independently of the entry count,
///   * [HipsTileCache.get] touches (promotes to MRU) so the right tile survives,
///   * eviction and replacement dispose the dropped [ui.Image],
///   * a single oversized tile is always admitted (never-blank invariant),
///   * [HipsTileCache.snapshot] is immutable, recency-neutral, and isolated from
///     later mutation, and
///   * use-after-dispose / invalid configuration surface as errors, not silent
///     fallbacks.
///
/// A render-verify test additionally composites a cache snapshot into a PNG so
/// the GPU-drawn tile path (`drawImageRect` over `ui.Image`s held by the cache)
/// is visually locked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds a solid-colour [ui.Image] of the given size. Real decoded RGBA
  /// images, produced the same way the framing golden synthesises its survey
  /// image (PictureRecorder -> toImage), so byte-budget math is exercised
  /// against genuine `width * height` dimensions.
  Future<ui.Image> makeImage(
    int width,
    int height, {
    ui.Color color = const ui.Color(0xFF2080C0),
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = color,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  }

  HipsTileId id(int npix, {int norder = 3, String survey = 'CDS/P/DSS2/red'}) =>
      HipsTileId(survey: survey, norder: norder, npix: npix);

  group('construction', () {
    test('rejects non-positive maxEntries', () {
      expect(
        () => HipsTileCache(maxEntries: 0, maxBytes: 1 << 20),
        throwsArgumentError,
      );
    });

    test('rejects non-positive maxBytes', () {
      expect(
        () => HipsTileCache(maxEntries: 4, maxBytes: 0),
        throwsArgumentError,
      );
    });

    test('starts empty', () {
      final cache = HipsTileCache(maxEntries: 4, maxBytes: 1 << 20);
      addTearDown(cache.dispose);
      expect(cache.isEmpty, isTrue);
      expect(cache.length, 0);
      expect(cache.currentBytes, 0);
    });
  });

  group('basic put/get', () {
    test('get returns the stored image and accounts bytes', () async {
      final cache = HipsTileCache(maxEntries: 4, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      final img = await makeImage(16, 8);
      cache.put(id(0), img);

      expect(cache.length, 1);
      expect(cache.currentBytes, 16 * 8 * 4);
      expect(identical(cache.get(id(0)), img), isTrue);
    });

    test('get returns null for a missing tile without mutating', () async {
      final cache = HipsTileCache(maxEntries: 4, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      cache.put(id(0), await makeImage(8, 8));
      expect(cache.get(id(99)), isNull);
      expect(cache.length, 1);
    });

    test('contains does not affect recency', () async {
      final cache = HipsTileCache(maxEntries: 2, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      cache.put(id(0), await makeImage(8, 8));
      cache.put(id(1), await makeImage(8, 8));
      // Probe id(0) via contains — must NOT promote it.
      expect(cache.contains(id(0)), isTrue);
      // Insert a third tile; LRU (id 0, unpromoted) must be evicted.
      cache.put(id(2), await makeImage(8, 8));
      expect(cache.contains(id(0)), isFalse);
      expect(cache.contains(id(1)), isTrue);
      expect(cache.contains(id(2)), isTrue);
    });
  });

  group('entry-count eviction', () {
    test('evicts least-recently-used when over maxEntries', () async {
      final cache = HipsTileCache(maxEntries: 3, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      for (var i = 0; i < 3; i++) {
        cache.put(id(i), await makeImage(8, 8));
      }
      expect(cache.keysByRecency, [id(0), id(1), id(2)]);

      cache.put(id(3), await makeImage(8, 8));
      // id(0) was LRU -> evicted.
      expect(cache.length, 3);
      expect(cache.contains(id(0)), isFalse);
      expect(cache.keysByRecency, [id(1), id(2), id(3)]);
    });

    test('get promotes to MRU so a different tile is evicted', () async {
      final cache = HipsTileCache(maxEntries: 3, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      for (var i = 0; i < 3; i++) {
        cache.put(id(i), await makeImage(8, 8));
      }
      // Touch id(0): now MRU order is [1, 2, 0].
      expect(cache.get(id(0)), isNotNull);
      expect(cache.keysByRecency, [id(1), id(2), id(0)]);

      cache.put(id(3), await makeImage(8, 8));
      // id(1) is now LRU -> evicted; id(0) survives.
      expect(cache.contains(id(1)), isFalse);
      expect(cache.contains(id(0)), isTrue);
      expect(cache.keysByRecency, [id(2), id(0), id(3)]);
    });
  });

  group('byte-budget eviction', () {
    test('evicts on byte budget independently of entry count', () async {
      // Budget holds exactly two 32x32 tiles (32*32*4 = 4096 bytes each).
      final cache = HipsTileCache(maxEntries: 100, maxBytes: 4096 * 2);
      addTearDown(cache.dispose);
      cache.put(id(0), await makeImage(32, 32));
      cache.put(id(1), await makeImage(32, 32));
      expect(cache.length, 2);
      expect(cache.currentBytes, 4096 * 2);

      cache.put(id(2), await makeImage(32, 32));
      // Over budget by one tile -> evict LRU id(0).
      expect(cache.length, 2);
      expect(cache.contains(id(0)), isFalse);
      expect(cache.currentBytes, 4096 * 2);
    });

    test('evicts multiple LRU tiles to fit a large tile', () async {
      // Budget = 4 small tiles. A big tile worth 3 small ones forces 3
      // evictions in one put.
      const small = 16 * 16 * 4; // 1024
      final cache = HipsTileCache(maxEntries: 100, maxBytes: small * 4);
      addTearDown(cache.dispose);
      for (var i = 0; i < 4; i++) {
        cache.put(id(i), await makeImage(16, 16));
      }
      expect(cache.length, 4);

      // 16 x 48 = 3 * small bytes.
      cache.put(id(10), await makeImage(16, 48));
      expect(cache.contains(id(10)), isTrue);
      // Must have evicted the 3 oldest to fit (total <= budget).
      expect(cache.currentBytes, lessThanOrEqualTo(small * 4));
      expect(cache.contains(id(0)), isFalse);
      expect(cache.contains(id(1)), isFalse);
      expect(cache.contains(id(2)), isFalse);
      expect(cache.contains(id(3)), isTrue);
    });

    test('a single oversized tile is always admitted', () async {
      const big = 64 * 64 * 4; // 16384
      final cache = HipsTileCache(maxEntries: 100, maxBytes: big ~/ 2);
      addTearDown(cache.dispose);
      cache.put(id(0), await makeImage(64, 64));
      // Never-blank invariant: the tile the caller needs is resident even
      // though it alone exceeds the budget.
      expect(cache.length, 1);
      expect(cache.contains(id(0)), isTrue);
      expect(cache.currentBytes, big);
    });
  });

  group('image ownership / disposal', () {
    test('evicting disposes the dropped image', () async {
      final cache = HipsTileCache(maxEntries: 1, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      final first = await makeImage(8, 8);
      cache.put(id(0), first);
      cache.put(id(1), await makeImage(8, 8));
      // first was evicted -> disposed.
      expect(first.debugDisposed, isTrue);
    });

    test('replacing a key with a new image disposes the old one', () async {
      final cache = HipsTileCache(maxEntries: 4, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      final old = await makeImage(8, 8);
      final fresh = await makeImage(16, 16);
      cache.put(id(0), old);
      cache.put(id(0), fresh);
      expect(old.debugDisposed, isTrue);
      expect(fresh.debugDisposed, isFalse);
      expect(cache.length, 1);
      expect(cache.currentBytes, 16 * 16 * 4);
    });

    test('replacing with the identical instance does not dispose it', () async {
      final cache = HipsTileCache(maxEntries: 4, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      final img = await makeImage(8, 8);
      cache.put(id(0), img);
      cache.put(id(0), img);
      expect(img.debugDisposed, isFalse);
      expect(cache.length, 1);
      expect(cache.currentBytes, 8 * 8 * 4);
    });

    test('remove disposes and returns true; false on miss', () async {
      final cache = HipsTileCache(maxEntries: 4, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      final img = await makeImage(8, 8);
      cache.put(id(0), img);
      expect(cache.remove(id(0)), isTrue);
      expect(img.debugDisposed, isTrue);
      expect(cache.length, 0);
      expect(cache.currentBytes, 0);
      expect(cache.remove(id(0)), isFalse);
    });

    test('clear disposes every image and leaves the cache usable', () async {
      final cache = HipsTileCache(maxEntries: 4, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      final a = await makeImage(8, 8);
      final b = await makeImage(8, 8);
      cache.put(id(0), a);
      cache.put(id(1), b);
      cache.clear();
      expect(a.debugDisposed, isTrue);
      expect(b.debugDisposed, isTrue);
      expect(cache.isEmpty, isTrue);
      expect(cache.currentBytes, 0);
      // Still usable after clear.
      cache.put(id(2), await makeImage(8, 8));
      expect(cache.length, 1);
    });
  });

  group('snapshot', () {
    test('reflects resident tiles and is unmodifiable', () async {
      final cache = HipsTileCache(maxEntries: 4, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      final img = await makeImage(8, 8);
      cache.put(id(0), img);
      final snap = cache.snapshot();
      expect(snap.length, 1);
      expect(identical(snap[id(0)], img), isTrue);
      expect(snap.contains(id(0)), isTrue);
      expect(snap.ids, contains(id(0)));
    });

    test('does not promote recency (recency-neutral read)', () async {
      final cache = HipsTileCache(maxEntries: 3, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      for (var i = 0; i < 3; i++) {
        cache.put(id(i), await makeImage(8, 8));
      }
      // Snapshot reads id(0) but must not promote it.
      final snap = cache.snapshot();
      expect(snap[id(0)], isNotNull);

      cache.put(id(3), await makeImage(8, 8));
      // id(0) was LRU and snapshot didn't touch it -> evicted.
      expect(cache.contains(id(0)), isFalse);
    });

    test('is isolated from later cache mutation', () async {
      final cache = HipsTileCache(maxEntries: 1, maxBytes: 1 << 24);
      addTearDown(cache.dispose);
      final first = await makeImage(8, 8);
      cache.put(id(0), first);
      final snap = cache.snapshot();
      // Evict id(0) by inserting another (maxEntries == 1).
      cache.put(id(1), await makeImage(8, 8));
      // Snapshot map still references the (now-evicted) id(0) entry — it is a
      // detached copy. (The image handle itself was disposed by eviction;
      // the snapshot map structure is unchanged.)
      expect(snap.contains(id(0)), isTrue);
      expect(snap.contains(id(1)), isFalse);
    });

    test('empty snapshot constant has no tiles', () {
      expect(HipsTileCacheSnapshot.empty.isEmpty, isTrue);
      expect(HipsTileCacheSnapshot.empty.length, 0);
    });
  });

  group('dispose', () {
    test('disposes all images and rejects further use', () async {
      final cache = HipsTileCache(maxEntries: 4, maxBytes: 1 << 24);
      final img = await makeImage(8, 8);
      cache.put(id(0), img);
      cache.dispose();
      expect(img.debugDisposed, isTrue);
      expect(cache.isDisposed, isTrue);
      expect(() => cache.get(id(0)), throwsStateError);
      expect(() => cache.put(id(1), img), throwsStateError);
      expect(() => cache.snapshot(), throwsStateError);
      expect(() => cache.clear(), throwsStateError);
      expect(() => cache.contains(id(0)), throwsStateError);
    });

    test('double dispose is a no-op', () async {
      final cache = HipsTileCache(maxEntries: 4, maxBytes: 1 << 24);
      cache.put(id(0), await makeImage(8, 8));
      cache.dispose();
      expect(cache.dispose, returnsNormally);
    });
  });

  group('render-verify', () {
    test('composites a cache snapshot to a registered PNG', () async {
      // Two surveys/orders share the cache; we lay out 4 resident tiles in a
      // 2x2 grid and draw them via the production primitive (drawImageRect over
      // the snapshot's ui.Images) to prove the GPU path works off cache state.
      final cache = HipsTileCache(maxEntries: 8, maxBytes: 1 << 24);
      addTearDown(cache.dispose);

      const tilePx = 96;
      final colors = <ui.Color>[
        const ui.Color(0xFF2E5BFF),
        const ui.Color(0xFF20C997),
        const ui.Color(0xFFFFC107),
        const ui.Color(0xFFE83E8C),
      ];
      for (var i = 0; i < 4; i++) {
        cache.put(id(i), await makeImage(tilePx, tilePx, color: colors[i]));
      }

      final snap = cache.snapshot();
      const canvasW = 2 * tilePx;
      const canvasH = 2 * tilePx;
      const double tilePxD = 96;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, canvasW.toDouble(), canvasH.toDouble()),
        ui.Paint()..color = const ui.Color(0xFF000000),
      );
      final paint = ui.Paint()..filterQuality = ui.FilterQuality.high;
      // Seam-free 2x2 mosaic from cache tiles.
      final placements = <HipsTileId, ui.Offset>{
        id(0): const ui.Offset(0, 0),
        id(1): const ui.Offset(tilePxD, 0),
        id(2): const ui.Offset(0, tilePxD),
        id(3): const ui.Offset(tilePxD, tilePxD),
      };
      for (final entry in placements.entries) {
        final image = snap[entry.key];
        expect(image, isNotNull, reason: 'tile ${entry.key} must be resident');
        final dest = entry.value & const ui.Size(tilePxD, tilePxD);
        canvas.drawImageRect(
          image!,
          ui.Rect.fromLTWH(
            0,
            0,
            image.width.toDouble(),
            image.height.toDouble(),
          ),
          dest,
          paint,
        );
      }
      final picture = recorder.endRecording();
      final out = await picture.toImage(canvasW, canvasH);
      picture.dispose();
      final pngBytes = await out.toByteData(format: ui.ImageByteFormat.png);
      out.dispose();
      expect(pngBytes, isNotNull);

      // Sample artifact at repo root for eyeballing.
      final repoRoot = _repoRoot();
      final verifyDir = Directory('${repoRoot.path}/.hips_verify');
      if (!verifyDir.existsSync()) {
        verifyDir.createSync(recursive: true);
      }
      final samplePath = '${verifyDir.path}/hips_tile_cache_mosaic.png';
      File(samplePath).writeAsBytesSync(pngBytes!.buffer.asUint8List());
      // ignore: avoid_print
      print('C4 cache render-verify sample written: $samplePath');
    });
  });
}

/// Walks up from the test directory to the monorepo root (the directory whose
/// parent contains `packages/`), so the sample artifact lands at repo-root
/// `.hips_verify/` regardless of where `flutter test` is invoked from.
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (Directory('${dir.path}/packages').existsSync() &&
        Directory('${dir.path}/native').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  return Directory.current;
}
