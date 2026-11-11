import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
// Why still imported: UpdatePushDiscovery (LAN update-push responder) lives in
// skotiq_remote_protocol/discovery.dart. The package carries no server of
// its own; only the discovery primitives are used here.
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:path/path.dart' as path;

import 'host/host_server.dart';
import 'secret_file.dart';

const String _logSource = 'DesktopBootstrap';

/// Take up the Darkroom's durable background work: arm the delivery retry
/// sweep for the life of the process, then catch up the dawn jobs a crash left
/// queued and the delivery rows whose retry came due while the process was
/// down.
///
/// Shared by the GUI bootstrap and the headless daemon because the two have the
/// same obligation — the job rows and the journal rows outlive the process that
/// wrote them, so whichever mode starts next owes them a pass.
///
/// **The sweep belongs to delivery, not to remote access.** It used to be armed
/// inside [HeadlessApiServer]'s start, which a desktop GUI only reaches when
/// `web_server_enabled` is on — and that setting is off on a fresh install. So
/// a GUI with remote access off had no periodic sweep at all, while a stopped
/// dawn pass told the operator in as many words that "the retry sweep resumes
/// them": measured against the release bundle, a destination that came back 28
/// seconds after the startup pass failed still had nothing written to it four
/// minutes past the row's due time, and the rows only moved on the next launch.
/// Arming it here makes that sentence true in every mode that owns the journal,
/// and [DeliveryRetrySweeper.start] is idempotent, so the daemon — which runs
/// this seam and the API server both — still arms exactly one timer.
///
/// **Armed before the catch-up, not after.** The catch-up is network-bound and
/// can sit for minutes on a host that is still asleep; the ladder for every
/// other row must not wait behind it.
///
/// **Fire-and-forget by construction.** Both catch-up passes are long and
/// network-bound (an SFTP upload of a full linear master over a domestic
/// uplink), and neither is a precondition for anything else in the bootstrap.
/// Awaiting either here would hold the "running" banner behind an overnight
/// retry to a host that is still asleep.
///
/// **Order is load-bearing.** A drained job hands its artifacts to delivery,
/// which writes the journal rows the sweep then reads; sweeping first would
/// leave anything the drain produced for the periodic sweeper's first tick.
void resumeDarkroomWork({
  required ProviderContainer container,
  required LoggingService logger,
  required String logSource,
}) {
  container.read(deliveryRetrySweeperProvider).start();
  unawaited(_resumeDarkroomWork(container, logger, logSource));
}

Future<void> _resumeDarkroomWork(
  ProviderContainer container,
  LoggingService logger,
  String logSource,
) async {
  try {
    final outcomes = await container
        .read(dawnAutopilotServiceProvider)
        .drainQueue();
    if (outcomes.isNotEmpty) {
      logger.info(
        'Resumed ${outcomes.length} queued Darkroom '
        'job${outcomes.length == 1 ? '' : 's'} left by a previous run',
        source: logSource,
        fields: {
          'done': outcomes.where((o) => o.succeeded).length,
          'jobs': outcomes.map((o) => o.jobId).join(','),
        },
      );
    }
  } catch (e, st) {
    logger.error(
      'The queued Darkroom jobs could not be drained at startup: $e\n$st',
      source: logSource,
    );
  }

  try {
    final report = await container
        .read(deliveryRetrySweeperProvider)
        .sweepOnce();
    if (report != null && report.destinations.isNotEmpty) {
      logger.info(
        'Darkroom delivery catch-up sweep: ${report.summary}',
        source: logSource,
      );
    }
  } catch (e, st) {
    logger.error(
      'The Darkroom delivery retry sweep could not run at startup: $e\n$st',
      source: logSource,
    );
  }
}

/// The remote-access settings this run applies. `--serve` turns the server
/// on for this run only: the stored setting, which every later plain launch
/// reads, is left as the user set it.
AppSettingsState effectiveRemoteAccessSettings(
  AppSettingsState settings, {
  required bool forceServe,
}) => forceServe && !settings.webServerEnabled
    ? settings.copyWith(webServerEnabled: true)
    : settings;

