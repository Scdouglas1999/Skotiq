/// A real OpenSSH server, running as this user, for tests that need to prove
/// something against the wire rather than against a scripted process runner.
///
/// Everything the server needs — host key, an authorised user key, an
/// unauthorised one, `authorized_keys`, `sshd_config`, its pid file and its
/// log — is generated into one temporary directory and removed with it. The
/// server listens on 127.0.0.1 only, on the first free port in
/// [_portSearchStart]..[_portSearchEnd], and authenticates the same account
/// the test is running as, so nothing outside the temp directory is touched.
///
/// Two settings are deliberately not production-shaped, and both are here to
/// make the fixture deterministic rather than to make a test pass:
///
///   * `StrictModes no` — sshd otherwise refuses a home directory and an
///     `authorized_keys` it does not consider private enough, and the fixture
///     keeps both in a temp directory.
///   * `PerSourcePenalties no` — an sshd built after 9.8 starts dropping
///     connections from a source that fails authentication or connects
///     without authenticating (measured: two failed authentications is
///     enough). A test that deliberately presents a wrong key would poison
///     every case after it. The penalty behaviour itself is real and worth
///     knowing about; it is simply not what these tests are measuring.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// First port the fixture tries.
const int _portSearchStart = 2299;

/// Last port the fixture tries.
const int _portSearchEnd = 2310;

/// The binaries a real-sshd test needs on PATH.
const List<String> _requiredBinaries = [
  'sshd',
  'ssh',
  'sftp',
  'ssh-keyscan',
  'ssh-keygen',
];

/// One temporary OpenSSH server.
class RealSshdServer {
  /// The directory holding every file the server and its clients use.
  final Directory root;

  /// The loopback port the server listens on.
  final int port;

  /// The account the server authenticates — the one running the test.
  final String user;

  /// A directory on the server the test can deliver into.
  final Directory incomingDir;

  /// The private key `authorized_keys` accepts, as PEM text.
  final String authorizedPrivateKey;

  /// A well-formed private key the server has never heard of.
  final String unauthorizedPrivateKey;

  Process _process;
  String _hostKeyEntry;
  String _hostKeyFingerprint;

  RealSshdServer._({
    required this.root,
    required this.port,
    required this.user,
    required this.incomingDir,
    required this.authorizedPrivateKey,
    required this.unauthorizedPrivateKey,
    required Process process,
    required String hostKeyEntry,
    required String hostKeyFingerprint,
  }) : _process = process,
       _hostKeyEntry = hostKeyEntry,
       _hostKeyFingerprint = hostKeyFingerprint;

  /// The server's host key as a destination row stores it:
  /// `<algorithm> <base64 key>`.
  String get hostKeyEntry => _hostKeyEntry;

  /// OpenSSH's `SHA256:` fingerprint of [hostKeyEntry].
  String get hostKeyFingerprint => _hostKeyFingerprint;

  /// Why this machine cannot run the fixture, or null when it can.
  ///
  /// Synchronous so a suite can decide at declaration time whether to skip,
  /// and honest about which binary is missing: a skip that does not say what
  /// is absent is indistinguishable from a test that was quietly abandoned.
  static String? unavailableReason() {
    final missing = _requiredBinaries
        .where((binary) => _which(binary) == null)
        .toList();
    if (missing.isNotEmpty) {
      return 'this machine has no ${missing.join(', ')} on PATH, so the SFTP '
          'transport cannot be run against a real SSH server here';
    }
    if (Platform.isWindows) {
      return 'the fixture launches a userland sshd with a POSIX config and has '
          'not been validated on Windows';
    }
    return null;
  }

  /// Generate the key material and configuration, start `sshd`, and wait for
  /// it to accept connections.
  ///
  /// [banner] configures a login banner, which OpenSSH sends before
  /// authentication and the client prints on STDERR ahead of anything else —
  /// the shape a great many real servers have, and the one that decides
  /// whether a delivery failure names the failure or the banner.
  static Future<RealSshdServer> start({String? banner}) async {
    final root = await Directory.systemTemp.createTemp('ns_real_sshd_');
    try {
      return await _start(root, banner);
    } on Object {
      await root.delete(recursive: true);
      rethrow;
    }
  }

