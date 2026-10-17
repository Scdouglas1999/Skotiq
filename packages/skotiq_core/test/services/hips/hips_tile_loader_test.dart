import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/models/hips/hips_tile_id.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget;
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_fetcher.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';

// Test doubles

/// A manually-driven clock: scheduled callbacks fire only when [fireAll] is
/// called, so the debounce is fully deterministic with no real wall-clock wait.
class _FakeClock implements HipsLoaderClock {
  final List<_FakeTimer> _timers = <_FakeTimer>[];

  @override
  HipsLoaderTimer schedule(Duration delay, void Function() callback) {
    final timer = _FakeTimer(callback);
    _timers.add(timer);
    return timer;
  }

  /// Fires every currently-active (not cancelled, not yet fired) timer.
  void fireAll() {
    // Snapshot first: a fired callback may schedule a new timer.
    final pending = _timers.where((t) => t.isActive).toList();
    for (final t in pending) {
      t.fire();
    }
  }

  int get activeCount => _timers.where((t) => t.isActive).length;
}

class _FakeTimer implements HipsLoaderTimer {
  final void Function() _callback;
  bool _fired = false;
  bool _cancelled = false;

  _FakeTimer(this._callback);

  @override
  void cancel() => _cancelled = true;

  @override
  bool get isActive => !_fired && !_cancelled;

  void fire() {
    if (_fired || _cancelled) return;
    _fired = true;
    _callback();
  }
}

/// Captures surfaced (non-cancellation) failures.
class _CapturingErrorSink implements HipsTileLoaderErrorSink {
  final List<HipsTileFailure> failures = <HipsTileFailure>[];

  @override
  void onTileError(HipsTileFailure failure) => failures.add(failure);
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
  ui.Size canvasSize = const ui.Size(1200, 900),
  double raHours = 5.5,
  double decDegrees = -5.4,
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

Uint8List _png({int r = 120, int g = 60, int b = 200, int size = 16}) {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

/// A mock HTTP client that counts requests per URL and can serve tiles, the
/// Allsky map, or programmable errors. Tile requests are gated on a latch so a
/// test can hold them in-flight to exercise cancellation/dedup.
class _MockHipsServer {
  final Map<String, int> hitsByUrl = <String, int>{};
  final List<String> requestedUrls = <String>[];

  /// URLs that should return a 404 instead of an image.
  final Set<String> notFound = <String>{};

  /// When set, the responder waits on this completer before answering tile
  /// requests, letting a test hold requests in flight.
  Completer<void>? gate;

  http.Client build() {
    return MockClient((request) async {
      final url = request.url.toString();
      requestedUrls.add(url);
      hitsByUrl[url] = (hitsByUrl[url] ?? 0) + 1;

      final g = gate;
      if (g != null && !url.endsWith('/properties')) {
        await g.future;
      }

      if (notFound.contains(url)) {
        return http.Response('not found', 404);
      }
      // Allsky and tiles are both PNG images.
      return http.Response.bytes(_png(), 200);
    });
  }
}

Future<void> _drainMicrotasks() async {
  // Tile fetch flows through a real MockClient request and a real off-thread
  // image decode (instantiateImageCodec); both resolve on real (not microtask)
  // futures, so give the engine a handful of short real ticks to settle rather
  // than only draining the microtask queue.
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HipsTileLoader debounce', () {
    test(
      'coalesces a burst of viewports into a single recompute generation',
      () async {
        final clock = _FakeClock();
        final server = _MockHipsServer();
        final fetcher = HipsTileFetcher(httpClient: server.build());
        final cache = HipsTileCache(
          maxEntries: 256,
          maxBytes: 64 * 1024 * 1024,
        );
        final loader = HipsTileLoader(
          cache: cache,
          fetcher: fetcher,
          clock: clock,
          debounce: const Duration(milliseconds: 90),
        );
        addTearDown(loader.dispose);

        // Emit a burst of distinct viewports (a pan gesture).
        loader.requestTiles(_viewport(pan: const ui.Offset(0, 0)));
        loader.requestTiles(_viewport(pan: const ui.Offset(5, 0)));
        loader.requestTiles(_viewport(pan: const ui.Offset(10, 0)));

        // Only one timer should be active (the trailing one); earlier ones were
        // cancelled and replaced.
        expect(clock.activeCount, 1);
        expect(loader.generation, 0); // not yet computed

        clock.fireAll();
        await _drainMicrotasks();

        // Exactly one recompute generation ran for the burst.
        expect(loader.generation, 1);
      },
    );

    test('identical stationary viewport is a no-op (no reschedule)', () async {
      final clock = _FakeClock();
      final server = _MockHipsServer();
      final loader = HipsTileLoader(
        cache: HipsTileCache(maxEntries: 64, maxBytes: 16 * 1024 * 1024),
        fetcher: HipsTileFetcher(httpClient: server.build()),
        clock: clock,
      );
      addTearDown(loader.dispose);

      final vp = _viewport();
      loader.requestTiles(vp);
      clock.fireAll();
      await _drainMicrotasks();
      final genAfterFirst = loader.generation;

      // Re-request the identical viewport: should not schedule a new recompute.
      loader.requestTiles(_viewport());
      expect(clock.activeCount, 0);
      expect(loader.generation, genAfterFirst);
    });
  });

