import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../models/command_action_result.dart';

/// Provider for the MountCommandService.
final mountCommandServiceProvider = Provider((ref) {
  final backend = ref.watch(deviceBackendProvider);
  final deviceService = ref.watch(deviceServiceProvider);
  return MountCommandService(
    ref,
    backend: backend,
    deviceService: deviceService,
  );
});

/// Centralized service for all mount control actions.
///
/// This eliminates duplicate mount command implementations across screens.
/// All mount control buttons should use this service instead of implementing
/// their own try/catch patterns with deviceServiceProvider.
class MountCommandService {
  final Ref _ref;
  final DeviceBackend _backend;
  final DeviceService _deviceService;
  bool _commandInFlight = false;

  MountCommandService(
    this._ref, {
    DeviceBackend? backend,
    DeviceService? deviceService,
  }) : _backend = backend ?? _ref.read(deviceBackendProvider),
       _deviceService = deviceService ?? _ref.read(deviceServiceProvider);

  MountState get _mountState => _ref.read(mountStateProvider);

  String? get _connectedMountId {
    final mount = _mountState;
    if (mount.connectionState != DeviceConnectionState.connected ||
        mount.deviceId == null ||
        mount.deviceId!.isEmpty) {
      return null;
    }
    return mount.deviceId;
  }

  /// Returns true if a mount is currently connected.
  bool get isConnected => _connectedMountId != null;

  Future<MountCapabilities> _getCapabilities(String deviceId) async {
    final capabilities = await _backend.getMountCapabilities(deviceId);
    if (capabilities == null) {
      throw StateError(
        'Mount capabilities are unavailable; command was not sent',
      );
    }
    return capabilities;
  }

  bool _isStillConnectedTo(String deviceId) => _connectedMountId == deviceId;

  Future<CommandActionResult> _runExclusive(
    Future<CommandActionResult> Function(String deviceId) command,
  ) async {
    final deviceId = _connectedMountId;
    if (deviceId == null) {
      return const CommandActionResult.failure('No mount connected');
    }
    if (_commandInFlight) {
      return const CommandActionResult.failure(
        'Another mount command is already in progress',
      );
    }

    _commandInFlight = true;
    try {
      final result = await command(deviceId);
      return _connectionChanged(deviceId) ?? result;
    } finally {
      _commandInFlight = false;
    }
  }

  CommandActionResult? _connectionChanged(String deviceId) {
    if (_isStillConnectedTo(deviceId) &&
        identical(_ref.read(deviceBackendProvider), _backend) &&
        identical(_ref.read(deviceServiceProvider), _deviceService)) {
      return null;
    }
    return const CommandActionResult.failure(
      'Mount connection changed while the command was in progress',
    );
  }

  String? _equatorialCoordinateError(double ra, double dec) {
    if (!ra.isFinite || ra < 0 || ra >= 24) {
      return 'Right ascension must be between 0 (inclusive) and 24 hours (exclusive)';
    }
    if (!dec.isFinite || dec < -90 || dec > 90) {
      return 'Declination must be between -90 and +90 degrees';
    }
    return null;
  }

  /// Toggles between parked and unparked state.
  Future<CommandActionResult> togglePark() async {
    return _runExclusive((deviceId) async {
      final unparkRequested = _mountState.isParked;
      try {
        final capabilities = await _getCapabilities(deviceId);
        final changed = _connectionChanged(deviceId);
        if (changed != null) return changed;
        if (unparkRequested) {
          if (!capabilities.canUnpark) {
            return const CommandActionResult.failure(
              'This mount reports that unpark is unsupported',
            );
          }
          await _deviceService.unparkMount();
        } else {
          if (!capabilities.canPark) {
            return const CommandActionResult.failure(
              'This mount reports that park is unsupported',
            );
          }
          await _deviceService.parkMount();
        }
        return CommandActionResult.ok;
      } catch (e) {
        final operation = unparkRequested ? 'unpark' : 'park';
        return CommandActionResult.failure('Failed to $operation mount: $e');
      }
    });
  }

