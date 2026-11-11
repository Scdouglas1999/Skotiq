import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api_server.dart';
import 'package:skotiq_desktop/host/host_server.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../headless_api/handler_test_helpers.dart';

/// A linked client pins the fingerprint it paired with and refuses a host
/// that answers with another one, so a host restarted on the same data
/// directory must come back with the same fingerprint.
void main() {
  late Directory dataDir;
  late ProviderContainer container;
  final logger = LoggingService();

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('host_identity_test');
    container = createHeadlessTestContainer();
  });

  tearDown(() async {
    container.dispose();
    await dataDir.delete(recursive: true);
  });

  /// One start of the daemon: the identity resolved the way the host start-up
  /// resolves it, and the server built from it.
  Future<String> startDaemon({
    String? authToken,
    bool requireAuth = false,
    Directory? dataDirectory,
  }) async {
    final server = HeadlessApiServer(
      port: 0,
      container: container,
      authToken: authToken,
      requireAuth: requireAuth,
      identitySecret: await hostIdentitySecret(
        adminToken: authToken,
        dataDirectory: dataDirectory ?? dataDir,
        logger: logger,
        logSource: 'test',
      ),
    );
    return server.serverFingerprint;
  }

  test('a host with no token keeps its fingerprint across restarts', () async {
    final first = await startDaemon();
    final second = await startDaemon();
    expect(second, first);
  });

  test('a host that generates its token at start keeps its fingerprint '
      'across restarts', () async {
    final first = await startDaemon(requireAuth: true);
    final second = await startDaemon(requireAuth: true);
    expect(second, first);
  });

  test('two hosts with their own data directories have different '
      'fingerprints', () async {
    final other = await Directory.systemTemp.createTemp('host_identity_other');
    addTearDown(() => other.delete(recursive: true));
    expect(await startDaemon(dataDirectory: other), isNot(await startDaemon()));
  });

  test('a configured admin token stays the identity clients paired with', () async {
    expect(
      await startDaemon(authToken: 'operator-token'),
      computeServerFingerprint('operator-token'),
    );
    expect(
      File(p.join(dataDir.path, hostIdentityKeyFileName)).existsSync(),
      isFalse,
    );
  });

  test('the identity key is readable by its owner only', () async {
    await startDaemon();
    final mode = File(p.join(dataDir.path, hostIdentityKeyFileName))
        .statSync()
        .modeString();
    expect(mode, 'rw-------');
  }, skip: Platform.isWindows ? 'POSIX file modes' : null);
}
