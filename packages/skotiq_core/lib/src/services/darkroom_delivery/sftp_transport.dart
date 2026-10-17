/// Delivery over SFTP to a host the rig can reach — "my Linux box in the
/// office".
///
/// Config (`delivery_targets.config_json`), no key material:
///
/// ```json
/// {"host": "office.local", "port": 22, "user": "sean",
///  "remoteDir": "/srv/astro/incoming",
///  "hostKeyFingerprint": "SHA256:s0m3Base64",
///  "hostKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...",
///  "digestCommand": "sha256sum", "rigId": "shed-rig"}
/// ```
///
/// `rigId` is the rig-identity component every delivered name carries, so two
/// rigs uploading into one incoming directory do not land on each other's file
/// names — see [DeliveryNaming].
///
/// The private key lives in `SecretsStore` under the destination row's
/// `secret_ref` and is written to a mode-0600 file inside a private scratch
/// directory for the duration of the delivery.
///
/// **Host key pinning.** On the first delivery the transport scans the
/// server's host keys, pins one of them — both its fingerprint and the key
/// itself — onto the destination row, and writes a known-hosts file for the
/// session. Every later delivery hands that key to OpenSSH as the only one it
/// will accept, so a server presenting anything else is refused by `ssh`
/// itself before a byte moves and reported as
/// [DeliveryFailureKind.hostKeyMismatch]. This is trust on first use — the
/// first connection is the one an attacker would have to already own.
///
/// The pinned key is stored because `ssh-keyscan` is not free. One scan opens
/// SIX unauthenticated connections (measured against OpenSSH 10.5), and an
/// sshd built after 9.8 penalises a source that connects without
/// authenticating: three scans in a row is enough for the server to start
/// dropping the rig's connections outright, corrected credentials and all.
/// Scanning therefore happens once per destination, not once per delivery.
///
/// The session's known-hosts file holds exactly one key and names it under
/// [kSftpHostKeyAlias] rather than under `host:port`, which is what keeps the
/// stored pin free of `ssh-keyscan`'s `[host]:port` formatting.
///
/// **Password authentication is not offered.** OpenSSH deliberately refuses to
/// read a password from a pipe, and the alternative (`sshpass`) is not a
/// dependency of this project. A destination configured for password auth
/// fails with [DeliveryFailureKind.authMethodUnavailable] naming the
/// substitute — a key — rather than appearing to work and hanging on a prompt.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../models/darkroom/delivery.dart';
import '../notification/secrets_store.dart';
import 'artifact_transport.dart';
import 'atomic_file_write.dart';
import 'delivery_failure.dart';
import 'delivery_artifact.dart';
import 'delivery_naming.dart';
import 'sftp_command_runner.dart';

/// How long any one OpenSSH invocation may run before it is killed. The
/// upload gets its own, longer budget.
const Duration kSftpControlCommandTimeout = Duration(seconds: 30);

/// How long one file upload may run before it is killed.
const Duration kSftpUploadTimeout = Duration(minutes: 30);

/// The remote command used to verify a delivered file when the destination
/// names none.
const String kDefaultRemoteDigestCommand = 'sha256sum';

/// The name the session's known-hosts file records the pinned key under.
///
/// The file holds exactly one key and is thrown away with the session, so the
/// name is free. Using a fixed one (via OpenSSH's `HostKeyAlias`) means the
/// stored pin is the key alone, with no `[host]:port` pattern to keep in step
/// with the row it sits on. Which server the key is accepted for is decided by
/// the row's own host and port, not by the text of a known-hosts pattern.
const String kSftpHostKeyAlias = 'skotiq-delivery';

/// OpenSSH's own exit status: the SSH transport failed and the remote command
/// never ran. Every other status came from the remote command itself.
const int kOpenSshTransportExitCode = 255;

/// What `test` exits when it answers "no". A remote existence check that ends
/// any other way did not answer at all.
const int kRemoteTestFalseExitCode = 1;

/// Called when the transport learns a host key it had no pin for, so the
/// caller can persist it onto the destination row. Delivery does not continue
/// until the pin is durable — a key that lives only in memory would be
/// re-learned (and re-trusted) on the next attempt.
typedef HostKeyPinWriter = Future<void> Function(HostKeyScanEntry key);