  group('HipsTileLoader fetch + cache + snapshot', () {
    test(
      'fetches selected-order tiles and Allsky, populates snapshot',
      () async {
        final clock = _FakeClock();
        final server = _MockHipsServer();
        final cache = HipsTileCache(
          maxEntries: 512,
          maxBytes: 64 * 1024 * 1024,
        );
        final loader = HipsTileLoader(
          cache: cache,
          fetcher: HipsTileFetcher(httpClient: server.build()),
          clock: clock,
        );
        addTearDown(loader.dispose);

        var notifications = 0;
        loader.addListener(() => notifications++);

        loader.requestTiles(_viewport(zoom: 1.0));
        clock.fireAll();
        await _drainMicrotasks();
        await _drainMicrotasks();

        // The snapshot advanced past empty.
        expect(loader.snapshot.version, greaterThan(0));
        expect(notifications, greaterThan(0));
        // Primary tiles became resident.
        expect(loader.snapshot.primaryTiles, isNotEmpty);
        expect(loader.snapshot.selectedNorder, greaterThanOrEqualTo(3));
        // An Allsky request was issued at the min order (3).
        expect(
          server.requestedUrls.any((u) => u.contains('Norder3/Allsky.png')),
          isTrue,
        );
        // The Allsky base layer is resident in the snapshot.
        expect(loader.snapshot.allsky, isNotNull);
        // Every resident primary tile's image is borrowable from the snapshot.
        for (final tile in loader.snapshot.primaryTiles) {
          expect(loader.snapshot.cacheSnapshot.contains(tile.id), isTrue);
        }
      },
    );

    test(
      'fetches the Allsky at the standard order (3), NOT hips_order_min, for a '
      'survey that omits hips_order_min (real DSS 404s Norder0/1/2 Allsky)',
      () async {
        final clock = _FakeClock();
        final server = _MockHipsServer();
        // Mirror real CDS DSS: the Allsky exists ONLY at the standard order 3.
        // Requesting it at the survey min order (0) would 404, so if the loader
        // (wrongly) fetched at hips_order_min the base layer would never load.
        for (final order in const [0, 1, 2]) {
          server.notFound.add(
            HipsTileId.allskyUrl(_baseUrl, order, HipsTileFormat.png),
          );
        }
        final loader = HipsTileLoader(
          cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
          fetcher: HipsTileFetcher(httpClient: server.build()),
          clock: clock,
        );
        addTearDown(loader.dispose);

        // A survey that OMITS hips_order_min -> defaults to 0, but allskyOrder = 3.
        final props = HipsProperties.parse('''
hips_order        = 9
hips_tile_width   = 512
hips_tile_format  = png
hips_frame        = equatorial
''');
        expect(props.hipsOrderMin, 0);
        expect(props.allskyOrder, 3);

        final viewport = HipsViewport(
          plateScale: const FramingPlateScale(
            surveyFovWidthDeg: 1.5,
            surveyFovHeightDeg: 1.5,
            imagePixelWidth: 1200,
            imagePixelHeight: 1200,
          ),
          target: const FramingTarget(
            name: 'M42',
            raHours: 5.5,
            decDegrees: -5.4,
          ),
          canvasSize: const ui.Size(1200, 900),
          zoom: 1.0,
          pan: ui.Offset.zero,
          rotationDegrees: 0.0,
          baseUrl: _baseUrl,
          surveyId: _surveyId,
          format: HipsTileFormat.png,
          props: props,
        );

        loader.requestTiles(viewport);
        clock.fireAll();
        await _drainMicrotasks();
        await _drainMicrotasks();

        // The Allsky was requested at the STANDARD order 3, never at order 0.
        expect(
          server.requestedUrls.any((u) => u.contains('Norder3/Allsky.png')),
          isTrue,
          reason: 'the Allsky must be fetched at the standard order 3',
        );
        expect(
          server.requestedUrls.any((u) => u.contains('Norder0/Allsky.png')),
          isFalse,
          reason:
              'the loader must NOT request the Allsky at hips_order_min (0)',
        );
        // The never-blank base layer actually loaded.
        expect(
          loader.snapshot.allsky,
          isNotNull,
          reason:
              'the Allsky base layer must be resident for the never-blank '
              'guarantee to hold for a real DSS-style survey',
        );
      },
    );

    test('dedups concurrent in-flight requests for the same tile', () async {
      final clock = _FakeClock();
      final server = _MockHipsServer();
      // Hold all tile/allsky requests in flight.
      server.gate = Completer<void>();
      final loader = HipsTileLoader(
        cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
        fetcher: HipsTileFetcher(httpClient: server.build()),
        clock: clock,
      );
      addTearDown(loader.dispose);

      // Two recomputes for the SAME view: the second must not re-issue fetches
      // for tiles already in flight from the first.
      loader.requestTiles(_viewport());
      clock.fireAll();
      await _drainMicrotasks();

      final hitsAfterFirst = Map<String, int>.from(server.hitsByUrl);

      // Force a second recompute of an equivalent (but not no-op) view by
      // nudging pan so it reschedules, then firing.
      loader.requestTiles(_viewport(pan: const ui.Offset(1, 0)));
      clock.fireAll();
      await _drainMicrotasks();

      // Release the gate and let everything settle.
      server.gate!.complete();
      await _drainMicrotasks();
      await _drainMicrotasks();

      // No tile URL was requested more than once while it was in flight: the
      // second recompute deduped against the in-flight map. (Allsky is fetched
      // once at the min order.)
      final tileUrls = server.hitsByUrl.entries
          .where((e) => e.key.contains('/Npix'))
          .toList();
      for (final e in tileUrls) {
        expect(e.value, 1, reason: 'tile ${e.key} fetched ${e.value} times');
      }
      // Sanity: the first recompute did issue requests.
      expect(hitsAfterFirst.isNotEmpty, isTrue);
    });

    test('cancels superseded generation on a fast view change', () async {
      final clock = _FakeClock();
      final server = _MockHipsServer();
      server.gate = Completer<void>();
      final loader = HipsTileLoader(
        cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
        fetcher: HipsTileFetcher(httpClient: server.build()),
        clock: clock,
      );
      addTearDown(loader.dispose);

      // Generation 1: tiles held in flight.
      loader.requestTiles(_viewport(raHours: 5.5));
      clock.fireAll();
      await _drainMicrotasks();
      expect(loader.generation, 1);

      // A fast move to a different sky region supersedes generation 1.
      loader.requestTiles(_viewport(raHours: 12.0, decDegrees: 40.0));
      clock.fireAll();
      await _drainMicrotasks();
      expect(loader.generation, 2);

      // Release the gate; generation-1 fetches that were bound to the cancelled
      // token complete as cancellations and are dropped quietly.
      server.gate!.complete();
      await _drainMicrotasks();
      await _drainMicrotasks();

      // The loader survived a superseded generation without surfacing
      // cancellations as errors.
      expect(loader.snapshot.failures, isEmpty);
    });

    test(
      'parent (ipix>>2) fallback prefetch is issued one order coarser',
      () async {
        final clock = _FakeClock();
        final server = _MockHipsServer();
        final loader = HipsTileLoader(
          cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
          fetcher: HipsTileFetcher(httpClient: server.build()),
          clock: clock,
        );
        addTearDown(loader.dispose);

        loader.requestTiles(_viewport(zoom: 1.0));
        clock.fireAll();
        await _drainMicrotasks();
        await _drainMicrotasks();

        final selected = loader.snapshot.selectedNorder;
        expect(selected, greaterThan(3));
        final parentOrder = selected - 1;
        // At least one parent-order tile was requested as a prefetch.
        expect(
          server.requestedUrls.any((u) => u.contains('Norder$parentOrder/')),
          isTrue,
          reason: 'expected a parent-order (Norder$parentOrder) prefetch',
        );
      },
    );

    test(
      'lower-order tile shows as fallback under a not-yet-loaded sharp tile',
      () async {
        final clock = _FakeClock();
        final server = _MockHipsServer();
        final cache = HipsTileCache(
          maxEntries: 512,
          maxBytes: 64 * 1024 * 1024,
        );
        final loader = HipsTileLoader(
          cache: cache,
          fetcher: HipsTileFetcher(httpClient: server.build()),
          clock: clock,
        );
        addTearDown(loader.dispose);

        // First settle a coarse view so parent-order tiles are resident.
        loader.requestTiles(_viewport(zoom: 0.5));
        clock.fireAll();
        await _drainMicrotasks();
        await _drainMicrotasks();
        final coarseNorder = loader.snapshot.selectedNorder;

        // Now zoom in so the selected order increases; the sharp tiles are not
        // resident yet at the instant of the recompute, so the coarser resident
        // tiles must appear as fallbacks (never blank).
        server.gate = Completer<void>(); // hold the new sharp tiles in flight
        loader.requestTiles(_viewport(zoom: 2.0));
        clock.fireAll();
        await _drainMicrotasks();

        final sharpNorder = loader.snapshot.selectedNorder;
        expect(sharpNorder, greaterThan(coarseNorder));
        // The view is not blank: either fallbacks or the Allsky base cover it.
        expect(loader.snapshot.hasAnyImagery, isTrue);

        server.gate!.complete();
        await _drainMicrotasks();
      },
    );
  });