  /// Parks the mount.
  Future<CommandActionResult> park() async {
    return _runExclusive((deviceId) async {
      try {
        final capabilities = await _getCapabilities(deviceId);
        final changed = _connectionChanged(deviceId);
        if (changed != null) return changed;
        if (!capabilities.canPark) {
          return const CommandActionResult.failure(
            'This mount reports that park is unsupported',
          );
        }
        await _deviceService.parkMount();
        return CommandActionResult.ok;
      } catch (e) {
        return CommandActionResult.failure('Failed to park mount: $e');
      }
    });
  }

  /// Unparks the mount.
  Future<CommandActionResult> unpark() async {
    return _runExclusive((deviceId) async {
      try {
        final capabilities = await _getCapabilities(deviceId);
        final changed = _connectionChanged(deviceId);
        if (changed != null) return changed;
        if (!capabilities.canUnpark) {
          return const CommandActionResult.failure(
            'This mount reports that unpark is unsupported',
          );
        }
        await _deviceService.unparkMount();
        return CommandActionResult.ok;
      } catch (e) {
        return CommandActionResult.failure('Failed to unpark mount: $e');
      }
    });
  }

  /// Slews the mount to the specified RA/Dec coordinates.
  ///
  /// Completes when the slew is over, not when the driver accepts it: a
  /// success means the mount stopped on the target, and a slew that was
  /// aborted, stopped short or never started is a failure saying which.
  Future<CommandActionResult> slewTo(
    double ra,
    double dec, {
    bool showFeedback = true,
  }) async {
    final coordinateError = _equatorialCoordinateError(ra, dec);
    if (coordinateError != null) {
      return CommandActionResult.failure(coordinateError);
    }
    return _runExclusive((deviceId) async {
      try {
        final capabilities = await _getCapabilities(deviceId);
        final changed = _connectionChanged(deviceId);
        if (changed != null) return changed;
        if (!capabilities.canSlew && !capabilities.canSlewAsync) {
          return const CommandActionResult.failure(
            'This mount reports that GoTo slewing is unsupported',
          );
        }
        await _deviceService.slewMountToCoordinates(ra, dec);
        if (showFeedback) {
          return const CommandActionResult.success(message: 'Slew complete');
        }
        return CommandActionResult.ok;
      } on MountSlewException catch (e) {
        return CommandActionResult.failure(e.message);
      } catch (e) {
        return CommandActionResult.failure('Slew failed: $e');
      }
    });
  }

  /// Aborts any current slew operation, including a home in progress.
  ///
  /// The panic button does NOT take the one-command-at-a-time slot: a slew or
  /// a home holds that slot for as long as the mount is moving, which is
  /// exactly when abort is pressed. Queued behind it, abort was refused with
  /// "Another mount command is already in progress".
  Future<CommandActionResult> abortSlew({bool showFeedback = true}) async {
    final deviceId = _connectedMountId;
    if (deviceId == null) {
      return const CommandActionResult.failure('No mount connected');
    }
    try {
      final capabilities = await _getCapabilities(deviceId);
      final changed = _connectionChanged(deviceId);
      if (changed != null) return changed;
      if (!capabilities.canAbortSlew) {
        return const CommandActionResult.failure(
          'This mount reports that aborting a slew is unsupported',
        );
      }
      await _deviceService.abortMountSlew();
      if (showFeedback) {
        return const CommandActionResult.success(message: 'Mount slew aborted');
      }
      return CommandActionResult.ok;
    } catch (e) {
      return CommandActionResult.failure('Failed to abort slew: $e');
    }
  }

  /// Sets the mount tracking state.
  Future<CommandActionResult> setTracking(bool enabled) async {
    return _runExclusive((deviceId) async {
      try {
        final capabilities = await _getCapabilities(deviceId);
        final changed = _connectionChanged(deviceId);
        if (changed != null) return changed;
        if (!capabilities.canSetTracking) {
          return const CommandActionResult.failure(
            'This mount reports that tracking control is unsupported',
          );
        }
        await _deviceService.setMountTracking(enabled);
        return CommandActionResult.ok;
      } catch (e) {
        return CommandActionResult.failure('Failed to set tracking: $e');
      }
    });
  }

  /// Toggles the mount tracking state.
  Future<CommandActionResult> toggleTracking() async {
    if (!isConnected) {
      return const CommandActionResult.failure('No mount connected');
    }
    return setTracking(!_mountState.isTracking);
  }

