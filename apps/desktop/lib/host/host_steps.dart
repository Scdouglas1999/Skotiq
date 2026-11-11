import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/skotiq_app.dart';
import 'package:skotiq_app/startup/always_on_services.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_updater/skotiq_updater.dart';

import '../desktop_app_bootstrap.dart';
import '../headless/headless_disk_watchdog_bootstrap.dart';
import '../headless/host_checkpoint_directory.dart';
import '../headless_api/handlers/pairing_handlers.dart'
    show operatorPairingCodePath;
import '../headless_api/update_wiring.dart';
import 'host_auto_connect.dart';
import 'host_server.dart';
import 'host_startup.dart';

const _gui = HostKind.gui;
const _daemon = HostKind.daemon;
const _core = HostStartupPhase.core;
const _services = HostStartupPhase.services;

/// How a process that owns the hardware starts, GUI and daemon alike.
///
/// The two used to be written separately and had drifted apart: each had
/// services the other silently lacked. A step runs on both unless it names
/// the one host it is for and says why.
final List<HostStartupStep> hostStartupSteps = [
  HostStartupStep(
    name: 'local backend',
    phase: _core,
    run: (host) async {
      final ready = host.container
          .read(backendProvider.notifier)
          .useLocalBackend();
      host.backendReady = ready;
      // The steps that need the backend wait on [HostStartup.backendReady]
      // and report its failure themselves.
      unawaited(ready.then((_) {}, onError: (_) {}));
    },
  ),
  HostStartupStep(
    name: 'database',
    phase: _core,
    // The daemon refuses to serve without one. The GUI goes on to its window,
    // where the database recovery notice explains what happened.
    fatalFor: {_daemon},
    run: (host) async {
      // Constructing the database opens nothing; one real query makes a
      // missing sqlite runtime or an unreadable file fail here, not as a
      // request that hangs later.
      await host.container
          .read(databaseProvider)
          .customSelect('SELECT 1')
          .getSingle();
    },
  ),
  HostStartupStep(
    name: 'interrupted-work recovery',
    phase: _core,
    needs: ['database'],
    run: _recoverInterruptedWork,
  ),
  HostStartupStep(
    name: 'plugin runtime',
    phase: _core,
    needs: ['database'],
    // Plugin sequence nodes run on the host, so the bundled plugins are
    // registered before anything can start a sequence.
    run: (host) => initializeBundledPluginRuntime(host.container),
  ),
  HostStartupStep(
    name: 'catalog manager',
    phase: _core,
    run: (host) => initialiseCatalogManager(host.logger),
  ),
  HostStartupStep(
    name: 'sequencer checkpoints',
    phase: _core,
    only: _daemon,
    because:
        'the GUI keeps its checkpoints beside the database it opened and '
        'adopts an older location, which its shell does when it looks for an '
        'interrupted run; the daemon uses the data directory',
    fatalFor: {_daemon},
    run: (host) async {
      final checkpointDir = await resolveHostCheckpointDirectory();
      await host.container
          .read(sequenceExecutorProvider)
          .initializeCheckpoints(checkpointDir.path);
    },
  ),

  HostStartupStep(
    name: 'open plan',
    phase: _core,
    only: _daemon,
    because:
        "the GUI's shell puts the plan back after its checkpoint prompt, "
        'which may load the interrupted run instead; a daemon raises no prompt',
    needs: ['database', 'sequencer checkpoints'],
    run: (host) async {
      final restored = await restoreOpenPlan(host.container.read);
      if (restored != null) {
        host.logger.info(
          'Reopened the plan that was open at the last stop',
          source: host.logSource,
          fields: {'plan': restored.sequence.name, 'unsaved': restored.unsaved},
        );
      }
    },
  ),
  HostStartupStep(
    name: 'automatic backups',
    phase: _services,
    needs: ['database'],
    // The GUI must not hold its other services behind the first backup
    // settings read.
    waitedFor: {_daemon},
    run: (host) async {
      final service = await host.container.read(
        autoSaveLifecycleProvider.future,
      );
      host.onStop('auto-save service', () async => service.stop());
    },
  ),
  HostStartupStep(
    name: 'remote access server',
    phase: _services,
    needs: ['database', 'sequencer checkpoints'],
    fatalFor: {_daemon},
    run: (host) async {
      switch (host.kind) {
        case HostKind.daemon:
          await _startDaemonServer(host);
        case HostKind.gui:
          // The operator can switch Remote Access on and off, and change its
          // port, while the app runs; the server follows the settings.
          final remoteAccess = GuiRemoteAccess(
            container: host.container,
            logger: host.logger,
            launchArgs: host.args,
            forceServe: host.forceServe,
          );
          host.onStop('remote access server', remoteAccess.stop);
          await remoteAccess.start();
      }
    },
  ),
  HostStartupStep(
    name: 'always-on services',
    phase: _services,
    only: _daemon,
    because:
        'a window starts them with its widget tree (SkotiqApp), the same way '
        'for a host, a linked client and the phone app',
    needs: ['local backend'],
    run: (host) async {
      final services = startAlwaysOnServices(
        host.container,
        AppRole.hostDaemon,
      );
      host.alwaysOn = services;
      host.onStop('always-on services', () async => services.stop());
    },
  ),
  HostStartupStep(
    name: 'QHY discovery switch',
    phase: _services,
    needs: ['local backend', 'database'],
    // Before anything scans: the auto-connect below enumerates the buses, and
    // that is where a misbehaving QHY SDK hangs.
    run: _followQhyDiscoverySetting,
  ),
  HostStartupStep(
    name: 'equipment auto-connect',
    phase: _services,
    needs: ['local backend', 'remote access server'],
    // The daemon reports itself running only once its equipment has been
    // tried. A window is usable while devices connect.
    waitedFor: {_daemon},
    run: (host) => hostAutoConnect(
      container: host.container,
      logger: host.logger,
      kind: host.kind,
      backendReady: host.backendReady,
    ),
  ),
  HostStartupStep(
    name: 'update receiver',
    phase: _services,
    // A port that is slow to bind must not hold the GUI's Darkroom work.
    waitedFor: {_daemon},
    run: _startUpdateReceiver,
  ),
  HostStartupStep(
    name: 'disk-space watchdog',
    phase: _services,
    only: _daemon,
    because:
        "the GUI's sequencer controller listens to the same watchdog and "
        'pauses the run itself',
    run: (host) async {
      final guard = host.container.read(diskSpaceGuardProvider);
      host.onStop('disk guard', () async => guard.stop());
      final subscription = await startDiskSpaceWatchdog(
        container: host.container,
        guard: guard,
        logger: host.logger,
      );
      host.onStop(
        'disk watchdog subscription',
        () async => subscription?.cancel(),
      );
    },
  ),
  HostStartupStep(
    name: 'Darkroom work',
    phase: _services,
    needs: ['database'],
    run: (host) async {
      // Registered last so it is the first thing undone, while the database
      // is still up: a pass left `running` by an orderly stop is read at the
      // next open as a dead process and charged one of its three starts.
      host.onStop(
        'Darkroom pass hand-back',
        () => host.container
            .read(dawnAutopilotServiceProvider)
            .releaseRunningJobsForShutdown(),
      );
      resumeDarkroomWork(
        container: host.container,
        logger: host.logger,
        logSource: host.logSource,
      );
    },
  ),
  HostStartupStep(
    name: 'device discovery at launch',
    phase: _services,
    only: _gui,
    because:
        "it fills this window's Equipment screen; a daemon's clients scan "
        'through the API when they open theirs',
    needs: ['local backend'],
    waitedFor: {},
    run: _discoverDevicesAtLaunch,
  ),
];

