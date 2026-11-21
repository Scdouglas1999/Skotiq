import '../../async_scope.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../backend/remote_host.dart';
import '../../../backend/skotiq_backend.dart';
import '../../../models/equipment/equipment_models.dart';
import '../../../models/phd2_models.dart';
import '../../backend_provider.dart';
import '../../equipment/guider_state_provider.dart';
import '../../guiding_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';
import '../../../models/backend/backend_types.dart';
import '../../logging_service_provider.dart';

/// Guiding events after which the guider's own status says something new.
/// Guide steps are not among them: the graph they build is published with
/// the status, on its own timer, rather than by re-reading the guider.
const _statusChangingEvents = <String>{
  'Connected',
  'Disconnected',
  'AppState',
  'GuidingStarted',
  'GuidingStopped',
  'Paused',
  'Resumed',
  'StarLost',
  'Settling',
  'SettleDone',
  'LoopingExposures',
  'Calibrating',
  'CalibrationComplete',
  'StopReason',
};

/// How long after the last guiding event of a burst the status is read again.
/// The guider can still report the state it is leaving when the event that
/// announces the change arrives.
const Duration _statusSettle = Duration(seconds: 2);

/// What is known of the host's guider: the state its guiding events since it
/// connected leave it in ([state], null before the first), and the status it
/// last reported about itself.
typedef HostGuiderStatus = ({
  String deviceId,
  Phd2State? state,
  Phd2Status status,
});

/// Follows the host's guider for the guider channel: its state from the
/// guiding events, and a status read whenever an event says the status
/// changed (the guiding providers are filled only while a guiding screen is
/// open, and a status can still name the state the guider just left).
class HostGuiderStatusNotifier extends StateNotifier<HostGuiderStatus?> {
  HostGuiderStatusNotifier(this._ref) : super(null) {
    _ref.listen<SkotiqBackend>(backendProvider, (_, next) => _bind(next));
    _ref.listen<(String?, DeviceConnectionState)>(
      guiderStateProvider.select((s) => (s.deviceId, s.connectionState)),
      (previous, next) {
        if (previous?.$1 != next.$1) _eventState = null;
        _request();
      },
    );
    _bind(_ref.read(backendProvider));
  }

  final Ref _ref;
  StreamSubscription<SkotiqEvent>? _events;
  Timer? _settle;
  bool _reading = false;
  Phd2State? _eventState;

  void _bind(SkotiqBackend backend) {
    unawaited(_events?.cancel());
    _events = null;
    _settle?.cancel();
    if (!backend.ownsDeviceBridge) {
      state = null;
      return;
    }
    _events = backend.eventStream.listen((event) {
      if (event.category != EventCategory.guiding) return;
      final after = phd2StateAfterEvent(event.eventType, event.data);
      final known = state;
      if (after != null) {
        _eventState = after;
        if (known != null && known.state != after) {
          state = (
            deviceId: known.deviceId,
            state: after,
            status: known.status,
          );
        }
      }
      if (_statusChangingEvents.contains(event.eventType)) _request();
    });
    unawaited(_read());
  }

  /// One read at the first event of a burst and one after its last.
  void _request() {
    final inBurst = _settle?.isActive ?? false;
    _settle?.cancel();
    _settle = Timer(_statusSettle, () => unawaited(_read()));
    if (!inBurst) unawaited(_read());
  }

  Future<void> _read() async {
    if (_reading || !mounted) return;
    final backend = _ref.read(backendProvider);
    if (!backend.ownsDeviceBridge) return;
    final deviceId = _ref.read(guiderStateProvider).deviceId;
    if (deviceId == null) {
      state = null;
      return;
    }
    _reading = true;
    try {
      final status = await backend.guiderGetStatus();
      if (mounted && _ref.backendScopeOver(backend).isCurrent) {
        state = (deviceId: deviceId, state: _eventState, status: status);
      }
    } on Object catch (e) {
      // The last status stands; the next guiding event reads again.
      if (mounted) {
        _ref
            .read(loggingServiceProvider)
            .debug(
              'Guider status not read for the mirror: $e',
              source: 'HostRuntimeMirror',
            );
      }
    } finally {
      _reading = false;
    }
  }

  @override
  void dispose() {
    _settle?.cancel();
    unawaited(_events?.cancel());
    super.dispose();
  }
}