  /// Sets the mount tracking rate after validating the driver's advertised
  /// capability and supported-rate list.
  Future<CommandActionResult> setTrackingRate(TrackingRate rate) async {
    return _runExclusive((deviceId) async {
      try {
        final capabilities = await _getCapabilities(deviceId);
        final changed = _connectionChanged(deviceId);
        if (changed != null) return changed;
        if (!capabilities.canSetTrackingRate) {
          return const CommandActionResult.failure(
            'This mount reports that tracking-rate control is unsupported',
          );
        }
        if (!capabilities.supportedTrackingRates.contains(rate)) {
          return CommandActionResult.failure(
            'This mount does not support the ${rate.name} tracking rate',
          );
        }
        await _deviceService.setMountTrackingRate(rate.index);
        return CommandActionResult.ok;
      } catch (e) {
        return CommandActionResult.failure('Failed to set tracking rate: $e');
      }
    });
  }

  /// Syncs the mount to the specified RA/Dec coordinates.
  Future<CommandActionResult> sync(double ra, double dec) async {
    final coordinateError = _equatorialCoordinateError(ra, dec);
    if (coordinateError != null) {
      return CommandActionResult.failure(coordinateError);
    }
    return _runExclusive((deviceId) async {
      try {
        final capabilities = await _getCapabilities(deviceId);
        final changed = _connectionChanged(deviceId);
        if (changed != null) return changed;
        if (!capabilities.canSync) {
          return const CommandActionResult.failure(
            'This mount reports that coordinate sync is unsupported',
          );
        }
        await _deviceService.syncMountToCoordinates(ra, dec);
        return const CommandActionResult.success(
          message: 'Mount synced to coordinates',
        );
      } catch (e) {
        return CommandActionResult.failure('Sync failed: $e');
      }
    });
  }

  /// Slews the mount to the specified Alt/Az coordinates.
  Future<CommandActionResult> slewToAltAz(
    double altitude,
    double azimuth, {
    bool showFeedback = true,
  }) async {
    if (!altitude.isFinite || altitude < -90 || altitude > 90) {
      return const CommandActionResult.failure(
        'Altitude must be between -90 and +90 degrees',
      );
    }
    if (!azimuth.isFinite || azimuth < 0 || azimuth > 360) {
      return const CommandActionResult.failure(
        'Azimuth must be between 0 and 360 degrees',
      );
    }
    return _runExclusive((deviceId) async {
      try {
        final capabilities = await _getCapabilities(deviceId);
        final changed = _connectionChanged(deviceId);
        if (changed != null) return changed;
        if (!capabilities.supportsAltAz) {
          return const CommandActionResult.failure(
            'This mount reports that Alt/Az slewing is unsupported',
          );
        }
        await _deviceService.slewMountToAltAz(altitude, azimuth);
        if (showFeedback) {
          return CommandActionResult.success(
            message:
                'Alt/Az slew complete at ${altitude.toStringAsFixed(1)}°, ${azimuth.toStringAsFixed(1)}°',
          );
        }
        return CommandActionResult.ok;
      } catch (e) {
        return CommandActionResult.failure('Alt/Az slew failed: $e');
      }
    });
  }

  /// Sends the mount to its home position and reports where it ended up.
  ///
  /// Homing is not parking: the mount is left unparked and commandable. A
  /// parked mount is refused with a request to unpark it first, never
  /// unparked silently. The result is a success only once the mount has been
  /// seen to move and stop (see [MountHomeWatcher]); when its driver cannot
  /// report `AtHome` the success says the home is unconfirmed.
  Future<CommandActionResult> findHome() async {
    return _runExclusive((deviceId) async {
      try {
        final capabilities = await _getCapabilities(deviceId);
        final changed = _connectionChanged(deviceId);
        if (changed != null) return changed;
        if (!capabilities.canFindHome) {
          return const CommandActionResult.failure(
            'This mount does not have a home position it can find',
          );
        }
        if (_mountState.isParked) {
          return const CommandActionResult.failure(homeWhileParkedMessage);
        }
        final outcome = await _deviceService.findMountHome();
        return switch (outcome) {
          MountHomeOutcome.confirmed => const CommandActionResult.success(
            message: 'Mount is at home',
          ),
          MountHomeOutcome.unconfirmed => const CommandActionResult.success(
            message: homeUnconfirmedMessage,
          ),
        };
      } on MountHomeException catch (e) {
        return CommandActionResult.failure(e.message);
      } catch (e) {
        return CommandActionResult.failure('Home failed: $e');
      }
    });
  }

