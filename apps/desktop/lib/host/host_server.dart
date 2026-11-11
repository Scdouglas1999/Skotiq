import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_updater/skotiq_updater.dart';

import '../headless/headless_discovery_bootstrap.dart';
import '../headless/headless_relay_bootstrap.dart';
import '../headless/headless_security_advisories.dart';
import '../headless_api/auth_policy.dart';
import '../headless_api/handlers/pairing_handlers.dart' show PairingMode;
import '../headless_api/tls_provisioner.dart';
import '../headless_api/update_wiring.dart';
import '../headless_api_server.dart';
import 'host_startup.dart';

/// How the remote access server is to be started. The daemon fills this from
/// its command line; the GUI from the Remote Access settings and its stored
/// token.
class HostServerConfig {
  const HostServerConfig({
    required this.port,
    required this.hostMode,
    required this.bindLocalOnly,
    this.authToken,
    this.scopedAuthTokens = const {},
    this.fineGrainedAuthTokens = const {},
    this.requireAuth = false,
    this.allowUnauthenticated = false,
    this.corsAllowedOrigins = const [],
    this.pairingPrintCodes = false,
    this.pairingMode = PairingMode.lanOpen,
    this.tlsEnabled = false,
    this.tlsCertPath,
    this.tlsKeyPath,
    this.showApiCapturesInPreview = false,
    this.relayArgs = const [],
  });

  final int port;
  final SkotiqHostMode hostMode;
  final bool bindLocalOnly;
  final String? authToken;
  final Map<String, HeadlessTokenScope> scopedAuthTokens;
  final Map<String, HeadlessAuthGrant> fineGrainedAuthTokens;
  final bool requireAuth;
  final bool allowUnauthenticated;
  final List<String> corsAllowedOrigins;
  final bool pairingPrintCodes;
  final PairingMode pairingMode;
  final bool tlsEnabled;
  final String? tlsCertPath;
  final String? tlsKeyPath;

  /// A client's captures also appear in this process's image view (GUI).
  final bool showApiCapturesInPreview;

  /// The launch arguments, read for `--relay-url` and
  /// `--relay-allow-insecure-tls` (the environment is read as well).
  final List<String> relayArgs;
}

/// A started remote access server with everything that hangs off it.
class RunningHostServer {
  RunningHostServer._({
    required this.server,
    required this.updateStack,
    required this.tls,
    required this.securityAdvisories,
    required this.stopSteps,
  });

  final HeadlessApiServer server;

  /// The update stack behind `/api/system/update/*`, or null when it could
  /// not be provisioned.
  final UpdateStack? updateStack;

  final TlsProvisionResult? tls;
  final List<String> securityAdvisories;

  /// How this stops, in order: peers stop being told about the server
  /// (discovery, mDNS, relay) before its socket closes, the update controller
  /// is detached before the server stops, and the update stack goes last.
  final List<HostStop> stopSteps;

  /// Runs every stop step; one that throws does not skip the rest.
  Future<void> stop(LoggingService logger, String logSource) async {
    for (final step in stopSteps) {
      try {
        await step.action();
      } catch (e) {
        logger.warning('Stopping ${step.name} failed: $e', source: logSource);
      }
    }
  }
}

