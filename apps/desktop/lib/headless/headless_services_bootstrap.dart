import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../headless_api/auth/pairing_service.dart';
import '../headless_api/auth_policy.dart';
import '../headless_api/handlers/pairing_handlers.dart' show PairingMode;
import '../headless_api/tls_provisioner.dart';
import '../headless_api_server.dart';
import 'headless_discovery_bootstrap.dart';
import 'headless_security_advisories.dart';
import 'host_checkpoint_directory.dart';

const _headlessLogSource = 'HeadlessMain';

/// Provision the TLS context (when enabled), build and start the
/// [HeadlessApiServer], and wire the LAN-facing surfaces (UDP discovery, LAN
/// push broadcaster, cellular push delivery) appropriate to the bind mode.
///
/// Returns the started server. TLS and database failures rethrow so a broken
/// configuration surfaces as a clean startup error rather than a mid-flight
/// 5xx; the LAN-facing extras are best-effort and log-and-continue.
Future<HeadlessApiServer> startHeadlessServices(
  ProviderContainer container, {
  required LoggingService logger,
  String? authToken,
  Map<String, HeadlessTokenScope> scopedAuthTokens = const {},
  Map<String, HeadlessAuthGrant> fineGrainedAuthTokens = const {},
  bool requireAuth = false,
  bool allowUnauthenticated = false,
  bool bindLocalOnly = true,
  int port = 8080,
  List<String> corsAllowedOrigins = const [],
  bool pairingPrintCodes = false,
  PairingMode pairingMode = PairingMode.lanOpen,
  bool tlsEnabled = false,
  String? tlsCertPath,
  String? tlsKeyPath,
}) async {
  try {
    final database = container.read(databaseProvider);
    // Constructing Drift's lazy database does not load sqlite or open the
    // file. Execute a real query before binding the API so a missing native
    // runtime cannot leave a server that advertises healthy endpoints while
    // every database-backed request hangs.
    await database.customSelect('SELECT 1').getSingle();
    logger.info('Database initialized', source: _headlessLogSource);
  } catch (e) {
    logger.critical(
      'Database initialization failed: $e — headless server cannot function without a database',
      source: _headlessLogSource,
    );
    rethrow;
  }

  // provision the TLS context BEFORE bind so a cert generation
  // failure surfaces as a clean startup error instead of an HTTPS 5xx
  // mid-flight.
  TlsProvisionResult? tlsProvision;
  if (tlsEnabled) {
    final appData = await resolveSkotiqDataDirectory();
    try {
      tlsProvision = await provisionTlsContext(
        appDataDirectory: appData.path,
        certPath: tlsCertPath,
        keyPath: tlsKeyPath,
      );
      logger.info(
        'TLS provisioning OK: cert=${tlsProvision.certificatePath} '
        'spki_sha256=${tlsProvision.publicKeyFingerprintSha256} '
        'validity=${tlsProvision.validity.notBefore.toUtc().toIso8601String()}..'
        '${tlsProvision.validity.notAfter.toUtc().toIso8601String()}',
        source: _headlessLogSource,
      );
    } catch (e, st) {
      logger.critical(
        'TLS provisioning failed: $e\n$st — refusing to start the server. '
        'Remove --tls to fall back to plain HTTP, or pass --tls-cert + '
        '--tls-key with a hand-issued PEM pair.',
        source: _headlessLogSource,
      );
      rethrow;
    }
  }

  // Construct the PairingService eagerly so the server hydrates
  // _pairedSessionTokens from the on-disk Drift DB at startup. Lazy creation
  // on the first /api/pairing/verify would leave already-paired clients
  // rejected with 403 until they re-pair. Construction is cheap (no DB I/O);
  // the file opens on the first query.
  final pairingService = PairingService();

  // Crash recovery is a production feature, not an opt-in API call. Configure
  // its durable directory before accepting requests so the first sequence and
  // `/api/sequencer/checkpoint/save` share the same checkpoint manager.
  final checkpointDir = await resolveHostCheckpointDirectory();
  await container
      .read(sequenceExecutorProvider)
      .initializeCheckpoints(checkpointDir.path);
  logger.info('Sequencer checkpoints initialized', source: _headlessLogSource);

  final apiServer = HeadlessApiServer(
    port: port,
    container: container,
    authToken: authToken,
    scopedAuthTokens: scopedAuthTokens,
    fineGrainedAuthTokens: fineGrainedAuthTokens,
    requireAuth: requireAuth,
    allowUnauthenticated: allowUnauthenticated,
    bindLocalOnly: bindLocalOnly,
    corsAllowedOrigins: corsAllowedOrigins,
    pairingPrintCodes: pairingPrintCodes,
    pairingMode: pairingMode,
    tlsContext: tlsProvision?.securityContext,
    tlsPublicKeyFingerprint: tlsProvision?.publicKeyFingerprintSha256,
    pairingService: pairingService,
  );

  await apiServer.start();
  logger.info('API server started on port $port', source: _headlessLogSource);

  // Surface the two real LAN-exposure footguns — no authentication, and
  // credentials sent in cleartext — so an operator who opens the server to the
  // network cannot miss them. Persist them to the structured log here; the
  // operator-facing stdout banner below repeats them.
  final securityAdvisories = headlessSecurityAdvisories(
    bindLocalOnly: bindLocalOnly,
    hasAuth: apiServer.effectiveAuthToken != null,
    tlsEnabled: tlsProvision != null,
  );
  for (final advisory in securityAdvisories) {
    logger.warning('SECURITY: $advisory', source: _headlessLogSource);
  }

  if (!bindLocalOnly) {
    try {
      final appVersion = container.read(appVersionProvider);
      await startDiscoveryServer(
        logger: logger,
        apiServer: apiServer,
        appVersion: appVersion.version,
      );
      logger.info(
        'Discovery server started on UDP port 45679 '
        '(advertising ${apiServer.actualPort})',
        source: _headlessLogSource,
      );
    } catch (e) {
      logger.warning('Discovery server failed: $e', source: _headlessLogSource);
    }
  } else {
    logger.info(
      'Headless server is bound to loopback; LAN discovery is disabled',
      source: _headlessLogSource,
    );
  }

  // spin up the LAN UDP push broadcaster when the server is
  // exposed on the LAN. Loopback-only deployments have no LAN clients to
  // wake, so the broadcaster is skipped (its `start()` would still warn
  // about no interfaces — clearer to skip explicitly). The broadcaster's
  // fingerprint MUST match the server's `/api/info` fingerprint, which
  // is the same one paired phones learned during enrollment; that
  // identity binding is what stops a malicious LAN host from forging
  // alerts (see lan_push_broadcaster.dart header for the threat model).
  if (!bindLocalOnly) {
    try {
      final pushBroadcaster = LanPushBroadcaster(
        serverFingerprint: apiServer.serverFingerprint,
        logger: (level, message, {fields}) {
          switch (level) {
            case LanPushLogLevel.info:
              logger.info(message, source: _headlessLogSource, fields: fields);
              break;
            case LanPushLogLevel.warning:
              logger.warning(
                message,
                source: _headlessLogSource,
                fields: fields,
              );
              break;
            case LanPushLogLevel.error:
              logger.error(message, source: _headlessLogSource, fields: fields);
              break;
          }
        },
      );
      apiServer.setLanPushBroadcaster(pushBroadcaster);
      await pushBroadcaster.start();
      logger.info(
        'LAN push broadcaster started '
        '(port=${pushBroadcaster.port}, interfaces=${pushBroadcaster.activeSinkCount})',
        source: _headlessLogSource,
      );
    } catch (e, st) {
      // Bind failure is non-fatal — see doc reference in
      // setPushNotificationStream. Phones still get critical pushes via
      // the WebSocket when their WS is alive; UDP is the supplement.
      logger.warning(
        'LAN push broadcaster failed to start: $e\n$st',
        source: _headlessLogSource,
      );
    }
  } else {
    logger.info(
      'Headless server is loopback-only; LAN push broadcaster is skipped',
      source: _headlessLogSource,
    );
  }

  // Phase D — wire cellular (FCM/APNs) remote push delivery. Wired regardless
  // of the LAN-bind state because the cellular path reaches a phone hours from
  // the rig even when the server is loopback-only behind a reverse proxy. The
  // delivery is chosen from push_config.json (app-support dir, or the
  // SKOTIQ_PUSH_CONFIG override): the real FCM/APNs senders activate when
  // the operator supplies a service-account JSON / .p8 key. With no cloud
  // channel the cellular path stays disabled; a would-send mock is permitted
  // only when the operator explicitly sets `mock:true` for development.
  try {
    final pushAppSupportDir = await resolveSkotiqDataDirectory();
    final delivery = await apiServer.wireRemotePushDelivery(
      appSupportDir: pushAppSupportDir.path,
      log: (message) => logger.info(message, source: _headlessLogSource),
    );
    logger.info(
      delivery is MockRemotePushDelivery
          ? 'Cellular push delivery wired (mock — no cloud credentials)'
          : delivery == null
          ? 'Cellular push delivery not wired (no channel configured)'
          : 'Cellular push delivery wired (cloud channel configured)',
      source: _headlessLogSource,
    );
  } catch (e, st) {
    logger.warning(
      'Cellular push delivery failed to wire: $e\n$st',
      source: _headlessLogSource,
    );
  }

  try {
    final interfaces = await NetworkInterface.list();
    String? localIp;

    for (final interface in interfaces) {
      final isLoopback =
          interface.name.contains('lo') || interface.name.contains('Loopback');
      if (isLoopback) {
        continue;
      }
      for (final addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4) {
          localIp = addr.address;
          break;
        }
      }
      if (localIp != null) {
        break;
      }
    }

    final scheme = tlsProvision != null ? 'https' : 'http';

    // Operator-facing connect-URL block. These are intentionally on stdout
    // (not the structured logger) so a sysadmin invoking the headless server
    // sees them immediately in the console; the redacted token form keeps
    // the captured stdout safe to share for debugging.
    if (!bindLocalOnly && localIp != null) {
      stdout.writeln('\n  Mobile devices can connect to:');
      stdout.writeln('    $scheme://$localIp:$port');
      if (apiServer.effectiveAuthToken != null) {
        stdout.writeln('\n  Authentication required:');
        stdout.writeln(
          '    Authorization: Bearer ${_redactToken(apiServer.effectiveAuthToken!)}',
        );
      }
      if (tlsProvision != null) {
        stdout.writeln(
          '  TLS fingerprint (SPKI SHA-256): ${tlsProvision.publicKeyFingerprintSha256}',
        );
      }
      for (final advisory in securityAdvisories) {
        stdout.writeln('\n  WARNING: $advisory');
      }
      stdout.writeln('');
    } else {
      stdout.writeln('\n  Headless API is available on:');
      stdout.writeln('    $scheme://127.0.0.1:$port');
      stdout.writeln(
        '  Add --require-auth or --auth-token to expose authenticated LAN access.',
      );
      if (tlsProvision != null) {
        stdout.writeln(
          '  TLS fingerprint (SPKI SHA-256): ${tlsProvision.publicKeyFingerprintSha256}',
        );
      }
      stdout.writeln('');
    }
  } catch (e) {
    // The LAN-address banner is informational; surface the failure on stdout
    // rather than swallowing it, but never let it abort startup.
    stdout.writeln('  (local IP details unavailable: $e)');
  }

  return apiServer;
}

/// Redact a bearer token for log output: shows the first 4 and last 4
/// characters, masks the middle. A full token must never reach stdout or the
/// log — console output is captured to files that outlive the session.
String _redactToken(String token) {
  if (token.length <= 8) return '*' * token.length;
  return '${token.substring(0, 4)}...${token.substring(token.length - 4)}';
}
