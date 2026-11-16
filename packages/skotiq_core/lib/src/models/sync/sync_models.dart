import '../../utils/endpoint_sanitizer.dart';

// Settings keys (app_settings table) — non-secret config + sync state.

class SyncSettingsKeys {
  /// Prefix of every cloud backup row.
  static const prefix = 'cloud_sync_';

  static const provider = '${prefix}provider';
  static const serverUrl = '${prefix}server_url';
  static const username = '${prefix}username';
  static const machineName = '${prefix}machine_name';
  static const autoPush = '${prefix}auto_push';
  static const retainCount = '${prefix}retain_count';
  static const lastPushAt = '${prefix}last_push_at';
  static const lastError = '${prefix}last_error';

  // S3-compatible (AWS / MinIO / Backblaze B2) non-secret config. The S3
  // secret key is NOT here — it lives in the keyring via
  // [SecretField.cloudSyncS3SecretKey], exactly like the WebDAV password.
  static const s3Endpoint = '${prefix}s3_endpoint';
  static const s3Region = '${prefix}s3_region';
  static const s3Bucket = '${prefix}s3_bucket';
  static const s3AccessKey = '${prefix}s3_access_key';
  static const s3PathStyle = '${prefix}s3_path_style';
}

/// Cloud-backup provider kind. The string [key] is the stable persisted
/// value in `app_settings` (not the enum index, which could be reordered).
enum SyncProvider {
  webdav('webdav'),
  s3('s3');

  const SyncProvider(this.key);

  final String key;

  /// A null, unknown or absent persisted value maps to [SyncProvider.webdav],
  /// so a config written before the provider key existed still loads.
  static SyncProvider fromKey(String? raw) =>
      raw == SyncProvider.s3.key ? SyncProvider.s3 : SyncProvider.webdav;
}

/// Remote directory root under the WebDAV base URL.
const String kSyncRemoteRoot = 'skotiq-sync';

/// Default number of bundles retained per machine.
const int kSyncDefaultRetainCount = 5;

/// Safe projection for status screens and remote APIs. Provider endpoints are
/// configured as ordinary URLs, so users can paste credentials in user-info or
/// token-bearing query parameters even though Skotiq offers separate
/// credential fields. Keep the useful origin/path while never echoing those
/// URL-embedded secrets.
String sanitizeSyncEndpointForDisplay(String raw) {
  return sanitizeEndpointForDisplay(raw);
}

/// Non-secret sync configuration (the per-provider secret — the WebDAV
/// password or the S3 secret key — is read separately from the
/// keyring-backed [SecretsStore]).
class SyncConfig {
  /// Active cloud-backup provider. Defaults to [SyncProvider.webdav] so
  /// every existing `const SyncConfig()` call site is unchanged.
  final SyncProvider provider;

  // WebDAV config.
  final String serverUrl;
  final String username;

  // S3-compatible config (AWS / MinIO / Backblaze B2). The S3 secret key
  // is intentionally NOT a field here — it flows separately through
  // [SecretsStore], exactly as the WebDAV password does.
  final String s3Endpoint;
  final String s3Region;
  final String s3Bucket;

  /// S3 access key — non-secret, mirrors the WebDAV [username].
  final String s3AccessKey;

  /// Path-style addressing (`<endpoint>/<bucket>/<key>`); MinIO requires it.
  final bool s3PathStyle;

  final String machineName;
  final bool autoPushEnabled;
  final int retainCount;

  const SyncConfig({
    this.provider = SyncProvider.webdav,
    this.serverUrl = '',
    this.username = '',
    this.s3Endpoint = '',
    this.s3Region = '',
    this.s3Bucket = '',
    this.s3AccessKey = '',
    this.s3PathStyle = false,
    this.machineName = '',
    this.autoPushEnabled = false,
    this.retainCount = kSyncDefaultRetainCount,
  });

  /// True when enough config exists to build a target for the active
  /// provider. The secret is checked at connect time (an empty password is
  /// legal for some WebDAV servers). Only the active provider's fields are
  /// evaluated, so a half-filled inactive provider blob never blocks save.
  bool get isConfigured => switch (provider) {
    SyncProvider.webdav =>
      serverUrl.trim().isNotEmpty && machineName.trim().isNotEmpty,
    SyncProvider.s3 =>
      s3Endpoint.trim().isNotEmpty &&
          s3Region.trim().isNotEmpty &&
          s3Bucket.trim().isNotEmpty &&
          s3AccessKey.trim().isNotEmpty &&
          machineName.trim().isNotEmpty,
  };

  SyncConfig copyWith({
    SyncProvider? provider,
    String? serverUrl,
    String? username,
    String? s3Endpoint,
    String? s3Region,
    String? s3Bucket,
    String? s3AccessKey,
    bool? s3PathStyle,
    String? machineName,
    bool? autoPushEnabled,
    int? retainCount,
  }) {
    return SyncConfig(
      provider: provider ?? this.provider,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      s3Endpoint: s3Endpoint ?? this.s3Endpoint,
      s3Region: s3Region ?? this.s3Region,
      s3Bucket: s3Bucket ?? this.s3Bucket,
      s3AccessKey: s3AccessKey ?? this.s3AccessKey,
      s3PathStyle: s3PathStyle ?? this.s3PathStyle,
      machineName: machineName ?? this.machineName,
      autoPushEnabled: autoPushEnabled ?? this.autoPushEnabled,
      retainCount: retainCount ?? this.retainCount,
    );
  }
}

