import '../../utils/endpoint_sanitizer.dart';
import 'package:skotiq_remote_protocol/wire.dart';

/// Client-side mirror of `GET /api/system/version`. Carries the
/// running build info plus the last-check / last-applied bookkeeping
/// timestamps. All optional fields tolerate missing keys so a future
/// server that drops one (e.g. when the controller cannot persist the
/// state markers) does not break older clients.
class RemoteVersionInfo {
  final String currentVersion;
  final int buildNumber;

  /// OTA channel the host follows. Null when the host runs without a
  /// provisioned update stack — the always-on `/api/system/version` fallback
  /// (headless hosts, dev builds) reports build info with no channel.
  final String? channel;
  final String platform;
  final String? dataDir;
  final String? updateServerUrl;

  /// Where the host looks for updates, when it has a source at all.
  ///
  /// [updateServerUrl] alone can no longer answer that: a host reading the
  /// project's GitHub releases has no server URL, and treating a null URL as
  /// "OTA is off" told the operator updates were unavailable on a rig that
  /// could update perfectly well. Null only when the host reported no source.
  final String? updateSource;
  final DateTime? lastUpdateCheck;
  final DateTime? lastUpdateApplied;

  const RemoteVersionInfo({
    required this.currentVersion,
    required this.buildNumber,
    this.channel,
    required this.platform,
    this.dataDir,
    this.updateServerUrl,
    this.updateSource,
    this.lastUpdateCheck,
    this.lastUpdateApplied,
  });

  factory RemoteVersionInfo.fromJson(Map<String, dynamic> json) {
    DateTime? parse(Object? raw) {
      if (raw is! String) return null;
      return tryParseWireTime(raw);
    }

    final rawUpdateServerUrl = json['updateServerUrl'];
    final safeUpdateServerUrl = rawUpdateServerUrl is String
        ? sanitizeEndpointForDisplay(rawUpdateServerUrl)
        : '';

    final currentVersion = json['currentVersion'];
    final buildNumber = json['buildNumber'];
    final channel = json['channel'];
    final platform = json['platform'];
    if (currentVersion is! String || currentVersion.trim().isEmpty) {
      throw const FormatException(
        'System version response is missing `currentVersion`.',
      );
    }
    if (buildNumber is! num ||
        !buildNumber.toDouble().isFinite ||
        buildNumber < 0 ||
        buildNumber.toInt() != buildNumber) {
      throw const FormatException(
        'System version response has an invalid `buildNumber`.',
      );
    }
    // `channel` is absent on hosts without a provisioned update stack (the
    // always-on version fallback) — treat missing/blank as "no channel".
    final safeChannel = channel is String && channel.trim().isNotEmpty
        ? channel
        : null;
    if (platform is! String || platform.trim().isEmpty) {
      throw const FormatException(
        'System version response is missing `platform`.',
      );
    }

    return RemoteVersionInfo(
      currentVersion: currentVersion,
      buildNumber: buildNumber.toInt(),
      channel: safeChannel,
      platform: platform,
      dataDir: json['dataDir'] is String ? json['dataDir'] as String : null,
      updateServerUrl: safeUpdateServerUrl.isEmpty ? null : safeUpdateServerUrl,
      updateSource: switch (json['updateSource']) {
        final String s when s.trim().isNotEmpty => s.trim(),
        // An older host predates this field. It only ever had a server URL,
        // so its presence is the honest answer for those builds.
        _ => safeUpdateServerUrl.isEmpty ? null : safeUpdateServerUrl,
      },
      lastUpdateCheck: parse(json['lastUpdateCheck']),
      lastUpdateApplied: parse(json['lastUpdateApplied']),
    );
  }
}

/// Client-side mirror of `GET /api/system/update/status`. State is
/// kept loose (string, not enum) so a server that adds a new
/// lifecycle phase does not crash older clients — the caller
/// branches on the wire name.
class RemoteUpdateStatus {
  final String state;
  final String? availableVersion;
  final int? availableBuildNumber;
  final bool requiresManualUpgrade;
  final String? stagedVersion;
  final DateTime? stagedAt;
  final double? progressPct;
  final String? message;
  final String? lastError;
  final bool rollbackAvailable;
  final bool canAuthenticateUpdates;

  const RemoteUpdateStatus({
    required this.state,
    this.availableVersion,
    this.availableBuildNumber,
    this.requiresManualUpgrade = false,
    this.stagedVersion,
    this.stagedAt,
    this.progressPct,
    this.message,
    this.lastError,
    this.rollbackAvailable = false,
    this.canAuthenticateUpdates = true,
  });