  static Future<RealSshdServer> _start(Directory root, String? banner) async {
    final incoming = Directory(p.join(root.path, 'incoming'));
    await incoming.create();

    await _generateKey(p.join(root.path, 'host_key'));
    await _generateKey(p.join(root.path, 'user_key'));
    await _generateKey(p.join(root.path, 'unauthorized_key'));
    await File(p.join(root.path, 'authorized_keys')).writeAsString(
      await File(p.join(root.path, 'user_key.pub')).readAsString(),
    );

    final port = await _firstFreePort();
    final config = await _writeConfig(root: root, port: port, banner: banner);
    final process = await _launch(root: root, config: config, port: port);

    final hostKey = await File(
      p.join(root.path, 'host_key.pub'),
    ).readAsString();
    return RealSshdServer._(
      root: root,
      port: port,
      user: _whoami(),
      incomingDir: incoming,
      authorizedPrivateKey: await File(
        p.join(root.path, 'user_key'),
      ).readAsString(),
      unauthorizedPrivateKey: await File(
        p.join(root.path, 'unauthorized_key'),
      ).readAsString(),
      process: process,
      hostKeyEntry: _entryOf(hostKey),
      hostKeyFingerprint: await _fingerprintOf(
        p.join(root.path, 'host_key.pub'),
      ),
    );
  }