/// One bundle entry inside a machine's `manifest.json`.
class SyncBundleInfo {
  final String file;
  final String sha256;
  final int sizeBytes;
  final DateTime createdAt;

  const SyncBundleInfo({
    required this.file,
    required this.sha256,
    required this.sizeBytes,
    required this.createdAt,
  });

  factory SyncBundleInfo.fromJson(Map<String, dynamic> json) {
    return SyncBundleInfo(
      file: json['file'] as String? ?? '',
      sha256: json['sha256'] as String? ?? '',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, dynamic> toJson() => {
    'file': file,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
    'createdAt': createdAt.toIso8601String(),
  };
}

/// Per-machine `manifest.json` stored next to the bundles.
class SyncManifest {
  static const int formatVersion = 1;

  final String machine;
  final String appVersion;
  final DateTime updatedAt;

  /// Newest first.
  final List<SyncBundleInfo> bundles;

  const SyncManifest({
    required this.machine,
    required this.appVersion,
    required this.updatedAt,
    required this.bundles,
  });

  factory SyncManifest.fromJson(Map<String, dynamic> json) {
    final rawBundles = json['bundles'];
    final bundles = <SyncBundleInfo>[];
    if (rawBundles is List) {
      for (final entry in rawBundles) {
        if (entry is Map) {
          bundles.add(SyncBundleInfo.fromJson(entry.cast<String, dynamic>()));
        }
      }
    }
    bundles.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return SyncManifest(
      machine: json['machine'] as String? ?? '',
      appVersion: json['appVersion'] as String? ?? 'unknown',
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      bundles: bundles,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': formatVersion,
    'machine': machine,
    'appVersion': appVersion,
    'updatedAt': updatedAt.toIso8601String(),
    'bundles': bundles.map((b) => b.toJson()).toList(),
  };

  /// Returns a copy with [bundle] prepended and the list trimmed to
  /// [retainCount] entries (newest first). The trimmed-off entries are
  /// returned so the caller can delete the corresponding remote files.
  (SyncManifest, List<SyncBundleInfo> pruned) withBundle(
    SyncBundleInfo bundle, {
    required int retainCount,
    required DateTime now,
  }) {
    final all = [bundle, ...bundles]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final keep = retainCount < 1 ? 1 : retainCount;
    final kept = all.take(keep).toList();
    final pruned = all.skip(keep).toList();
    return (
      SyncManifest(
        machine: machine,
        appVersion: appVersion,
        updatedAt: now,
        bundles: kept,
      ),
      pruned,
    );
  }
}

/// A remote machine directory under `skotiq-sync/`.
class SyncRemoteMachine {
  final String name;
  const SyncRemoteMachine(this.name);
}

class SyncPushResult {
  final bool success;
  final String? remotePath;
  final String? errorMessage;
  final int? sizeBytes;
  final DateTime timestamp;

  const SyncPushResult({
    required this.success,
    this.remotePath,
    this.errorMessage,
    this.sizeBytes,
    required this.timestamp,
  });
}

/// Snapshot for the settings UI / headless status endpoint.
class SyncStatus {
  final bool configured;
  final bool autoPushEnabled;
  final String machineName;
  final String serverUrl;
  final DateTime? lastPushAt;
  final String? lastError;
  final bool pushInProgress;

  const SyncStatus({
    required this.configured,
    required this.autoPushEnabled,
    required this.machineName,
    required this.serverUrl,
    this.lastPushAt,
    this.lastError,
    required this.pushInProgress,
  });

  factory SyncStatus.fromJson(Map<String, dynamic> json) {
    final configured = json['configured'];
    final autoPushEnabled = json['autoPushEnabled'];
    final pushInProgress = json['pushInProgress'];
    if (configured is! bool ||
        autoPushEnabled is! bool ||
        pushInProgress is! bool) {
      throw const FormatException('Malformed cloud sync status response');
    }
    final rawLastPush = json['lastPushAt'];
    return SyncStatus(
      configured: configured,
      autoPushEnabled: autoPushEnabled,
      machineName: json['machineName'] as String? ?? '',
      serverUrl: json['serverUrl'] as String? ?? '',
      lastPushAt: rawLastPush is String
          ? DateTime.tryParse(rawLastPush)
          : rawLastPush is num
          ? DateTime.fromMillisecondsSinceEpoch(rawLastPush.toInt())
          : null,
      lastError: json['lastError'] as String?,
      pushInProgress: pushInProgress,
    );
  }

  Map<String, dynamic> toJson() => {
    'configured': configured,
    'autoPushEnabled': autoPushEnabled,
    'machineName': machineName,
    'serverUrl': serverUrl,
    'lastPushAt': lastPushAt?.toIso8601String(),
    'lastError': lastError,
    'pushInProgress': pushInProgress,
  };
}
