import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as path;

import '../models/update_manifest.dart';
import 'archive_extraction.dart';
import 'update_compatibility.dart';
import 'update_service.dart' show persistStagedManifest;
import 'update_verifier.dart';

/// Callback for push progress updates
typedef PushProgressCallback =
    void Function(
      int receivedBytes,
      int totalBytes,
      double progress,
      String message,
    );

/// Service for receiving LAN push updates from dev machine
class LanPushReceiver {
  static const int pushPort = 45680;

  /// Maximum time to wait for the authentication message before closing the connection
  static const Duration _authTimeout = Duration(seconds: 10);

  /// Hard cap on the total package bytes accepted over a single LAN push
  /// connection, independent of what the manifest claims. A malicious or
  /// mis-signed manifest can declare a giant `compressedSize` and fill the
  /// filesystem before signature failure is observed; this cap bails out
  /// before the disk is exhausted. 1 GiB clears the largest legitimate
  /// Skotiq installer by an order of magnitude.
  static const int maxPackageBytes = 1024 * 1024 * 1024;
  static const int maxManifestBytes = 1024 * 1024;

  final String _currentVersion;
  final int _currentBuildNumber;
  final UpdateVerifier _verifier;
  final int _serverPort;
  final String _currentPlatform;
  final String _currentArch;

  /// Pre-shared key required from push clients for authentication.
  /// Must be set before starting the server. Generate with [generatePushSecret].
  String? _pushSecret;

  ServerSocket? _server;
  _ReceiveState _receiveState = _ReceiveState.idle;

  /// Callback when an update push is complete
  void Function(UpdateManifest manifest, String stagingPath)? onUpdateReceived;

  /// Callback for push progress
  PushProgressCallback? onProgress;

  /// Callback for errors
  void Function(String error)? onError;

  LanPushReceiver({
    required String currentVersion,
    required int currentBuildNumber,
    String? pushSecret,
    UpdateVerifier? verifier,
    int serverPort = pushPort,
    String? currentPlatform,
    String? currentArch,
  }) : _currentVersion = currentVersion,
       _currentBuildNumber = currentBuildNumber,
       _pushSecret = pushSecret,
       _serverPort = serverPort,
       _currentPlatform = normalizeUpdatePlatform(
         currentPlatform ?? currentUpdatePlatform(),
       ),
       _currentArch = normalizeUpdateArchitecture(
         currentArch ?? currentUpdateArchitecture(),
       ),
       _verifier = verifier ?? UpdateVerifier();

  /// Set the pre-shared push secret. Must be called before [startServer].
  void setPushSecret(String secret) {
    _pushSecret = secret;
  }

