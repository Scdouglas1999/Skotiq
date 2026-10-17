import 'dart:io';

import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import 'headless_env.dart';

const _headlessLogSource = 'HeadlessMain';

/// v4 couch-grade remote: start the outbound relay uplink if a relay URL was
/// supplied (`--relay-url=<url>` / `SKOTIQ_RELAY_URL`). Returns null when
/// no relay is configured. Never throws — relay is strictly additive on top
/// of the LAN/mDNS path, so a misconfigured or unreachable relay must not stop
/// the daemon from coming up.
///
/// The minted appliance id + secret persist in `relay_credentials.json` under
/// the application-support directory so the rig keeps the same id across
/// restarts. The secret authenticates the appliance to the relay only; phone
/// authentication remains the end-to-end pairing token the relay never sees.
Future<RelayUplink?> startRelayUplink({
  required List<String> args,
  required LoggingService logger,
  required int localPort,
  void Function(String? applianceId)? onApplianceId,
}) async {
  String? relayUrlRaw = trimToNull(Platform.environment['SKOTIQ_RELAY_URL']);
  for (final arg in args) {
    if (arg.startsWith('--relay-url=')) {
      relayUrlRaw = trimToNull(arg.substring('--relay-url='.length));
    }
  }
  if (relayUrlRaw == null) return null;

  // Off by default: only trust a self-signed relay cert when the operator
  // explicitly opts in (relays they run themselves before getting a real cert).
  final allowInsecureTls =
      args.contains('--relay-allow-insecure-tls') ||
      envFlag('SKOTIQ_RELAY_ALLOW_INSECURE_TLS');

  final Uri relayUrl;
  try {
    relayUrl = RelayUplink.normalizeRelayUrl(Uri.parse(relayUrlRaw));
  } catch (e) {
    logger.error(
      'Invalid relay URL "$relayUrlRaw": $e. Relay disabled; LAN access '
      'unaffected.',
      source: _headlessLogSource,
    );
    return null;
  }

  final appData = await resolveSkotiqDataDirectory();
  final credentialsPath =
      '${appData.path}${Platform.pathSeparator}relay_credentials.json';

  final uplink = RelayUplink(
    relayUrl: relayUrl,
    localPort: localPort,
    credentialsStore: FileRelayCredentialsStore(credentialsPath),
    allowBadTlsCertificate: allowInsecureTls,
    onLog: (message) =>
        logger.info('[relay] $message', source: _headlessLogSource),
    onStatus: (status) {
      switch (status.state) {
        case RelayUplinkState.connected:
          final id = status.applianceId;
          logger.info(
            'Relay uplink connected. Appliance id: $id — enter this id plus '
            'the relay URL in the mobile app to connect from anywhere.',
            source: _headlessLogSource,
          );
          if (id != null) {
            stdout.writeln('Relay connected — appliance id: $id');
          }
          // Surface the appliance id via /api/info so the mobile app can show
          // it instead of the operator reading it off this log.
          onApplianceId?.call(id);
        case RelayUplinkState.authFailed:
          logger.error(
            'Relay rejected stored credentials (${status.lastError}). '
            'Delete $credentialsPath to mint a new appliance id, or restore '
            'the relay state file.',
            source: _headlessLogSource,
          );
        case RelayUplinkState.waitingToRetry:
          logger.warning(
            'Relay uplink retrying (${status.lastError})',
            source: _headlessLogSource,
          );
        case RelayUplinkState.stopped:
        case RelayUplinkState.connecting:
        case RelayUplinkState.registering:
          break;
      }
    },
  );
  uplink.start();
  logger.info(
    'Relay uplink starting -> $relayUrl (proxying loopback port $localPort)',
    source: _headlessLogSource,
  );
  return uplink;
}
