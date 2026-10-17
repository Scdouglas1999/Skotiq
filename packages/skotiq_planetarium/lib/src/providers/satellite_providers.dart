import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../astronomy/sgp4.dart';
import '../catalogs/satellite_catalog.dart';
import 'planetarium_providers.dart';

// Satellite toggle provider

/// Whether satellite overlay is enabled
final showSatellitesProvider = StateProvider<bool>((ref) => false);

// Satellite catalog provider

/// Singleton satellite catalog instance for TLE management
final satelliteCatalogProvider = Provider<SatelliteCatalog>((ref) {
  return SatelliteCatalog();
});

// TLE data provider

/// Loads bright satellite TLE data. Auto-refreshes when toggled on.
final satelliteTleProvider = FutureProvider<List<OrbitalElements>>((ref) async {
  final showSatellites = ref.watch(showSatellitesProvider);
  if (!showSatellites) return [];

  final catalog = ref.read(satelliteCatalogProvider);
  try {
    return await catalog.loadBrightSatellites();
  } catch (e) {
    developer.log(
      '[Satellite] Failed to load TLE data: $e',
      name: 'SatelliteProviders',
      level: 1000,
      error: e,
    );
    rethrow;
  }
});

// Current satellite positions provider

/// Satellite position state that updates every few seconds.
class SatellitePositionState {
  final List<SatelliteData> satellites;
  final DateTime lastUpdate;

  const SatellitePositionState({
    this.satellites = const [],
    required this.lastUpdate,
  });
}

/// Notifier that periodically recomputes satellite positions.
class SatellitePositionNotifier extends StateNotifier<SatellitePositionState> {
  final Ref _ref;
  Timer? _timer;

  SatellitePositionNotifier(this._ref)
    : super(SatellitePositionState(lastUpdate: DateTime.now())) {
    _startUpdates();

    // Listen for TLE data changes
    _ref.listen(satelliteTleProvider, (prev, next) {
      next.whenData((_) => _updatePositions());
    });

    // Listen for satellite toggle
    _ref.listen(showSatellitesProvider, (prev, next) {
      if (next) {
        _startUpdates();
      } else {
        _stopUpdates();
        state = SatellitePositionState(
          satellites: const [],
          lastUpdate: DateTime.now(),
        );
      }
    });
  }

