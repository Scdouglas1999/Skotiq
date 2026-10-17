import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as path;

import '../models/update_manifest.dart';
import 'anti_freeze_store.dart';
import 'archive_extraction.dart';
import 'android_installer.dart';
import 'github_release_source.dart';
import 'update_compatibility.dart';
import 'update_downloader.dart';
import 'update_verifier.dart';

/// Filename of the staged manifest persisted alongside `ready.json`.
/// Both staging paths (HTTPS download + LAN push) write this so apply-time
/// can recover the exact verified manifest.
const String _stagedManifestFile = 'manifest.json';

/// Marker proving the staged tree was end-to-end verified (manifest
/// signature + package hash + per-file hashes). Apply-time refuses to
/// touch the install or copy `updater.exe` unless this marker exists
/// and its content matches the staged manifest.
const String _stagedVerifiedMarker = 'staged_verified.marker';

/// Filename of the per-file expected-hashes JSON consumed by the Rust
/// updater (`--expected-hashes`). Built from the verified manifest at
/// apply-time so the on-disk copy is never read after the manifest has
/// been hash-verified.
const String _expectedHashesFile = 'expected_hashes.json';

/// Deadline for the two small metadata fetches (`/api/version` and the
/// manifest), so they stay bounded: the controller has a single operation slot,
/// and a host that accepts the connection and never answers would hold it until
/// the process restarts, turning every later check/download/apply into a
/// `StateError`.
const Duration defaultUpdateHttpTimeout = Duration(seconds: 20);

/// Name of the helper binary that performs the install swap.
///
/// The swap cannot be done by the running app, which holds its own files
/// open, so a separate short-lived process does it after the app exits.
/// Windows needs the `.exe` suffix to execute it; Linux must not have one,
/// and looking for `updater.exe` there was why the Linux apply path could
/// never find its own helper.
final String updaterExecutableName = Platform.isWindows
    ? 'updater.exe'
    : 'updater';

/// The command line this process was started with, as its `main` received it.
///
/// Handed to the updater so the app comes back the way it was started. A
/// headless rig launched as `skotiq_desktop --headless --port=...` used to
/// be relaunched with no arguments at all, which starts the GUI: on a machine
/// with no display that is nothing, and the rig drops off the network after
/// what looked like a successful update.
List<String> _relaunchArguments = const [];

/// Record the app's own command line for the updater to reuse. Called once
/// from `main`.
void setUpdateRelaunchArguments(List<String> args) {
  _relaunchArguments = List.unmodifiable(args);
}

/// Updater flags that restart the app with [setUpdateRelaunchArguments]'s
/// command line. `=` keeps a value that starts with `--` attached to its flag.
List<String> updaterRelaunchFlags() => [
  for (final arg in _relaunchArguments) '--relaunch-arg=$arg',
];

/// One-shot UI banner queued after [getStagedUpdate] discards a
/// corrupted marker. The next consumer that reads + clears
/// this gets a single chance to surface the message; the banner is not
/// re-emitted on subsequent reads.
class UpdateNotice {
  final String message;
  final DateTime occurredAt;
  const UpdateNotice(this.message, this.occurredAt);
}

class _NoticeQueue {
  UpdateNotice? _pending;

  void enqueue(String message) {
    _pending = UpdateNotice(message, DateTime.now());
  }

  UpdateNotice? takePending() {
    final notice = _pending;
    _pending = null;
    return notice;
  }
}

/// Main service for managing OTA updates
class UpdateService {
  final String _currentVersion;
  final int _currentBuildNumber;
  final UpdateDownloader _downloader;
  final UpdateVerifier _verifier;
  final AntiFreezeStore _antiFreezeStore;
  final http.Client _httpClient;
  final Duration _httpTimeout;
  final Future<Directory> Function() _applicationSupportDirectoryProvider;
  final Future<Directory> Function() _installDirectoryProvider;
  final bool _allowInsecureUpdateSource;
  final String _currentPlatform;
  final String _currentArch;
  final _NoticeQueue _noticeQueue = _NoticeQueue();

  String? _updateServerUrl;
  GithubReleaseSource? _githubSource;
  String _channel = 'stable';
  CancelToken? _currentDownloadToken;

  UpdateService({
    required String currentVersion,
    required int currentBuildNumber,
    UpdateDownloader? downloader,
    UpdateVerifier? verifier,
    AntiFreezeStore? antiFreezeStore,
    http.Client? httpClient,
    Duration httpTimeout = defaultUpdateHttpTimeout,
    Future<Directory> Function()? applicationSupportDirectoryProvider,
    Future<Directory> Function()? installDirectoryProvider,
    String? currentPlatform,
    String? currentArch,
    // OTA sources must use https. This default-off escape hatch exists
    // only for trusted local testing (e.g. a loopback mock server) and is
    // sourced from a compile-time define so production builds can never
    // silently allow http. Leave it false in any shipped build.
    bool allowInsecureUpdateSource = const bool.fromEnvironment(
      'SKOTIQ_ALLOW_INSECURE_UPDATE_SOURCE',
    ),
  }) : _currentVersion = currentVersion,
       _currentBuildNumber = currentBuildNumber,
       _downloader = downloader ?? UpdateDownloader(),
       _verifier = verifier ?? UpdateVerifier(),
       _antiFreezeStore =
           antiFreezeStore ??
           AntiFreezeStore(
             applicationSupportDirectoryProvider ?? resolveSkotiqDataDirectory,
           ),
       _httpClient = httpClient ?? http.Client(),
       _httpTimeout = httpTimeout,
       _applicationSupportDirectoryProvider =
           applicationSupportDirectoryProvider ?? resolveSkotiqDataDirectory,
       _installDirectoryProvider =
           installDirectoryProvider ?? _executableDirectory,
       _allowInsecureUpdateSource = allowInsecureUpdateSource,
       _currentPlatform = normalizeUpdatePlatform(
         currentPlatform ?? Platform.operatingSystem,
       ),
       _currentArch = normalizeUpdateArchitecture(
         currentArch ?? currentUpdateArchitecture(),
       );

  /// Whether this build can cryptographically authenticate update manifests
  /// to the vendor key. False when no trusted Ed25519 public key is compiled
  /// in (or every key id has been revoked): OTA can still surface that an
  /// update exists, but [downloadAndStage] / [applyUpdate] fail closed. The
  /// wiring reads this to warn when a server is configured against a build
  /// that cannot accept downloads.
  bool get canAuthenticateUpdates => _verifier.hasTrustedPublicKey;

  /// Whether an Abort request can still interrupt the network transfer.
  /// Verification/extraction deliberately run to a clean terminal state.
  bool get canCancelDownload => _currentDownloadToken != null;