/// Copies artifacts to an SFTP server, one atomic file at a time.
class SftpTransport implements ArtifactTransport {
  /// The destination row this transport serves.
  final ArtifactDestination destination;

  /// The job whose artifacts are being delivered; names the remote staged
  /// files.
  final int jobId;

  final SftpCommandRunner _runner;
  final SecretsStore _secrets;
  final HostKeyPinWriter _pinHostKey;

  _SftpSession? _session;

  SftpTransport({
    required this.destination,
    required this.jobId,
    required SecretsStore secrets,
    required HostKeyPinWriter pinHostKey,
    SftpCommandRunner runner = const ProcessSftpCommandRunner(),
  }) : _secrets = secrets,
       _pinHostKey = pinHostKey,
       _runner = runner;

  @override
  ArtifactDestinationKind get kind => ArtifactDestinationKind.sftp;

  @override
  Future<void> open(List<DeliveryFile> artifacts) async {
    final config = _SftpConfig.parse(destination);

    for (final tool in <String>[
      'ssh',
      'sftp',
      // Only a destination with no key pinned yet scans for one, so a machine
      // without `ssh-keyscan` can still deliver to every destination that has
      // already been through its first delivery.
      if (config.hostKey == null) 'ssh-keyscan',
    ]) {
      if (!await _runner.isAvailable(tool)) {
        throw DeliveryFailure(
          DeliveryFailureKind.transportToolMissing,
          'SFTP delivery drives the OpenSSH client and `$tool` is not on this '
          'machine\'s PATH',
        );
      }
    }

    final secretRef = destination.secretRef;
    if (secretRef == null || secretRef.trim().isEmpty) {
      throw const DeliveryFailure(
        DeliveryFailureKind.credentialMissing,
        'This SFTP destination names no secret_ref, so there is no key to '
        'authenticate with',
      );
    }
    final privateKey = await _secrets.read(secretRef);
    if (privateKey.isEmpty) {
      throw DeliveryFailure(
        DeliveryFailureKind.credentialMissing,
        'The keyring holds no value for $secretRef',
      );
    }

    final workDir = await Directory.systemTemp.createTemp('sk_sftp_');
    final _SftpSession session;
    try {
      session = await _openSession(
        config: config,
        privateKey: privateKey,
        workDir: workDir,
      );
    } on Object catch (error, stack) {
      // The scratch directory holds the private key. Whatever went wrong, the
      // key does not outlive the failed attempt — and the original failure is
      // what reaches the caller, with its stack intact.
      await _deleteWorkDir(workDir);
      Error.throwWithStackTrace(error, stack);
    }
    _session = session;
  }

  /// Write the key material, pin the host key, and prove the remote directory
  /// is there. The caller owns [workDir] and removes it if this throws.
  Future<_SftpSession> _openSession({
    required _SftpConfig config,
    required String privateKey,
    required Directory workDir,
  }) async {
    final keyFile = File(p.join(workDir.path, 'id_delivery'));
    await keyFile.writeAsString(
      privateKey.endsWith('\n') ? privateKey : '$privateKey\n',
    );
    if (!Platform.isWindows) {
      // OpenSSH refuses a private key any other account can read. Dart cannot
      // set a file mode directly, so this is the one place the transport
      // shells out for something other than SSH itself.
      final chmod = await _runner.run('chmod', [
        '600',
        keyFile.path,
      ], timeout: const Duration(seconds: 10));
      if (!chmod.succeeded) {
        throw DeliveryFailure(
          DeliveryFailureKind.transportFailure,
          'The delivery key file could not be made private: '
          '${chmod.diagnostic}',
        );
      }
    }

    final knownHosts = File(p.join(workDir.path, 'known_hosts'));
    final pinned = await _pinAndWriteKnownHosts(
      config: config,
      knownHosts: knownHosts,
    );

    final session = _SftpSession(
      config: config,
      workDir: workDir,
      keyFile: keyFile,
      knownHosts: knownHosts,
      pinnedFingerprint: pinned,
    );

    final probe = await _runner.run('ssh', [
      ...session.sshOptions,
      config.userAtHost,
      'test',
      '-d',
      config.quotedRemoteDir,
    ], timeout: kSftpControlCommandTimeout);
    if (probe.exitCode == kRemoteTestFalseExitCode) {
      // The remote `test` ran and said no: the directory is not there right
      // now, which a later attempt may find mounted again.
      throw DeliveryFailure(
        DeliveryFailureKind.destinationUnreachable,
        '${config.userAtHost}:${config.remoteDir} is not a directory on the '
        'server',
      );
    }
    if (!probe.succeeded) {
      // Anything else means the probe never reached a shell — a refused
      // connection, a key the server would not take, a host key that changed.
      // Those are different problems with different answers, and OpenSSH says
      // which on stderr.
      throw DeliveryFailure(
        classifyOpenSshFailure(probe),
        'Reaching ${config.userAtHost}:${config.remoteDir} failed: '
        '${probe.diagnostic}',
      );
    }

    return session;
  }