/// Closes the runs and sessions, re-queues the Darkroom jobs and rebuilds the
/// session statistics a dead process left behind.
///
/// Once per process, after the database is known to open and before anything
/// starts or reads a run, a session or a Darkroom job: the recovery treats
/// every row still marked live as residue, so a later call would close this
/// process's own work. A linked client owns no runs and does not call it.
Future<void> _recoverInterruptedWork(HostStartup host) =>
    recoverFromPreviousProcessExit(host.container.read(databaseProvider));

Future<void> _startDaemonServer(HostStartup host) async {
  final config = host.daemonConfig!;
  final running = await startHostServer(
    container: host.container,
    logger: host.logger,
    logSource: host.logSource,
    config: HostServerConfig(
      port: config.port,
      hostMode: SkotiqHostMode.headless,
      bindLocalOnly: config.bindLocalOnly,
      authToken: config.token,
      scopedAuthTokens: config.scopedTokens,
      fineGrainedAuthTokens: config.fineGrainedTokens,
      requireAuth: config.requireAuth,
      allowUnauthenticated: config.allowUnauthenticated,
      corsAllowedOrigins: config.corsAllowedOrigins,
      pairingPrintCodes: config.pairingPrintCodes,
      pairingMode: config.pairingMode,
      tlsEnabled: config.tlsEnabled,
      tlsCertPath: config.tlsCertPath,
      tlsKeyPath: config.tlsKeyPath,
      relayArgs: host.args,
    ),
  );
  host.daemonServer = running;
  // Teardown runs last-registered first.
  for (final stop in running.stopSteps.reversed) {
    host.onStop(stop.name, stop.action);
  }
  await _printConnectBanner(
    running,
    config.bindLocalOnly,
    pairingCodePath: operatorPairingCodePath(host.logger),
    pairingPrintCodes: config.pairingPrintCodes,
  );
}

