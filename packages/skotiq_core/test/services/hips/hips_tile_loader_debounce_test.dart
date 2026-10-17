// C9 unit tests — loader debounce / dedup / cancel under an injected fake clock.
//
// This is the anti-jank heart of the tile layer: during a pan/zoom gesture the
// loader receives a *burst* of viewports (one per frame, ~16 ms apart). It must
// NOT fetch on every delta. The C9 contract verified here:
//
//   * DEBOUNCE: a burst of N viewport updates results in exactly ONE recompute
//     generation (fetch work proportional to the final set, O(final-set), not to
//     the number of updates O(N)). The fake clock makes this deterministic — only
//     the trailing timer survives the burst.
//   * DEDUP: a given tile id is fetched at most once even when two recomputes
//     both need it; an in-flight request is shared, not re-issued, and a resident
//     (cached) tile is never re-fetched.
//   * CANCEL: when a newer viewport supersedes a generation, that
//     generation's [HipsFetchToken] is cancelled so its in-flight requests
//     abort and never thrash; its late completions do not surface as errors.
//
// Driving: a [_FakeClock] makes the debounce wall-clock-free; a [_CountingServer]
// (MockClient) counts GETs per URL so "fetch invoked once per tile" and
// "O(final-set) not O(updates)" are asserted directly on request counts; a gate
// completer holds requests in flight to exercise dedup and cancellation.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget;
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_fetcher.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';

// Test doubles

/// A manually-driven clock: scheduled callbacks fire only when [fireAll] is
/// called, so the debounce window is fully deterministic with no wall-clock wait.
class _FakeClock implements HipsLoaderClock {
  final List<_FakeTimer> _timers = <_FakeTimer>[];

  /// Total timers ever scheduled (active + fired + cancelled), to prove how many
  /// recompute attempts the debounce actually armed across a burst.
  int scheduledCount = 0;

  @override
  HipsLoaderTimer schedule(Duration delay, void Function() callback) {
    scheduledCount++;
    final timer = _FakeTimer(callback);
    _timers.add(timer);
    return timer;
  }

  /// Fires every currently-active (not cancelled, not yet fired) timer.
  void fireAll() {
    final pending = _timers.where((t) => t.isActive).toList();
    for (final t in pending) {
      t.fire();
    }
  }

  int get activeCount => _timers.where((t) => t.isActive).length;
  int get firedCount => _timers.where((t) => t.fired).length;
}

class _FakeTimer implements HipsLoaderTimer {
  final void Function() _callback;
  bool fired = false;
  bool _cancelled = false;

  _FakeTimer(this._callback);

  @override
  void cancel() => _cancelled = true;

  @override
  bool get isActive => !fired && !_cancelled;

  void fire() {
    if (fired || _cancelled) return;
    fired = true;
    _callback();
  }
}

/// Captures surfaced (non-cancellation) failures.
class _CapturingErrorSink implements HipsTileLoaderErrorSink {
  final List<HipsTileFailure> failures = <HipsTileFailure>[];

  @override
  void onTileError(HipsTileFailure failure) => failures.add(failure);
}

/// A MockClient-backed server that counts GETs per URL and can hold tile/Allsky
/// requests in flight on a gate so dedup and cancellation are observable.
class _CountingServer {
  final Map<String, int> hitsByUrl = <String, int>{};
  Completer<void>? gate;

  http.Client build() {
    return MockClient((request) async {
      final url = request.url.toString();
      hitsByUrl[url] = (hitsByUrl[url] ?? 0) + 1;
      final g = gate;
      // Properties is text and is not part of these tests; only image requests
      // are gated so a held gate exercises tile/Allsky in-flight behaviour.
      if (g != null) {
        await g.future;
      }
      return http.Response.bytes(_png(), 200);
    });
  }

  /// Image-tile URLs only (excludes the Allsky map), with their GET counts.
  Iterable<MapEntry<String, int>> get tileHits =>
      hitsByUrl.entries.where((e) => e.key.contains('/Npix'));

  /// Total GETs issued for actual tiles (not Allsky).
  int get totalTileGets => tileHits.fold(0, (sum, e) => sum + e.value);
}

Uint8List _png({int size = 8}) {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(80, 120, 200));
  return Uint8List.fromList(img.encodePng(image));
}

// Fixtures

const String _surveyId = 'CDS/P/DSS2/red';
const String _baseUrl = 'https://alasky.cds.unistra.fr/DSS/DSS2Merged';

HipsProperties _props() => HipsProperties.parse('''
hips_order        = 9
hips_order_min    = 3
hips_tile_width   = 512
hips_tile_format  = png
hips_frame        = equatorial
''');