  /// Stores the mount's current position as its park position.
  ///
  /// Nothing moves and the mount is not parked. Refused when the driver
  /// cannot set park or the mount is moving.
  Future<CommandActionResult> setParkHere() async {
    return _runExclusive((deviceId) async {
      try {
        final capabilities = await _getCapabilities(deviceId);
        final changed = _connectionChanged(deviceId);
        if (changed != null) return changed;
        final unavailable = setParkUnavailableReason(
          mountState: _mountState,
          isConnected: true,
          canSetPark: capabilities.canSetPark,
        );
        if (unavailable != null) {
          return CommandActionResult.failure(unavailable);
        }
        await _deviceService.setMountParkHere();
        return const CommandActionResult.success(
          message: 'Park position set to where the mount is pointing',
        );
      } catch (e) {
        return CommandActionResult.failure('Set park failed: $e');
      }
    });
  }

  /// Why Set park cannot be pressed right now, or null when it can.
  static String? setParkUnavailableReason({
    required MountState mountState,
    required bool isConnected,
    required bool canSetPark,
  }) {
    if (!isConnected) return 'Connect a mount to set its park position.';
    if (!canSetPark) {
      return 'This mount cannot store a park position from the app.';
    }
    if (mountState.isSlewing || mountState.isHoming) {
      return 'Wait for the mount to stop moving.';
    }
    return null;
  }

  /// Why Home cannot be pressed right now, or null when it can.
  ///
  /// Every Home control (Imaging › Mount, the Equipment mount card) gates on
  /// this, so they refuse for the same reasons in the same words.
  static String? homeUnavailableReason({
    required MountState mountState,
    required bool isConnected,
    required bool canFindHome,
  }) {
    if (!isConnected) return 'Connect a mount to send it home.';
    if (!canFindHome) return 'This mount does not have a home position.';
    if (mountState.isParked) return 'Unpark the mount before sending it home.';
    if (mountState.isHoming) return 'The mount is on its way home.';
    if (mountState.isSlewing) return 'Wait for the mount to stop moving.';
    return null;
  }

  /// Why Home refuses a parked mount.
  static const String homeWhileParkedMessage =
      'The mount is parked. Unpark it before sending it home.';

  /// The success message for a home whose driver cannot report `AtHome`.
  static const String homeUnconfirmedMessage =
      'The mount moved and stopped, but its driver cannot confirm it is at home';

  /// Sends a pulse guide command in the specified direction.
  Future<CommandActionResult> pulseGuide(
    String direction, {
    int durationMs = 500,
  }) async {
    final normalizedDirection = direction.toLowerCase();
    if (!const {
      'north',
      'south',
      'east',
      'west',
    }.contains(normalizedDirection)) {
      return const CommandActionResult.failure(
        'Pulse direction must be north, south, east, or west',
      );
    }
    if (durationMs <= 0) {
      return const CommandActionResult.failure(
        'Pulse duration must be greater than zero',
      );
    }

    return _runExclusive((deviceId) async {
      try {
        final capabilities = await _getCapabilities(deviceId);
        final changed = _connectionChanged(deviceId);
        if (changed != null) return changed;
        if (!capabilities.canPulseGuide) {
          return const CommandActionResult.failure(
            'This mount reports that pulse guiding is unsupported',
          );
        }
        final minMs = capabilities.minPulseGuideMs;
        final maxMs = capabilities.maxPulseGuideMs;
        if (minMs != null && durationMs < minMs) {
          return CommandActionResult.failure(
            'Pulse duration must be at least ${minMs.ceil()} ms for this mount',
          );
        }
        if (maxMs != null && durationMs > maxMs) {
          return CommandActionResult.failure(
            'Pulse duration must be at most ${maxMs.floor()} ms for this mount',
          );
        }
        await _deviceService.pulseGuidMount(
          direction: normalizedDirection,
          durationMs: durationMs,
        );
        return CommandActionResult.ok;
      } catch (e) {
        return CommandActionResult.failure('Pulse guide failed: $e');
      }
    });
  }
}
