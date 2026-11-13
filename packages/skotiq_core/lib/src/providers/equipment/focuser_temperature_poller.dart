import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/skotiq_backend.dart';
import '../../models/equipment/equipment_models.dart';
import '../backend_provider.dart';
import 'focuser_state_provider.dart';
import '../logging_service_provider.dart';

/// Reads a connected focuser's temperature on a fixed cadence on the machine
/// that owns the rig.
///
/// No driver sends a temperature event, so the focuser's temperature was read
/// only at connect and after a move. The host's own screens then showed the
/// connect-time value for the rest of the night (19.2 °C while the focuser
/// reported 18.1 °C), and the idle temperature compensation never saw the
/// drift it is meant to follow. A linked client is kept current by the remote
/// re-hydrate, so the poller stays idle there.
final focuserTemperaturePollerProvider = Provider<FocuserTemperaturePoller>((
  ref,
) {
  final poller = FocuserTemperaturePoller(
    ref: ref,
    backend: ref.watch(backendProvider),
    focuserIsHere: !ref.watch(isRemoteModeProvider),
  );
  ref.listen<FocuserState>(
    focuserStateProvider,
    (_, next) => poller.follow(next),
    fireImmediately: true,
  );
  ref.onDispose(poller.dispose);
  return poller;
});

class FocuserTemperaturePoller {
  FocuserTemperaturePoller({
    required Ref ref,
    required SkotiqBackend backend,
    required bool focuserIsHere,
    this.interval = const Duration(seconds: 30),
  }) : _ref = ref,
       _backend = backend,
       _focuserIsHere = focuserIsHere;

  final Ref _ref;
  final SkotiqBackend _backend;
  final bool _focuserIsHere;
  final Duration interval;

  Timer? _timer;
  String? _deviceId;
  bool _inFlight = false;

  /// The focuser being read, or null when idle.
  String? get deviceId => _deviceId;

  /// Start, keep or stop reading to match [state].
  void follow(FocuserState state) {
    final deviceId = state.deviceId;
    final readable =
        _focuserIsHere &&
        state.connectionState == DeviceConnectionState.connected &&
        deviceId != null &&
        deviceId.isNotEmpty &&
        (state.hasTemperature || state.temperature != null);
    if (!readable) {
      _stop();
      return;
    }
    if (_deviceId == deviceId && _timer != null) return;
    _stop();
    _deviceId = deviceId;
    _timer = Timer.periodic(interval, (_) => unawaited(_read(deviceId)));
  }

  Future<void> _read(String deviceId) async {
    if (_inFlight || _deviceId != deviceId) return;
    // A move reads the focuser itself, temperature included.
    if (_ref.read(focuserStateProvider).isMoving) return;
    _inFlight = true;
    try {
      final status = await _backend.getFocuserStatus(deviceId);
      final temperature = status.temperature;
      if (_deviceId != deviceId || temperature == null) return;
      _ref.read(focuserStateProvider.notifier).updateTemperature(temperature);
    } catch (e) {
      if (_deviceId != deviceId) return;
      _ref
          .read(loggingServiceProvider)
          .debug(
            'Could not read the focuser temperature: $e',
            source: 'FocuserTemperaturePoller',
          );
    } finally {
      _inFlight = false;
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _deviceId = null;
  }

  void dispose() => _stop();
}
