import '../runtime_mirror/channels/device_slot_channel.dart';
import '../runtime_mirror/client_runtime_mirror.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/equipment/equipment_models.dart';
import '../../models/backend/device_types.dart' show DeviceType, PierSide;
import 'device_read_health_provider.dart';
import 'device_connection_notifier.dart';
import '../backend_provider.dart';
import '../../services/logging_service.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

final mountStateProvider =
    StateNotifierProvider<MountStateNotifier, MountState>((ref) {
      return MountStateNotifier(ref);
    });

class MountStateNotifier extends DeviceSlotNotifier<MountState> {
  Timer? _positionPollTimer;
  bool _isPolling = false;

  /// A [refreshNow] arrived while a poll was in flight; that poll's reading
  /// may predate the command, so another runs as soon as it ends.
  bool _pollAgain = false;

  /// Normal polling interval (tracking/idle)
  static const _normalPollInterval = Duration(seconds: 2);

  /// Fast polling interval (while slewing)
  static const _slewingPollInterval = Duration(milliseconds: 500);
  static const _companionPollInterval = Duration(seconds: 5);
  static const _companionSlewingPollInterval = Duration(seconds: 1);

  MountStateNotifier(Ref ref)
    : super(ref, DeviceType.mount, const MountState());

  @override
  void dispose() {
    _stopPositionPolling();
    super.dispose();
  }

  @override
  Future<void> disconnect() async {
    _stopPositionPolling();
    try {
      await super.disconnect();
    } catch (_) {
      if (mounted && state.connectionState == DeviceConnectionState.connected) {
        _startPositionPolling();
      }
      rethrow;
    }
  }

  @override
  void setConnecting(String deviceId, [String? deviceName]) {
    _stopPositionPolling();
    super.setConnecting(deviceId, deviceName);
  }

  @override
  void setConnected() {
    super.setConnected();
    _startPositionPolling();
  }

  @override
  void setDisconnected() {
    _stopPositionPolling();
    super.setDisconnected();
  }

  /// [alt] / [az] are null when the mount cannot report the horizon frame —
  /// no observing site, or a driver that does not expose alt/az. That is a
  /// different fact from "0°", which is the horizon, so it is stored as null
  /// and the panels render `--`.
  void updatePosition(double ra, double dec, double? alt, double? az) {
    state = state.copyWith(
      ra: ra,
      dec: dec,
      altitude: alt,
      azimuth: az,
      clearHorizonFrame: alt == null && az == null,
    );
  }

  void setTracking(bool tracking) {
    state = state.copyWith(isTracking: tracking);
  }

  void setSlewing(bool slewing) {
    final wasSlewing = state.isSlewing;
    state = state.copyWith(isSlewing: slewing);
    if (wasSlewing != slewing &&
        state.connectionState == DeviceConnectionState.connected) {
      _restartPollingWithCurrentRate();
    }
  }

  void setParked(bool parked) {
    state = state.copyWith(isParked: parked);
  }

  /// Mark a Home command as in progress (or over). Starting one clears the
  /// previous home's unconfirmed flag; it is about to be superseded.
  void setHoming(bool homing) {
    state = state.copyWith(
      isHoming: homing,
      homeUnconfirmed: homing ? false : null,
    );
  }

  /// Record how the last home ended: [unconfirmed] when the mount stopped but
  /// its driver cannot report `AtHome`.
  void setHomeUnconfirmed(bool unconfirmed) {
    state = state.copyWith(homeUnconfirmed: unconfirmed);
  }

  void setTrackingRate(TrackingRate rate) {
    state = state.copyWith(trackingRate: rate);
  }

  void setCanSetTrackingRate(bool canSet) {
    state = state.copyWith(canSetTrackingRate: canSet);
  }

  void _startPositionPolling() {
    _stopPositionPolling();
    final companion = ref.read(isRemoteModeProvider);
    if (_hostSendsReadings) return;
    // A host from before the device channels is polled, at a slower pace
    // than the host polls itself: every read is a driver round trip there.
    final interval = state.isSlewing
        ? (companion ? _companionSlewingPollInterval : _slewingPollInterval)
        : (companion ? _companionPollInterval : _normalPollInterval);
    Log.info(
      '[Mount] Starting position polling (interval: ${interval.inMilliseconds}ms)',
      source: 'MountStateNotifier',
    );
    _positionPollTimer = Timer.periodic(interval, (_) => _pollPosition());
  }