  @override
  Future<TransportDeliveryOutcome> deliver(DeliveryFile artifact) async {
    final session = _session;
    if (session == null) {
      throw const DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        'This SFTP destination was asked to deliver before it was opened',
      );
    }
    final config = session.config;
    final deliveredName = config.naming.nameFor(artifact.fileName);
    final finalPath = p.posix.join(config.remoteDir, deliveredName);
    final stagedPath = p.posix.join(
      config.remoteDir,
      '.$deliveredName.$jobId$kStagedDeliverySuffix',
    );
    _refuseUnquotableName(deliveredName);

    final existing = await _runner.run('ssh', [
      ...session.sshOptions,
      config.userAtHost,
      'test',
      '-e',
      _quote(finalPath),
    ], timeout: kSftpControlCommandTimeout);
    if (existing.succeeded) {
      final remoteDigest = await _remoteDigest(session, finalPath);
      if (remoteDigest == artifact.checksum) {
        return TransportDeliveryOutcome(
          disposition: DeliveryDisposition.delivered,
          checksum: remoteDigest,
          destinationDescription: '${config.userAtHost}:$finalPath',
        );
      }
      throw DeliveryFailure(
        DeliveryFailureKind.destinationConflict,
        '${config.userAtHost}:$finalPath already exists with different '
        'content (there: $remoteDigest, here: ${artifact.checksum}); delivery '
        'copies and never overwrites',
      );
    }
    if (existing.exitCode != kRemoteTestFalseExitCode) {
      // "Not answered" is not "not there". The delivery ends in an SFTP
      // `rename`, which OpenSSH performs as a POSIX rename — it REPLACES
      // whatever sits at the final name, silently and without an error. The
      // promise that delivery never overwrites therefore rests entirely on
      // this check, so an unanswered check stops the delivery instead of
      // being read as an empty destination.
      throw DeliveryFailure(
        classifyOpenSshFailure(existing),
        'Whether $deliveredName is already on ${config.userAtHost} could '
        'not be determined (${existing.diagnostic}), and delivery does not '
        'upload over an answer it does not have',
      );
    }

    final upload = await _runner.run(
      'sftp',
      [...session.sftpOptions, '-b', '-', config.userAtHost],
      timeout: kSftpUploadTimeout,
      stdinText: 'put ${_quote(artifact.sourcePath)} ${_quote(stagedPath)}\n',
    );
    if (!upload.succeeded) {
      await _removeRemote(session, stagedPath);
      throw DeliveryFailure(
        classifyOpenSshFailure(upload),
        'Uploading $deliveredName to ${config.userAtHost} failed: '
        '${upload.diagnostic}',
      );
    }

    final landed = await _remoteDigest(session, stagedPath);
    if (landed != artifact.checksum) {
      await _removeRemote(session, stagedPath);
      throw DeliveryFailure(
        DeliveryFailureKind.checksumMismatch,
        'The copy of $deliveredName on ${config.userAtHost} hashes to '
        '$landed, not ${artifact.checksum}',
      );
    }

    final rename = await _runner.run(
      'sftp',
      [...session.sftpOptions, '-b', '-', config.userAtHost],
      timeout: kSftpControlCommandTimeout,
      stdinText: 'rename ${_quote(stagedPath)} ${_quote(finalPath)}\n',
    );
    if (!rename.succeeded) {
      await _removeRemote(session, stagedPath);
      throw DeliveryFailure(
        classifyOpenSshFailure(rename),
        'Renaming $deliveredName into place on ${config.userAtHost} '
        'failed: ${rename.diagnostic}',
      );
    }

