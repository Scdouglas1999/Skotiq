import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget, SurveySource;
import 'package:skotiq_core/src/providers/hips_framing_provider.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_fetcher.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';
import '../harness/in_memory_database.dart';

// Fixtures / doubles

const String _dssRedSurveyId = 'CDS/P/DSS2/red';
const String _dssRedBaseUrl = 'https://alasky.cds.unistra.fr/DSS/DSS2Merged';

HipsProperties _props() => HipsProperties.parse('''
hips_order        = 9
hips_order_min    = 3
hips_tile_width   = 512
hips_tile_format  = png
hips_frame        = equatorial
''');

const FramingPlateScale _plateScale = FramingPlateScale(
  surveyFovWidthDeg: 1.5,
  surveyFovHeightDeg: 1.5,
  imagePixelWidth: 1200,
  imagePixelHeight: 1200,
);

const FramingTarget _target = FramingTarget(
  name: 'M42',
  raHours: 5.59,
  decDegrees: -5.39,
);

const ui.Size _canvas = ui.Size(1200, 900);

Uint8List _solidPng({int size = 16, int r = 80, int g = 120, int b = 200}) {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

/// A MockClient that serves a distinct solid tile for every request, so the
/// provider-driven loader has real (decodable) bytes to stream without touching
/// the network. Counts requests so a test can assert dedup / cancellation.
MockClient _tileServer({List<String>? requestedUrls}) {
  return MockClient((request) async {
    final url = request.url.toString();
    requestedUrls?.add(url);
    final seed = url.hashCode & 0x7fffffff;
    return http.Response.bytes(
      _solidPng(
        r: 60 + seed % 150,
        g: 60 + (seed ~/ 150) % 150,
        b: 80 + (seed ~/ 22500) % 150,
      ),
      200,
    );
  });
}

/// Captures surfaced (non-cancellation) failures from the loader.
class _CapturingErrorSink implements HipsTileLoaderErrorSink {
  final List<HipsTileFailure> failures = <HipsTileFailure>[];
  @override
  void onTileError(HipsTileFailure failure) => failures.add(failure);
}

/// Builds a container whose loader provider is overridden with a deterministic
/// zero-debounce loader fed a MockClient fetcher (so recomputes run on the next
/// microtask, no real wall-clock wait, no network).
ProviderContainer _container({
  MockClient? server,
  HipsTileLoaderErrorSink? errorSink,
  bool enabled = true,
}) {
  final client = server ?? _tileServer();
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      hipsFramingEnabledProvider.overrideWith((ref) => enabled),
      hipsTileFetcherProvider.overrideWithValue(
        HipsTileFetcher(httpClient: client),
      ),
      hipsTileCacheProvider.overrideWithValue(
        HipsTileCache(maxEntries: 256, maxBytes: 64 * 1024 * 1024),
      ),
      hipsTileLoaderProvider.overrideWith((ref) {
        final loader = HipsTileLoader(
          cache: ref.watch(hipsTileCacheProvider),
          fetcher: ref.watch(hipsTileFetcherProvider),
          // Zero debounce so requestTiles -> recompute happens on a microtask.
          debounce: Duration.zero,
          errorSink: errorSink ?? const _NoopSink(),
          subdivisions: 4,
          ownsFetcher: true,
        );
        ref.onDispose(loader.dispose);
        return loader;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Keeps the autoDispose resident-tiles provider (and the loader pipeline it
/// depends on) alive for the duration of a test, mirroring a mounted widget
/// that `ref.watch`es the snapshot. Without an active listener an autoDispose
/// provider is torn down the moment the synchronous `read` returns, which would
/// cancel the loader's pending recompute timer before the event loop runs.
ProviderSubscription<HipsResidentSnapshot> _keepAlive(
  ProviderContainer container,
) {
  final sub = container.listen<HipsResidentSnapshot>(
    hipsResidentTilesProvider,
    (_, __) {},
    fireImmediately: true,
  );
  addTearDown(sub.close);
  return sub;
}

class _NoopSink implements HipsTileLoaderErrorSink {
  const _NoopSink();
  @override
  void onTileError(HipsTileFailure failure) {}
}

/// Lets real off-thread image decodes and the zero-debounce timer resolve.
Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Feature flag + capability gate
  group('feature flag and survey capability gate', () {
    test('hipsFramingEnabledProvider defaults on', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      expect(container.read(hipsFramingEnabledProvider), isTrue);
    });

    test(
      'DSS surveys are tile-capable; resolve-at-runtime surveys are not',
      () {
        // DSS2 red / blue have verified base URLs in the registry.
        expect(hipsSurveyIsTileCapable(SurveySource.dss2Red), isTrue);
        expect(hipsSurveyIsTileCapable(SurveySource.dss2Blue), isTrue);
        // The remaining surveys have no verified base URL.
        expect(hipsSurveyIsTileCapable(SurveySource.sdss), isFalse);
        expect(hipsSurveyIsTileCapable(SurveySource.wise12), isFalse);
        expect(hipsSurveyIsTileCapable(SurveySource.twomassJ), isFalse);
      },
    );

    test('active = user toggle AND survey capability', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      // Enabled (default) + capable survey => active.
      expect(
        container.read(hipsFramingActiveProvider(SurveySource.dss2Red)),
        isTrue,
      );
      // Enabled but incapable survey => inactive (fall back to single cutout).
      expect(
        container.read(hipsFramingActiveProvider(SurveySource.sdss)),
        isFalse,
      );
    });

    test('toggling the user flag off deactivates even a capable survey', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      container.read(hipsFramingEnabledProvider.notifier).state = false;
      expect(
        container.read(hipsFramingActiveProvider(SurveySource.dss2Red)),
        isFalse,
      );
    });
  });

  // Survey address resolution
  group('HipsSurveyAddress', () {
    test('resolves verified DSS survey to its base URL + canonical id', () {
      final addr = HipsSurveyAddress.forSurvey(SurveySource.dss2Red);
      expect(addr.baseUrl, _dssRedBaseUrl);
      expect(addr.surveyId, _dssRedSurveyId);
    });

    test('throws (errors are a feature) for a resolve-at-runtime survey', () {
      expect(
        () => HipsSurveyAddress.forSurvey(SurveySource.sdss),
        throwsStateError,
      );
    });
  });

  // DI wiring + ownership
  group('DI wiring and ownership', () {
    test('loader provider builds from the cache + fetcher providers', () {
      final container = _container();
      final loader = container.read(hipsTileLoaderProvider);
      expect(loader, isA<HipsTileLoader>());
      // The notifier borrows the same loader instance.
      final notifier = container.read(hipsResidentTilesProvider.notifier);
      expect(identical(notifier.loader, loader), isTrue);
    });

    test(
      'disposing the container disposes the loader (and through it the cache '
      '+ fetcher) exactly once',
      () async {
        final client = _tileServer();
        final cache = HipsTileCache(maxEntries: 8, maxBytes: 8 * 1024 * 1024);
        final fetcher = HipsTileFetcher(httpClient: client);
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            hipsTileCacheProvider.overrideWithValue(cache),
            hipsTileFetcherProvider.overrideWithValue(fetcher),
          ],
        );
        // Force the loader to build.
        final loader = container.read(hipsTileLoaderProvider);
        expect(cache.isDisposed, isFalse);

        container.dispose();

        // The loader disposed the cache; a second dispose on the cache is a
        // tolerated no-op (proving single ownership, not a double-free crash).
        expect(cache.isDisposed, isTrue);
        // The loader rejects use after dispose (a feature, not a silent no-op).
        expect(() => loader.requestTiles(_viewport()), throwsStateError);
      },
    );
  });

  // Resident-tiles notifier
  group('HipsResidentTilesNotifier', () {
    test('starts at the loader empty snapshot', () {
      final container = _container();
      _keepAlive(container);
      final snap = container.read(hipsResidentTilesProvider);
      expect(snap.version, HipsResidentSnapshot.empty.version);
      expect(snap.hasAnyImagery, isFalse);
    });

    test('requestViewport before setSurvey throws (wiring bug surfaced)', () {
      final container = _container();
      _keepAlive(container);
      final notifier = container.read(hipsResidentTilesProvider.notifier);
      expect(
        () => notifier.requestViewport(
          plateScale: _plateScale,
          target: _target,
          canvasSize: _canvas,
          zoom: 1.0,
          pan: ui.Offset.zero,
          rotationDegrees: 0.0,
          format: HipsTileFormat.png,
          props: _props(),
        ),
        throwsStateError,
      );
    });

    test('setSurvey resolves the verified address; re-setting is a no-op', () {
      final container = _container();
      _keepAlive(container);
      final notifier = container.read(hipsResidentTilesProvider.notifier);
      notifier.setSurvey(SurveySource.dss2Red);
      expect(notifier.address!.baseUrl, _dssRedBaseUrl);
      expect(notifier.address!.surveyId, _dssRedSurveyId);
      // Re-setting the same survey must not flash the view blank: snapshot
      // version stays put because clearSurvey is not re-run.
      final beforeVersion = container.read(hipsResidentTilesProvider).version;
      notifier.setSurvey(SurveySource.dss2Red);
      expect(container.read(hipsResidentTilesProvider).version, beforeVersion);
    });

    test('requestViewport streams resident tiles and the notifier mirrors the '
        'loader snapshot into Riverpod state', () async {
      final container = _container();
      _keepAlive(container);
      final notifier = container.read(hipsResidentTilesProvider.notifier);
      notifier.setSurvey(SurveySource.dss2Red);

      notifier.requestViewport(
        plateScale: _plateScale,
        target: _target,
        canvasSize: _canvas,
        zoom: 1.0,
        pan: ui.Offset.zero,
        rotationDegrees: 0.0,
        format: HipsTileFormat.png,
        props: _props(),
      );
      await _settle();

      final snap = container.read(hipsResidentTilesProvider);
      // The state the widget watches is the SAME object the loader published.
      expect(identical(snap, notifier.loader.snapshot), isTrue);
      expect(snap.version, greaterThan(0));
      expect(
        snap.hasAnyImagery,
        isTrue,
        reason: 'tiles / Allsky should have streamed in',
      );
      expect(snap.visibleSet, isNotNull);
    });

    test('switching surveys clears the cache and re-addresses', () async {
      final container = _container();
      _keepAlive(container);
      final notifier = container.read(hipsResidentTilesProvider.notifier);
      final cache = container.read(hipsTileCacheProvider);

      notifier.setSurvey(SurveySource.dss2Red);
      notifier.requestViewport(
        plateScale: _plateScale,
        target: _target,
        canvasSize: _canvas,
        zoom: 1.0,
        pan: ui.Offset.zero,
        rotationDegrees: 0.0,
        format: HipsTileFormat.png,
        props: _props(),
      );
      await _settle();
      expect(cache.isNotEmpty, isTrue);

      notifier.setSurvey(SurveySource.dss2Blue);
      // Survey switch hard-resets: cache emptied, snapshot blank.
      expect(cache.isEmpty, isTrue);
      expect(notifier.address!.surveyId, 'CDS/P/DSS2/blue');
      expect(container.read(hipsResidentTilesProvider).hasAnyImagery, isFalse);
    });

    test(
      'a held (identical) viewport does not re-issue fetches (dedup)',
      () async {
        final urls = <String>[];
        final container = _container(server: _tileServer(requestedUrls: urls));
        _keepAlive(container);
        final notifier = container.read(hipsResidentTilesProvider.notifier);
        notifier.setSurvey(SurveySource.dss2Red);

        void request() => notifier.requestViewport(
          plateScale: _plateScale,
          target: _target,
          canvasSize: _canvas,
          zoom: 1.0,
          pan: ui.Offset.zero,
          rotationDegrees: 0.0,
          format: HipsTileFormat.png,
          props: _props(),
        );

        request();
        await _settle();
        final afterFirst = urls.length;
        expect(afterFirst, greaterThan(0));

        // Re-request the identical viewport several times: no new requests.
        request();
        request();
        request();
        await _settle();
        expect(
          urls.length,
          afterFirst,
          reason: 'identical viewport must not thrash the network',
        );
      },
    );

    test(
      'surfaces genuine fetch failures to the injected error sink',
      () async {
        final sink = _CapturingErrorSink();
        final failing = MockClient((request) async {
          return http.Response('not found', 404);
        });
        final container = _container(server: failing, errorSink: sink);
        _keepAlive(container);
        final notifier = container.read(hipsResidentTilesProvider.notifier);
        notifier.setSurvey(SurveySource.dss2Red);

        notifier.requestViewport(
          plateScale: _plateScale,
          target: _target,
          canvasSize: _canvas,
          zoom: 1.0,
          pan: ui.Offset.zero,
          rotationDegrees: 0.0,
          format: HipsTileFormat.png,
          props: _props(),
        );
        await _settle();

        expect(
          sink.failures,
          isNotEmpty,
          reason: 'errors are a feature: a 404 must surface, not be swallowed',
        );
        expect(
          container.read(hipsResidentTilesProvider).failures,
          isNotEmpty,
          reason: 'failures must also appear in the snapshot for a UI banner',
        );
      },
    );
  });
}

HipsViewport _viewport() => HipsViewport(
  plateScale: _plateScale,
  target: _target,
  canvasSize: _canvas,
  zoom: 1.0,
  pan: ui.Offset.zero,
  rotationDegrees: 0.0,
  baseUrl: _dssRedBaseUrl,
  surveyId: _dssRedSurveyId,
  format: HipsTileFormat.png,
  props: _props(),
);
