// Cloud backup/sync — orchestration on top of the existing BackupService.
//
// What this service does:
//   * push   — create a full backup bundle via [BackupService.createBackup]
//              (the exact same bundling code the local Backup screen uses),
//              upload it to `skotiq-sync/<machine>/bundle-<ts>.skbak`
//              on the configured [SyncTarget], update the per-machine
//              `manifest.json` (machine, app version, SHA-256 content
//              hashes, timestamps) and prune bundles beyond the configured
//              retention count (default 5).
//   * pull   — list remote machines/bundles, download a bundle, verify its
//              SHA-256 against the manifest, and hand the file to the
//              existing [BackupService.restoreBackup] path.
//   * auto   — opt-in scheduled push, hooked into [AutoSaveService]'s daily
//              backup cycle (see autoSaveServiceProvider) rather than a
//              second ad-hoc timer.
//
// CONFLICT STANCE (read this before "improving" it): sync is bundle-based.
// There is NO field-level merging between machines. A push uploads the
// whole local configuration as one opaque bundle; a restore replaces local
// configuration with the remote bundle through the same validated restore
// path (and the same user confirmation) a local backup restore uses. Two
// machines that both push simply keep separate bundle histories under
// their own machine directory — they never overwrite each other.
//
// Persistence: all non-secret config and sync state live in the existing
// `app_settings` key-value table (no Drift schema change). The WebDAV
// password lives in the OS keyring via the existing [SecretsStore].

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../database/daos/settings_dao.dart';
import '../backup_service.dart';
import '../../utils/logging_service.dart';
import '../notification/secrets_store.dart';
import 's3_sync_target.dart';
import 'sync_target.dart';
import 'webdav_sync_target.dart';
import '../../models/sync/sync_models.dart';
import '../../models/backup/restore_mode.dart';

class SyncService {
  /// Keyring field (via [SecretsStore]) holding the WebDAV password.
  static const String passwordSecretField = SecretField.cloudSyncPassword;

  /// Keyring field (via [SecretsStore]) holding the S3 secret key. Read /
  /// written ONLY through this field — never `app_settings`, never logs.
  static const String s3SecretField = SecretField.cloudSyncS3SecretKey;

  final BackupService backupService;
  final SettingsDao settingsDao;
  final SecretsStore secretsStore;
  final LoggingService _logger;

  /// Test seam: build a [SyncTarget] from config + password. Production
  /// default constructs a [WebDavSyncTarget].
  final SyncTarget Function(SyncConfig config, String password) _targetFactory;

  /// Test seam: where downloaded bundles are staged before restore.
  /// Production default is the local backup directory so pulled bundles
  /// also show up in the Backup screen's "Recent Backups" list.
  final Future<Directory> Function() _downloadDirectoryProvider;

  final DateTime Function() _clock;

  bool _pushInProgress = false;
  bool get pushInProgress => _pushInProgress;

  SyncService({
    required this.backupService,
    required this.settingsDao,
    required this.secretsStore,
    required LoggingService logger,
    SyncTarget Function(SyncConfig config, String password)? targetFactory,
    Future<Directory> Function()? downloadDirectoryProvider,
    DateTime Function()? clock,
  }) : _logger = logger,
       _targetFactory = targetFactory ?? defaultTargetFactory,
       _downloadDirectoryProvider =
           downloadDirectoryProvider ??
           (() async {
             final dir = await backupService.getBackupDirectory();
             await dir.create(recursive: true);
             return dir;
           }),
       _clock = clock ?? DateTime.now;

