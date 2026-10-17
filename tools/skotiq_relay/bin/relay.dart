// Skotiq relay server CLI.
//
// Usage:
//   dart run bin/relay.dart [options]
//   docker run -p 9777:9777 -v relay-state:/data skotiq-relay
//
// Options (env var equivalent in parentheses):
//   --port=<n>                 Listen port, default 9777 (SKOTIQ_RELAY_PORT)
//   --bind=<addr>              Bind address, default 0.0.0.0 (SKOTIQ_RELAY_BIND)
//   --state-file=<path>        Appliance registry persistence,
//                              default ./relay_state.json (SKOTIQ_RELAY_STATE_FILE)
//   --tls-cert=<path>          PEM certificate chain (SKOTIQ_RELAY_TLS_CERT)
//   --tls-key=<path>           PEM private key (SKOTIQ_RELAY_TLS_KEY)
//   --max-appliances=<n>       Default 50 (SKOTIQ_RELAY_MAX_APPLIANCES)
//   --max-clients=<n>          Per-appliance phone cap, default 8
//                              (SKOTIQ_RELAY_MAX_CLIENTS)
//   --quiet                    Suppress per-connection logging

import 'dart:async';
import 'dart:io';

import 'package:skotiq_relay/skotiq_relay.dart';

void main(List<String> args) async {
  String? stringOpt(String flag, String env) {
    for (final arg in args) {
      if (arg.startsWith('--$flag=')) {
        final value = arg.substring(flag.length + 3).trim();
        if (value.isNotEmpty) return value;
      }
    }
    final fromEnv = Platform.environment[env]?.trim();
    return (fromEnv == null || fromEnv.isEmpty) ? null : fromEnv;
  }

  int intOpt(String flag, String env, int fallback) {
    final raw = stringOpt(flag, env);
    if (raw == null) return fallback;
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      stderr.writeln('Invalid --$flag value: "$raw"');
      exit(2);
    }
    return parsed;
  }

  final quiet = args.contains('--quiet');
  final tlsCert = stringOpt('tls-cert', 'SKOTIQ_RELAY_TLS_CERT');
  final tlsKey = stringOpt('tls-key', 'SKOTIQ_RELAY_TLS_KEY');
  if ((tlsCert == null) != (tlsKey == null)) {
    stderr.writeln('--tls-cert and --tls-key must be supplied together.');
    exit(2);
  }

  final bind = stringOpt('bind', 'SKOTIQ_RELAY_BIND');
  final config = RelayServerConfig(
    port: intOpt('port', 'SKOTIQ_RELAY_PORT', 9777),
    bindAddress: bind == null ? null : InternetAddress(bind),
    stateFilePath:
        stringOpt('state-file', 'SKOTIQ_RELAY_STATE_FILE') ??
        'relay_state.json',
    tlsCertificatePath: tlsCert,
    tlsPrivateKeyPath: tlsKey,
    maxAppliances: intOpt(
      'max-appliances',
      'SKOTIQ_RELAY_MAX_APPLIANCES',
      50,
    ),
    maxClientsPerAppliance: intOpt(
      'max-clients',
      'SKOTIQ_RELAY_MAX_CLIENTS',
      8,
    ),
  );

  final server = RelayServer(
    config,
    onLog: quiet ? null : (message) => stdout.writeln('[relay] $message'),
  );

  try {
    await server.start();
  } catch (e) {
    stderr.writeln('Failed to start relay: $e');
    exit(1);
  }

  final scheme = tlsCert != null ? 'wss' : 'ws';
  stdout.writeln('Skotiq relay running.');
  stdout.writeln(
    '  Appliance uplink : $scheme://<this-host>:${server.port}/uplink',
  );
  stdout.writeln(
    '  Phone connect    : $scheme://<this-host>:${server.port}/connect/<appliance-id>',
  );
  stdout.writeln(
    '  Health check     : http${tlsCert != null ? 's' : ''}://<this-host>:${server.port}/healthz',
  );
  stdout.writeln('  State file       : ${config.stateFilePath}');

  Future<void> shutdown(String reason) async {
    stdout.writeln('$reason — shutting down.');
    await server.stop();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => unawaited(shutdown('SIGINT')));
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => unawaited(shutdown('SIGTERM')));
  }
}
