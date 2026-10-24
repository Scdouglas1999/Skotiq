import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

/// Which way the operator wants site/time copied.
enum MountSiteSyncDirection {
  /// Push the computer's site and time into the mount.
  computerToMount,

  /// Adopt the mount's site and time as the computer's.
  mountToComputer,
}

/// What the app does when a connected mount disagrees with the computer.
enum MountSiteSyncMode {
  /// Ask every time the two disagree.
  ask,

  /// Always push the computer's values without asking.
  alwaysComputerToMount,

  /// Always adopt the mount's values without asking.
  alwaysMountToComputer,

  /// Never compare and never ask.
  never,
}

/// A side-by-side of what the computer believes and what the mount believes.
///
/// Held as data rather than acted on: neither source is automatically right. A
/// hand controller set carefully at the pier can be better than a laptop that
/// has never had its timezone fixed, and a laptop with GPS can be better than a
/// mount whose backup battery died. The operator decides.
class MountSiteReconciliation {
  const MountSiteReconciliation({
    required this.deviceId,
    required this.deviceName,
    required this.capabilities,
    required this.computerLatitudeDeg,
    required this.computerLongitudeDeg,
    required this.computerElevationM,
    required this.computerUtcSeconds,
    required this.computerUtcOffsetHours,
    this.mountLatitudeDeg,
    this.mountLongitudeDeg,
    this.mountElevationM,
    this.mountUtcSeconds,
    this.mountUtcOffsetHours,
    this.siteReadError,
    this.timeReadError,
  });

  /// Coordinates closer than this are treated as agreeing. One arcminute is the
  /// LX200 wire resolution, so a tighter threshold would report a disagreement
  /// that no amount of syncing could ever resolve.
  static const double siteToleranceDeg = 1.0 / 60.0;

  /// Clocks closer than this are treated as agreeing. Serial round-trips and
  /// the mount's one-second clock resolution make anything tighter noise.
  static const Duration timeTolerance = Duration(seconds: 30);

  final String deviceId;
  final String deviceName;
  final bridge.MountSiteCapabilities capabilities;

  final double computerLatitudeDeg;
  final double computerLongitudeDeg;
  final double? computerElevationM;
  final int computerUtcSeconds;
  final double computerUtcOffsetHours;

  final double? mountLatitudeDeg;
  final double? mountLongitudeDeg;
  final double? mountElevationM;
  final int? mountUtcSeconds;
  final double? mountUtcOffsetHours;

  /// Why the mount's site could not be read, when it could not.
  final String? siteReadError;
  final String? timeReadError;

  bool get hasMountSite =>
      mountLatitudeDeg != null && mountLongitudeDeg != null;
  bool get hasMountTime => mountUtcSeconds != null;

  double? get latitudeDeltaDeg =>
      hasMountSite ? (mountLatitudeDeg! - computerLatitudeDeg).abs() : null;
  double? get longitudeDeltaDeg =>
      hasMountSite ? (mountLongitudeDeg! - computerLongitudeDeg).abs() : null;

  Duration? get timeDelta => hasMountTime
      ? Duration(seconds: (mountUtcSeconds! - computerUtcSeconds).abs())
      : null;

  bool get siteDiffers {
    final lat = latitudeDeltaDeg;
    final lon = longitudeDeltaDeg;
    if (lat == null || lon == null) return false;
    return lat > siteToleranceDeg || lon > siteToleranceDeg;
  }

  bool get timeDiffers {
    final delta = timeDelta;
    if (delta == null) return false;
    return delta > timeTolerance;
  }

  /// The mount's elevation, when this computer has none to offer and the two
  /// agree on where the site is. A profile elevation of exactly 0 m is the
  /// unset default; a mount's 0 m is no better.
  double? get elevationToAdopt {
    final mine = computerElevationM;
    final theirs = mountElevationM;
    if (mine != null && mine != 0) return null;
    if (theirs == null || theirs.abs() < 1) return null;
    if (!hasMountSite || siteDiffers) return null;
    return theirs;
  }

  /// Whether there is anything worth asking the operator about.
  bool get needsAttention => siteDiffers || timeDiffers;

  /// Whether a given direction is possible for this mount at all.
  bool canApply(MountSiteSyncDirection direction) {
    switch (direction) {
      case MountSiteSyncDirection.computerToMount:
        return (siteDiffers && capabilities.canWriteSite) ||
            (timeDiffers && capabilities.canWriteTime);
      case MountSiteSyncDirection.mountToComputer:
        return (siteDiffers && hasMountSite) || (timeDiffers && hasMountTime);
    }
  }

  /// Why a direction is unavailable, for the card to show instead of a dead
  /// button. Null when the direction IS available.
  String? unavailableReason(MountSiteSyncDirection direction) {
    if (canApply(direction)) return null;
    switch (direction) {
      case MountSiteSyncDirection.computerToMount:
        if (siteDiffers && !capabilities.canWriteSite) {
          return 'This driver cannot write a site to the mount';
        }
        if (timeDiffers && !capabilities.canWriteTime) {
          return 'This driver can read the mount clock but not set it';
        }
        return 'Nothing to send';
      case MountSiteSyncDirection.mountToComputer:
        return 'The mount did not report values to copy';
    }
  }
}