  bool get hasAvailableUpdate =>
      state == 'available' || availableVersion != null;
  bool get hasStagedUpdate => stagedVersion != null;
  bool get isInFlight =>
      state == 'checking' ||
      state == 'downloading' ||
      state == 'verifying' ||
      state == 'installing';

  factory RemoteUpdateStatus.fromJson(Map<String, dynamic> json) {
    DateTime? parse(Object? raw) {
      if (raw is! String) return null;
      return tryParseWireTime(raw);
    }

    final state = json['state'];
    if (state is! String || state.trim().isEmpty) {
      throw const FormatException('Update status response is missing `state`.');
    }
    final rawProgress = json['progressPct'];
    final progress = rawProgress is num ? rawProgress.toDouble() : null;
    if (rawProgress != null &&
        (progress == null ||
            !progress.isFinite ||
            progress < 0 ||
            progress > 100)) {
      throw const FormatException(
        'Update status response has invalid `progressPct`.',
      );
    }
    final rawAvailableBuild = json['availableBuildNumber'];
    if (rawAvailableBuild != null &&
        (rawAvailableBuild is! num ||
            !rawAvailableBuild.toDouble().isFinite ||
            rawAvailableBuild < 0 ||
            rawAvailableBuild.toInt() != rawAvailableBuild)) {
      throw const FormatException(
        'Update status response has invalid `availableBuildNumber`.',
      );
    }

    return RemoteUpdateStatus(
      state: state,
      availableVersion: json['availableVersion'] is String
          ? json['availableVersion'] as String
          : null,
      availableBuildNumber: rawAvailableBuild is num
          ? rawAvailableBuild.toInt()
          : null,
      requiresManualUpgrade: json['requiresManualUpgrade'] is bool
          ? json['requiresManualUpgrade'] as bool
          : false,
      stagedVersion: json['stagedVersion'] is String
          ? json['stagedVersion'] as String
          : null,
      stagedAt: parse(json['stagedAt']),
      progressPct: progress,
      message: json['message'] is String ? json['message'] as String : null,
      lastError: json['lastError'] is String
          ? json['lastError'] as String
          : null,
      rollbackAvailable: json['rollbackAvailable'] is bool
          ? json['rollbackAvailable'] as bool
          : false,
      // Older hosts never advertised whether a trusted vendor key was
      // provisioned. Unknown must be fail-closed: let the user check for an
      // update, but never enable a package download on an assumption.
      canAuthenticateUpdates: json['canAuthenticateUpdates'] is bool
          ? json['canAuthenticateUpdates'] as bool
          : false,
    );
  }
}

/// Client-side mirror of `GET /api/system/update/staged`. Returned by
/// [NetworkBackend.getStagedUpdate] when a staged update exists.
class RemoteStagedUpdate {
  final String stagedVersion;
  final int stagedBuildNumber;
  final DateTime? stagedAt;
  final String? manifestHash;
  final int fileCount;
  final int totalBytes;
  final String? sourceUrl;
  final Map<String, String> expectedHashes;

  const RemoteStagedUpdate({
    required this.stagedVersion,
    required this.stagedBuildNumber,
    required this.fileCount,
    required this.totalBytes,
    required this.expectedHashes,
    this.stagedAt,
    this.manifestHash,
    this.sourceUrl,
  });

  factory RemoteStagedUpdate.fromJson(Map<String, dynamic> json) {
    final hashesRaw = json['expectedHashes'];
    final hashes = <String, String>{};
    if (hashesRaw is Map) {
      hashesRaw.forEach((k, v) {
        if (k is String && v is String) {
          hashes[k] = v;
        }
      });
    }
    DateTime? parse(Object? raw) {
      if (raw is! String) return null;
      return tryParseWireTime(raw);
    }

    return RemoteStagedUpdate(
      stagedVersion: json['stagedVersion'] as String? ?? '',
      stagedBuildNumber: (json['stagedBuildNumber'] as num?)?.toInt() ?? 0,
      stagedAt: parse(json['stagedAt']),
      manifestHash: json['manifestHash'] as String?,
      fileCount: (json['fileCount'] as num?)?.toInt() ?? hashes.length,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      sourceUrl: json['sourceUrl'] as String?,
      expectedHashes: hashes,
    );
  }
}