    return TransportDeliveryOutcome(
      disposition: DeliveryDisposition.delivered,
      checksum: landed,
      destinationDescription: '${config.userAtHost}:$finalPath',
    );
  }

  @override
  Future<void> close() async {
    final session = _session;
    _session = null;
    if (session != null) await _deleteWorkDir(session.workDir);
  }

  /// Write the known-hosts file the session uses, scanning the server for a
  /// key first when this destination has none pinned yet.
  Future<String> _pinAndWriteKnownHosts({
    required _SftpConfig config,
    required File knownHosts,
  }) async {
    final pinnedKey = config.hostKey;
    if (pinnedKey != null) {
      // The key itself is pinned, so OpenSSH enforces it: a server presenting
      // anything else fails the connection before the first command. No scan
      // is needed, and none is made — see the note on `ssh-keyscan` and source
      // penalties in the library doc.
      await _writeKnownHosts(knownHosts, pinnedKey);
      return pinnedKey.fingerprint;
    }

    final scan = await _runner.run('ssh-keyscan', [
      '-p',
      '${config.port}',
      config.host,
    ], timeout: kSftpControlCommandTimeout);
    final entries = parseHostKeyScan(scan.stdout);
    if (entries.isEmpty) {
      throw DeliveryFailure(
        DeliveryFailureKind.destinationUnreachable,
        '${config.host}:${config.port} presented no host key: '
        '${scan.diagnostic}',
      );
    }

    final expected = config.hostKeyFingerprint;
    if (expected == null) {
      final learned = entries.first;
      await _pinHostKey(learned);
      await _writeKnownHosts(knownHosts, learned);
      return learned.fingerprint;
    }

    for (final entry in entries) {
      if (entry.fingerprint == expected) {
        // The trust decision is unchanged — this is the fingerprint already on
        // the row. Storing the key behind it is what lets every later delivery
        // skip the scan.
        await _pinHostKey(entry);
        await _writeKnownHosts(knownHosts, entry);
        return entry.fingerprint;
      }
    }
    throw DeliveryFailure(
      DeliveryFailureKind.hostKeyMismatch,
      '${config.host}:${config.port} presented '
      '${entries.map((e) => e.fingerprint).join(', ')} but this destination is '
      'pinned to $expected; nothing was sent',
    );
  }

  Future<void> _writeKnownHosts(File knownHosts, HostKeyScanEntry key) =>
      knownHosts.writeAsString('$kSftpHostKeyAlias ${key.knownHostsKey}\n');

  /// The remote digest of [remotePath], as lowercase hex.
  Future<String> _remoteDigest(_SftpSession session, String remotePath) async {
    final config = session.config;
    final commands = <String>[
      config.digestCommand,
      if (config.digestCommand == kDefaultRemoteDigestCommand) 'shasum -a 256',
    ];
    SftpCommandResult? last;
    for (final command in commands) {
      final result = await _runner.run('ssh', [
        ...session.sshOptions,
        config.userAtHost,
        command,
        _quote(remotePath),
      ], timeout: kSftpControlCommandTimeout);
      if (result.succeeded) {
        final digest = result.stdout.trim().split(RegExp(r'\s+')).first;
        if (digest.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(digest)) {
          return digest.toLowerCase();
        }
        throw DeliveryFailure(
          DeliveryFailureKind.transportToolMissing,
          '`$command` on ${config.userAtHost} answered "${digest.isEmpty ? result.stdout.trim() : digest}", '
          'which is not a SHA-256 digest',
        );
      }
      if (result.exitCode == kOpenSshTransportExitCode) {
        // SSH failed, so the digest command never ran. Falling through to the
        // next candidate would end in "this server offers no SHA-256 command",
        // sending the operator to install coreutils over what is a dropped
        // connection or a refused key.
        throw DeliveryFailure(
          classifyOpenSshFailure(result),
          'Verifying $remotePath on ${config.userAtHost} could not be started: '
          '${result.diagnostic}',
        );
      }
      last = result;
    }
    throw DeliveryFailure(
      DeliveryFailureKind.transportToolMissing,
      '${config.userAtHost} offers no SHA-256 command to verify the delivery '
      'with (tried ${commands.join(', ')}): ${last?.diagnostic ?? 'no output'}',
    );
  }

  /// Remove a remote staged file. The failure that brought us here is the one
  /// reported; a staged file left behind is overwritten by the next attempt
  /// for the same job and file.
  Future<void> _removeRemote(_SftpSession session, String remotePath) async {
    await _runner.run(
      'sftp',
      [...session.sftpOptions, '-b', '-', session.config.userAtHost],
      timeout: kSftpControlCommandTimeout,
      stdinText: 'rm ${_quote(remotePath)}\n',
    );
  }

  Future<void> _deleteWorkDir(Directory workDir) async {
    try {
      if (await workDir.exists()) await workDir.delete(recursive: true);
    } on FileSystemException catch (error) {
      throw DeliveryFailure(
        DeliveryFailureKind.transportFailure,
        'The private key file at ${workDir.path} could not be removed: '
        '${error.message}',
        cause: error,
      );
    }
  }
}