final hostGuiderStatusProvider =
    StateNotifierProvider<HostGuiderStatusNotifier, HostGuiderStatus?>(
      HostGuiderStatusNotifier.new,
    );

/// The guider state a status names, for a guider no event has spoken for
/// yet. A status also says `Connected` for an idle guider and `Settling`,
/// which no AppState event does.
Phd2State? _stateOf(String? status) => switch (status) {
  'Connected' => Phd2State.stopped,
  'Settling' => Phd2State.settling,
  _ => phd2StateFromAppState(status),
};

/// The state the host's guider reports: guiding, stopped, calibrating and
/// the rest, why it is held, its RMS, and the guide graph a late joiner
/// missed.
///
/// A client follows guiding through the host's guiding events. This fills
/// what the events before it linked said, so a client that joins while the
/// host guides shows it guiding and not an idle guider with a Start button.
/// The graph and the totals travel here, throttled, so the client does not
/// mix a partial event stream into the host's RMS. The all-night trace stays
/// on `GET /api/runtime/night-history`.
class GuiderStatusChannel extends RuntimeMirrorChannel<HostGuiderStatus?> {
  const GuiderStatusChannel();

  @override
  String get key => 'guiderStatus';

  @override
  get source => hostGuiderStatusProvider;

  /// Status changes publish at once. The graph is large, so a burst of guide
  /// steps becomes one publish.
  static const Duration graphInterval = Duration(milliseconds: 250);

  @override
  ProviderSubscription<HostGuiderStatus?> listen(
    Ref ref,
    void Function(HostGuiderStatus? value) onChange,
  ) {
    Timer? graph;
    ref.onDispose(() {
      graph?.cancel();
    });
    void scheduleGraph() {
      graph ??= Timer(graphInterval, () {
        graph = null;
        onChange(ref.read(source));
      });
    }

    ref.listen(guideGraphProvider, (_, _) => scheduleGraph());
    ref.listen(guideStatsProvider, (_, _) => scheduleGraph());
    ref.listen(targetDisplayHistoryProvider, (_, _) => scheduleGraph());
    ref.listen(calibrationStateProvider, (_, _) => scheduleGraph());
    ref.listen(lockPositionProvider, (_, _) => scheduleGraph());
    ref.listen(starLostEventProvider, (_, _) => scheduleGraph());
    ref.listen(guiderSettleTimeoutProvider, (_, _) => scheduleGraph());
    ref.listen(
      guiderStateProvider.select((s) => s.pixelScaleArcsecPerPixel),
      (_, _) => scheduleGraph(),
    );
    return ref.listen<HostGuiderStatus?>(source, (_, next) => onChange(next));
  }

  @override
  Map<String, dynamic>? encode(HostGuiderStatus? value) => null;