/// The GUI host's remote access server, which follows the Remote Access
/// settings: it starts, stops and restarts as the operator changes the switch
/// or the port. Restarts are queued so a quick run of edits cannot leave two
/// servers racing for one port.
///
/// The server itself, and everything that hangs off it, is started by
/// [startHostServer], the same as on the daemon.
class GuiRemoteAccess {
  GuiRemoteAccess({
    required this.container,
    required this.logger,
    required this.launchArgs,
    required this.forceServe,
  });

  final ProviderContainer container;
  final LoggingService logger;
  final List<String> launchArgs;
  final bool forceServe;

  RunningHostServer? _running;
  StreamSubscription<dynamic>? _collaborationSubscription;

  /// Feeds [WebServerState.connectedClients] from the server's socket
  /// registry. Separate from [_collaborationSubscription] because the two
  /// count different things: co-imaging participants versus every attached
  /// remote client.
  StreamSubscription<int>? _connectedClientSubscription;
  ProviderSubscription<AsyncValue<AppSettingsState>>? _settingsSubscription;

  String? _persistentToken;
  AppSettingsState? _lastApplied;
  AppSettingsState? _queuedSettings;
  bool _isApplying = false;

  /// Starts following the settings. Returns once the listener is in place;
  /// the server comes up in the background.
  Future<void> start() async {
    _persistentToken = await _getOrCreateRemoteAccessToken(logger);
    _settingsSubscription = container.listen<AsyncValue<AppSettingsState>>(
      appSettingsProvider,
      (_, next) {
        final stored = next.valueOrNull;
        if (stored == null) return;
        final settings = effectiveRemoteAccessSettings(
          stored,
          forceServe: forceServe,
        );
        final last = _lastApplied;
        if (last != null &&
            last.webServerEnabled == settings.webServerEnabled &&
            last.webServerPort == settings.webServerPort) {
          return;
        }
        _lastApplied = settings;
        unawaited(_schedule(settings));
      },
      fireImmediately: true,
    );
    logger.info(
      'Desktop GUI remote access is authenticated for non-local clients',
      source: _logSource,
    );
  }

  /// Stops following the settings and stops the server.
  Future<void> stop() async {
    _settingsSubscription?.close();
    _settingsSubscription = null;
    final last = _lastApplied;
    if (last != null) await _stop(last);
  }

  Future<void> _schedule(AppSettingsState settings) async {
    _queuedSettings = settings;
    if (_isApplying) return;

    _isApplying = true;
    try {
      while (_queuedSettings != null) {
        final next = _queuedSettings!;
        _queuedSettings = null;
        await _apply(next);
      }
    } finally {
      _isApplying = false;
    }
  }

  Future<void> _stop(AppSettingsState settings, {String error = ''}) async {
    await _collaborationSubscription?.cancel();
    _collaborationSubscription = null;

    await _connectedClientSubscription?.cancel();
    _connectedClientSubscription = null;

    final running = _running;
    _running = null;
    await running?.stop(logger, _logSource);

    container
        .read(webServerStateProvider.notifier)
        .setStopped(
          configuredPort: settings.webServerPort,
          actualPort: settings.webServerPort,
          bindLocalOnly: false,
          requiresAuthentication: true,
          dashboardAvailable: true,
          lastError: error,
        );
  }

