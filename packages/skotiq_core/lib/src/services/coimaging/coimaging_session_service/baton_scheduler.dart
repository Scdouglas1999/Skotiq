part of '../coimaging_session_service.dart';

/// The rig's observing site (degrees) the longitude-baton automation evaluates
/// each session target's altitude from. Resolved per tick so a relocated /
/// re-configured site is picked up without restarting the scheduler.
typedef CoImagingSiteResolver =
    Future<({double latitudeDeg, double longitudeDeg})?> Function();

/// Client-side scheduler tick for the longitude baton.
///
/// On a fixed interval it iterates this rig's active co-imaging memberships and
/// drives [CoImagingSessionService.evaluateBaton] for each at the rig's site:
/// when a session target rises above the imaging floor the baton is claimed; when
/// it sets the baton is released east — so an unattended appliance hands the
/// night on without operator input. Each tick aggregates every membership into a
/// SINGLE [CoImagingBatonReconciliation] and hands it to one injected
/// [onReconcile] callback, so the engine wiring (resume/pause the autopilot)
/// lives in the provider layer, stays pure + testable here, and drives one
/// deterministic decision over the single global autopilot per tick rather than
/// per-membership callbacks fighting over it.
class CoImagingBatonScheduler {
  CoImagingBatonScheduler({
    required CoImagingSessionService service,
    required CoImagingSiteResolver siteResolver,
    required LoggingService logger,
    Future<void> Function(CoImagingBatonReconciliation reconciliation)?
    onReconcile,
    Duration interval = const Duration(minutes: 5),
    double altitudeFloorDeg =
        CoImagingSessionService.defaultImagingAltitudeFloorDeg,
  }) : _service = service,
       _siteResolver = siteResolver,
       _logger = logger,
       _onReconcile = onReconcile,
       _interval = interval,
       _altitudeFloorDeg = altitudeFloorDeg;

  final CoImagingSessionService _service;
  final CoImagingSiteResolver _siteResolver;
  final LoggingService _logger;

  /// Single reconciled engine hook: invoked once per tick with the aggregated
  /// held/released split across ALL memberships. The engine policy lives in the
  /// provider layer (resume/pause the autopilot) so this stays pure + testable,
  /// and a single deterministic decision drives the one global autopilot per
  /// tick — never per-membership callbacks fighting over it.
  final Future<void> Function(CoImagingBatonReconciliation reconciliation)?
  _onReconcile;
  final Duration _interval;
  final double _altitudeFloorDeg;

  static const _logSource = 'CoImagingBatonScheduler';

  Timer? _timer;
  bool _ticking = false;

  /// Start the periodic tick (no-op if already running). Runs one tick
  /// immediately so a relaunch mid-night re-claims/releases without waiting a
  /// full interval.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(_interval, (_) => unawaited(_tick()));
    unawaited(_tick());
  }

  /// Stop the periodic tick.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One evaluation pass over every active membership. Public so the provider
  /// (or a test) can drive a single deterministic tick.
  Future<void> tickOnce() => _tick();

  Future<void> _tick() async {
    if (_ticking) return; // never overlap a slow network tick with the next.
    _ticking = true;
    try {
      final site = await _siteResolver();
      if (site == null) {
        // No configured site -> altitude is undefined; skip without churning the
        // baton. Logged once-per-tick at fine level, not an error.
        _logger.debug(
          'baton tick skipped: no observing site configured.',
          source: _logSource,
        );
        return;
      }
      final memberships = await _service.activeMemberships();
      final held = <CoImagingSessionRow>[];
      final released = <CoImagingSessionRow>[];
      for (final row in memberships) {
        try {
          final decision = await _service.evaluateBaton(
            row.sessionId,
            latitudeDeg: site.latitudeDeg,
            longitudeDeg: site.longitudeDeg,
            altitudeFloorDeg: _altitudeFloorDeg,
          );
          (decision.holdsBaton ? held : released).add(row);
        } catch (e) {
          // A membership we could not evaluate this tick is left out of BOTH
          // lists: we neither claim nor disclaim its baton, so a transient hub
          // error never strands the autopilot (no resume, and no pause of a
          // target we can no longer confirm has set).
          _logger.warning(
            'baton tick for session ${row.sessionId} failed: $e',
            source: _logSource,
          );
        }
      }
      // One reconciled decision per tick over the single global autopilot.
      await _onReconcile?.call(
        CoImagingBatonReconciliation(held: held, released: released),
      );
    } catch (e) {
      _logger.warning('baton tick failed: $e', source: _logSource);
    } finally {
      _ticking = false;
    }
  }
}