  /// Stop the server, leaving the directory (and the port) as they are.
  ///
  /// A delivery attempted after this is what a rig sees when the office
  /// machine goes down mid-job.
  Future<void> stop() async {
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return _process.exitCode;
      },
    );
    await _waitForPort(open: false);
  }

  /// Stop the server, give it a brand new host key, and start it again on the
  /// same port — the shape a man-in-the-middle has, and the shape a rebuilt
  /// server has.
  Future<void> restartWithNewHostKey() async {
    await stop();
    final hostKeyPath = p.join(root.path, 'host_key');
    await File(hostKeyPath).delete();
    await File('$hostKeyPath.pub').delete();
    await _generateKey(hostKeyPath);
    _hostKeyEntry = _entryOf(await File('$hostKeyPath.pub').readAsString());
    _hostKeyFingerprint = await _fingerprintOf('$hostKeyPath.pub');
    _process = await _launch(
      root: root,
      config: File(p.join(root.path, 'sshd_config')),
      port: port,
    );
  }

  /// Everything sshd wrote to its log, for a failure message worth reading.
  Future<String> readLog() async {
    final log = File(p.join(root.path, 'sshd.log'));
    return await log.exists() ? log.readAsString() : '';
  }

  /// Stop the server and remove every file it used.
  Future<void> dispose() async {
    try {
      await stop();
    } on ProcessException {
      // The process is already gone; the directory still has to go.
    }
    if (await root.exists()) await root.delete(recursive: true);
  }

  Future<void> _waitForPort({required bool open}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (await _portAccepts() == open) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError(
      'the fixture sshd on 127.0.0.1:$port never '
      '${open ? 'started' : 'stopped'} listening',
    );
  }

  Future<bool> _portAccepts() async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  static Future<Process> _launch({
    required Directory root,
    required File config,
    required int port,
  }) async {
    final sshd = _which('sshd')!;
    final process = await Process.start(sshd, [
      '-f',
      config.path,
      '-D',
      '-E',
      p.join(root.path, 'sshd.log'),
    ]);
    // sshd's own stdio is empty in this mode (-E sends the log to a file), but
    // an unread stream would keep the child blocked if that ever changed.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(seconds: 2),
        );
        socket.destroy();
        return process;
      } on SocketException {
        // Not up yet. If it died on the way up, say why rather than waiting
        // out the deadline.
        final exited = await process.exitCode.timeout(
          const Duration(milliseconds: 50),
          onTimeout: () => _stillRunningSentinel,
        );
        if (exited != _stillRunningSentinel) {
          final log = File(p.join(root.path, 'sshd.log'));
          throw StateError(
            'the fixture sshd exited with status $exited before it listened on '
            '127.0.0.1:$port: ${await log.exists() ? await log.readAsString() : 'no log'}',
          );
        }
      }
    }
    process.kill(ProcessSignal.sigkill);
    throw StateError(
      'the fixture sshd did not listen on 127.0.0.1:$port within 15s',
    );
  }

  /// A status no process exits with, used to mean "still running".
  static const int _stillRunningSentinel = -12345;

  static Future<File> _writeConfig({
    required Directory root,
    required int port,
    required String? banner,
  }) async {
    final config = File(p.join(root.path, 'sshd_config'));
    if (banner != null) {
      await File(p.join(root.path, 'banner.txt')).writeAsString('$banner\n');
    }
    final settings = <String>[
      'Port $port',
      'ListenAddress 127.0.0.1',
      'HostKey ${p.join(root.path, 'host_key')}',
      'PidFile ${p.join(root.path, 'sshd.pid')}',
      'AuthorizedKeysFile ${p.join(root.path, 'authorized_keys')}',
      'StrictModes no',
      'UsePAM no',
      'PasswordAuthentication no',
      'KbdInteractiveAuthentication no',
      'PubkeyAuthentication yes',
      'PerSourcePenalties no',
      'LogLevel VERBOSE',
      'Subsystem sftp internal-sftp',
      if (banner != null) 'Banner ${p.join(root.path, 'banner.txt')}',
    ];
    await config.writeAsString('${settings.join('\n')}\n');

    var check = await Process.run(_which('sshd')!, ['-t', '-f', config.path]);
    if (check.exitCode != 0 &&
        '${check.stderr}'.contains('PerSourcePenalties')) {
      // Older sshd does not know the keyword, and an unknown keyword is fatal.
      // Dropping it is safe there for the same reason: that build has no
      // source penalties to disable.
      settings.remove('PerSourcePenalties no');
      await config.writeAsString('${settings.join('\n')}\n');
      check = await Process.run(_which('sshd')!, ['-t', '-f', config.path]);
    }
    if (check.exitCode != 0) {
      throw StateError(
        'this machine\'s sshd rejected the fixture configuration: '
        '${'${check.stderr}'.trim()}',
      );
    }
    return config;
  }

  static Future<void> _generateKey(String path) async {
    final result = await Process.run(_which('ssh-keygen')!, [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-C',
      'skotiq-real-sshd-fixture',
      '-f',
      path,
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'ssh-keygen could not write $path: ${'${result.stderr}'.trim()}',
      );
    }
  }

  /// `<algorithm> <base64 key>` out of an OpenSSH `.pub` line, dropping the
  /// trailing comment.
  static String _entryOf(String publicKeyLine) {
    final parts = publicKeyLine.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) {
      throw StateError('ssh-keygen wrote an unreadable public key line');
    }
    return '${parts[0]} ${parts[1]}';
  }

  static Future<String> _fingerprintOf(String publicKeyPath) async {
    final result = await Process.run(_which('ssh-keygen')!, [
      '-l',
      '-f',
      publicKeyPath,
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'ssh-keygen could not fingerprint $publicKeyPath: '
        '${'${result.stderr}'.trim()}',
      );
    }
    final fields = '${result.stdout}'.trim().split(RegExp(r'\s+'));
    if (fields.length < 2 || !fields[1].startsWith('SHA256:')) {
      throw StateError(
        'ssh-keygen printed no SHA-256 fingerprint for $publicKeyPath: '
        '${'${result.stdout}'.trim()}',
      );
    }
    return fields[1];
  }

  static Future<int> _firstFreePort() async {
    for (var port = _portSearchStart; port <= _portSearchEnd; port++) {
      try {
        final socket = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        await socket.close();
        return port;
      } on SocketException {
        continue;
      }
    }
    throw StateError(
      'every port from $_portSearchStart to $_portSearchEnd is already in use',
    );
  }

  static String _whoami() {
    final result = Process.runSync('id', ['-un']);
    if (result.exitCode != 0) {
      throw StateError('`id -un` failed: ${'${result.stderr}'.trim()}');
    }
    return '${result.stdout}'.trim();
  }

  static String? _which(String binary) {
    final result = Process.runSync('which', [binary]);
    if (result.exitCode != 0) return null;
    final path = '${result.stdout}'.trim();
    return path.isEmpty ? null : path;
  }
}