  Future<void> _apply(AppSettingsState settings) async {
    await _stop(settings);

    if (!settings.webServerEnabled) {
      logger.info('Remote access is disabled in settings', source: _logSource);
      return;
    }

    final RunningHostServer running;
    try {
      running = await startHostServer(
        container: container,
        logger: logger,
        logSource: _logSource,
        config: HostServerConfig(
          port: settings.webServerPort,
          hostMode: SkotiqHostMode.gui,
          // Turning Remote Access on is the operator opting in to the LAN;
          // pairing and scoped tokens still gate every write.
          bindLocalOnly: false,
          showApiCapturesInPreview: true,
          authToken: _persistentToken,
          requireAuth: true,
          relayArgs: launchArgs,
        ),
      );
    } catch (e) {
      logger.error(
        'Remote access failed to start',
        source: _logSource,
        fields: {'error': '$e'},
      );
      await _stop(settings, error: 'Remote access failed to start: $e');
      return;
    }
    _running = running;
    final server = running.server;

    container
        .read(webServerStateProvider.notifier)
        .setRunning(
          isRunning: true,
          actualPort: server.actualPort,
          configuredPort: settings.webServerPort,
          bindLocalOnly: false,
          requiresAuthentication: true,
          dashboardAvailable: true,
          serverFingerprint: computeServerFingerprint(_persistentToken!),
        );

    _collaborationSubscription = server.collaborationManager.stream.listen((
      collabState,
    ) {
      container
          .read(webServerStateProvider.notifier)
          .setActiveViewers(collabState.viewers.length);
    });

    // "Is anyone connected?" is answered by the socket registry, not by the
    // co-imaging viewer list — a paired phone streaming /events all night
    // never joins a collaboration session.
    _connectedClientSubscription = server.connectedClientCountStream.listen((
      count,
    ) {
      container
          .read(webServerStateProvider.notifier)
          .setConnectedClients(count);
    });
    container
        .read(webServerStateProvider.notifier)
        .setConnectedClients(server.connectedClientCount);
  }
}

/// Initialise the global catalog manager. Failures are non-fatal — the rest
/// of the GUI can still operate without local catalog data — but they are
/// logged as errors so the operator knows why catalog-backed UI is empty.
Future<void> initialiseCatalogManager(LoggingService logger) async {
  try {
    final appDataDir = await resolveSkotiqDataDirectory();
    final catalogDir = path.join(appDataDir.path, 'catalogs');
    await CatalogManager.instance.initialize(catalogDir);
    logger.info('Catalog manager initialized', source: _logSource);
  } catch (e) {
    logger.error(
      'Failed to initialize catalog manager',
      source: _logSource,
      fields: {'error': '$e'},
    );
  }
}

/// Resolve the "start minimized" setting by reading directly from the
/// settings DAO before any Riverpod-listening widget exists. Errors here
/// degrade to "do not minimise" because the alternative is a hidden window
/// with no way to surface it.
Future<bool> shouldStartMinimized(ProviderContainer container) async {
  final logger = container.read(loggingServiceProvider);
  try {
    final dao = container.read(settingsDaoProvider);
    final value = await dao.getSetting('start_minimized');
    return value == 'true';
  } catch (e) {
    logger.warning(
      'Failed to read start_minimized setting; defaulting to false',
      source: _logSource,
      fields: {'error': '$e'},
    );
    return false;
  }
}

/// Load or generate the persistent bearer token used by the embedded API
/// server in GUI mode. Why persist on disk: rotating the token on every app
/// launch would force every paired mobile/dashboard client to re-pair through
/// the 6-digit pairing flow. The token is stored under the platform
/// application-support directory and written owner-only (0600) — the directory
/// itself is per-user-private on Windows and macOS but is created 0755 on
/// Linux, so the file mode, not the directory, is what keeps another local
/// account out.
Future<String> _getOrCreateRemoteAccessToken(LoggingService logger) async {
  final appData = await resolveSkotiqDataDirectory();
  final tokenFile = File(path.join(appData.path, 'remote_access_token.txt'));

  if (await tokenFile.exists()) {
    final existing = (await tokenFile.readAsString()).trim();
    if (existing.isNotEmpty) {
      // Repair a file an older build created world-readable.
      await restrictSecretFile(tokenFile);
      return existing;
    }
  }

  // 32 bytes of cryptographically random hex; matches the entropy that
  // HeadlessApiServer.requireAuth uses internally when no token is supplied.
  final rng = Random.secure();
  final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
  final token = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  await writeSecretFile(tokenFile, token);
  logger.info(
    'Generated new remote-access bearer token. Pair via the dashboard or '
    'copy the token from this file to configure mobile/CLI clients.',
    source: _logSource,
    fields: {'token_path': tokenFile.path},
  );
  return token;
}
