import 'dart:async';

import '../../backend/skotiq_backend.dart';
import '../../models/mount_site_reconciliation.dart';

/// Builds the computer-vs-mount comparison and applies whichever direction the
/// operator picks.
///
/// Deliberately knows nothing about UI: it produces a [MountSiteReconciliation]
/// and consumes a [MountSiteSyncDirection]. Whether that becomes a card, an
/// automatic sync, or nothing at all is decided above.
class MountSiteReconciler {
  const MountSiteReconciler({
    required DeviceBackend backend,
    required Future<void> Function(
      double latitude,
      double longitude,
      double? elevation,
    )
    writeComputerLocation,
    void Function(String message)? log,
  }) : _backend = backend,
       _writeComputerLocation = writeComputerLocation,
       _log = log;

  final DeviceBackend _backend;
  final Future<void> Function(double, double, double?) _writeComputerLocation;
  final void Function(String)? _log;

  /// Read the mount's side and pair it with the computer's.
  ///
  /// A mount that cannot report its site is not an error here — the card still
  /// has something to say ("this mount cannot tell us, send yours?"), so the
  /// read failures are carried rather than thrown.
  Future<MountSiteReconciliation> compare({
    required String deviceId,
    required String deviceName,
    required double computerLatitudeDeg,
    required double computerLongitudeDeg,
    double? computerElevationM,
    DateTime? now,
  }) async {
    final capabilities = await _backend.mountSiteCapabilities(deviceId);
    final clock = now ?? DateTime.now();

    double? mountLat;
    double? mountLon;
    double? mountElev;
    String? siteError;
    if (capabilities.canReadSite) {
      try {
        final site = await _backend.mountGetSite(deviceId);
        mountLat = site.latitudeDeg;
        mountLon = site.longitudeDeg;
        mountElev = site.elevationM;
      } catch (e) {
        siteError = e.toString();
        _log?.call('Could not read the site from $deviceId: $e');
      }
    }

    int? mountUtcSeconds;
    double? mountOffsetHours;
    String? timeError;
    if (capabilities.canReadTime) {
      try {
        final time = await _backend.mountGetTime(deviceId);
        mountUtcSeconds = time.utcUnixSeconds;
        mountOffsetHours = time.utcOffsetHours;
      } catch (e) {
        timeError = e.toString();
        _log?.call('Could not read the clock from $deviceId: $e');
      }
    }

    return MountSiteReconciliation(
      deviceId: deviceId,
      deviceName: deviceName,
      capabilities: capabilities,
      computerLatitudeDeg: computerLatitudeDeg,
      computerLongitudeDeg: computerLongitudeDeg,
      computerElevationM: computerElevationM,
      computerUtcSeconds: clock.toUtc().millisecondsSinceEpoch ~/ 1000,
      computerUtcOffsetHours: clock.timeZoneOffset.inMinutes / 60.0,
      mountLatitudeDeg: mountLat,
      mountLongitudeDeg: mountLon,
      mountElevationM: mountElev,
      mountUtcSeconds: mountUtcSeconds,
      mountUtcOffsetHours: mountOffsetHours,
      siteReadError: siteError,
      timeReadError: timeError,
    );
  }

  /// Copy values in [direction].
  ///
  /// Site and time are applied independently: a mount that takes a site but
  /// refuses a clock should end up with the right site, not with neither
  /// because one call threw. Failures are collected and reported together.
  Future<List<String>> apply(
    MountSiteReconciliation comparison,
    MountSiteSyncDirection direction,
  ) async {
    final failures = <String>[];

    switch (direction) {
      case MountSiteSyncDirection.computerToMount:
        if (comparison.siteDiffers && comparison.capabilities.canWriteSite) {
          try {
            await _backend.mountSetSite(
              comparison.deviceId,
              comparison.computerLatitudeDeg,
              comparison.computerLongitudeDeg,
              comparison.computerElevationM,
            );
          } catch (e) {
            failures.add('Site: $e');
          }
        }
        if (comparison.timeDiffers && comparison.capabilities.canWriteTime) {
          try {
            await _backend.mountSetTime(
              comparison.deviceId,
              comparison.computerUtcSeconds,
              comparison.computerUtcOffsetHours,
            );
          } catch (e) {
            failures.add('Clock: $e');
          }
        }

      case MountSiteSyncDirection.mountToComputer:
        if (comparison.siteDiffers && comparison.hasMountSite) {
          try {
            await _writeComputerLocation(
              comparison.mountLatitudeDeg!,
              comparison.mountLongitudeDeg!,
              comparison.mountElevationM,
            );
          } catch (e) {
            failures.add('Site: $e');
          }
        }
      // The computer's clock is the operating system's business. Adopting a
      // mount's clock would mean setting the system time, which this app has
      // no right to do — so this direction moves the site only, and the card
      // says so rather than silently ignoring half the request.
    }

    return failures;
  }
}