  /// A linked host sends every reading of its mount and how its reads go
  /// (the mount's device channel), so a client reads the mount itself only
  /// right after a command ([refreshNow]).
  bool get _hostSendsReadings =>
      ref.read(isRemoteModeProvider) &&
      ref
          .read(clientRuntimeMirrorStateProvider)
          .hostPublishes(_mountChannel.key);

  static final _mountChannel = deviceSlotChannels.firstWhere(
    (channel) => channel.slot.type == DeviceType.mount,
  );

  void _stopPositionPolling() {
    if (_positionPollTimer != null) {
      _positionPollTimer!.cancel();
      _positionPollTimer = null;
      Log.info(
        '[Mount] Stopped position polling',
        source: 'MountStateNotifier',
      );
    }
  }

  void _restartPollingWithCurrentRate() {
    if (_positionPollTimer == null) return; // Not currently polling
    _startPositionPolling();
  }

  /// Read the mount now instead of at the next poll tick.
  ///
  /// Called when the host reports a mount command (a sync, an abort, an
  /// alt/az slew) that has no event carrying the new state, whoever sent
  /// it, so every UI shows the result within one status read rather than
  /// after the 2 s (host) or 5 s (linked client) poll.
  Future<void> refreshNow() async {
    if (_isPolling) {
      _pollAgain = true;
      return;
    }
    await _pollPosition();
  }

  Future<void> _pollPosition() async {
    if (_isPolling) return; // Skip if previous poll is still in-flight
    if (!mounted) return;
    if (state.connectionState != DeviceConnectionState.connected) return;

    final deviceId = state.deviceId;
    if (deviceId == null) return;

    _isPolling = true;
    try {
      final backend = ref.read(deviceBackendProvider);
      final status = await backend.getMountStatus(deviceId);
      if (!mounted) return;
      if (state.connectionState != DeviceConnectionState.connected ||
          state.deviceId != deviceId ||
          !identical(ref.read(deviceBackendProvider), backend)) {
        // The response belongs to a mount/backend snapshot that is no longer
        // authoritative. Do not let a slow old-host poll overwrite a newly
        // connected mount or repopulate state after disconnect.
        return;
      }
      if (!_hostSendsReadings) {
        ref
            .read(deviceReadHealthProvider.notifier)
            .recordSuccess(DeviceType.mount, deviceId);
      }

      updatePosition(
        status.rightAscension,
        status.declination,
        status.altitude,
        status.azimuth,
      );

      // Also sync tracking/slewing/parked state and the side of pier from
      // hardware. The side of pier was read on every poll and dropped here, so
      // every panel that shows it (Imaging → Mount, the flip countdown's pier
      // hint and its new-cycle reset) only ever saw null.
      final wasSlewing = state.isSlewing;
      final pierSide = switch (status.sideOfPier) {
        PierSide.east => 'East',
        PierSide.west => 'West',
        PierSide.unknown => null,
      };
      state = state.copyWith(
        isTracking: status.tracking,
        isSlewing: status.slewing,
        isParked: status.parked,
        isAtHome: status.atHome,
        // An unconfirmed home stops being the mount's position the moment
        // it moves again, parks, or its driver confirms home after all. Not
        // cleared while the home itself is still running.
        homeUnconfirmed:
            !state.isHoming &&
                (status.slewing || status.parked || status.atHome)
            ? false
            : null,
        canPark: status.canPark,
        sideOfPier: pierSide,
        clearSideOfPier: pierSide == null,
      );

      if (wasSlewing != status.slewing) {
        _restartPollingWithCurrentRate();
      }
    } catch (e) {
      // The position, pier side and tracking state shown are now older than
      // this poll. A driver can keep answering the heartbeat while every
      // position read fails (the NYX-101, Nov 8 2026), so the values are
      // marked stale here, and the host's heartbeat counts the failed reads
      // too and takes the mount through error and reconnect.
      if (mounted &&
          !_hostSendsReadings &&
          state.deviceId == deviceId &&
          state.connectionState == DeviceConnectionState.connected) {
        ref
            .read(deviceReadHealthProvider.notifier)
            .recordFailure(DeviceType.mount, deviceId, e);
      }
      Log.warning(
        '[Mount] Position poll failed: $e',
        source: 'MountStateNotifier',
        error: e,
      );
    } finally {
      _isPolling = false;
      if (_pollAgain && mounted) {
        _pollAgain = false;
        unawaited(_pollPosition());
      }
    }
  }
}