  /// Build the production [SyncTarget] for [config]. The [password]
  /// parameter carries the active provider's secret (WebDAV password or S3
  /// secret key) — [_buildTarget] selects the correct keyring field. The
  /// validation messages name only non-secret fields, never the secret.
  @visibleForTesting
  static SyncTarget defaultTargetFactory(SyncConfig config, String password) {
    switch (config.provider) {
      case SyncProvider.webdav:
        final uri = Uri.parse(config.serverUrl.trim());
        if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
          throw SyncTargetException(
            'Server URL must start with http:// or https:// '
            '(got "${config.serverUrl}")',
            kind: SyncTargetErrorKind.unknown,
          );
        }
        return WebDavSyncTarget(
          baseUrl: uri,
          username: config.username,
          password: password,
        );
      case SyncProvider.s3:
        final uri = Uri.parse(config.s3Endpoint.trim());
        if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
          throw SyncTargetException(
            'S3 endpoint must start with http:// or https:// '
            '(got "${config.s3Endpoint}")',
            kind: SyncTargetErrorKind.unknown,
          );
        }
        if (config.s3Region.trim().isEmpty) {
          throw const SyncTargetException(
            'S3 region must not be empty',
            kind: SyncTargetErrorKind.unknown,
          );
        }
        if (config.s3Bucket.trim().isEmpty) {
          throw const SyncTargetException(
            'S3 bucket must not be empty',
            kind: SyncTargetErrorKind.unknown,
          );
        }
        return S3SyncTarget(
          endpoint: uri,
          region: config.s3Region.trim(),
          bucket: config.s3Bucket.trim(),
          accessKey: config.s3AccessKey.trim(),
          secretKey: password,
          pathStyle: config.s3PathStyle,
        );
    }
  }

  Future<SyncConfig> loadConfig() async {
    // Absent provider key -> webdav (back-compat hinge for installs that
    // pre-date the S3 provider).
    final provider = SyncProvider.fromKey(
      await settingsDao.getSetting(SyncSettingsKeys.provider),
    );
    final serverUrl =
        await settingsDao.getSetting(SyncSettingsKeys.serverUrl) ?? '';
    final username =
        await settingsDao.getSetting(SyncSettingsKeys.username) ?? '';
    final s3Endpoint =
        await settingsDao.getSetting(SyncSettingsKeys.s3Endpoint) ?? '';
    final s3Region =
        await settingsDao.getSetting(SyncSettingsKeys.s3Region) ?? '';
    final s3Bucket =
        await settingsDao.getSetting(SyncSettingsKeys.s3Bucket) ?? '';
    final s3AccessKey =
        await settingsDao.getSetting(SyncSettingsKeys.s3AccessKey) ?? '';
    final s3PathStyle =
        await settingsDao.getSetting(SyncSettingsKeys.s3PathStyle) == 'true';
    var machineName =
        await settingsDao.getSetting(SyncSettingsKeys.machineName) ?? '';
    if (machineName.trim().isEmpty) {
      machineName = defaultMachineName();
    }
    final autoPush =
        await settingsDao.getSetting(SyncSettingsKeys.autoPush) == 'true';
    final retain =
        int.tryParse(
          await settingsDao.getSetting(SyncSettingsKeys.retainCount) ?? '',
        ) ??
        kSyncDefaultRetainCount;
    return SyncConfig(
      provider: provider,
      serverUrl: serverUrl,
      username: username,
      s3Endpoint: s3Endpoint,
      s3Region: s3Region,
      s3Bucket: s3Bucket,
      s3AccessKey: s3AccessKey,
      s3PathStyle: s3PathStyle,
      machineName: machineName,
      autoPushEnabled: autoPush,
      retainCount: retain,
    );
  }

  /// Persist [config]; [password] is the active provider's secret (WebDAV
  /// password or S3 secret key) and is written to the OS keyring only when
  /// non-null (pass null to keep the stored secret unchanged, an empty
  /// string to clear it). The secret NEVER touches `app_settings`.
  ///
  /// Both providers' non-secret blobs are written so switching the provider
  /// dropdown is non-destructive — only the active provider's fields are
  /// evaluated by [SyncConfig.isConfigured], so a populated inactive blob
  /// is inert, not a leak (it holds no secret).
  Future<void> saveConfig(SyncConfig config, {String? password}) async {
    await settingsDao.setSettings({
      SyncSettingsKeys.provider: config.provider.key,
      SyncSettingsKeys.serverUrl: config.serverUrl.trim(),
      SyncSettingsKeys.username: config.username.trim(),
      SyncSettingsKeys.s3Endpoint: config.s3Endpoint.trim(),
      SyncSettingsKeys.s3Region: config.s3Region.trim(),
      SyncSettingsKeys.s3Bucket: config.s3Bucket.trim(),
      SyncSettingsKeys.s3AccessKey: config.s3AccessKey.trim(),
      SyncSettingsKeys.s3PathStyle: config.s3PathStyle.toString(),
      SyncSettingsKeys.machineName: sanitizeMachineName(config.machineName),
      SyncSettingsKeys.autoPush: config.autoPushEnabled.toString(),
      SyncSettingsKeys.retainCount: config.retainCount.toString(),
    });
    if (password != null) {
      await secretsStore.write(_secretFieldFor(config.provider), password);
    }
  }

  /// The keyring field carrying [provider]'s secret.
  static String _secretFieldFor(SyncProvider provider) =>
      provider == SyncProvider.s3 ? s3SecretField : passwordSecretField;

  /// Whether [provider]'s secret is already stored in the keyring.
  Future<bool> hasStoredSecret(SyncProvider provider) =>
      secretsStore.has(_secretFieldFor(provider));

  /// Back-compat: whether the WebDAV password is stored. Prefer
  /// [hasStoredSecret].
  Future<bool> hasStoredPassword() => secretsStore.has(passwordSecretField);

  /// Default machine name: the local hostname, sanitized for use as a
  /// remote directory name.
  static String defaultMachineName() =>
      sanitizeMachineName(Platform.localHostname);

  /// Machine names become remote directory names — keep them path- and
  /// URL-friendly.
  static String sanitizeMachineName(String raw) {
    final sanitized = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    return sanitized.isEmpty ? 'skotiq' : sanitized;
  }

  Future<SyncStatus> status() async {
    final config = await loadConfig();
    final lastPushRaw = await settingsDao.getSetting(
      SyncSettingsKeys.lastPushAt,
    );
    final lastError = await settingsDao.getSetting(SyncSettingsKeys.lastError);
    return SyncStatus(
      configured: config.isConfigured,
      autoPushEnabled: config.autoPushEnabled,
      machineName: config.machineName,
      // Display the meaningful endpoint for the active provider. This is
      // the non-secret endpoint/URL only — never the access/secret key —
      // so the headless status JSON stays safe.
      serverUrl: sanitizeSyncEndpointForDisplay(
        config.provider == SyncProvider.s3
            ? config.s3Endpoint
            : config.serverUrl,
      ),
      lastPushAt: lastPushRaw == null ? null : DateTime.tryParse(lastPushRaw),
      lastError: (lastError == null || lastError.isEmpty) ? null : lastError,
      pushInProgress: _pushInProgress,
    );
  }

  Future<SyncTarget> _buildTarget(SyncConfig config) async {
    if (!config.isConfigured) {
      throw const SyncTargetException(
        'Cloud sync is not configured (set a server URL in '
        'Settings > Backup & restore)',
        kind: SyncTargetErrorKind.unknown,
      );
    }
    final secret = await secretsStore.read(_secretFieldFor(config.provider));
    return _targetFactory(config, secret);
  }

  /// Probe the configured server (reachability + credentials).
  Future<void> testConnection() async {
    final target = await _buildTarget(await loadConfig());
    try {
      await target.testConnection();
    } finally {
      _closeIfOwned(target);
    }
  }

  String _machineDir(SyncConfig config) =>
      '$kSyncRemoteRoot/${sanitizeMachineName(config.machineName)}';

  /// Create a backup bundle and upload it, then update the manifest and
  /// prune bundles beyond the retention count.
  Future<SyncPushResult> pushNow() async {
    if (_pushInProgress) {
      return SyncPushResult(
        success: false,
        errorMessage: 'A push is already in progress',
        timestamp: _clock(),
      );
    }
    _pushInProgress = true;
    Directory? tempDir;
    SyncTarget? target;
    try {
      final config = await loadConfig();
      target = await _buildTarget(config);

      // 1. Bundle — reuse the exact backup creation the Backup screen uses.
      tempDir = await Directory.systemTemp.createTemp('sk_sync_push_');
      final timestamp = _fileTimestamp(_clock());
      final bundleName = 'bundle-$timestamp.skbak';
      final localPath = p.join(tempDir.path, bundleName);
      final backupResult = await backupService.createBackup(
        customPath: localPath,
      );
      if (!backupResult.success || backupResult.filePath == null) {
        throw SyncTargetException(
          'Backup bundle creation failed: '
          '${backupResult.errorMessage ?? 'unknown error'}',
        );
      }

      final bytes = await File(backupResult.filePath!).readAsBytes();
      final hash = sha256.convert(bytes).toString();

      // 2. Upload bundle.
      final machineDir = _machineDir(config);
      await target.ensureDirectory(machineDir);
      final remotePath = '$machineDir/$bundleName';
      await target.uploadFile(remotePath, bytes);

      // 3. Manifest update + prune.
      final manifest =
          await _readManifest(target, machineDir) ??
          SyncManifest(
            machine: sanitizeMachineName(config.machineName),
            appVersion: backupService.runtimeAppVersion,
            updatedAt: _clock(),
            bundles: const [],
          );
      final (updated, pruned) = manifest.withBundle(
        SyncBundleInfo(
          file: bundleName,
          sha256: hash,
          sizeBytes: bytes.length,
          createdAt: _clock(),
        ),
        retainCount: config.retainCount,
        now: _clock(),
      );
      await target.uploadFile(
        '$machineDir/manifest.json',
        utf8.encode(
          const JsonEncoder.withIndent('  ').convert(
            SyncManifest(
              machine: updated.machine,
              appVersion: backupService.runtimeAppVersion,
              updatedAt: updated.updatedAt,
              bundles: updated.bundles,
            ).toJson(),
          ),
        ),
      );
      for (final old in pruned) {
        try {
          await target.deleteFile('$machineDir/${old.file}');
        } on SyncTargetException catch (e) {
          // Best-effort: a stale bundle the server refuses to delete must
          // not fail the push that already succeeded.
          _logger.warning(
            'Failed to prune remote bundle ${old.file}: ${e.message}',
            source: 'SyncService',
          );
        }
      }

      final now = _clock();
      await settingsDao.setSettings({
        SyncSettingsKeys.lastPushAt: now.toIso8601String(),
        SyncSettingsKeys.lastError: '',
      });
      _logger.info(
        'Cloud sync push complete: $remotePath '
        '(${bytes.length} bytes, ${pruned.length} pruned)',
        source: 'SyncService',
      );
      return SyncPushResult(
        success: true,
        remotePath: remotePath,
        sizeBytes: bytes.length,
        timestamp: now,
      );
    } catch (e) {
      final message = e is SyncTargetException ? e.message : e.toString();
      _logger.error('Cloud sync push failed: $message', source: 'SyncService');
      await settingsDao.setSetting(SyncSettingsKeys.lastError, message);
      return SyncPushResult(
        success: false,
        errorMessage: message,
        timestamp: _clock(),
      );
    } finally {
      _pushInProgress = false;
      if (target != null) _closeIfOwned(target);
      if (tempDir != null) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {
          // Temp cleanup is best-effort.
        }
      }
    }
  }

  /// Opt-in scheduled push. Called by [AutoSaveService] after its daily
  /// backup cycle; swallows errors (they are recorded in sync state and
  /// surfaced in the settings UI) so a flaky network never breaks the
  /// local auto-backup path that invoked us.
  Future<void> maybeAutoPush({required String reason}) async {
    try {
      final config = await loadConfig();
      if (!config.autoPushEnabled || !config.isConfigured) return;
      _logger.info('Auto-push triggered ($reason)', source: 'SyncService');
      await pushNow();
    } catch (e) {
      _logger.warning('Auto-push ($reason) failed: $e', source: 'SyncService');
    }
  }

  /// List machine directories under `skotiq-sync/` on the remote.
  Future<List<SyncRemoteMachine>> listRemoteMachines() async {
    final target = await _buildTarget(await loadConfig());
    try {
      final entries = await target.listDirectory(kSyncRemoteRoot);
      return entries
          .where((e) => e.isDirectory)
          .map((e) => SyncRemoteMachine(e.name))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    } on SyncTargetException catch (e) {
      if (e.kind == SyncTargetErrorKind.notFound) {
        return const []; // Nothing has been pushed yet.
      }
      rethrow;
    } finally {
      _closeIfOwned(target);
    }
  }

  /// List the bundles a machine has pushed, newest first, from its
  /// manifest. Bundles present on disk but missing from the manifest are
  /// appended (hash-less) so a hand-uploaded bundle is still reachable.
  Future<List<SyncBundleInfo>> listRemoteBundles(String machine) async {
    final target = await _buildTarget(await loadConfig());
    try {
      final dir = '$kSyncRemoteRoot/${sanitizeMachineName(machine)}';
      final manifest = await _readManifest(target, dir);
      final known = manifest?.bundles ?? const <SyncBundleInfo>[];
      final knownNames = known.map((b) => b.file).toSet();

      List<SyncRemoteEntry> entries;
      try {
        entries = await target.listDirectory(dir);
      } on SyncTargetException catch (e) {
        if (e.kind == SyncTargetErrorKind.notFound) return const [];
        rethrow;
      }
      final extras = entries
          .where(
            (e) =>
                !e.isDirectory &&
                // `.nsbak` is the pre-rename bundle extension; bundles a
                // previous build uploaded still count toward the listing.
                (e.name.endsWith('.skbak') || e.name.endsWith('.nsbak')) &&
                !knownNames.contains(e.name),
          )
          .map(
            (e) => SyncBundleInfo(
              file: e.name,
              sha256: '',
              sizeBytes: e.sizeBytes ?? 0,
              createdAt: e.modified ?? DateTime.fromMillisecondsSinceEpoch(0),
            ),
          );
      return [...known, ...extras];
    } finally {
      _closeIfOwned(target);
    }
  }

  /// Download a bundle, verify its hash against the machine's manifest,
  /// stage it locally and hand it to [BackupService.restoreBackup].
  ///
  /// What the restore does is [mode]'s to say ([RestoreMode.summary]); the
  /// caller shows that to the operator and gets a yes first.
  Future<RestoreResult> pullAndRestore({
    required String machine,
    required String bundleFile,
    required RestoreMode mode,
  }) async {
    final target = await _buildTarget(await loadConfig());
    try {
      final dir = '$kSyncRemoteRoot/${sanitizeMachineName(machine)}';
      final bytes = await target.downloadFile('$dir/$bundleFile');

      // Hash verification against the manifest. A bundle that the manifest
      // knows about MUST match; a bundle absent from the manifest (manual
      // upload, pre-manifest push) is allowed through with a logged
      // warning since there is no recorded hash to check against.
      final manifest = await _readManifest(target, dir);
      SyncBundleInfo? expected;
      for (final b in manifest?.bundles ?? const <SyncBundleInfo>[]) {
        if (b.file == bundleFile && b.sha256.isNotEmpty) {
          expected = b;
          break;
        }
      }
      if (expected != null) {
        final actual = sha256.convert(bytes).toString();
        if (actual != expected.sha256) {
          return RestoreResult(
            success: false,
            errorMessage:
                'Hash mismatch for "$bundleFile". The remote bundle is '
                'corrupt or was tampered with. Restore aborted; local data '
                'was not touched.',
            timestamp: _clock(),
          );
        }
      } else {
        _logger.warning(
          'No manifest hash for "$bundleFile" — restoring without '
          'integrity verification',
          source: 'SyncService',
        );
      }

      final downloadDir = await _downloadDirectoryProvider();
      final stem = p.basenameWithoutExtension(bundleFile);
      final localFile = File(
        p.join(
          downloadDir.path,
          'cloud-${sanitizeMachineName(machine)}-$stem.skbackup',
        ),
      );
      await localFile.writeAsBytes(bytes, flush: true);

      return backupService.restoreBackup(filePath: localFile.path, mode: mode);
    } on SyncTargetException catch (e) {
      return RestoreResult(
        success: false,
        errorMessage: e.message,
        timestamp: _clock(),
      );
    } finally {
      _closeIfOwned(target);
    }
  }

  Future<SyncManifest?> _readManifest(SyncTarget target, String dir) async {
    try {
      final bytes = await target.downloadFile('$dir/manifest.json');
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return null;
      return SyncManifest.fromJson(decoded);
    } on SyncTargetException catch (e) {
      if (e.kind == SyncTargetErrorKind.notFound) return null;
      rethrow;
    } on FormatException {
      _logger.warning(
        'Remote manifest.json in $dir is malformed — treating as absent',
        source: 'SyncService',
      );
      return null;
    }
  }

  void _closeIfOwned(SyncTarget target) {
    if (target is WebDavSyncTarget) {
      target.close();
    } else if (target is S3SyncTarget) {
      // S3SyncTarget.close() guards _ownsClient, so an injected test client
      // is never closed.
      target.close();
    }
  }

  static String _fileTimestamp(DateTime t) =>
      t.toUtc().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');
}