  /// Generate a cryptographically secure push secret (64 hex characters).
  static String generatePushSecret() {
    final random = Random.secure();
    final bytes = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Current version info for discovery response
  Map<String, dynamic> get versionInfo => {
    'version': _currentVersion,
    'buildNumber': _currentBuildNumber,
    'isReceiving': _receiveState != _ReceiveState.idle,
  };

  /// The actual bound port, useful when [serverPort] was zero and the OS chose
  /// an ephemeral port.
  int? get listeningPort => _server?.port;

  /// Start listening for LAN push connections.
  /// A push secret must be configured via the constructor or [setPushSecret]
  /// before calling this method.
  ///
  /// Refuses to start if no `SKOTIQ_UPDATE_PUBLIC_KEY` was compiled
  /// into the build: without a trusted public key the receiver cannot
  /// verify the Ed25519 signature on the manifest, so any LAN-attached
  /// attacker who guesses the push secret could ship arbitrary code.
  /// Loudly disabled beats silently vulnerable.
  Future<void> startServer() async {
    if (_server != null) return;

    if (!_verifier.hasTrustedPublicKey) {
      throw StateError(
        'LAN push receiver disabled: no trusted public key compiled in. '
        'Build with --dart-define=SKOTIQ_UPDATE_PUBLIC_KEY=... to enable.',
      );
    }

    if (_pushSecret == null || _pushSecret!.isEmpty) {
      throw StateError(
        'Push secret must be configured before starting the server. '
        'Call setPushSecret() or pass pushSecret to the constructor.',
      );
    }

    _server = await ServerSocket.bind(InternetAddress.anyIPv4, _serverPort);
    developer.log(
      'Listening on port $_serverPort',
      name: 'LanPushReceiver',
      level: 800,
    );

    _server!.listen(
      _handleConnection,
      onError: (error) {
        developer.log(
          'Server error: $error',
          name: 'LanPushReceiver',
          level: 1000,
        );
        onError?.call('Server error: $error');
      },
    );
  }

  /// Stop the server
  Future<void> stopServer() async {
    await _server?.close();
    _server = null;
  }

  /// Handle incoming connection from push tool.
  /// Requires the client to send an authentication message as the first frame:
  ///   4 bytes (big-endian): length of auth JSON
  ///   N bytes: JSON with `{"secret": "<push_secret>"}`
  /// The server responds with {"auth": "ok"} or {"auth": "rejected"} and closes.
  void _handleConnection(Socket socket) async {
    final remoteAddress = socket.remoteAddress.address;
    developer.log(
      'Connection from $remoteAddress',
      name: 'LanPushReceiver',
      level: 800,
    );

    if (!_tryReserveReceiveSlot()) {
      socket.write(jsonEncode({'error': 'Already receiving update'}));
      await socket.close();
      return;
    }

    final reader = _SocketFrameReader(socket);
    try {
      // Authentication phase
      final authenticated = await _authenticateClient(
        reader,
        socket,
        remoteAddress,
      );
      if (!authenticated) {
        return; // socket already closed by _authenticateClient
      }

      _receiveState = _ReceiveState.receiving;
      onProgress?.call(0, 0, 0, 'Authenticated connection from $remoteAddress');

      await _receiveUpdate(reader, socket);
    } catch (e) {
      developer.log(
        'Error receiving update: $e',
        name: 'LanPushReceiver',
        level: 1000,
      );
      onError?.call(e.toString());
    } finally {
      _releaseReceiveSlot();
      unawaited(reader.cancel());
      await socket.close();
    }
  }

  bool _tryReserveReceiveSlot() {
    // Dart isolates run this compare+set synchronously until the first await,
    // giving us the CAS-like single-writer gate this receiver needs: only one
    // connection may progress into auth/receive, and every path releases it in
    // _handleConnection's finally block.
    if (_receiveState != _ReceiveState.idle) {
      return false;
    }
    _receiveState = _ReceiveState.authenticating;
    return true;
  }

  void _releaseReceiveSlot() {
    _receiveState = _ReceiveState.idle;
  }

  /// Authenticate an incoming client connection.
  /// Protocol: client sends [4-byte big-endian length][JSON {"secret":"..."}].
  /// Returns true if authenticated, false otherwise (socket is closed on failure).
  Future<bool> _authenticateClient(
    _SocketFrameReader reader,
    Socket socket,
    String remoteAddress,
  ) async {
    try {
      final header = await reader
          .readExactly(4)
          .timeout(_authTimeout, onTimeout: () => null);
      if (header == null) {
        socket.write(jsonEncode({'auth': 'rejected', 'reason': 'timeout'}));
        return false;
      }
      final authLen = ByteData.sublistView(header).getInt32(0, Endian.big);
      if (authLen <= 0 || authLen > 4096) {
        socket.write(
          jsonEncode({'auth': 'rejected', 'reason': 'invalid frame'}),
        );
        return false;
      }

      final payload = await reader
          .readExactly(authLen)
          .timeout(_authTimeout, onTimeout: () => null);
      if (payload == null) {
        socket.write(jsonEncode({'auth': 'rejected', 'reason': 'timeout'}));
        return false;
      }
      final authData = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      final clientSecret = authData['secret'] as String?;
      if (clientSecret == null ||
          !_constantTimeCompare(clientSecret, _pushSecret!)) {
        developer.log(
          'Invalid push secret from $remoteAddress',
          name: 'LanPushReceiver',
          level: 1000,
        );
        socket.write(
          jsonEncode({'auth': 'rejected', 'reason': 'invalid secret'}),
        );
        return false;
      }

      developer.log(
        'Authenticated push client from $remoteAddress',
        name: 'LanPushReceiver',
        level: 800,
      );
      socket.write(jsonEncode({'auth': 'ok'}));
      await socket.flush();
      return true;
    } catch (e) {
      developer.log(
        'Failed to authenticate $remoteAddress: $e',
        name: 'LanPushReceiver',
        level: 1000,
      );
      socket.write(jsonEncode({'auth': 'rejected', 'reason': 'parse error'}));
      return false;
    }
  }

  /// Constant-time string comparison to prevent timing attacks
  static bool _constantTimeCompare(String a, String b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  /// Receive update data from socket
  Future<void> _receiveUpdate(_SocketFrameReader reader, Socket socket) async {
    // Protocol:
    // 1. Receive manifest length (4 bytes, big-endian)
    // 2. Receive manifest JSON
    // 3. Receive package data

    final manifestHeader = await reader.readExactly(4);
    if (manifestHeader == null) throw Exception('Incomplete manifest frame');
    final manifestLength = ByteData.sublistView(
      manifestHeader,
    ).getInt32(0, Endian.big);
    if (manifestLength <= 0 || manifestLength > maxManifestBytes) {
      throw FormatException(
        'Invalid update manifest length: $manifestLength bytes',
      );
    }
    onProgress?.call(0, 0, 0, 'Receiving manifest...');

    final manifestBytes = await reader.readExactly(manifestLength);
    if (manifestBytes == null) throw Exception('Incomplete update manifest');
    final manifest = UpdateManifest.fromJson(
      jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>,
    );
    final manifestVerified = await _verifier.verifyManifestSignature(manifest);
    if (!manifestVerified) {
      throw Exception('Update manifest signature verification failed');
    }
    _assertCompatibleManifest(manifest);

    final packageSize = manifest.compressedSize;
    if (packageSize <= 0 || packageSize > maxPackageBytes) {
      throw Exception(
        'Invalid update package size: $packageSize bytes; expected '
        '1-$maxPackageBytes bytes',
      );
    }

    // Do not allocate staging storage until the manifest is authenticated,
    // compatible with this host, and bounded to a legitimate size.
    final staging = await _getStagingDirectory();
    final packagePath = path.join(staging.path, 'update.zip');
    File? packageFile;
    IOSink? packageSink;
    var receivedPackageBytes = 0;
    var receiveSucceeded = false;
    try {
      packageFile = File(packagePath);
      packageSink = packageFile.openWrite();
      socket.write(
        jsonEncode({'status': 'receiving', 'version': manifest.version}),
      );
      await socket.flush();

      while (receivedPackageBytes < packageSize) {
        final remaining = packageSize - receivedPackageBytes;
        final chunk = await reader.readAtMost(
          remaining < 64 * 1024 ? remaining : 64 * 1024,
        );
        if (chunk == null) {
          throw Exception(
            'Incomplete transfer: expected $packageSize bytes, received '
            '$receivedPackageBytes',
          );
        }
        packageSink.add(chunk);
        receivedPackageBytes += chunk.length;
        onProgress?.call(
          receivedPackageBytes,
          packageSize,
          receivedPackageBytes / packageSize,
          'Receiving ${manifest.version}...',
        );
      }
      receiveSucceeded = true;
    } finally {
      // Always release the file handle; otherwise a thrown error leaves
      // update.zip locked and the next push fails with a Windows
      // sharing-violation error.
      await packageSink?.close();
      if (!receiveSucceeded &&
          packageFile != null &&
          await packageFile.exists()) {
        // Why: a partial write is not a recoverable artefact — it
        // contains untrusted bytes that failed our cap or signature
        // checks. Leaving it on disk would let the verify step later
        // pick up garbage.
        try {
          await packageFile.delete();
        } catch (deleteError) {
          developer.log(
            'Failed to remove partial update.zip after receive error: '
            '$deleteError',
            name: 'LanPushReceiver',
            level: 1000,
          );
        }
      }
    }

    // Verify package size
    final actualSize = await packageFile.length();
    if (actualSize != manifest.compressedSize) {
      await packageFile.delete();
      throw Exception(
        'Size mismatch: expected ${manifest.compressedSize}, got $actualSize',
      );
    }

    final packageHash = manifest.packageSha256;
    if (packageHash == null ||
        packageHash.isEmpty ||
        !await _verifier.verifyFile(packageFile, packageHash)) {
      await packageFile.delete();
      throw Exception('Update package SHA-256 verification failed');
    }

    final extractPath = await extractVerifyAndStage(
      staging,
      packageFile,
      manifest,
      actualSize,
    );

    // Send success response (may fail if pusher already disconnected, which is OK)
    try {
      socket.write(
        jsonEncode({'status': 'complete', 'version': manifest.version}),
      );
      await socket.flush();
    } catch (e) {
      // Pusher may have disconnected - that's fine, update is complete
      developer.log(
        'Could not send completion response (pusher disconnected): $e',
        name: 'LanPushReceiver',
        level: 900,
      );
    }

    onProgress?.call(actualSize, actualSize, 1.0, 'Update ready!');
    onUpdateReceived?.call(manifest, extractPath);
  }

  /// Extract a fully-received, size-checked package, verify every staged
  /// file against the (already signature-verified) [manifest], then persist
  /// the trusted apply-time handoff and return the extracted-tree path.
  ///
  /// The persisted handoff is the same pair the HTTPS staging path writes in
  /// [UpdateService.downloadAndStage]: `manifest.json` plus the
  /// `staged_verified.marker`, alongside the `ready.json` discovery marker.
  /// [persistStagedManifest] runs ONLY after
  /// [UpdateVerifier.verifyDirectory] succeeds, so a tree that fails
  /// per-file hashing never gains a verified marker and
  /// [UpdateService.applyUpdate] keeps refusing it.
  ///
  /// Exposed for tests so the verified staging handoff can be exercised
  /// without opening a TCP listener.
  @visibleForTesting
  Future<String> extractVerifyAndStage(
    Directory staging,
    File packageFile,
    UpdateManifest manifest,
    int packageBytes,
  ) async {
    _assertCompatibleManifest(manifest);
    onProgress?.call(packageBytes, packageBytes, 1.0, 'Extracting...');

    // Extract package
    final extractDir = Directory(path.join(staging.path, 'extracted'));
    if (await extractDir.exists()) {
      await extractDir.delete(recursive: true);
    }
    await extractDir.create(recursive: true);

    await extractZipSafely(packageFile, extractDir);

    onProgress?.call(packageBytes, packageBytes, 1.0, 'Verifying...');

    // Verify extracted files
    final verification = await _verifier.verifyDirectory(extractDir, manifest);
    if (!verification.success) {
      await extractDir.delete(recursive: true);
      throw Exception('Verification failed: $verification');
    }

    // Persist the verified manifest + staged_verified marker so
    // UpdateService.applyUpdate() can recover the exact trusted manifest
    // and confirm end-to-end verification before touching the install.
    // This is the same handoff the HTTPS staging path performs in
    // downloadAndStage(); it is reached ONLY here, after the manifest
    // signature, package size, and per-file hashes have all verified, so
    // the marker is never written over an unverified or partial tree.
    await persistStagedManifest(staging, manifest);

    // Write ready marker
    final markerFile = File(path.join(staging.path, 'ready.json'));
    developer.log(
      'Writing ready marker to: ${markerFile.path}',
      name: 'LanPushReceiver',
    );
    await markerFile.writeAsString(
      jsonEncode({
        'version': manifest.version,
        'buildNumber': manifest.buildNumber,
        'stagedAt': DateTime.now().toIso8601String(),
        'extractPath': extractDir.path,
        'source': 'lan_push',
      }),
    );
    developer.log('Ready marker written successfully', name: 'LanPushReceiver');

    return extractDir.path;
  }

  void _assertCompatibleManifest(UpdateManifest manifest) {
    final incompatibility = incompatibleUpdateTargetMessage(
      manifest,
      currentPlatform: _currentPlatform,
      currentArch: _currentArch,
    );
    if (incompatibility != null) throw Exception(incompatibility);
  }

  /// Get staging directory
  Future<Directory> _getStagingDirectory() async {
    final appData = await resolveSkotiqDataDirectory();
    final staging = Directory(path.join(appData.path, 'updates', 'staging'));
    if (!await staging.exists()) {
      await staging.create(recursive: true);
    }
    return staging;
  }

  /// Dispose resources
  void dispose() {
    stopServer();
  }
}

enum _ReceiveState { idle, authenticating, receiving }

/// One subscription shared by authentication and update transfer. TCP can
/// coalesce both protocol frames into one chunk, so leftover bytes must remain
/// available when the authentication phase hands off to the manifest phase.
class _SocketFrameReader {
  final StreamIterator<Uint8List> _chunks;
  List<int> _buffer = const [];

  _SocketFrameReader(Stream<Uint8List> stream)
    : _chunks = StreamIterator<Uint8List>(stream);

  Future<Uint8List?> readExactly(int length) async {
    while (_buffer.length < length) {
      if (!await _chunks.moveNext()) return null;
      _buffer = [..._buffer, ..._chunks.current];
    }
    final result = Uint8List.fromList(_buffer.sublist(0, length));
    _buffer = _buffer.sublist(length);
    return result;
  }

  Future<Uint8List?> readAtMost(int maxLength) async {
    if (_buffer.isEmpty) {
      if (!await _chunks.moveNext()) return null;
      _buffer = _chunks.current;
    }
    final length = _buffer.length < maxLength ? _buffer.length : maxLength;
    final result = Uint8List.fromList(_buffer.sublist(0, length));
    _buffer = _buffer.sublist(length);
    return result;
  }

  Future<void> cancel() => _chunks.cancel();
}