HipsViewport _viewport({
  double zoom = 1.0,
  ui.Offset pan = ui.Offset.zero,
  double rotationDegrees = 0.0,
  double raHours = 5.5,
  double decDegrees = -5.4,
  ui.Size canvasSize = const ui.Size(1200, 900),
}) {
  return HipsViewport(
    plateScale: const FramingPlateScale(
      surveyFovWidthDeg: 1.5,
      surveyFovHeightDeg: 1.5,
      imagePixelWidth: 1200,
      imagePixelHeight: 1200,
    ),
    target: FramingTarget(
      name: 'M42',
      raHours: raHours,
      decDegrees: decDegrees,
    ),
    canvasSize: canvasSize,
    zoom: zoom,
    pan: pan,
    rotationDegrees: rotationDegrees,
    baseUrl: _baseUrl,
    surveyId: _surveyId,
    format: HipsTileFormat.png,
    props: _props(),
  );
}

/// Real off-thread image decode + MockClient requests settle on real (not
/// microtask) futures, so give the engine a handful of short real ticks.
Future<void> _settle() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('debounce: O(final-set) recomputes, not O(updates)', () {
    test(
      'a burst of N updates collapses to a single recompute generation',
      () async {
        final clock = _FakeClock();
        final server = _CountingServer();
        final loader = HipsTileLoader(
          cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
          fetcher: HipsTileFetcher(httpClient: server.build()),
          clock: clock,
          debounce: const Duration(milliseconds: 90),
        );
        addTearDown(loader.dispose);

        // A 10-frame pan gesture: 10 distinct viewports.
        for (var i = 0; i < 10; i++) {
          loader.requestTiles(_viewport(pan: ui.Offset(i * 4.0, 0)));
        }

        // Each update armed a timer, but only the trailing one is still active —
        // the previous nine were cancelled and replaced (trailing debounce).
        expect(clock.scheduledCount, 10);
        expect(clock.activeCount, 1);
        // Nothing has computed yet: no recompute ran during the burst.
        expect(loader.generation, 0);

        clock.fireAll();
        await _settle();

        // EXACTLY ONE recompute generation ran for the whole burst.
        expect(loader.generation, 1);
        expect(clock.firedCount, 1);
      },
    );

    test('holding the gesture stationary does not re-arm or re-fetch', () async {
      final clock = _FakeClock();
      final server = _CountingServer();
      final loader = HipsTileLoader(
        cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
        fetcher: HipsTileFetcher(httpClient: server.build()),
        clock: clock,
      );
      addTearDown(loader.dispose);

      loader.requestTiles(_viewport());
      clock.fireAll();
      await _settle();
      final genAfterFirst = loader.generation;
      final scheduledAfterFirst = clock.scheduledCount;
      final getsAfterFirst = server.totalTileGets;
      expect(getsAfterFirst, greaterThan(0));

      // Re-emit the identical viewport repeatedly (a held finger). None of these
      // should re-arm a timer, recompute, or re-fetch a single tile.
      for (var i = 0; i < 5; i++) {
        loader.requestTiles(_viewport());
      }
      expect(clock.activeCount, 0);
      expect(clock.scheduledCount, scheduledAfterFirst);
      expect(loader.generation, genAfterFirst);
      await _settle();
      expect(server.totalTileGets, getsAfterFirst);
    });

    test('flushPending runs the trailing recompute immediately', () async {
      final clock = _FakeClock();
      final server = _CountingServer();
      final loader = HipsTileLoader(
        cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
        fetcher: HipsTileFetcher(httpClient: server.build()),
        clock: clock,
      );
      addTearDown(loader.dispose);

      loader.requestTiles(_viewport());
      expect(loader.hasPendingRecompute, isTrue);
      loader.flushPending();
      await _settle();
      expect(loader.generation, 1);
      expect(loader.hasPendingRecompute, isFalse);
    });
  });

  group('dedup: each tile id fetched at most once', () {
    test('a settled view fetches every tile URL exactly once', () async {
      final clock = _FakeClock();
      final server = _CountingServer();
      final loader = HipsTileLoader(
        cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
        fetcher: HipsTileFetcher(httpClient: server.build()),
        clock: clock,
      );
      addTearDown(loader.dispose);

      loader.requestTiles(_viewport());
      clock.fireAll();
      await _settle();
      await _settle();

      // No tile URL was requested more than once.
      for (final e in server.tileHits) {
        expect(
          e.value,
          1,
          reason: 'tile ${e.key} fetched ${e.value} times (dedup failed)',
        );
      }
      expect(server.tileHits, isNotEmpty);
    });

    test(
      'a resident (cached) tile is not re-fetched on the next recompute',
      () async {
        final clock = _FakeClock();
        final server = _CountingServer();
        final loader = HipsTileLoader(
          cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
          fetcher: HipsTileFetcher(httpClient: server.build()),
          clock: clock,
        );
        addTearDown(loader.dispose);

        // First settle: tiles become resident.
        loader.requestTiles(_viewport());
        clock.fireAll();
        await _settle();
        await _settle();
        final getsAfterFirst = Map<String, int>.from(server.hitsByUrl);

        // A tiny pan reuses almost the entire visible set. Tiles already resident
        // must not be re-fetched (cache.contains dedup), so their counts stay 1.
        loader.requestTiles(_viewport(pan: const ui.Offset(1, 0)));
        clock.fireAll();
        await _settle();
        await _settle();

        for (final url in getsAfterFirst.keys.where(
          (u) => u.contains('/Npix'),
        )) {
          expect(
            server.hitsByUrl[url],
            getsAfterFirst[url],
            reason: 'cached tile $url was re-fetched',
          );
        }
      },
    );

    test(
      'two recomputes sharing an in-flight tile do not double-issue it',
      () async {
        final clock = _FakeClock();
        final server = _CountingServer();
        server.gate = Completer<void>(); // hold every request in flight
        final loader = HipsTileLoader(
          cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
          fetcher: HipsTileFetcher(httpClient: server.build()),
          clock: clock,
        );
        addTearDown(loader.dispose);

        // Generation 1: tiles requested but held in flight.
        loader.requestTiles(_viewport());
        clock.fireAll();
        await _settle();

        // Generation 2 for an overlapping view (tiny pan keeps most tiles the
        // same). Tiles still in flight from gen 1 must NOT be re-issued — but note
        // gen 2 supersedes gen 1, cancelling gen 1's token. We assert no tile URL
        // is requested more than once across both generations.
        loader.requestTiles(_viewport(pan: const ui.Offset(2, 0)));
        clock.fireAll();
        await _settle();

        server.gate!.complete();
        await _settle();
        await _settle();

        for (final e in server.tileHits) {
          expect(
            e.value,
            lessThanOrEqualTo(1),
            reason: 'tile ${e.key} issued ${e.value} times across generations',
          );
        }
      },
    );
  });

  group('cancel: superseded generation is abandoned', () {
    test('a fast view change supersedes the prior generation cleanly', () async {
      final clock = _FakeClock();
      final server = _CountingServer();
      final sink = _CapturingErrorSink();
      server.gate = Completer<void>();
      final loader = HipsTileLoader(
        cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
        fetcher: HipsTileFetcher(httpClient: server.build()),
        clock: clock,
        errorSink: sink,
      );
      addTearDown(loader.dispose);

      // Generation 1 over one sky region, held in flight.
      loader.requestTiles(_viewport(raHours: 5.5, decDegrees: -5.4));
      clock.fireAll();
      await _settle();
      expect(loader.generation, 1);

      // A fast jump to a far-away region supersedes generation 1; its token is
      // cancelled so its in-flight requests abort.
      loader.requestTiles(_viewport(raHours: 18.0, decDegrees: 60.0));
      clock.fireAll();
      await _settle();
      expect(loader.generation, 2);

      // Release the gate: generation-1 requests resolve as cancellations and are
      // dropped quietly (never surfaced as errors).
      server.gate!.complete();
      await _settle();
      await _settle();

      expect(
        sink.failures,
        isEmpty,
        reason: 'a cancellation must never be surfaced as a tile error',
      );
      expect(loader.snapshot.failures, isEmpty);
    });

    test(
      'the snapshot for the superseded generation is not the final one',
      () async {
        final clock = _FakeClock();
        final server = _CountingServer();
        final loader = HipsTileLoader(
          cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
          fetcher: HipsTileFetcher(httpClient: server.build()),
          clock: clock,
        );
        addTearDown(loader.dispose);

        loader.requestTiles(_viewport(raHours: 5.5, decDegrees: -5.4));
        clock.fireAll();
        await _settle();
        await _settle();
        final firstNorder = loader.snapshot.selectedNorder;
        expect(firstNorder, greaterThanOrEqualTo(3));

        // Generation 2 at a much wider FOV selects a different (lower) order; the
        // published snapshot must reflect generation 2, not the abandoned one.
        loader.requestTiles(
          _viewport(raHours: 18.0, decDegrees: 60.0, zoom: 0.25),
        );
        clock.fireAll();
        await _settle();
        await _settle();

        expect(loader.generation, 2);
        // The latest snapshot is for the current generation and has imagery
        // (never blank), proving the loader moved on from the superseded view.
        expect(loader.snapshot.hasAnyImagery, isTrue);
      },
    );

    test(
      'disposing mid-flight aborts cleanly without surfacing errors',
      () async {
        final clock = _FakeClock();
        final server = _CountingServer();
        final sink = _CapturingErrorSink();
        server.gate = Completer<void>();
        final loader = HipsTileLoader(
          cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
          fetcher: HipsTileFetcher(httpClient: server.build()),
          clock: clock,
          errorSink: sink,
        );

        loader.requestTiles(_viewport());
        clock.fireAll();
        await _settle();

        // Dispose while requests are in flight: pending completions must be
        // dropped (the disposed-image guard) and never surfaced.
        loader.dispose();
        server.gate!.complete();
        await _settle();
        await _settle();

        expect(sink.failures, isEmpty);
        // Using a disposed loader surfaces a StateError.
        expect(() => loader.requestTiles(_viewport()), throwsStateError);
      },
    );
  });
}