  group('HipsTileLoader error handling', () {
    test('surfaces a genuine HTTP failure to the sink and snapshot', () async {
      final clock = _FakeClock();
      final server = _MockHipsServer();
      final sink = _CapturingErrorSink();
      final loader = HipsTileLoader(
        cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
        fetcher: HipsTileFetcher(httpClient: server.build()),
        clock: clock,
        errorSink: sink,
      );
      addTearDown(loader.dispose);

      // Make the Allsky 404 so we get a deterministic surfaced failure.
      loader.requestTiles(_viewport());
      // Mark the allsky url as 404 before firing.
      server.notFound.add(
        HipsTileId.allskyUrl(_baseUrl, 3, HipsTileFormat.png),
      );
      clock.fireAll();
      await _drainMicrotasks();
      await _drainMicrotasks();

      expect(sink.failures, isNotEmpty);
      expect(sink.failures.first.error, isA<HipsFetchHttpException>());
    });
  });

  group('HipsTileLoader lifecycle', () {
    test('clearSurvey resets imagery and supersedes the generation', () async {
      final clock = _FakeClock();
      final server = _MockHipsServer();
      final loader = HipsTileLoader(
        cache: HipsTileCache(maxEntries: 512, maxBytes: 64 * 1024 * 1024),
        fetcher: HipsTileFetcher(httpClient: server.build()),
        clock: clock,
      );
      addTearDown(loader.dispose);

      loader.requestTiles(_viewport());
      clock.fireAll();
      await _drainMicrotasks();
      await _drainMicrotasks();
      expect(loader.snapshot.hasAnyImagery, isTrue);
      final genBefore = loader.generation;

      loader.clearSurvey();

      expect(loader.generation, greaterThan(genBefore));
      expect(loader.snapshot.primaryTiles, isEmpty);
      expect(loader.snapshot.fallbackTiles, isEmpty);
      expect(loader.snapshot.allsky, isNull);
      expect(loader.snapshot.hasAnyImagery, isFalse);
    });

    test('using a disposed loader throws', () async {
      final clock = _FakeClock();
      final server = _MockHipsServer();
      final loader = HipsTileLoader(
        cache: HipsTileCache(maxEntries: 64, maxBytes: 16 * 1024 * 1024),
        fetcher: HipsTileFetcher(httpClient: server.build()),
        clock: clock,
      );
      loader.dispose();
      expect(() => loader.requestTiles(_viewport()), throwsStateError);
    });

    test('rejects an invalid debounce / subdivisions', () {
      final server = _MockHipsServer();
      expect(
        () => HipsTileLoader(
          cache: HipsTileCache(maxEntries: 1, maxBytes: 1024),
          fetcher: HipsTileFetcher(httpClient: server.build()),
          debounce: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
      expect(
        () => HipsTileLoader(
          cache: HipsTileCache(maxEntries: 1, maxBytes: 1024),
          fetcher: HipsTileFetcher(httpClient: server.build()),
          subdivisions: 0,
        ),
        throwsArgumentError,
      );
    });
  });
}
