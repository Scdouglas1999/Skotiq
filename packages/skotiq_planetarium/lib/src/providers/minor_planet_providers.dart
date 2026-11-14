import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'element_refresh_providers.dart';
import 'planetarium_providers.dart';

/// Whether asteroid/comet overlay is enabled
final showMinorPlanetsProvider = StateProvider<bool>((ref) => false);

class MinorPlanetPositionState {
  final List<MinorBodyData> bodies;
  final DateTime lastUpdate;

  const MinorPlanetPositionState({
    this.bodies = const [],
    required this.lastUpdate,
  });
}

/// Notifier that periodically recomputes minor planet positions.
///
/// Updates every 30 seconds (asteroids move slowly — sub-arcsecond per second).
class MinorPlanetPositionNotifier
    extends StateNotifier<MinorPlanetPositionState> {
  final Ref _ref;
  Timer? _timer;

  MinorPlanetPositionNotifier(this._ref)
    : super(MinorPlanetPositionState(lastUpdate: DateTime.now())) {
    _ref.listen(showMinorPlanetsProvider, (prev, next) {
      if (next) {
        _startUpdates();
      } else {
        _stopUpdates();
        if (mounted) {
          state = MinorPlanetPositionState(
            bodies: const [],
            lastUpdate: DateTime.now(),
          );
        }
      }
    });

    if (_ref.read(showMinorPlanetsProvider)) {
      _startUpdates();
    }
  }

  void _startUpdates() {
    _timer?.cancel();
    // Update every 30 seconds — asteroids move slowly
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      _updatePositions();
    });
    _updatePositions();
  }

  void _stopUpdates() {
    _timer?.cancel();
    _timer = null;
  }

  void _updatePositions() {
    if (!mounted) return;

    final show = _ref.read(showMinorPlanetsProvider);
    if (!show) return;

    final timeState = _ref.read(observationTimeProvider);

    try {
      final bodies = KeplerianPropagator.computePositions(
        elements: _ref.read(effectiveMinorBodyElementsProvider),
        time: timeState.time,
      );

      if (!mounted) return;
      state = MinorPlanetPositionState(
        bodies: bodies,
        lastUpdate: DateTime.now(),
      );
    } catch (e) {
      developer.log(
        '[MinorPlanet] Position computation error: $e',
        name: 'MinorPlanetProviders',
        level: 900,
        error: e,
      );
    }
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

final minorPlanetPositionProvider =
    StateNotifierProvider<
      MinorPlanetPositionNotifier,
      MinorPlanetPositionState
    >((ref) {
      return MinorPlanetPositionNotifier(ref);
    });

/// Convenience provider for just the minor body list.
final currentMinorPlanetsProvider = Provider<List<MinorBodyData>>((ref) {
  return ref.watch(minorPlanetPositionProvider).bodies;
});