  @override
  Map<String, dynamic>? encodeCurrent(ProviderContainer container) {
    final value = container.read(source);
    if (value == null || !value.status.connected) return null;
    final status = value.status;
    final stats = container.read(guideStatsProvider);
    final lock = container.read(lockPositionProvider);
    final timeout = container.read(guiderSettleTimeoutProvider);
    final lost = container.read(starLostEventProvider);
    return {
      'deviceId': value.deviceId,
      'state': (value.state ?? _stateOf(status.state))?.name,
      'stopReason': status.stopReason,
      'rmsRa': finiteOrNull(status.rmsRa),
      'rmsDec': finiteOrNull(status.rmsDec),
      'rmsTotal': finiteOrNull(status.rmsTotal),
      'stats': stats.toJson(),
      'graph': [
        for (final point in container.read(guideGraphProvider))
          if (point.ra.isFinite && point.dec.isFinite)
            [point.time.millisecondsSinceEpoch, point.ra, point.dec],
      ],
      'target': [
        for (final point in container.read(targetDisplayHistoryProvider))
          if (point.raError.isFinite && point.decError.isFinite) point.toJson(),
      ],
      'calibration': container.read(calibrationStateProvider).toJson(),
      'lock': lock == null
          ? null
          : {'x': finiteOrNull(lock.x), 'y': finiteOrNull(lock.y)},
      'pixelScale': finiteOrNull(
        container.read(guiderStateProvider).pixelScaleArcsecPerPixel,
      ),
      'starLostAt': lost?.millisecondsSinceEpoch,
      'settleTimeout': timeout == null
          ? null
          : {'at': timeout.at.millisecondsSinceEpoch, 'error': timeout.error},
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (context.networkBackend == null || value == null) return;
    final guider = context.read(guiderStateProvider.notifier);
    final name = jsonString(value['state']);
    final state = Phd2State.values
        .where((candidate) => candidate.name == name)
        .firstOrNull;
    if (state != null) {
      context.read(phd2StateProvider.notifier).state = state;
      guider.setGuiding(state == Phd2State.guiding);
    }
    // Only a reason is applied: the run status, which the host always sends,
    // is what clears it.
    final stopReason = jsonString(value['stopReason']);
    if (stopReason != null && stopReason.isNotEmpty) {
      context.read(guidingStopReasonProvider.notifier).state = stopReason;
    }
    final rmsTotal = jsonDouble(value['rmsTotal']);
    if (rmsTotal != null && rmsTotal > 0) {
      guider.updateRms(
        jsonDouble(value['rmsRa']) ?? 0,
        jsonDouble(value['rmsDec']) ?? 0,
        rmsTotal,
      );
    }
    if (!value.containsKey('graph')) return;
    // From here the host's totals are the graph. Folding GuideStep events
    // on top of them would mix a partial stream into the host's RMS.
    context.read(hostGuidingMirrorActiveProvider.notifier).state = true;
    final statsRaw = value['stats'];
    if (statsRaw is Map) {
      final stats = Phd2GuideStats.fromJson(
        Map<String, dynamic>.from(statsRaw),
      );
      context.read(guideStatsProvider.notifier).applyHostStats(stats);
      // A status read can name an RMS before any guide step has been
      // collected. Zero totals from an empty graph must not wipe that.
      if (stats.frameCount > 0) {
        guider.updateRms(stats.rmsRa, stats.rmsDec, stats.rmsTotal);
      }
    }
    final graph = <GuideGraphPoint>[];
    final rawGraph = value['graph'];
    if (rawGraph is List) {
      for (final row in rawGraph) {
        if (row is! List || row.length != 3) continue;
        final at = row[0];
        final ra = row[1];
        final dec = row[2];
        if (at is! num || ra is! num || dec is! num) continue;
        final raValue = ra.toDouble();
        final decValue = dec.toDouble();
        if (!raValue.isFinite || !decValue.isFinite) continue;
        graph.add(
          GuideGraphPoint(
            raValue,
            decValue,
            DateTime.fromMillisecondsSinceEpoch(at.toInt()),
          ),
        );
      }
    }
    context.read(guideGraphProvider.notifier).applyHostHistory(graph);
    final target = <GuideErrorPoint>[];
    final rawTarget = value['target'];
    if (rawTarget is List) {
      for (final row in rawTarget) {
        if (row is! Map) continue;
        try {
          final point = GuideErrorPoint.fromJson(
            Map<String, dynamic>.from(row),
          );
          if (point.raError.isFinite && point.decError.isFinite) {
            target.add(point);
          }
        } on Object {
          continue;
        }
      }
    }
    context
        .read(targetDisplayHistoryProvider.notifier)
        .applyHostHistory(target);
    final calibration = value['calibration'];
    if (calibration is Map) {
      context
          .read(calibrationStateProvider.notifier)
          .applyHostState(
            Phd2CalibrationData.fromJson(
              Map<String, dynamic>.from(calibration),
            ),
          );
    }
    final lock = value['lock'];
    context
        .read(lockPositionProvider.notifier)
        .applyHostPosition(
          lock is Map && lock['x'] is num && lock['y'] is num
              ? (
                  x: (lock['x'] as num).toDouble(),
                  y: (lock['y'] as num).toDouble(),
                )
              : null,
        );
    guider.setPixelScale(jsonDouble(value['pixelScale']));
    context.read(starLostEventProvider.notifier).state = jsonInstant(
      value['starLostAt'],
    );
    final timeout = value['settleTimeout'];
    final at = timeout is Map ? jsonInstant(timeout['at']) : null;
    context.read(guiderSettleTimeoutProvider.notifier).state = at == null
        ? null
        : (at: at, error: jsonString(timeout['error']) ?? '');
  }
}
