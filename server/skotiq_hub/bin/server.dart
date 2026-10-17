// The hub prints its bootstrap admin token + fingerprint to stdout once on a
// fresh database so a self-host operator has a way in. These are the only
// stdout writes in the entrypoint.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:skotiq_hub/skotiq_hub.dart';

/// Entry point for the self-hosted Constellation hub. Configuration is via flags
/// (with environment-variable fallbacks) so it drops cleanly into the Dockerfile.
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption(
      'port',
      help: 'TCP port to listen on.',
      defaultsTo: _env('SKOTIQ_HUB_PORT', '8088'),
    )
    ..addOption(
      'bind',
      help: 'Bind address.',
      defaultsTo: _env('SKOTIQ_HUB_BIND', '0.0.0.0'),
    )
    ..addOption(
      'db',
      help: 'Path to the sqlite database file.',
      defaultsTo: _env('SKOTIQ_HUB_DB', '/data/hub.db'),
    )
    ..addOption(
      'atlas-root',
      help: 'Directory for fused tile sidecars.',
      defaultsTo: _env('SKOTIQ_HUB_ATLAS_ROOT', '/data/atlas'),
    )
    ..addOption(
      'secret',
      help: 'Server secret (fingerprint + admin bootstrap derivation).',
      defaultsTo: _env('SKOTIQ_HUB_SECRET', ''),
    )
    ..addOption(
      'name',
      help: 'Human-readable hub name in /v1/info.',
      defaultsTo: _env('SKOTIQ_HUB_NAME', 'Skotiq Constellation Hub'),
    )
    ..addFlag(
      'closed-signup',
      help: 'Require an admin token to create accounts (invite-only hub).',
      defaultsTo: _env('SKOTIQ_HUB_CLOSED_SIGNUP', 'false') == 'true',
    )
    ..addFlag(
      'accepts-raw-subs',
      help:
          'Accept raw FITS subframes in addition to additive sums. Off by '
          'default — raw subs expose exact pixels/pointing and cannot be '
          'cleanly subtracted, so only enable on a hub the contributors trust.',
      defaultsTo: _env('SKOTIQ_HUB_ACCEPTS_RAW_SUBS', 'false') == 'true',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exitCode = 64;
    return;
  }
  if (args['help'] as bool) {
    print(parser.usage);
    return;
  }

  var secret = args['secret'] as String;
  if (secret.trim().isEmpty) {
    // A fresh, persistent random secret beats refusing to start: write it back
    // next to the DB so the fingerprint + admin bootstrap survive a restart.
    secret = _ensurePersistentSecret(args['db'] as String);
  } else {
    // An operator-supplied secret must be strong: it is both the fingerprint
    // seed AND the bootstrap admin password, so a guessable value (e.g. the old
    // Dockerfile "change-me") is a full hub takeover. Refuse to start rather
    // than run insecurely; the operator can omit --secret to get a strong
    // auto-generated one instead.
    final weakness = secretWeakness(secret.trim());
    if (weakness != null) {
      stderr.writeln('Refusing to start: SKOTIQ_HUB_SECRET $weakness.');
      stderr.writeln(
        'Pass a high-entropy value (e.g. SKOTIQ_HUB_SECRET="\$(openssl '
        'rand -hex 32)") or omit it to auto-generate a strong secret.',
      );
      exitCode = 78; // EX_CONFIG
      return;
    }
  }

  final config = HubConfig(
    databasePath: args['db'] as String,
    atlasRoot: args['atlas-root'] as String,
    serverSecret: secret,
    name: args['name'] as String,
    port: int.parse(args['port'] as String),
    bindAddress: args['bind'] as String,
    openSignup: !(args['closed-signup'] as bool),
    acceptsRawSubs: args['accepts-raw-subs'] as bool,
  );

  final freshDb =
      !File(config.databasePath).existsSync() &&
      config.databasePath != ':memory:';

  final server = HubServer(config);
  final bound = await server.start();
  print('Skotiq Constellation hub listening on $bound');
  print('Fingerprint: ${server.fingerprint}');
  if (freshDb) {
    print(
      'Admin bootstrap: log in with publicKey="admin:${server.fingerprint}" '
      'and password=<server secret>.',
    );
  }

  // Graceful shutdown on SIGINT/SIGTERM so the WAL is checkpointed.
  for (final signal in <ProcessSignal>[
    ProcessSignal.sigint,
    ProcessSignal.sigterm,
  ]) {
    signal.watch().listen((_) async {
      print('Shutting down...');
      await server.stop();
      server.dispose();
      exit(0);
    });
  }
}

String _env(String key, String fallback) =>
    Platform.environment[key] ?? fallback;

/// Read (or create) a persistent random secret stored beside the DB. Keeps the
/// fingerprint stable across restarts without forcing the operator to manage a
/// secret if they do not pass one.
String _ensurePersistentSecret(String dbPath) {
  if (dbPath == ':memory:') {
    return 'ephemeral-${DateTime.now().microsecondsSinceEpoch}';
  }
  final secretFile = File('$dbPath.secret');
  if (secretFile.existsSync()) {
    final existing = secretFile.readAsStringSync().trim();
    if (existing.isNotEmpty) return existing;
  }
  final generated = _generateSecret();
  secretFile.parent.createSync(recursive: true);
  secretFile.writeAsStringSync(generated, flush: true);
  return generated;
}

String _generateSecret() {
  final rng = Random.secure();
  final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
  return 'nshub-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}
