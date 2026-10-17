// Component C10 support — shared helpers for the app-level HiPS framing tile
// tests, all anchored on the committed real DSS2-colour C-FIX fixtures.
//
// This is the single place the C10 tests reach for:
//   * decoding committed JPEG fixture bytes into a `ui.Image` through the EXACT
//     production path (`ui.decodeImageFromList`, whose codec work runs off the
//     build thread on the engine's IO/raster workers — the anti-jank "decode is
//     never on the UI/build thread" requirement #1);
//   * a fixture-backed [HipsTileFetcher] that serves the committed bytes instead
//     of the network, so the real C5 fetch contract (off-thread decode,
//     cancellation, typed errors) is exercised with zero network access;
//   * a deterministic [HipsLoaderClock] so the C6 loader's debounce window is
//     driven explicitly (no real wall-clock waits, no flaky timing);
//   * resolving which of a visible tile set's ids are actually committed
//     fixtures (only a subset of any selection's tiles were bundled).
//
// Everything here is pure Dart + `dart:ui` + `dart:io` file reads; it imports no
// Flutter widget layer beyond the test binding the callers already initialise.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/hips/hips_tile_id.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_fetcher.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';

import '../../../fixtures/hips/fixture_field.dart' as fixture;

/// Decodes encoded image [bytes] into a [ui.Image] through the production
/// `ui.decodeImageFromList` path the framing provider and the C5 fetcher use.
///
/// This performs the codec work off the build thread on the engine's IO/raster
/// workers, so it never blocks the caller's frame — exactly the path the tile
/// layer relies on for the off-UI-thread-decode anti-jank guarantee.
Future<ui.Image> decodeFixtureImage(List<int> bytes) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromList(
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    completer.complete,
  );
  return completer.future;
}

/// Drives the C6 loader's async fetch/decode work to completion on the REAL
/// event loop and waits for [condition] to hold (condition-based waiting, not a
/// fixed-count drain).
///
/// Why this exists: the C6 loader performs its fetch + decode inside detached
/// `unawaited` continuations, and the decode goes through the engine's image
/// codec (`ui.decodeImageFromList`). Under [AutomatedTestWidgetsFlutterBinding]
/// (the binding a plain `test()` installs once `ensureInitialized()` is called),
/// those engine decode callbacks are only serviced while the test is executing
/// inside [TestWidgetsFlutterBinding.runAsync] AND real wall-clock time is
/// allowed to pass — a `Future.delayed(Duration.zero)` micro-drain in the
/// default fake-async zone never lets the codec complete, so the decoded image
/// never lands in the cache and the loader's snapshot stays empty.
///
/// [drive] performs the synchronous loader interaction that schedules work
/// (e.g. `loader.requestTiles(...)` then `clock.flush()`), and runs INSIDE the
/// real-async zone so any microtasks it spawns are serviced there. After it
/// returns, this pumps real (1 ms) ticks until [condition] is satisfied or
/// [maxTicks] elapse, then returns whether the condition held. A caller asserts
/// on the returned bool / the loader state so a stuck decode fails loudly rather
/// than hanging the suite.
///
/// This is the single, shared "settle the loader" primitive every C10 async/LOD
/// test uses, replacing per-file fixed-iteration drains that could not observe
/// the real decode.
Future<bool> settleLoaderUntil({
  required void Function() drive,
  required bool Function() condition,
  int maxTicks = 240,
}) async {
  final binding = TestWidgetsFlutterBinding.instance;
  var satisfied = false;
  await binding.runAsync(() async {
    drive();
    if (condition()) {
      satisfied = true;
      return;
    }
    for (var i = 0; i < maxTicks; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (condition()) {
        satisfied = true;
        return;
      }
    }
  });
  return satisfied;
}

/// Returns the committed JPEG bytes for [id] if it is part of the C-FIX set, or
/// `null` if that tile was not bundled (a visible-tile selection legitimately
/// includes tiles outside the committed sample).
List<int>? fixtureTileBytesOrNull(HipsTileId id) {
  if (!fixture.allTiles.contains(id)) return null;
  return fixture.readTileBytes(id);
}

/// The committed survey `properties`, parsed through the production C0 parser.
HipsProperties fixtureProperties() =>
    HipsProperties.parse(fixture.readPropertiesText());

/// A [HipsTileFetcher] that serves the committed C-FIX bytes instead of hitting
/// the network, decoding through the production codec path.
///
/// It extends the real fetcher (so the production type flows through the C6
/// loader and C7 provider unchanged) and overrides only the three fetch methods
/// to read committed bytes. Cancellation is honoured exactly like the real
/// fetcher: a cancelled token throws [HipsFetchCancelledException] before any
/// work, so the loader's supersede-on-pan path is exercised faithfully.
///
/// A tile / Allsky id with no committed bytes surfaces a [HipsFetchHttpException]
/// (a 404 stand-in) rather than silently returning a blank, so the loader
/// records the failure into the snapshot.
class FixtureTileFetcher extends HipsTileFetcher {
  /// Tile ids whose fetch should be delayed until [releaseDelayed] is called,
  /// so a test can hold a generation's fetches in flight to exercise cancel /
  /// supersede / never-blank-while-streaming behaviour deterministically.
  final Set<HipsTileId> _heldTiles = <HipsTileId>{};
  final List<Completer<void>> _heldGates = <Completer<void>>[];