  void _startUpdates() {
    _timer?.cancel();
    // Update every 2 seconds for smooth satellite motion
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      _updatePositions();
    });
    // Also do an initial update
    _updatePositions();
  }

  void _stopUpdates() {
    _timer?.cancel();
    _timer = null;
  }

  void _updatePositions() {
    if (!mounted) return;

    final showSatellites = _ref.read(showSatellitesProvider);
    if (!showSatellites) return;

    final tleData = _ref.read(satelliteTleProvider);
    final elements = tleData.valueOrNull;
    if (elements == null || elements.isEmpty) return;

    // A satellite's position on the sky is topocentric: no site, no pass to
    // draw.
    final site = _ref.read(observerLocationProvider).site;
    if (site == null) return;
    final timeState = _ref.read(observationTimeProvider);

    final satellites = SatelliteCatalog.computePositions(
      elements: elements,
      time: timeState.time,
      observerLatitude: site.latitude,
      observerLongitude: site.longitude,
    );

    if (!mounted) return;
    state = SatellitePositionState(
      satellites: satellites,
      lastUpdate: DateTime.now(),
    );
  }

  /// Force an immediate position update.
  void refresh() {
    _updatePositions();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final satellitePositionProvider =
    StateNotifierProvider<SatellitePositionNotifier, SatellitePositionState>((
      ref,
    ) {
      return SatellitePositionNotifier(ref);
    });

/// Convenience provider for just the satellite list.
final currentSatellitesProvider = Provider<List<SatelliteData>>((ref) {
  return ref.watch(satellitePositionProvider).satellites;
});

// Pass prediction provider

/// State for satellite pass predictions.
class PassPredictionState {
  final List<SatellitePass> passes;
  final bool isComputing;
  final String? error;

  const PassPredictionState({
    this.passes = const [],
    this.isComputing = false,
    this.error,
  });
}

typedef PassPredictionComputer =
    Future<List<SatellitePass>> Function({
      required List<OrbitalElements> elements,
      required double latitude,
      required double longitude,
      required DateTime startTime,
      required Duration predictionWindow,
    });

final passPredictionComputerProvider = Provider<PassPredictionComputer>((ref) {
  return ({
    required elements,
    required latitude,
    required longitude,
    required startTime,
    required predictionWindow,
  }) {
    return compute(
      _computePassesIsolate,
      _ComputePassesArgs(
        elements: elements,
        latitude: latitude,
        longitude: longitude,
        startTime: startTime,
        durationMinutes: predictionWindow.inMinutes,
      ),
    );
  };
});

/// Computes satellite pass predictions in the background.
class PassPredictionNotifier extends StateNotifier<PassPredictionState> {
  final Ref _ref;
  int _computeGeneration = 0;

  PassPredictionNotifier(this._ref) : super(const PassPredictionState()) {
    _ref.listen<bool>(showSatellitesProvider, (previous, next) {
      if (!next) {
        _computeGeneration++;
        state = const PassPredictionState();
        return;
      }
      _refreshForCurrentInputs();
    });
    _ref.listen<AsyncValue<List<OrbitalElements>>>(satelliteTleProvider, (
      previous,
      next,
    ) {
      if (_ref.read(showSatellitesProvider)) _refreshForCurrentInputs();
    });
    _ref.listen<PlanetariumObserver>(observerLocationProvider, (_, __) {
      if (_ref.read(showSatellitesProvider) &&
          _ref.read(satelliteTleProvider).valueOrNull?.isNotEmpty == true) {
        unawaited(computePasses());
      }
    });
  }

  void _refreshForCurrentInputs() {
    final tleData = _ref.read(satelliteTleProvider);
    final elements = tleData.valueOrNull;
    if (elements != null && elements.isNotEmpty) {
      unawaited(computePasses());
      return;
    }

    // Loading is expected immediately after the satellite layer is enabled.
    // Keep a spinner up and let the TLE listener start prediction when ready.
    _computeGeneration++;
    if (tleData.isLoading) {
      state = const PassPredictionState(isComputing: true);
    } else if (tleData.hasError) {
      state = PassPredictionState(
        error: 'Could not load satellite data: ${tleData.error}',
      );
    } else {
      state = const PassPredictionState(error: 'No satellite data loaded');
    }
  }

  /// Compute pass predictions for all loaded satellites.
  /// This can take several seconds for many satellites, so runs in isolate.
  Future<void> computePasses({
    Duration predictionWindow = const Duration(hours: 48),
  }) async {
    if (!mounted) return;
    if (!_ref.read(showSatellitesProvider)) {
      _computeGeneration++;
      state = const PassPredictionState();
      return;
    }
    if (predictionWindow <= Duration.zero) {
      _computeGeneration++;
      state = const PassPredictionState(
        error: 'Prediction window must be greater than zero',
      );
      return;
    }

    final tleData = _ref.read(satelliteTleProvider);
    final elements = tleData.valueOrNull;
    if (elements == null) {
      _refreshForCurrentInputs();
      return;
    }
    if (elements.isEmpty) {
      _computeGeneration++;
      state = const PassPredictionState(error: 'No satellite data loaded');
      return;
    }

    final site = _ref.read(observerLocationProvider).site;
    if (site == null) {
      _computeGeneration++;
      state = const PassPredictionState(
        error: 'Set an observing site to predict passes',
      );
      return;
    }
    final generation = ++_computeGeneration;

    state = const PassPredictionState(isComputing: true);

    try {
      final passes = await _ref.read(passPredictionComputerProvider)(
        elements: elements,
        latitude: site.latitude,
        longitude: site.longitude,
        startTime: DateTime.now().toUtc(),
        predictionWindow: predictionWindow,
      );

      if (!_canPublish(generation)) return;
      state = PassPredictionState(passes: passes);
    } catch (e) {
      if (!_canPublish(generation)) return;
      state = PassPredictionState(error: 'Pass prediction failed: $e');
    }
  }

  bool _canPublish(int generation) {
    return mounted &&
        generation == _computeGeneration &&
        _ref.read(showSatellitesProvider);
  }
}

/// Arguments for isolate computation.
class _ComputePassesArgs {
  final List<OrbitalElements> elements;
  final double latitude;
  final double longitude;
  final DateTime startTime;
  final int durationMinutes;

  _ComputePassesArgs({
    required this.elements,
    required this.latitude,
    required this.longitude,
    required this.startTime,
    required this.durationMinutes,
  });
}

/// Isolate function for pass prediction (CPU-intensive).
List<SatellitePass> _computePassesIsolate(_ComputePassesArgs args) {
  final allPasses = <SatellitePass>[];

  for (final elem in args.elements) {
    final passes = SatelliteCatalog.predictPasses(
      elements: elem,
      latitude: args.latitude,
      longitude: args.longitude,
      startTime: args.startTime,
      duration: Duration(minutes: args.durationMinutes),
      minElevation: 10.0, // Only include passes with max elev > 10 degrees
    );
    allPasses.addAll(passes);
  }

  // Sort all passes by rise time
  allPasses.sort((a, b) => a.riseTime.compareTo(b.riseTime));
  return allPasses;
}

final passPredictionProvider =
    StateNotifierProvider<PassPredictionNotifier, PassPredictionState>((ref) {
      return PassPredictionNotifier(ref);
    });

/// Provider for upcoming passes (future only).
final upcomingPassesProvider = Provider<List<SatellitePass>>((ref) {
  final state = ref.watch(passPredictionProvider);
  final now = DateTime.now();
  return state.passes.where((p) => p.setTime.isAfter(now)).toList();
});
