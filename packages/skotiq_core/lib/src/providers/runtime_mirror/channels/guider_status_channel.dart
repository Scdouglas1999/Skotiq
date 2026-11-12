import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../backend/remote_host.dart';
import '../../../backend/skotiq_backend.dart';
import '../../../models/equipment/equipment_models.dart';
import '../../../models/phd2_models.dart';
import '../../../services/logging_service.dart';
import '../../backend_provider.dart';
import '../../equipment/guider_state_provider.dart';
import '../../guiding_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// Guiding events after which the guider's own status says something new.
/// Guide steps and star statistics are not among them: a client receives
/// those itself and derives its graph and RMS from them.
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
      if (mounted && identical(_ref.read(backendProvider), backend)) {
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
/// the rest, why it is held, and its last RMS.
///
/// A client follows guiding through the host's guiding events. This fills
/// what the events before it linked said, so a client that joins while the
/// host guides shows it guiding and not an idle guider with a Start button.
class GuiderStatusChannel extends RuntimeMirrorChannel<HostGuiderStatus?> {
  const GuiderStatusChannel();

  @override
  String get key => 'guiderStatus';

  @override
  get source => hostGuiderStatusProvider;

  @override
  Map<String, dynamic>? encode(HostGuiderStatus? value) {
    if (value == null || !value.status.connected) return null;
    final status = value.status;
    return {
      'deviceId': value.deviceId,
      'state': (value.state ?? _stateOf(status.state))?.name,
      'stopReason': status.stopReason,
      'rmsRa': finiteOrNull(status.rmsRa),
      'rmsDec': finiteOrNull(status.rmsDec),
      'rmsTotal': finiteOrNull(status.rmsTotal),
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
  }
}