/// The daemon's console is its only screen: say where to connect. The token
/// is redacted because console output is captured to files.
Future<void> _printConnectBanner(
  RunningHostServer running,
  bool bindLocalOnly, {
  required String? pairingCodePath,
  required bool pairingPrintCodes,
}) async {
  final server = running.server;
  final scheme = server.isTlsActive ? 'https' : 'http';
  final tls = running.tls;
  try {
    final localIp = bindLocalOnly ? null : await firstLanAddress();
    if (localIp != null) {
      stdout.writeln('\n  Mobile devices can connect to:');
      stdout.writeln('    $scheme://$localIp:${server.actualPort}');
      final token = server.effectiveAuthToken;
      if (token != null) {
        stdout.writeln('\n  Authentication required:');
        stdout.writeln('    Authorization: Bearer ${_redactToken(token)}');
      }
    } else {
      stdout.writeln('\n  Headless API is available on:');
      stdout.writeln('    $scheme://127.0.0.1:${server.actualPort}');
      stdout.writeln(
        '  Add --require-auth or --auth-token to expose authenticated LAN '
        'access.',
      );
    }
    if (tls != null) {
      stdout.writeln(
        '  TLS fingerprint (SPKI SHA-256): ${tls.publicKeyFingerprintSha256}',
      );
    }
    if (pairingCodePath != null) {
      // This daemon has no screen: say where the code a computer asks for
      // goes, before anyone asks.
      stdout.writeln(
        '\n  To link a computer, press Link on it. A code it asks for',
      );
      stdout.writeln('  is written to $pairingCodePath');
      stdout.writeln(
        pairingPrintCodes
            ? '  and printed here.'
            : '  (start with --pairing-print-codes to see codes here too).',
      );
    }
    if (localIp != null) {
      for (final advisory in running.securityAdvisories) {
        stdout.writeln('\n  WARNING: $advisory');
      }
    }
    stdout.writeln('');
  } catch (e) {
    stdout.writeln('  (local IP details unavailable: $e)');
  }
}

String _redactToken(String token) {
  if (token.length <= 8) return '*' * token.length;
  return '${token.substring(0, 4)}...${token.substring(token.length - 4)}';
}