  /// Count of fetch calls per tile id, so a test can assert dedup (a tile is
  /// fetched at most once across a burst of identical viewports).
  final Map<HipsTileId, int> tileFetchCounts = <HipsTileId, int>{};

  /// Count of Allsky fetches per order (dedup assertion for the base layer).
  final Map<int, int> allskyFetchCounts = <int, int>{};

  /// Count of property fetches (must be exactly one per survey).
  int propertiesFetchCount = 0;

  FixtureTileFetcher();

  /// Marks [ids] as held: their [fetchTile] futures will not resolve until
  /// [releaseHeld] is called, letting a test observe the in-flight / coarse
  /// fallback window.
  void hold(Iterable<HipsTileId> ids) => _heldTiles.addAll(ids);

  /// Releases all held fetches so their decoded images resolve.
  void releaseHeld() {
    for (final gate in _heldGates) {
      if (!gate.isCompleted) gate.complete();
    }
    _heldGates.clear();
  }

  @override
  Future<HipsProperties> fetchProperties(
    String baseUrl, {
    HipsFetchToken? token,
  }) async {
    if (token != null && token.isCancelled) {
      throw HipsFetchCancelledException('$baseUrl/properties');
    }
    propertiesFetchCount++;
    return fixtureProperties();
  }

  @override
  Future<ui.Image> fetchAllsky(
    String baseUrl,
    int order,
    HipsTileFormat format, {
    HipsFetchToken? token,
  }) async {
    final url = HipsTileId.allskyUrl(baseUrl, order, format);
    if (token != null && token.isCancelled) {
      throw HipsFetchCancelledException(url);
    }
    allskyFetchCounts[order] = (allskyFetchCounts[order] ?? 0) + 1;
    // The committed Allsky is at the survey min order; other orders 404.
    if (order != fixture.allskyOrder) {
      throw HipsFetchHttpException(
        'no committed Allsky at order $order',
        url,
        statusCode: 404,
      );
    }
    return decodeFixtureImage(fixture.readAllskyBytes());
  }

  @override
  Future<ui.Image> fetchTile(
    HipsTileId id,
    String baseUrl,
    HipsTileFormat format, {
    HipsFetchToken? token,
  }) async {
    final url = id.tileUrl(baseUrl, format);
    if (token != null && token.isCancelled) {
      throw HipsFetchCancelledException(url);
    }
    tileFetchCounts[id] = (tileFetchCounts[id] ?? 0) + 1;

    if (_heldTiles.contains(id)) {
      final gate = Completer<void>();
      _heldGates.add(gate);
      await gate.future;
      // Re-check cancellation after the hold: a superseded generation cancels
      // the token while we waited, and must surface as a cancellation.
      if (token != null && token.isCancelled) {
        throw HipsFetchCancelledException(url);
      }
    }

    final bytes = fixtureTileBytesOrNull(id);
    if (bytes == null) {
      // A 404 stand-in for a tile outside the committed sample: surfaced, not
      // silently blanked.
      throw HipsFetchHttpException(
        'tile $id is not part of the committed fixture set',
        url,
        statusCode: 404,
      );
    }
    return decodeFixtureImage(bytes);
  }
}

/// A manually-advanced [HipsLoaderClock] so the C6 loader's debounce is driven
/// deterministically: scheduled callbacks fire only when [flush] (or
/// [advanceAndFlush]) is called, never on a real wall-clock.
class ManualLoaderClock implements HipsLoaderClock {
  final List<_ManualTimer> _pending = <_ManualTimer>[];

  /// Number of currently-pending (scheduled, not yet fired/cancelled) timers.
  int get pendingCount => _pending.where((t) => t.isActive).length;

  @override
  HipsLoaderTimer schedule(Duration delay, void Function() callback) {
    final timer = _ManualTimer(callback, this);
    _pending.add(timer);
    return timer;
  }

  /// Fires every currently-pending callback in scheduling order, clearing the
  /// queue. A debounce that restarts the timer enqueues a fresh one, so callers
  /// flush until [pendingCount] is zero when they want the burst fully drained.
  void flush() {
    final due = _pending.where((t) => t.isActive).toList();
    _pending.clear();
    for (final timer in due) {
      timer.fire();
    }
  }

  void _remove(_ManualTimer timer) => _pending.remove(timer);
}

class _ManualTimer implements HipsLoaderTimer {
  final void Function() _callback;
  final ManualLoaderClock _owner;
  bool _active = true;

  _ManualTimer(this._callback, this._owner);

  @override
  bool get isActive => _active;

  @override
  void cancel() {
    _active = false;
    _owner._remove(this);
  }

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }
}