/// One host key, as OpenSSH writes it in a known-hosts file: the algorithm
/// name and the base64 key, without the host pattern in front of them.
///
/// The host pattern is left off because the session writes its own: what a
/// destination row stores is the key, and `ssh-keyscan`'s `[host]:port` prefix
/// is formatting that would then have to be kept in step with the row.
class HostKeyScanEntry {
  /// The key algorithm, e.g. `ssh-ed25519`.
  final String algorithm;

  /// The base64 key blob, verbatim.
  final String blob;

  /// OpenSSH's `SHA256:<base64>` fingerprint of that key.
  final String fingerprint;

  const HostKeyScanEntry({
    required this.algorithm,
    required this.blob,
    required this.fingerprint,
  });

  /// The two fields a known-hosts line carries after its host pattern. This
  /// is also what the destination row stores.
  String get knownHostsKey => '$algorithm $blob';

  /// Read back a key stored as `<algorithm> <base64>`, or null when that is
  /// not what the string holds.
  static HostKeyScanEntry? parse(String storedKey) {
    final parts = storedKey.trim().split(RegExp(r'\s+'));
    if (parts.length != 2) return null;
    return _entryFor(algorithm: parts[0], encodedBlob: parts[1]);
  }
}

/// Parse `ssh-keyscan` output into host-key entries with their OpenSSH
/// SHA-256 fingerprints.
///
/// The fingerprint is computed here rather than by shelling out to
/// `ssh-keygen -lf`: it is exactly the unpadded base64 of the SHA-256 of the
/// key blob, so computing it removes one binary from the dependency list and
/// one place the two could disagree.
///
/// `ssh-keyscan` writes its progress comments to STDOUT, interleaved with the
/// keys — one `# host:port SSH-2.0-…` line per connection it opens — so the
/// comment skip below is load-bearing, not decoration.
List<HostKeyScanEntry> parseHostKeyScan(String scanOutput) {
  final entries = <HostKeyScanEntry>[];
  for (final raw in const LineSplitter().convert(scanOutput)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 3) continue;
    final entry = _entryFor(algorithm: parts[1], encodedBlob: parts[2]);
    if (entry != null) entries.add(entry);
  }
  return entries;
}

/// Classify a failed `ssh` or `sftp` run from what OpenSSH actually wrote.
///
/// Every string matched here was taken from a real OpenSSH 10.5 client
/// talking to a real sshd, not from the manual. The kind decides whether the
/// retry sweep tries again, and getting that wrong is expensive in both
/// directions: a rejected key retried every few minutes is what an sshd built
/// after 9.8 penalises, and it will start dropping the rig's connections
/// outright once the penalty passes its threshold.
DeliveryFailureKind classifyOpenSshFailure(SftpCommandResult result) {
  final text = '${result.stderr}\n${result.stdout}';
  if (text.contains('REMOTE HOST IDENTIFICATION HAS CHANGED') ||
      text.contains('Host key verification failed')) {
    return DeliveryFailureKind.hostKeyMismatch;
  }
  // Every refusal OpenSSH could be made to produce here says "Permission
  // denied": the server rejecting the key ("(publickey)"), the server offering
  // only a method batch mode cannot use ("(keyboard-interactive)"), and the
  // server rejecting the write ("dest open …: Permission denied"). All three
  // are terminal, and all three are fixed by a person, not by a retry.
  if (text.contains('Permission denied') ||
      text.contains('UNPROTECTED PRIVATE KEY FILE')) {
    return DeliveryFailureKind.permissionDenied;
  }
  if (text.contains('Connection refused') ||
      text.contains('No such file or directory') ||
      text.contains('Could not resolve hostname')) {
    return DeliveryFailureKind.destinationUnreachable;
  }
  return DeliveryFailureKind.transportFailure;
}