/// Listens for an update pushed over the LAN and answers the pusher's
/// discovery probe, so `push_update` can find this host.
///
/// A received update goes to the process's update controller, which is what
/// the update dialog and `/api/system/update/*` both show. The receiver runs
/// with Remote Access off too. A build with no update key compiled in cannot
/// verify a push, so it neither listens nor answers.
Future<void> _startUpdateReceiver(HostStartup host) async {
  final logger = host.logger;
  final source = host.logSource;
  final controller = host.container.read(updateControllerProvider);
  final receiver = LanPushReceiver(
    currentVersion: host.appVersion.version,
    currentBuildNumber: host.appVersion.buildNumber,
    dataDirectory: resolveSkotiqDataDirectory,
    pushSecret: await getOrCreatePushSecret(logger, logSource: source),
  );
  receiver.onUpdateReceived = (manifest, stagingPath) {
    logger.info(
      'Update received via LAN push',
      source: source,
      fields: {'version': manifest.version},
    );
    controller.lanPushReceived(manifest, stagingPath);
  };
  receiver.onProgress = (received, total, progress, message) {
    logger.debug(
      'LAN push progress',
      source: source,
      fields: {
        'progress_pct': (progress * 100).toStringAsFixed(1),
        'received': received,
        'total': total,
        'message': message,
      },
    );
  };
  receiver.onError = (error) {
    logger.error('LAN push error', source: source, fields: {'error': error});
    controller.lanPushFailed(error);
  };
  try {
    await receiver.startServer();
  } catch (e) {
    if ('$e'.contains('no trusted public key compiled in')) {
      // Unsigned local/development builds deliberately disable LAN updates.
      // This is an expected capability state, not an operational failure.
      logger.info(
        'LAN push receiver disabled for this unsigned build',
        source: source,
      );
    } else {
      logger.warning(
        'LAN push receiver did not start. HTTPS pull updates remain '
        'available.',
        source: source,
        fields: {'error': '$e'},
      );
    }
    return;
  }
  host.onStop('LAN push receiver', receiver.stopServer);
  logger.info('LAN push receiver started on port 45680', source: source);
  bool isReceiving() => receiver.versionInfo['isReceiving'] == true;

  if (host.daemonConfig?.bindLocalOnly ?? false) {
    // A loopback-only daemon was asked not to announce itself on the LAN.
    return;
  }

  final responder = await UpdatePushDiscovery.startResponding(
    name: 'Skotiq',
    version: host.appVersion.version,
    buildNumber: host.appVersion.buildNumber,
    isReceivingCallback: isReceiving,
  );
  host.onStop('update push responder', () async => responder.release());
  host.logger.info(
    'Update push discovery responder started',
    source: host.logSource,
  );
}

/// Applies "Look for QHY cameras" to the native SDK layer, which forgets it
/// at every start, and again each time the setting changes, from this
/// computer or from a linked client.
Future<void> _followQhyDiscoverySetting(HostStartup host) async {
  await host.backendReady;
  Future<void> apply(bool enabled) async {
    final backend = host.container.read(backendProvider);
    if (backend is! VendorSdkBackend) return;
    await (backend as VendorSdkBackend).setQhyDiscoveryEnabled(enabled);
    if (!enabled) {
      host.logger.info(
        'QHY cameras are left out of device scans (Settings > Connection)',
        source: host.logSource,
      );
    }
  }

  final settings = await host.container.read(appSettingsProvider.future);
  await apply(settings.qhyDiscoveryEnabled);
  final subscription = host.container.listen<bool?>(
    appSettingsProvider.select((s) => s.valueOrNull?.qhyDiscoveryEnabled),
    (previous, next) {
      if (next != null && next != previous) unawaited(apply(next));
    },
  );
  host.onStop('QHY discovery switch', () async => subscription.close());
}

/// Scans for devices once the window is up, when "Discover devices on
/// launch" is on. Queued behind the first frame so the window never waits
/// for a scan.
Future<void> _discoverDevicesAtLaunch(HostStartup host) async {
  final settings = await host.container.read(appSettingsProvider.future);
  if (!settings.autoDiscoverOnLaunch) {
    host.logger.info(
      'Device discovery at launch is off in settings',
      source: host.logSource,
    );
    return;
  }
  await host.backendReady;
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  await host.container
      .read(unifiedDiscoveryProvider.notifier)
      .discoverAll(
        includeIndi: settings.indiAutoConnect,
        includeAlpaca: settings.alpacaAutoDiscover,
      );
}