/// Starts the remote access server and everything a client reaches through
/// it, the same way for the GUI host and the daemon:
///
/// 1. TLS context (when asked for) and the update stack, before the bind.
/// 2. The server itself.
/// 3. On a LAN bind: UDP discovery beacons, the mDNS advertisement and the
///    LAN push broadcaster. A loopback-only server has nobody on the LAN to
///    tell.
/// 4. Push notifications to connected phones, and cellular push delivery.
/// 5. The update endpoints.
/// 6. The relay uplink, when a relay URL was given.
///
/// A TLS or bind failure throws. Everything after the bind is best-effort:
/// it is logged and the server keeps running without that part.
Future<RunningHostServer> startHostServer({
  required ProviderContainer container,
  required LoggingService logger,
  required String logSource,
  required HostServerConfig config,
}) async {
  final appVersion = container.read(appVersionProvider);
  final stops = <HostStop>[];

  TlsProvisionResult? tls;
  if (config.tlsEnabled) {
    final appData = await resolveSkotiqDataDirectory();
    try {
      tls = await provisionTlsContext(
        appDataDirectory: appData.path,
        certPath: config.tlsCertPath,
        keyPath: config.tlsKeyPath,
      );
      logger.info(
        'TLS provisioning OK: cert=${tls.certificatePath} '
        'spki_sha256=${tls.publicKeyFingerprintSha256} '
        'validity=${tls.validity.notBefore.toUtc().toIso8601String()}..'
        '${tls.validity.notAfter.toUtc().toIso8601String()}',
        source: logSource,
      );
    } catch (e, st) {
      logger.critical(
        'TLS provisioning failed: $e\n$st — refusing to start the server. '
        'Remove --tls to fall back to plain HTTP, or pass --tls-cert + '
        '--tls-key with a hand-issued PEM pair.',
        source: logSource,
      );
      rethrow;
    }
  }

  UpdateStack? updateStack;
  try {
    updateStack = await provisionUpdateStack(
      currentVersion: appVersion.version,
      currentBuildNumber: appVersion.buildNumber,
      logger: logger,
      logSource: logSource,
      applySafetyCheck: () =>
          defaultUpdateApplySafetyCheckWithReader(container.read),
    );
  } catch (e, st) {
    logger.warning(
      'OTA update stack failed to provision; /api/system/update/* '
      'will be unavailable for this session',
      source: logSource,
      fields: {'error': '$e', 'stack': '$st'},
    );
  }

  final server = HeadlessApiServer(
    port: config.port,
    container: container,
    authToken: config.authToken,
    scopedAuthTokens: config.scopedAuthTokens,
    fineGrainedAuthTokens: config.fineGrainedAuthTokens,
    requireAuth: config.requireAuth,
    allowUnauthenticated: config.allowUnauthenticated,
    bindLocalOnly: config.bindLocalOnly,
    showApiCapturesInPreview: config.showApiCapturesInPreview,
    hostMode: config.hostMode,
    corsAllowedOrigins: config.corsAllowedOrigins,
    pairingPrintCodes: config.pairingPrintCodes,
    pairingMode: config.pairingMode,
    tlsContext: tls?.securityContext,
    tlsPublicKeyFingerprint: tls?.publicKeyFingerprintSha256,
  );

  try {
    await server.start();
  } catch (_) {
    await server.stop();
    await updateStack?.dispose();
    rethrow;
  }
  logger.info(
    'Remote access server started',
    source: logSource,
    fields: {'port': server.actualPort, 'hostMode': config.hostMode.wire},
  );

  // Registered in start order; the stop order is assembled below.
  final stack = updateStack;
  final serverStops = <HostStop>[
    (name: 'API server', action: server.stop),
    if (stack != null) (name: 'OTA update stack', action: stack.dispose),
  ];

  // No authentication, and credentials sent in cleartext, are the two ways an
  // operator exposes a rig by accident.
  final securityAdvisories = headlessSecurityAdvisories(
    bindLocalOnly: config.bindLocalOnly,
    hasAuth: server.effectiveAuthToken != null,
    tlsEnabled: tls != null,
  );
  for (final advisory in securityAdvisories) {
    logger.warning('SECURITY: $advisory', source: logSource);
  }

  final scheme = server.isTlsActive ? 'https' : 'http';
  final hostName = hostComputerName();

  if (!config.bindLocalOnly) {
    try {
      final beacons = await SkotiqDiscovery.startBroadcasting(
        webPort: server.actualPort,
        signalingPort: server.actualPort,
        name: hostName,
        hostName: hostName,
        hostMode: config.hostMode.wire,
        version: appVersion.version,
        scheme: scheme,
        fingerprint: server.serverFingerprint,
        authRequired: server.isAuthRequired,
        authenticationMode: server.isAuthRequired ? 'token' : 'none',
        pairingSupported: true,
      );
      stops.add((name: 'discovery socket', action: () async => beacons.stop()));
      logger.info(
        'UDP discovery broadcasting on port 45679 '
        '(advertising ${server.actualPort})',
        source: logSource,
      );
    } catch (e) {
      logger.warning(
        'UDP discovery broadcaster failed to start',
        source: logSource,
        fields: {'error': '$e'},
      );
    }

    // Additive to the UDP beacons: most Wi-Fi access points block
    // client-to-client broadcast, and a VPN segment has no broadcast domain.
    if (config.hostMode == SkotiqHostMode.headless) {
      // The appliance installs a static Avahi service file with port 8080 and
      // http; keep it in step with what was actually bound.
      refreshAvahiServiceFile(
        logger: logger,
        port: server.actualPort,
        scheme: scheme,
        version: appVersion.version,
      );
    }
    try {
      final registration = MdnsServiceRegistration(
        name: 'Skotiq on $hostName',
        port: server.actualPort,
        txt: {
          'version': appVersion.version,
          'scheme': scheme,
          'fingerprint': server.serverFingerprint,
          'pairingSupported': 'true',
          'name': hostName,
          'hostName': hostName,
          'hostMode': config.hostMode.wire,
        },
        onWarning: (msg) => logger.warning(msg, source: logSource),
      );
      await registration.start();
      stops.add((name: 'mDNS advertisement', action: registration.stop));
      if (registration.isRegistered) {
        logger.info(
          'mDNS advertisement active',
          source: logSource,
          fields: {
            'service': '_skotiq._tcp',
            'port': server.actualPort,
            'scheme': scheme,
            'fingerprint': server.serverFingerprint,
          },
        );
      }
    } catch (e, st) {
      logger.warning(
        'mDNS registration failed unexpectedly: $e\n$st',
        source: logSource,
      );
    }

    // The broadcaster's fingerprint is the one paired phones learned at
    // enrollment; that binding is what stops another LAN host forging alerts.
    try {
      final pushBroadcaster = LanPushBroadcaster(
        serverFingerprint: server.serverFingerprint,
        logger: (level, message, {fields}) {
          switch (level) {
            case LanPushLogLevel.info:
              logger.info(message, source: logSource, fields: fields);
            case LanPushLogLevel.warning:
              logger.warning(message, source: logSource, fields: fields);
            case LanPushLogLevel.error:
              logger.error(message, source: logSource, fields: fields);
          }
        },
      );
      server.setLanPushBroadcaster(pushBroadcaster);
      await pushBroadcaster.start();
      logger.info(
        'LAN push broadcaster started',
        source: logSource,
        fields: {
          'port': pushBroadcaster.port,
          'interfaces': pushBroadcaster.activeSinkCount,
        },
      );
    } catch (e, st) {
      // Phones still get critical pushes over the WebSocket while it is up.
      logger.warning(
        'LAN push broadcaster failed to start: $e\n$st',
        source: logSource,
      );
    }
  } else {
    logger.info(
      'Remote access server is loopback-only; LAN discovery, mDNS and the '
      'LAN push broadcaster are skipped',
      source: logSource,
    );
  }

  // Weather aborts, sequence failures and lost guiding reach connected
  // phones as push_notification envelopes.
  try {
    final pushService = container.read(pushNotificationServiceProvider);
    server.setPushNotificationStream(
      pushService.notifications.map((n) => n.toJson()),
    );
  } catch (e, st) {
    // Logged at error: the operator has to know overnight push is off before
    // relying on it.
    logger.error(
      'Failed to wire push notifications: $e\n$st',
      source: logSource,
    );
  }

  // Cellular (FCM/APNs) delivery reaches a phone hours from the rig, so it is
  // wired whatever the bind. With no cloud channel in push_config.json it
  // stays off.
  try {
    final appSupportDir = await resolveSkotiqDataDirectory();
    final delivery = await server.wireRemotePushDelivery(
      appSupportDir: appSupportDir.path,
      log: (message) => logger.info(message, source: logSource),
    );
    logger.info(
      delivery is MockRemotePushDelivery
          ? 'Cellular push delivery wired (mock — no cloud credentials)'
          : delivery == null
          ? 'Cellular push delivery not wired (no channel configured)'
          : 'Cellular push delivery wired (cloud channel configured)',
      source: logSource,
    );
  } catch (e, st) {
    logger.warning(
      'Cellular push delivery failed to wire: $e\n$st',
      source: logSource,
    );
  }

  if (stack != null) {
    server.setUpdateController(stack.controller);
    logger.info(
      'OTA update endpoints wired to the remote access server',
      source: logSource,
      fields: {
        'channel': stack.controller.channel,
        'updateSource': stack.controller.updateSourceLabel,
      },
    );
  } else {
    logger.info(
      'OTA update stack not provisioned; /api/system/update/* will be '
      'unavailable.',
      source: logSource,
    );
  }

  // Dial out to a self-hosted relay so the rig is reachable with no port
  // forwarding. The relay never sees the pairing token in plaintext. A relay
  // that is down leaves LAN access untouched.
  try {
    final uplink = await startRelayUplink(
      args: config.relayArgs,
      logger: logger,
      localPort: server.actualPort,
      onApplianceId: server.setRelayApplianceId,
    );
    if (uplink != null) {
      stops.add((name: 'relay uplink', action: uplink.stop));
    }
  } catch (e, st) {
    logger.warning('Relay uplink failed to start: $e\n$st', source: logSource);
  }

  return RunningHostServer._(
    server: server,
    updateStack: updateStack,
    tls: tls,
    securityAdvisories: securityAdvisories,
    stopSteps: [
      ...stops,
      (
        name: 'update controller detach',
        action: () async => server.setUpdateController(null),
      ),
      ...serverStops,
    ],
  );
}

/// The LAN address a phone on the same network would use, when there is one.
Future<String?> firstLanAddress() async {
  for (final interface in await NetworkInterface.list()) {
    if (interface.name.contains('lo') || interface.name.contains('Loopback')) {
      continue;
    }
    for (final addr in interface.addresses) {
      if (addr.type == InternetAddressType.IPv4) return addr.address;
    }
  }
  return null;
}