/// Build an entry from an algorithm and a base64 key, or null when the key
/// does not decode.
///
/// A line whose key field is not base64 is not a host key — `ssh-keyscan`
/// also emits comment and error lines. Skipping it here is what makes the
/// caller's "presented no host key" failure fire when NONE of the lines
/// parse.
HostKeyScanEntry? _entryFor({
  required String algorithm,
  required String encodedBlob,
}) {
  final List<int>? blob = _decodeBase64(encodedBlob);
  if (blob == null || blob.isEmpty) return null;
  final digest = sha256.convert(blob);
  final encoded = base64.encode(digest.bytes).replaceAll('=', '');
  return HostKeyScanEntry(
    algorithm: algorithm,
    blob: encodedBlob,
    fingerprint: 'SHA256:$encoded',
  );
}

List<int>? _decodeBase64(String value) {
  try {
    return base64.decode(value);
  } on FormatException {
    return null;
  }
}

/// The SFTP transport's parsed, non-secret configuration.
class _SftpConfig {
  final String host;
  final int port;
  final String user;
  final String remoteDir;
  final String? hostKeyFingerprint;

  /// The pinned host key itself, once a first delivery has learned it. When
  /// this is set no scan is made and OpenSSH enforces the pin.
  final HostKeyScanEntry? hostKey;
  final String digestCommand;

  /// The rig-identity component this destination's delivered names carry.
  final DeliveryNaming naming;

  const _SftpConfig({
    required this.host,
    required this.port,
    required this.user,
    required this.remoteDir,
    required this.hostKeyFingerprint,
    required this.hostKey,
    required this.digestCommand,
    required this.naming,
  });

  String get userAtHost => '$user@$host';

  String get quotedRemoteDir => _quote(remoteDir);

  static _SftpConfig parse(ArtifactDestination destination) {
    final config = decodeDeliveryConfig(destination, what: 'SFTP destination');

    final authMethod = config['authMethod'];
    if (authMethod is String && authMethod.trim().toLowerCase() == 'password') {
      throw const DeliveryFailure(
        DeliveryFailureKind.authMethodUnavailable,
        'SFTP delivery authenticates with a key. OpenSSH refuses to read a '
        'password from a pipe, so configure this destination with a private '
        'key in the keyring instead',
      );
    }

    final host = _requiredString(config, 'host');
    final user = _requiredString(config, 'user');
    final remoteDir = _requiredString(config, 'remoteDir');
    _refuseUnquotableName(remoteDir);

    final rawPort = config['port'];
    final port = rawPort ?? 22;
    if (port is! int || port < 1 || port > 65535) {
      throw DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        'port on this SFTP destination is $rawPort, which is not a TCP port',
      );
    }