  /// Refuse any update source URL that is not https.
  ///
  /// An update fetched over plaintext http can be transparently rewritten
  /// by a network attacker. The manifest signature check is the primary
  /// defence; requiring https closes the downgrade/observation surface and
  /// matches the vendor download URLs the build scripts emit.
  /// http is permitted only when [_allowInsecureUpdateSource] is explicitly
  /// enabled (default off) for trusted local testing.
  void _assertSecureUpdateUrl(String rawUrl, String purpose) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme) {
      throw UpdateException('Invalid $purpose URL: "$rawUrl"');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'https') {
      return;
    }
    if (scheme == 'http' && _allowInsecureUpdateSource) {
      return;
    }
    throw UpdateException(
      'Refusing $purpose over insecure scheme "${uri.scheme}": $rawUrl. '
      'Update sources must use https. Enable allowInsecureUpdateSource only '
      'for trusted local testing.',
    );
  }

  /// Cancel any in-progress download
  void cancelDownload() {
    _currentDownloadToken?.cancel();
    _currentDownloadToken = null;
  }

  /// Configure the update server URL and channel
  void configure({required String serverUrl, String channel = 'stable'}) {
    _updateServerUrl = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    _githubSource = null;
    _channel = channel;
  }

  /// Read updates from a project's GitHub Releases instead of an update
  /// server.
  ///
  /// This is the source shipped builds use. CI already attaches a signed
  /// manifest to every release, so discovery is the only thing that changes:
  /// the manifest is authenticated to the vendor key exactly as before, and a
  /// release carrying an unsigned or wrongly-signed manifest is refused at
  /// download time just like an update server's would be.
  ///
  /// Supersedes any [configure] call; the two sources are mutually exclusive
  /// so there is never a question of which one a check consulted.
  void configureGithubSource({
    required String owner,
    required String repo,
    String channel = 'stable',
    GithubReleaseSource? source,
  }) {
    _githubSource =
        source ??
        GithubReleaseSource(
          owner: owner,
          repo: repo,
          httpClient: _httpClient,
          timeout: _httpTimeout,
        );
    _updateServerUrl = null;
    _channel = channel;
  }

  /// Change the channel without touching the configured source.
  ///
  /// The one-off `?channel=` override must come through here rather than
  /// [configure] or [configureGithubSource]: both of those pick the source as
  /// well, so routing a channel change through either silently discards
  /// whichever source is currently set.
  void setChannel(String channel) {
    _channel = channel;
  }

  /// Whether any update source is configured. False means checks are skipped
  /// rather than failed: an operator who wants no OTA has not set one.
  bool get hasUpdateSource =>
      _githubSource != null ||
      (_updateServerUrl != null && _updateServerUrl!.isNotEmpty);

  /// Human-facing page for the configured source's releases, when it has one.
  String? get releasesPageUrl => _githubSource?.releasesPageUrl;

  /// Pop the most recent UI banner notice queued by background work, if any.
  /// Returns null if no notice is pending. Subsequent calls return null until
  /// a new notice is queued.
  UpdateNotice? takePendingNotice() => _noticeQueue.takePending();

  /// Verify whether a previously applied update booted successfully.
  Future<PendingInstallStatus> verifyPendingInstall() async {
    final pendingFile = await _getPendingInstallFile();
    if (!await pendingFile.exists()) {
      return const PendingInstallStatus.none();
    }

    try {
      final payload =
          jsonDecode(await pendingFile.readAsString()) as Map<String, dynamic>;
      final targetVersion = payload['targetVersion'] as String?;
      final targetBuild = payload['targetBuildNumber'] as int?;
      final previousVersion = payload['previousVersion'] as String?;
      final previousBuild = payload['previousBuildNumber'] as int?;
      final backupDirPath = payload['backupDir'] as String?;

      // The marker is the only record of what was being installed. When it does
      // not name a build, say so — rendering "+0" would put a build number the
      // operator can compare against their running build into a message where
      // no build number was ever recorded.
      final targetLabel = switch ((targetVersion, targetBuild)) {
        (final String v, final int b) => '$v+$b',
        (final String v, null) => '$v (build not recorded)',
        (null, final int b) => 'an unnamed version+$b',
        _ => 'an unrecorded version',
      };

      if (targetVersion == _currentVersion &&
          targetBuild == _currentBuildNumber) {
        await pendingFile.delete();
        if (backupDirPath != null) {
          final backupDir = Directory(backupDirPath);
          if (await backupDir.exists()) {
            await backupDir.delete(recursive: true);
          }
        }
        return PendingInstallStatus.verified(
          'Verified update $targetVersion+$targetBuild on startup.',
        );
      }

      if (previousVersion == _currentVersion &&
          previousBuild == _currentBuildNumber) {
        await pendingFile.delete();
        // The staged copy of the update that was just rolled back is either
        // gone (the updater removes the extracted tree once the swap
        // succeeds) or the tree that failed the updater's checks. Offering it
        // as ready to install could only fail the same way; a fresh check
        // offers the release again with a new download.
        final staged = await getStagedUpdate();
        if (staged != null &&
            staged.version == targetVersion &&
            staged.buildNumber == targetBuild) {
          await clearStagedUpdate();
        }
        return PendingInstallStatus.rolledBack(
          'Rollback restored build $_currentVersion+$_currentBuildNumber '
          'after update to $targetLabel.',
        );
      }

      return PendingInstallStatus.requiresAttention(
        'Pending update marker targets $targetLabel, but the running build is '
        '$_currentVersion+$_currentBuildNumber.',
      );
    } catch (e) {
      await pendingFile.delete();
      return PendingInstallStatus.requiresAttention(
        'Discarded unreadable pending update marker: $e',
      );
    }
  }

  /// GET with a hard deadline. Every update metadata fetch goes through here
  /// so no update-server behaviour can leave the caller waiting forever.
  Future<http.Response> _get(Uri uri) => _httpClient
      .get(uri)
      .timeout(
        _httpTimeout,
        onTimeout: () => throw UpdateException(
          'Update server did not respond within ${_httpTimeout.inSeconds}s '
          '($uri).',
        ),
      );

  /// Check for available updates
  Future<UpdateCheckResult> checkForUpdates() async {
    final github = _githubSource;
    if (github != null) return _checkGithubForUpdates(github);

    if (_updateServerUrl == null) {
      throw UpdateException('Update server URL not configured');
    }

    try {
      // Fetch version info from server
      final versionUrl = '$_updateServerUrl/api/version';
      _assertSecureUpdateUrl(versionUrl, 'update version check');
      final response = await _get(Uri.parse(versionUrl));

      if (response.statusCode != 200) {
        throw UpdateException('Server returned ${response.statusCode}');
      }

      final versionInfo = VersionInfo.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );

      // Get the channel info
      final channelInfo = versionInfo.channels[_channel];
      if (channelInfo == null) {
        return UpdateCheckResult(
          hasUpdate: false,
          currentVersion: _currentVersion,
        );
      }

      // Check if newer version available
      final latestVersion = channelInfo.version;
      final manifest = await _fetchManifest(channelInfo.manifestUrl);
      if (manifest.version != latestVersion) {
        throw UpdateException(
          'Update metadata mismatch: channel "$_channel" advertises '
          '$latestVersion, but its manifest identifies ${manifest.version}.',
        );
      }
      _assertManifestCompatibility(manifest);

      // Offer when the semver is strictly newer, or when it matches the
      // current semver but carries a higher build (a rebuild of the same
      // version). An identical version+build is never offered, so there is
      // no self-update loop.
      if (manifest.isNewerBuildThan(_currentVersion, _currentBuildNumber)) {
        // Check if we can upgrade from current version
        if (!manifest.canUpgradeFrom(_currentVersion)) {
          return UpdateCheckResult(
            hasUpdate: true,
            currentVersion: _currentVersion,
            availableVersion: latestVersion,
            manifest: manifest,
            requiresManualUpgrade: true,
          );
        }

        return UpdateCheckResult(
          hasUpdate: true,
          currentVersion: _currentVersion,
          availableVersion: latestVersion,
          manifest: manifest,
        );
      }

      return UpdateCheckResult(
        hasUpdate: false,
        currentVersion: _currentVersion,
      );
    } on SocketException catch (e) {
      throw UpdateException('Network error: ${e.message}');
    } on http.ClientException catch (e) {
      throw UpdateException('Network error: ${e.message}');
    } on FormatException catch (e) {
      throw UpdateException('Invalid response format: ${e.message}');
    } on TypeError catch (e) {
      throw UpdateException('Invalid response format: $e');
    }
  }

  /// Check GitHub Releases for a newer build.
  ///
  /// The release tag and the manifest must agree on the version. They are
  /// produced by the same CI job from the same `version.yaml`, so a mismatch
  /// means the assets on that release were not all built from one commit —
  /// exactly the case where installing the package the manifest names would
  /// put an unexpected build on the machine. Refuse instead of guessing which
  /// one is right.
  Future<UpdateCheckResult> _checkGithubForUpdates(
    GithubReleaseSource github,
  ) async {
    try {
      final release = await github.fetchLatestRelease(channel: _channel);
      if (release == null) {
        return UpdateCheckResult(
          hasUpdate: false,
          currentVersion: _currentVersion,
        );
      }

      final resolved = await github.fetchManifest(
        release,
        platform: _currentPlatform,
        arch: _currentArch,
      );
      final manifest = resolved.manifest;

      if (manifest.version != release.version) {
        throw UpdateException(
          'Update metadata mismatch: release ${release.tagName} advertises '
          '${release.version}, but its manifest identifies '
          '${manifest.version}.',
        );
      }

      // Version and build number are the same across every target CI builds
      // from one `version.yaml`, so this comparison holds even when the
      // manifest that was found describes another platform. Answering it
      // first keeps a host that is already current from being told anything
      // about which packages the release happens to carry.
      if (!manifest.isNewerBuildThan(_currentVersion, _currentBuildNumber)) {
        return UpdateCheckResult(
          hasUpdate: false,
          currentVersion: _currentVersion,
        );
      }

      final pageUrl = release.htmlUrl.isNotEmpty
          ? release.htmlUrl
          : github.releasesPageUrl;

      final incompatible = incompatibleUpdateTargetMessage(
        manifest,
        currentPlatform: _currentPlatform,
        currentArch: _currentArch,
      );
      if (incompatible != null) {
        // A manifest named for this host that describes a different one is a
        // packaging fault, and stays loud. A bare `manifest.json` describing
        // another platform means the release carries nothing this host can
        // install — ordinary for a release built before per-target manifests,
        // and not something the operator can act on. Reporting it as a failed
        // check would put an error on screen every time a Linux or Android
        // install looked for an update.
        if (!resolved.isGenericFallback) throw UpdateException(incompatible);
        return UpdateCheckResult(
          hasUpdate: false,
          currentVersion: _currentVersion,
          unavailableReason:
              'Release ${release.tagName} publishes no update that this '
              '$_currentPlatform/$_currentArch build can install.',
          releasePageUrl: pageUrl,
        );
      }

      final notes = tidyReleaseNotes(release.body) ?? manifest.releaseNotes;

      return UpdateCheckResult(
        hasUpdate: true,
        currentVersion: _currentVersion,
        availableVersion: manifest.version,
        manifest: manifest,
        requiresManualUpgrade: !manifest.canUpgradeFrom(_currentVersion),
        releaseNotes: notes,
        releasePageUrl: pageUrl,
      );
    } on GithubReleaseException catch (e) {
      throw UpdateException(e.message);
    } on FormatException catch (e) {
      throw UpdateException('Invalid response format: ${e.message}');
    } on TypeError catch (e) {
      throw UpdateException('Invalid response format: $e');
    }
  }

  /// Fetch manifest from URL (relative or absolute)
  Future<UpdateManifest> _fetchManifest(String manifestUrl) async {
    final baseUri = Uri.parse('$_updateServerUrl/');
    final url = baseUri.resolve(manifestUrl).toString();

    _assertSecureUpdateUrl(url, 'manifest fetch');
    final response = await _get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw UpdateException('Failed to fetch manifest: ${response.statusCode}');
    }

    return UpdateManifest.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  void _assertManifestCompatibility(UpdateManifest manifest) {
    final incompatibility = incompatibleUpdateTargetMessage(
      manifest,
      currentPlatform: _currentPlatform,
      currentArch: _currentArch,
    );
    if (incompatibility != null) throw UpdateException(incompatibility);
  }

  /// Download and stage an update
  Future<void> downloadAndStage(
    UpdateManifest manifest, {
    DownloadProgressCallback? onProgress,
    void Function()? onVerifying,
  }) async {
    // The download is cryptographically authenticated to the vendor key.
    // A build with no trusted update public key compiled in
    // (SKOTIQ_UPDATE_PUBLIC_KEY) cannot authenticate ANY manifest, so
    // OTA auto-update is disabled by design. Refusing loudly beats falling
    // back to hash-only acceptance of a self-referential manifest, which
    // is an RCE / supply-chain hole. The LAN push receiver takes the same
    // posture and refuses to start without a trusted key.
    if (!_verifier.hasTrustedPublicKey) {
      throw UpdateException(
        'OTA auto-update is disabled: this build has no trusted update '
        'public key (SKOTIQ_UPDATE_PUBLIC_KEY) compiled in, so update '
        'manifests cannot be authenticated to the vendor. Provision the '
        'vendor public key at build time to enable signed OTA updates.',
      );
    }

    // Reject plaintext download sources (unless explicitly allowed for
    // trusted local testing) before spending any bandwidth.
    _assertSecureUpdateUrl(manifest.downloadUrl, 'package download');

    // Authenticate the manifest before downloading what it names. A manifest
    // that can never verify would otherwise cost the whole package over a
    // rig's link, and then be reported as a corrupted or tampered download,
    // which sends the operator looking at the network instead of the release.
    // The signature is checked again with the package hash after download.
    if (manifest.signature == null || manifest.signature!.trim().isEmpty) {
      throw UpdateException(
        'Skotiq ${manifest.version} was published without a signature on '
        'its update manifest, so this build will not install it. Install it '
        'from the release page instead.',
      );
    }
    if (!await _verifier.verifyManifestSignature(manifest)) {
      throw UpdateException(
        'The update manifest for Skotiq ${manifest.version} is not signed '
        'by the Skotiq update key this build trusts, so it will not be '
        'installed.',
      );
    }

    // Android ships an APK, not a tree of files to swap: there is nothing to
    // extract and nothing to hash per-file, and the install is performed by
    // the OS rather than by the updater binary.
    if (_currentPlatform == 'android') {
      return _downloadAndStageApk(
        manifest,
        onProgress: onProgress,
        onVerifying: onVerifying,
      );
    }

    // Get staging directory
    final stagingDir = await _getStagingDirectory();
    final packagePath = path.join(stagingDir.path, 'update.zip');

    // Create cancel token for this download
    _currentDownloadToken = CancelToken();

    // Download the package
    try {
      await _downloader.download(
        manifest.downloadUrl,
        packagePath,
        onProgress: onProgress,
        expectedSize: manifest.compressedSize,
        cancelToken: _currentDownloadToken,
      );
    } finally {
      // Once the byte stream ends (success, cancellation, or error), Abort can
      // no longer affect this token. Never leave a stale token looking active.
      _currentDownloadToken = null;
    }

    // Hash/signature verification and extraction are deliberately
    // non-abortable: cancelling after the bytes are complete could otherwise
    // leave a partially-promoted staging tree. Tell the controller/UI that the
    // cancellable network phase has ended.
    onVerifying?.call();

    // Verify package integrity: size and SHA-256 hash
    final packageFile = File(packagePath);
    final verified = await _verifier.verifyPackage(packageFile, manifest);
    if (!verified) {
      await packageFile.delete();
      throw UpdateException(
        'Package integrity verification failed: '
        'the package hash or manifest signature did not verify. '
        'The download may be corrupted or tampered with.',
      );
    }

    // Anti-freeze: the signature above proves `releaseDate` is vendor-signed,
    // so reject a manifest that is older than the newest release this host
    // already accepted (a rollback/freeze attack) or implausibly future-dated.
    await _assertManifestNotRolledBack(manifest);

    // Extract the package
    final extractDir = Directory(path.join(stagingDir.path, 'extracted'));
    if (await extractDir.exists()) {
      await extractDir.delete(recursive: true);
    }
    await extractDir.create(recursive: true);

    await extractZipSafely(packageFile, extractDir);

    // Verify extracted files
    final verification = await _verifier.verifyDirectory(extractDir, manifest);
    if (!verification.success) {
      await extractDir.delete(recursive: true);
      throw UpdateException('Verification failed: $verification');
    }

    await persistStagedManifest(stagingDir, manifest);

    // Advance the anti-freeze watermark only now, after a fully verified
    // stage: a malicious or future-dated manifest that fails any earlier
    // gate can never poison the high-water mark.
    await _antiFreezeStore.advance(_channel, manifest.releaseDate);

    // Marker file indicating staging is complete (separate from
    // staged_verified.marker which proves end-to-end verification).
    final markerFile = File(path.join(stagingDir.path, 'ready.json'));
    await markerFile.writeAsString(
      jsonEncode({
        'version': manifest.version,
        'buildNumber': manifest.buildNumber,
        'stagedAt': DateTime.now().toIso8601String(),
        'extractPath': extractDir.path,
      }),
    );
  }

  /// Hand a verified APK to Android's package installer.
  ///
  /// Control returns here: Android shows its own confirmation UI, and the app
  /// keeps running until the user accepts and the system replaces it. That is
  /// why this does not exit the process the way the desktop path does, and
  /// why no pending-install marker is written — there is no window in which a
  /// half-applied install could exist for startup to detect.
  Future<void> _applyAndroidUpdate(
    String apkPath,
    UpdateManifest manifest,
  ) async {
    final apk = File(apkPath);
    if (!await apk.exists()) {
      throw UpdateException(
        'Staged APK is missing from $apkPath. The staged update must be '
        'downloaded again.',
      );
    }

    // Re-hash immediately before hand-off. Between staging and apply the file
    // sat in app storage where another process on a rooted device could have
    // swapped it; the signature check above covers the manifest, not the
    // bytes still on disk.
    final actualHash = await _verifier.hashFile(apk);
    final expected = manifest.packageSha256;
    if (expected == null ||
        actualHash.toLowerCase() != expected.toLowerCase()) {
      await apk.delete();
      throw UpdateException(
        'Staged APK no longer matches the hash its signed manifest names; '
        'refusing to install it.',
      );
    }

    await installApkViaPlatform(apkPath);
  }

  /// Download and verify an Android APK for hand-off to the system installer.
  ///
  /// The desktop path stages a tree and swaps it in itself, so it verifies
  /// every file after extraction. An APK is installed by Android, which does
  /// its own package-signature check and refuses an APK not signed by the key
  /// that signed the installed app. This path therefore verifies exactly what
  /// it is responsible for — that the bytes are the ones the vendor-signed
  /// manifest names — and lets the platform enforce the rest. Both checks are
  /// mandatory: neither substitutes for the other.
  Future<void> _downloadAndStageApk(
    UpdateManifest manifest, {
    DownloadProgressCallback? onProgress,
    void Function()? onVerifying,
  }) async {
    final stagingDir = await _getStagingDirectory();
    // A fixed name, like the desktop path's `update.zip`. The bytes land
    // before the manifest's signature has been checked, so no manifest field
    // may take part in choosing where they are written.
    final apkPath = path.join(stagingDir.path, 'update.apk');

    _currentDownloadToken = CancelToken();
    try {
      await _downloader.download(
        manifest.downloadUrl,
        apkPath,
        onProgress: onProgress,
        expectedSize: manifest.compressedSize,
        cancelToken: _currentDownloadToken,
      );
    } finally {
      _currentDownloadToken = null;
    }

    onVerifying?.call();

    final apkFile = File(apkPath);
    final verified = await _verifier.verifyPackage(apkFile, manifest);
    if (!verified) {
      await apkFile.delete();
      throw UpdateException(
        'Package integrity verification failed: '
        'the package hash or manifest signature did not verify. '
        'The download may be corrupted or tampered with.',
      );
    }

    await _assertManifestNotRolledBack(manifest);
    await persistStagedManifest(stagingDir, manifest);
    await _antiFreezeStore.advance(_channel, manifest.releaseDate);

    // `extractPath` names the APK itself here rather than a directory. The
    // Android apply path hands that exact file to the installer; nothing on
    // this platform ever walks it as a tree.
    final markerFile = File(path.join(stagingDir.path, 'ready.json'));
    await markerFile.writeAsString(
      jsonEncode({
        'version': manifest.version,
        'buildNumber': manifest.buildNumber,
        'stagedAt': DateTime.now().toIso8601String(),
        'extractPath': apkPath,
      }),
    );
  }

  /// The manifest of the currently staged update, or null when nothing is
  /// staged or the stored manifest cannot be read.
  ///
  /// Callers get the manifest the update was actually staged from, rather
  /// than rebuilding a stand-in out of `ready.json` — which carries only a
  /// version and a build number, so every other field would have to be
  /// invented.
  Future<UpdateManifest?> readStagedManifest() async =>
      _readStagedManifest(await _getStagingDirectory());

  /// Get the staging directory for updates
  Future<Directory> _getStagingDirectory() async {
    final updatesRoot = await _getUpdatesRootDirectory();
    final staging = Directory(path.join(updatesRoot.path, 'staging'));
    if (!await staging.exists()) {
      await staging.create(recursive: true);
    }
    return staging;
  }

  /// Check if there's a staged update ready to apply.
  ///
  /// Marker corruption is a destructive event: the staged directory is
  /// wiped (the bytes on disk have lost their provenance and are not
  /// trustworthy) and a one-shot UI banner is queued so the user learns
  /// the staged update was discarded.
  Future<StagedUpdate?> getStagedUpdate() async {
    final staging = await _getStagingDirectory();
    final markerFile = File(path.join(staging.path, 'ready.json'));

    if (!await markerFile.exists()) {
      return null;
    }

    try {
      final content = await markerFile.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      final version = data['version'];
      final buildNumber = data['buildNumber'];
      final stagedAt = data['stagedAt'];
      final extractPath = data['extractPath'];

      if (version is! String ||
          buildNumber is! int ||
          stagedAt is! String ||
          extractPath is! String) {
        throw const FormatException('marker missing required fields');
      }

      // A staged build that does not supersede the running one has already
      // been installed, or been overtaken by a newer install. Android always
      // lands here after a successful update: the OS replaces and relaunches
      // the app, and nothing clears staging the way the desktop helper does.
      // Offering it would announce the running version as a pending update.
      if (!UpdateManifest.buildSupersedes(
        version,
        buildNumber,
        _currentVersion,
        _currentBuildNumber,
      )) {
        developer.log(
          'Discarding staged update $version+$buildNumber: the running build '
          '$_currentVersion+$_currentBuildNumber is not older.',
          name: 'UpdateService',
          level: 800,
        );
        await clearStagedUpdate();
        return null;
      }

      return StagedUpdate(
        version: version,
        buildNumber: buildNumber,
        stagedAt: DateTime.parse(stagedAt),
        extractPath: extractPath,
      );
    } catch (e) {
      developer.log(
        'Discarding corrupted staged-update marker (${markerFile.path}): $e',
        name: 'UpdateService',
        level: 900,
      );
      _noticeQueue.enqueue(
        'A staged update was found in an inconsistent state and was '
        'discarded. Please redownload.',
      );
      await clearStagedUpdate();
      return null;
    }
  }

  /// Clear any staged update
  Future<void> clearStagedUpdate() async {
    final staging = await _getStagingDirectory();
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }

  /// Apply staged update by launching the external updater.
  ///
  /// The updater will:
  /// 1. Wait for this process to exit.
  /// 2. Move-then-copy each staged file (rolling back to .bak on failure).
  /// 3. Hash-verify every applied file against `expected_hashes.json`.
  /// 4. Launch the new version (if `--launch-after`).
  ///
  /// The updater is spawned only when [_stagedVerifiedMarker] is present
  /// and matches the staged manifest hash AND the staged manifest's vendor
  /// Ed25519 signature re-verifies against the trusted key compiled into
  /// this build. The marker alone is a cheap consistency check — its value
  /// is sha256(manifest), which an attacker who can write the staging dir
  /// can recompute after swapping the manifest + tree + marker — so the
  /// signature is the authoritative apply-time gate and fails closed when
  /// no trusted key is present, matching the download-time posture. On
  /// `Process.start` failure the in-memory status returns to staged rather
  /// than `exit(0)`-ing into a half-broken state.
  Future<UpdateApplyOutcome> applyUpdate() async {
    final staged = await getStagedUpdate();
    if (staged == null) {
      throw UpdateException('No staged update available');
    }

    final stagingRoot = await _getStagingDirectory();
    final manifest = await _readStagedManifest(stagingRoot);
    if (manifest == null) {
      throw UpdateException(
        'Staged manifest is missing or unreadable. '
        'The staged update is incomplete and must be rebuilt.',
      );
    }

    // The marker matches the staged manifest before any byte of the
    // install is touched. A missing or stale marker means the staging tree
    // is not trusted. This is a cheap consistency check only — the
    // signature gate below carries the authoritative trust.
    await _assertVerifiedMarkerMatches(stagingRoot, manifest);

    // The marker above hashes the manifest with sha256, which an attacker
    // who can write the staging dir can recompute after swapping the
    // manifest + extracted tree + marker. The authoritative apply-time gate
    // is the vendor Ed25519 signature, re-verified against the trusted key
    // compiled into this build before any byte of the install is touched.
    // This mirrors the download-time posture and fails closed — a build
    // with no trusted key cannot authenticate any update, and an unsigned
    // or invalidly signed staged manifest is rejected — so a hash-only
    // forgery cannot pass even though the marker matches.
    if (!_verifier.hasTrustedPublicKey) {
      throw UpdateException(
        'Refusing to apply staged update: this build has no trusted update '
        'public key (SKOTIQ_UPDATE_PUBLIC_KEY) compiled in, so the '
        'staged manifest cannot be authenticated to the vendor.',
      );
    }
    if (!await _verifier.verifyManifestSignature(manifest)) {
      throw UpdateException(
        'Staged manifest failed Ed25519 signature re-verification at apply '
        'time; refusing to apply. The staging tree may have been tampered '
        'with after download (a recomputed hash marker is not sufficient).',
      );
    }

    // Anti-freeze re-check at apply time: a staged tree could have sat on
    // disk while a newer release was accepted, or been swapped for an older
    // signed manifest. The signature above is genuine, so the vendor-signed
    // releaseDate is authoritative — refuse a rollback/freeze here too.
    await _assertManifestNotRolledBack(manifest);

    // Android hands the verified APK to the system installer. There is no
    // file swap to perform, no updater binary to launch and no backup to
    // keep: Android replaces the package atomically and keeps the user's
    // data, and a failed install leaves the current app in place.
    if (_currentPlatform == 'android') {
      await _applyAndroidUpdate(staged.extractPath, manifest);
      return UpdateApplyOutcome.handedToPlatformInstaller;
    }

    // Build expected_hashes.json (POSIX-relative path -> sha256 hex)
    // straight from the verified manifest. The Rust updater will
    // re-verify this exact data after apply.
    final expectedHashesFile = await _writeExpectedHashes(
      stagingRoot,
      manifest,
    );

    final installDir = await _getInstallDirectory();
    final updaterPath = path.join(installDir.path, updaterExecutableName);
    final backupDir = await _getBackupDirectory();
    final pendingFile = await _getPendingInstallFile();

    // Bootstrap updater.exe out of the verified staging tree if it is
    // missing from the install dir (e.g. user installed before updater
    // was bundled). We only do this AFTER the verified marker check
    // above so we never copy an updater binary from an untrusted tree.
    if (!await File(updaterPath).exists()) {
      final stagedUpdaterPath = path.join(
        staged.extractPath,
        updaterExecutableName,
      );
      developer.log(
        'Updater not in install dir, checking staging: $stagedUpdaterPath',
        name: 'UpdateService',
        level: 900,
      );

      if (await File(stagedUpdaterPath).exists()) {
        developer.log(
          'Found updater in staging, copying to install directory',
          name: 'UpdateService',
          level: 800,
        );
        try {
          await File(stagedUpdaterPath).copy(updaterPath);
          developer.log(
            'Updater bootstrapped successfully',
            name: 'UpdateService',
            level: 800,
          );
        } catch (e) {
          throw UpdateException(
            'Failed to bootstrap updater from staged update: $e\n'
            'Try running Skotiq as administrator, or install a full release build.',
          );
        }
      } else {
        throw UpdateException(
          'Updater executable not found.\n'
          'Not in install directory: $updaterPath\n'
          'Not in staged update: $stagedUpdaterPath\n\n'
          'Solutions:\n'
          '1. Create a new update package using build_update_package.ps1 (includes updater)\n'
          '2. Or install a full release build with package_windows.ps1',
        );
      }
    }

    await _assertInstallWritable(installDir, manifest);

    await pendingFile.parent.create(recursive: true);
    await pendingFile.writeAsString(
      jsonEncode({
        'targetVersion': staged.version,
        'targetBuildNumber': staged.buildNumber,
        'previousVersion': _currentVersion,
        'previousBuildNumber': _currentBuildNumber,
        'installDir': installDir.path,
        'backupDir': backupDir.path,
        'stagingDir': staged.extractPath,
        'createdAt': DateTime.now().toIso8601String(),
      }),
    );

    final args = <String>[
      '--parent-pid',
      pid.toString(),
      '--staging-dir',
      staged.extractPath,
      '--install-dir',
      installDir.path,
      '--backup-dir',
      backupDir.path,
      '--pending-file',
      pendingFile.path,
      '--expected-hashes',
      expectedHashesFile.path,
      ...updaterRelaunchFlags(),
      '--launch-after',
    ];

    developer.log(
      'Launching updater: $updaterPath with args: $args',
      name: 'UpdateService',
      level: 800,
    );

    final Process updaterProcess;
    try {
      updaterProcess = await Process.start(
        updaterPath,
        args,
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      // Spawn failed. Do NOT exit(0) — the user is still here and the
      // staged tree is still valid. Drop the pending marker so a
      // half-finished apply does not confuse next launch, then surface
      // the failure so the UI can re-arm the "Apply" button.
      try {
        if (await pendingFile.exists()) {
          await pendingFile.delete();
        }
      } catch (cleanupError) {
        developer.log(
          'Failed to remove pending marker after spawn failure: $cleanupError',
          name: 'UpdateService',
          level: 1000,
        );
      }
      throw UpdateException(
        'Failed to launch updater process at $updaterPath: $e',
      );
    }

    // A detached process with pid==0 means CreateProcess returned but left
    // no handle to wait on; that counts as failure rather than letting
    // exit(0) destroy the only diagnostic.
    if (updaterProcess.pid == 0) {
      try {
        if (await pendingFile.exists()) {
          await pendingFile.delete();
        }
      } catch (e) {
        // Cleanup of the pending marker is secondary here; the spawn failure
        // thrown below is the load-bearing error. Log the delete failure so it
        // is not lost.
        developer.log(
          'Failed to delete pending marker during pid=0 cleanup: $e',
          name: 'UpdateService',
          level: 900,
        );
      }
      throw UpdateException(
        'Updater process reported pid=0; spawn was rejected by the OS. '
        'Check antivirus / file lock state on $updaterPath.',
      );
    }

    developer.log(
      'updater launched, pid=${updaterProcess.pid}',
      name: 'UpdateService',
      level: 800,
    );

    // Hold the parent open for 500 ms so the OS commits the child process
    // and the log flush reaches disk before exit(0) tears down stdio.
    // Without it a child that fails to start leaves no trace in the
    // user-visible log.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _flushDeveloperLog();

    exit(0);
  }

  /// Whether a manual rollback to the pre-update build is currently
  /// possible. True only while a retained restore point exists — i.e. an
  /// update was applied on this host and the next boot has not yet
  /// confirmed it healthy (the boot verifier wipes the backup dir once it
  /// does). The restore point is the `rollback_log.json` the Rust updater
  /// leaves under the backup dir after a successful apply, paired with the
  /// `restore_point/` originals.
  Future<bool> hasRestorePoint() async {
    // Compute the path without creating any directories — this is a pure
    // read-only probe that must not have side effects.
    final appData = await _applicationSupportDirectoryProvider();
    final logFile = File(
      path.join(appData.path, 'updates', 'backup', 'rollback_log.json'),
    );
    return logFile.exists();
  }

  /// Roll back the last applied update by relaunching the external updater
  /// in `--rollback` mode. The updater restores the retained restore point
  /// (the pre-update files) over the install, deletes the files the update
  /// added, then relaunches the restored build.
  ///
  /// Like [applyUpdate], this calls `exit(0)` on success — the host process
  /// is handed off to the updater. On spawn failure it surfaces an
  /// [UpdateException] instead of exiting so the caller can re-arm the UI.
  Future<void> rollbackToPrevious() async {
    if (!await hasRestorePoint()) {
      throw UpdateException(
        'No restore point is available to roll back to. A rollback is only '
        'possible after an update is applied and before the next launch '
        'confirms it healthy.',
      );
    }

    final installDir = await _getInstallDirectory();
    final updaterPath = path.join(installDir.path, updaterExecutableName);
    if (!await File(updaterPath).exists()) {
      throw UpdateException(
        'Updater executable not found at $updaterPath; cannot roll back. '
        'Reinstall a full release build to restore the updater.',
      );
    }

    final backupDir = await _getBackupDirectory();
    final pendingFile = await _getPendingInstallFile();

    final args = <String>[
      '--parent-pid',
      pid.toString(),
      // Staging is unused in rollback mode but the arg is required; point it
      // at the backup dir so the path is valid.
      '--staging-dir',
      backupDir.path,
      '--install-dir',
      installDir.path,
      '--backup-dir',
      backupDir.path,
      '--pending-file',
      pendingFile.path,
      // expected-hashes is unused in rollback mode but required by the parser;
      // point it at a path that need not exist (the rollback branch returns
      // before reading it).
      '--expected-hashes',
      path.join(backupDir.path, 'expected_hashes.json'),
      '--rollback',
      ...updaterRelaunchFlags(),
      '--launch-after',
    ];

    developer.log(
      'Launching updater for rollback: $updaterPath with args: $args',
      name: 'UpdateService',
      level: 800,
    );

    final Process updaterProcess;
    try {
      updaterProcess = await Process.start(
        updaterPath,
        args,
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      throw UpdateException(
        'Failed to launch updater for rollback at $updaterPath: $e',
      );
    }

    if (updaterProcess.pid == 0) {
      throw UpdateException(
        'Rollback updater process reported pid=0; spawn was rejected by the '
        'OS. Check antivirus / file lock state on $updaterPath.',
      );
    }

    developer.log(
      'rollback updater launched, pid=${updaterProcess.pid}',
      name: 'UpdateService',
      level: 800,
    );

    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _flushDeveloperLog();

    exit(0);
  }

  /// The directory the running build was installed into.
  Future<Directory> _getInstallDirectory() => _installDirectoryProvider();

  static Future<Directory> _executableDirectory() async =>
      Directory(path.dirname(Platform.resolvedExecutable));

  /// Refuse, while the app is still running, an apply the updater could not
  /// carry out.
  ///
  /// The app exits before the updater touches anything, so an install this
  /// user cannot write to (a tarball unpacked into /opt by root, the
  /// appliance unit's `ProtectSystem=strict`, or an installer-made install
  /// under Program Files on Windows) used to end with the program gone and
  /// the reason in a temp file. Each existing directory the update writes
  /// into is probed with a real file.
  ///
  /// On Windows this replaces elevation. The updater used to demand
  /// administrator rights in its manifest, which a plain process launch cannot
  /// grant (the apply never started), and which would have handed the
  /// relaunched app an administrator token. It now runs as the user, and an
  /// install that needs elevation is updated with the installer instead.
  Future<void> _assertInstallWritable(
    Directory installDir,
    UpdateManifest manifest,
  ) async {
    final dirs = <String>{installDir.path};
    for (final rel in manifest.files.keys) {
      final parts = rel.replaceAll(r'\', '/').split('/')..removeLast();
      var dir = installDir.path;
      for (final part in parts) {
        dir = path.join(dir, part);
        if (await Directory(dir).exists()) dirs.add(dir);
      }
    }
    for (final dir in dirs) {
      final probe = File(path.join(dir, '.skotiq-write-probe-$pid'));
      try {
        await probe.writeAsString('');
        await probe.delete();
      } on FileSystemException catch (e) {
        throw UpdateException(
          'Cannot install the update here: this user cannot write to $dir '
          '(${e.osError?.message ?? e.message}). Skotiq was left running '
          'on its current version. Install the new version from the release '
          'page${Platform.isWindows ? ' with the installer' : ''}, or run '
          'Skotiq from a folder this user owns.',
        );
      }
    }
  }

  /// Get the backup directory
  Future<Directory> _getBackupDirectory() async {
    final updatesRoot = await _getUpdatesRootDirectory();
    final backup = Directory(path.join(updatesRoot.path, 'backup'));
    if (!await backup.exists()) {
      await backup.create(recursive: true);
    }
    return backup;
  }

  Future<Directory> _getUpdatesRootDirectory() async {
    final appData = await _applicationSupportDirectoryProvider();
    final updatesRoot = Directory(path.join(appData.path, 'updates'));
    if (!await updatesRoot.exists()) {
      await updatesRoot.create(recursive: true);
    }
    return updatesRoot;
  }

  Future<File> _getPendingInstallFile() async {
    final updatesRoot = await _getUpdatesRootDirectory();
    return File(path.join(updatesRoot.path, 'pending_install.json'));
  }

  Future<File> _getSkippedVersionFile() async {
    final updatesRoot = await _getUpdatesRootDirectory();
    return File(path.join(updatesRoot.path, 'skipped_version.json'));
  }

  /// Read the persisted "skip this version" choice, or null if none is
  /// stored. Failure is swallowed so a corrupt/unreadable marker never
  /// blocks startup.
  Future<String?> readSkippedVersion() async {
    try {
      final file = await _getSkippedVersionFile();
      if (!await file.exists()) return null;
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final version = data['skippedVersion'];
      return version is String ? version : null;
    } catch (e) {
      developer.log(
        'Failed to read skipped-version marker: $e',
        name: 'UpdateService',
        level: 900,
      );
      return null;
    }
  }

  /// Persist the "skip this version" choice, or clear it when [version] is
  /// null. Failure is swallowed so update flow is never blocked by IO.
  Future<void> writeSkippedVersion(String? version) async {
    try {
      final file = await _getSkippedVersionFile();
      if (version == null) {
        if (await file.exists()) await file.delete();
        return;
      }
      await file.writeAsString(jsonEncode({'skippedVersion': version}));
    } catch (e) {
      developer.log(
        'Failed to persist skipped-version marker: $e',
        name: 'UpdateService',
        level: 900,
      );
    }
  }

  /// Anti-freeze / anti-rollback gate. MUST only be called once the
  /// manifest's Ed25519 signature has already verified, so `releaseDate` is
  /// known to be vendor-signed (an attacker cannot backdate it without
  /// breaking the signature). Rejects:
  ///   1. a `releaseDate` older than the newest release this host already
  ///      accepted on this channel (a rollback/freeze attack), and
  ///   2. a `releaseDate` implausibly far in the future, which a forged
  ///      high watermark could otherwise use to lock out real updates —
  ///      bounded to a small clock-skew tolerance.
  Future<void> _assertManifestNotRolledBack(UpdateManifest manifest) async {
    final releaseDate = manifest.releaseDate.toUtc();
    final skewCeiling = DateTime.now().toUtc().add(const Duration(days: 2));
    if (releaseDate.isAfter(skewCeiling)) {
      throw UpdateException(
        'anti-freeze: manifest releaseDate ${releaseDate.toIso8601String()} '
        'is more than 2 days ahead of this host clock; refusing a '
        'future-dated update that could poison the rollback watermark.',
      );
    }

    final watermark = await _antiFreezeStore.watermark(_channel);
    if (watermark != null && releaseDate.isBefore(watermark)) {
      throw UpdateException(
        'anti-freeze: manifest releaseDate ${releaseDate.toIso8601String()} '
        'is older than the last accepted release '
        '${watermark.toIso8601String()} on channel "$_channel"; refusing a '
        'rollback/freeze.',
      );
    }
  }

  Future<UpdateManifest?> _readStagedManifest(Directory stagingDir) async {
    final manifestFile = File(path.join(stagingDir.path, _stagedManifestFile));
    if (!await manifestFile.exists()) {
      return null;
    }
    try {
      return UpdateManifest.fromJson(
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>,
      );
    } on FormatException catch (e) {
      throw UpdateException(
        'Staged manifest at ${manifestFile.path} is malformed: ${e.message}',
      );
    }
  }

  Future<void> _assertVerifiedMarkerMatches(
    Directory stagingDir,
    UpdateManifest manifest,
  ) async {
    final markerFile = File(path.join(stagingDir.path, _stagedVerifiedMarker));
    if (!await markerFile.exists()) {
      throw UpdateException(
        'Staged update is missing the verified marker '
        '(${markerFile.path}). Refusing to apply: redownload the update.',
      );
    }

    final expectedHash = computeStagedManifestHash(manifest);
    final markerContent = (await markerFile.readAsString()).trim();
    if (markerContent != expectedHash) {
      throw UpdateException(
        'Verified marker at ${markerFile.path} does not match the staged '
        'manifest hash. Refusing to apply: the staging tree may have '
        'been tampered with after download.',
      );
    }
  }

  Future<File> _writeExpectedHashes(
    Directory stagingDir,
    UpdateManifest manifest,
  ) async {
    final expectedFile = File(path.join(stagingDir.path, _expectedHashesFile));
    final files = <String, String>{};
    for (final entry in manifest.files.entries) {
      // Why POSIX: the Rust updater normalises install-relative paths to
      // forward slashes; matching here keeps the hash lookup
      // platform-independent.
      final posixKey = entry.key.replaceAll('\\', '/');
      files[posixKey] = entry.value.sha256;
    }
    await expectedFile.writeAsString(jsonEncode({'files': files}));
    return expectedFile;
  }

  /// Force the developer.log buffer to drain before `exit(0)`. The log
  /// channel is fundamentally async; without an explicit flush the spawn
  /// pid is silently lost on early exit. Best we can do without dart:io
  /// `stdout.flush` because developer.log routes through the Dart VM
  /// service.
  Future<void> _flushDeveloperLog() async {
    try {
      await stdout.flush();
      await stderr.flush();
    } catch (e) {
      // Why: stdio may be detached in headless mode. Surface but do not
      // block exit on a non-essential flush.
      developer.log(
        'stdout/stderr flush failed: $e',
        name: 'UpdateService',
        level: 900,
      );
    }
  }

  /// Dispose resources
  void dispose() {
    _downloader.dispose();
    _httpClient.close();
  }
}

/// Persist the verified manifest plus the staged_verified marker into a
/// staging directory. Both download paths (HTTPS pull + LAN push) call
/// this once verification has succeeded so apply-time has a single
/// trusted handoff. Exposed at the library level so the
/// LAN push receiver can reuse it without duplicating filenames.
Future<void> persistStagedManifest(
  Directory stagingDir,
  UpdateManifest manifest,
) async {
  await stagingDir.create(recursive: true);

  final manifestJson = jsonEncode(manifest.toJson());
  final manifestFile = File(path.join(stagingDir.path, _stagedManifestFile));
  await manifestFile.writeAsString(manifestJson);

  final markerFile = File(path.join(stagingDir.path, _stagedVerifiedMarker));
  await markerFile.writeAsString(computeStagedManifestHash(manifest));
}

/// Hash of the canonical manifest JSON. Stable across runs because
/// `manifest.toJson` round-trips through freezed-generated keys in
/// declaration order.
String computeStagedManifestHash(UpdateManifest manifest) {
  return sha256.convert(utf8.encode(jsonEncode(manifest.toJson()))).toString();
}

/// Result of checking for updates
class UpdateCheckResult {
  final bool hasUpdate;
  final String currentVersion;
  final String? availableVersion;
  final UpdateManifest? manifest;
  final bool requiresManualUpgrade;

  /// Release notes to show for this update, in markdown.
  ///
  /// Separate from [UpdateManifest.releaseNotes] because that field is inside
  /// the signed canonical payload: rewriting it to carry a GitHub release body
  /// would invalidate every signature. When the source is GitHub this holds
  /// the release body, which is the text a human actually wrote; otherwise it
  /// falls back to the manifest's own notes.
  final String? releaseNotes;

  /// Human-facing page for this release, when the source has one. Lets the UI
  /// offer "read the full notes" for a build it cannot install here.
  final String? releasePageUrl;

  /// Why there is no update, when the answer is something other than "this
  /// build is current" — for example a newer release that publishes nothing
  /// for this platform. Null when the plain reading applies.
  final String? unavailableReason;

  UpdateCheckResult({
    required this.hasUpdate,
    required this.currentVersion,
    this.availableVersion,
    this.manifest,
    this.requiresManualUpgrade = false,
    String? releaseNotes,
    this.releasePageUrl,
    this.unavailableReason,
  }) : releaseNotes = releaseNotes ?? manifest?.releaseNotes;
}

/// Information about a staged update
class StagedUpdate {
  final String version;
  final int buildNumber;
  final DateTime stagedAt;
  final String extractPath;

  StagedUpdate({
    required this.version,
    required this.buildNumber,
    required this.stagedAt,
    required this.extractPath,
  });
}

enum PendingInstallState { none, verified, rolledBack, requiresAttention }

class PendingInstallStatus {
  final PendingInstallState state;
  final String? message;

  const PendingInstallStatus._(this.state, this.message);

  const PendingInstallStatus.none() : this._(PendingInstallState.none, null);

  const PendingInstallStatus.verified(String message)
    : this._(PendingInstallState.verified, message);

  const PendingInstallStatus.rolledBack(String message)
    : this._(PendingInstallState.rolledBack, message);

  const PendingInstallStatus.requiresAttention(String message)
    : this._(PendingInstallState.requiresAttention, message);
}

/// How [UpdateService.applyUpdate] handed the update off.
///
/// Callers used to infer this from still being alive afterwards — the desktop
/// path exits the process, so any return meant something had gone wrong. That
/// inference is false on Android, where the OS installer takes over and this
/// process keeps running normally, and it made a successful install report
/// itself as "the app should have restarted".
enum UpdateApplyOutcome {
  /// A helper process was launched and this process is exiting. Reaching a
  /// caller at all means the handoff failed.
  processExiting,

  /// The update was handed to the platform's own installer. This process
  /// stays alive; the OS replaces it once the user confirms.
  handedToPlatformInstaller,
}

/// Exception thrown by update operations
class UpdateException implements Exception {
  final String message;

  UpdateException(this.message);

  @override
  String toString() => 'UpdateException: $message';
}