    final fingerprint = config['hostKeyFingerprint'];
    if (fingerprint != null && fingerprint is! String) {
      throw DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        'hostKeyFingerprint on this SFTP destination is $fingerprint, which '
        'is not a fingerprint string',
      );
    }
    final pinnedFingerprint = (fingerprint as String?)?.trim();

    final storedKey = config['hostKey'];
    HostKeyScanEntry? hostKey;
    if (storedKey != null) {
      if (storedKey is! String || storedKey.trim().isEmpty) {
        throw DeliveryFailure(
          DeliveryFailureKind.configurationInvalid,
          'hostKey on this SFTP destination is $storedKey, which is not a '
          'stored host key',
        );
      }
      hostKey = HostKeyScanEntry.parse(storedKey);
      if (hostKey == null) {
        throw const DeliveryFailure(
          DeliveryFailureKind.configurationInvalid,
          'hostKey on this SFTP destination is not an OpenSSH host key '
          '("<algorithm> <base64 key>")',
        );
      }
      if (pinnedFingerprint != null &&
          pinnedFingerprint.isNotEmpty &&
          hostKey.fingerprint != pinnedFingerprint) {
        // Two pins that disagree is not something to pick a winner from: one
        // of them was edited by hand or by a bug, and trusting either would be
        // trusting a key nobody decided on.
        throw DeliveryFailure(
          DeliveryFailureKind.configurationInvalid,
          'This SFTP destination pins the fingerprint $pinnedFingerprint but '
          'stores a host key whose fingerprint is ${hostKey.fingerprint}; '
          'clear one of them and let the next delivery re-pin',
        );
      }
    }

    final digest = config['digestCommand'];
    if (digest != null && (digest is! String || digest.trim().isEmpty)) {
      throw DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        'digestCommand on this SFTP destination is $digest, which is not a '
        'command',
      );
    }
    final digestCommand =
        (digest as String?)?.trim() ?? kDefaultRemoteDigestCommand;
    _refuseUnquotableName(digestCommand);

    return _SftpConfig(
      host: host,
      port: port,
      user: user,
      remoteDir: remoteDir,
      hostKeyFingerprint: pinnedFingerprint,
      hostKey: hostKey,
      digestCommand: digestCommand,
      naming: DeliveryNaming.of(config),
    );
  }

  static String _requiredString(Map<String, Object?> config, String key) {
    final value = config[key];
    if (value is! String || value.trim().isEmpty) {
      throw DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        'This SFTP destination names no $key',
      );
    }
    return value.trim();
  }
}

/// One opened SFTP session: the scratch key material and the option list
/// every OpenSSH invocation shares.
class _SftpSession {
  final _SftpConfig config;
  final Directory workDir;
  final File keyFile;
  final File knownHosts;
  final String pinnedFingerprint;

  const _SftpSession({
    required this.config,
    required this.workDir,
    required this.keyFile,
    required this.knownHosts,
    required this.pinnedFingerprint,
  });

  /// Options common to `ssh` and `sftp`.
  ///
  /// `BatchMode=yes` and `NumberOfPasswordPrompts=0` are what turn a server
  /// that wants a password into an immediate non-zero exit instead of a
  /// process blocked on a prompt no one will ever see.
  ///
  /// `LogLevel=ERROR` is what keeps a server's login banner out of the failure
  /// message. OpenSSH prints the banner on STDERR ahead of everything else, so
  /// at the default log level a delivery to a banner-carrying server reports
  /// "AUTHORIZED USE ONLY" as the reason it failed. Refusals — a denied key, a
  /// refused connection, a changed host key, an SFTP write that could not open
  /// its destination — are all logged above ERROR and survive.
  List<String> get _commonOptions => <String>[
    '-o',
    'BatchMode=yes',
    '-o',
    'StrictHostKeyChecking=yes',
    '-o',
    'UserKnownHostsFile=${knownHosts.path}',
    '-o',
    'GlobalKnownHostsFile=${p.join(workDir.path, 'no_global_known_hosts')}',
    '-o',
    'HostKeyAlias=$kSftpHostKeyAlias',
    '-o',
    'IdentitiesOnly=yes',
    '-o',
    'PasswordAuthentication=no',
    '-o',
    'NumberOfPasswordPrompts=0',
    '-o',
    'ConnectTimeout=15',
    '-o',
    'LogLevel=ERROR',
    '-i',
    keyFile.path,
  ];

  /// `ssh` argument prefix.
  List<String> get sshOptions => <String>[
    ..._commonOptions,
    '-p',
    '${config.port}',
  ];

  /// `sftp` argument prefix. `sftp` spells the port `-P`.
  List<String> get sftpOptions => <String>[
    ..._commonOptions,
    '-P',
    '${config.port}',
  ];
}

/// Wrap [value] in single quotes for the remote shell.
String _quote(String value) => "'$value'";

/// Refuse a name that cannot be safely quoted for the remote shell.
///
/// Every remote path is passed inside single quotes, which is airtight for
/// every character except a single quote itself. Rather than build an escaping
/// scheme, a name carrying one is refused — an astronomical target name never
/// needs it, and a half-escaped path is how a delivery becomes a command.
void _refuseUnquotableName(String value) {
  if (value.contains("'")) {
    throw DeliveryFailure(
      DeliveryFailureKind.configurationInvalid,
      'SFTP delivery cannot address "$value": a single quote in a remote path '
      'cannot be passed to the remote shell safely',
    );
  }
}
