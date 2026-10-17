import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_updater/skotiq_updater.dart';
// Why still imported: UpdatePushDiscovery (LAN update-push responder) lives in
// skotiq_remote_protocol/discovery.dart. The package carries no server of
// its own; only the discovery primitives are used here.
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:path/path.dart' as path;

import 'headless_api/update_wiring.dart';
import 'headless_api_server.dart';
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

/// Start the host-owned background services this GUI is responsible for: the
/// Darkroom's durable work, and the embedded server for mobile/remote access.
///
/// Why the remote half delegates to [HeadlessApiServer]: the GUI and headless
/// mode serve mobile/web clients from ONE server, so a client sees the same
/// endpoint set whichever mode is running. The GUI gets the modular handlers,
/// pairing flow, scoped tokens, and middleware stack for free.
///
/// The Darkroom half is started here rather than inside [_runBackgroundServices]
/// so that it is reached before that function's first `await`. Everything in
/// there is remote-access plumbing — a token file, a UDP receiver bind — and a
/// rig whose delivery journal is owed a sweep is owed it whether or not any of
/// that plumbing answers.
void startBackgroundServices(
  ProviderContainer container, {
  required String appVersion,
  required int appBuildNumber,
}) {
  resumeDarkroomWork(
    container: container,
    logger: container.read(loggingServiceProvider),
    logSource: _logSource,
  );
  Future.microtask(
    () => _runBackgroundServices(
      container,
      appVersion: appVersion,
      appBuildNumber: appBuildNumber,
    ),
  );
}

Future<void> _runBackgroundServices(
  ProviderContainer container, {
  required String appVersion,
  required int appBuildNumber,
}) async {
  final logger = container.read(loggingServiceProvider);
  final persistentToken = await _getOrCreateRemoteAccessToken(logger);

  final apiLifecycle = _ApiServerLifecycle(
    container: container,
    logger: logger,
    persistentToken: persistentToken,
    appVersion: appVersion,
    appBuildNumber: appBuildNumber,
  );

  try {
    AppSettingsState? lastAppliedSettings;
    container.listen<AsyncValue<AppSettingsState>>(appSettingsProvider, (
      _,
      next,
    ) {
      final settings = next.valueOrNull;
      if (settings == null) {
        return;
      }

      final shouldRestart =
          lastAppliedSettings == null ||
          lastAppliedSettings!.webServerEnabled != settings.webServerEnabled ||
          lastAppliedSettings!.webServerPort != settings.webServerPort;

      if (!shouldRestart) {
        return;
      }

      lastAppliedSettings = settings;
      unawaited(apiLifecycle.scheduleUpdate(settings));
    }, fireImmediately: true);

    await _startLanPushReceiver(
      logger: logger,
      appVersion: appVersion,
      appBuildNumber: appBuildNumber,
    );

    // Eager-init: the focuser temperature compensation controller listens
    // to FocuserState updates and AppSettings changes. It must exist before
    // the focuser connects, otherwise the first temperature reading is
    // missed and the baseline never captures.
    container.read(focuserTempCompensationProvider);

    // DEV-P3-1: install the capability-refresh-on-connect listener so the
    // UI sees fresh capability data after the next device reconnect. Must
    // attach before the first connect transition or we miss the edge.
    container.read(capabilityRefreshOnConnectProvider);

    // C8: install the camera-preset seed-on-connect listener so the factory
    // unity_gain preset is seeded from the camera's CameraRecommendedSettings
    // the first time a camera connects. Like the capability-refresh listener
    // above, this Provider<void> only attaches its ref.listen side effect when
    // something reads it — so it MUST be eager-initialised here, before the
    // first connect transition, or the seeding never fires. Camera connection
    // is a host-side (FfiBackend) concern; the mobile companion mirrors host
    // state over NetworkBackend and never connects a camera locally, so this
    // wiring lives only in the desktop bootstrap.
    container.read(cameraPresetsSeedOnConnectProvider);

    // Architecture-unification, Subsystem 3: eager-mount the
    // NotificationRouter. It is the single producer for ALL notification
    // transports (in-app, mobile push, plus the external ones — Discord,
    // email, Telegram, Pushover, MQTT, webhook). Reading it here attaches its
    // backend event-stream subscription at app start, so those transports
    // fire for any routed event even when no sequence is running (e.g. a
    // weather-unsafe abort or equipment disconnect during idle). Without this
    // eager read the router only existed once a UI surface that depends on it
    // was built, so at-idle external alerts were silently dead.
    container.read(notificationRouterProvider);

    // v4 couch-grade remote: eager-mount the Home Assistant discovery
    // service. Like the router above, it is a background MQTT publisher
    // with no UI surface, so it must be read at startup to run. It is a
    // no-op until the user enables discovery in Settings.
    container.read(homeAssistantDiscoveryProvider);
  } catch (e) {
    logger.error(
      'Background services failed to initialise',
      source: _logSource,
      fields: {'error': '$e'},
    );
  }

  logger.info(
    'Desktop GUI remote access is authenticated for non-local clients',
    source: _logSource,
  );
}

/// Owns the lifecycle of the embedded [HeadlessApiServer] for the desktop GUI.
/// Restarts in response to settings changes are queued so a rapid sequence of
/// edits cannot leave two server instances racing on the same port.
class _ApiServerLifecycle {
  final ProviderContainer container;
  final LoggingService logger;
  final String persistentToken;
  final String appVersion;
  final int appBuildNumber;

  HeadlessApiServer? _apiServer;
  DiscoveryBroadcaster? _discoveryBroadcaster;
  MdnsServiceRegistration? _mdnsRegistration;
  StreamSubscription<dynamic>? _collaborationSubscription;

  /// Feeds [WebServerState.connectedClients] from the server's socket
  /// registry. Separate from [_collaborationSubscription] because the two
  /// count different things: co-imaging participants versus every attached
  /// remote client.
  StreamSubscription<int>? _connectedClientSubscription;

  AppSettingsState? _queuedSettings;
  bool _isApplying = false;

  /// the OTA update controller wired into the API server. Owned
  /// here so it gets torn down whenever the server is stopped (e.g. the
  /// operator toggles remote access off in settings).
  UpdateController? _updateController;

  _ApiServerLifecycle({
    required this.container,
    required this.logger,
    required this.persistentToken,
    required this.appVersion,
    required this.appBuildNumber,
  });

  Future<void> scheduleUpdate(AppSettingsState settings) async {
    _queuedSettings = settings;
    if (_isApplying) {
      return;
    }

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

    _discoveryBroadcaster?.stop();
    _discoveryBroadcaster = null;

    // mDNS unregister before the HTTP socket closes so dialing clients see
    // the service vanish rather than getting refused connections to a port
    // we're about to free.
    final mdns = _mdnsRegistration;
    _mdnsRegistration = null;
    if (mdns != null) {
      await mdns.stop();
    }

    final running = _apiServer;
    _apiServer = null;
    if (running != null) {
      // detach the update controller BEFORE stopping the server so
      // the controller's event subscription is cancelled cleanly. The
      // controller itself is disposed below.
      running.setUpdateController(null);
      await running.stop();
    }

    final updateController = _updateController;
    _updateController = null;
    if (updateController != null) {
      await updateController.dispose();
    }

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

    final nextServer = HeadlessApiServer(
      port: settings.webServerPort,
      container: container,
      // GUI mode is always LAN-accessible (the operator opted in via the
      // remote access toggle); pairing/scoped tokens still gate writes.
      bindLocalOnly: false,
      authToken: persistentToken,
      requireAuth: true,
    );

    try {
      logger.info(
        'Starting authenticated desktop remote access server',
        source: _logSource,
      );
      await nextServer.start();
      _apiServer = nextServer;
      logger.info(
        'Remote access started',
        source: _logSource,
        fields: {'port': nextServer.actualPort},
      );

      container
          .read(webServerStateProvider.notifier)
          .setRunning(
            isRunning: true,
            actualPort: nextServer.actualPort,
            configuredPort: settings.webServerPort,
            bindLocalOnly: false,
            requiresAuthentication: true,
            dashboardAvailable: true,
            serverFingerprint: computeServerFingerprint(persistentToken),
          );

      try {
        final appVersion = container.read(appVersionProvider).version;
        _discoveryBroadcaster = await SkotiqDiscovery.startBroadcasting(
          webPort: nextServer.actualPort,
          signalingPort: nextServer.actualPort,
          name: 'Skotiq',
          version: appVersion,
          scheme: nextServer.isTlsActive ? 'https' : 'http',
          fingerprint: nextServer.serverFingerprint,
          authRequired: true,
          authenticationMode: 'token',
          pairingSupported: true,
        );
        logger.info(
          'UDP discovery broadcasting on port 45679 (HTTP ${nextServer.actualPort})',
          source: _logSource,
        );
      } catch (e) {
        logger.warning(
          'UDP discovery broadcaster failed to start',
          source: _logSource,
          fields: {'error': '$e'},
        );
      }

      // mDNS / Bonjour advertisement. Additive to UDP broadcast above —
      // most modern Wi-Fi APs block client-to-client broadcast, and Tailscale
      // / VPN segments have no broadcast domain at all. Register
      // `_skotiq._tcp` so phones discover the GUI server in those
      // topologies without needing the QR or manual entry.
      try {
        final appVersion = container.read(appVersionProvider).version;
        final txt = <String, String>{
          'version': appVersion,
          'scheme': nextServer.isTlsActive ? 'https' : 'http',
          'fingerprint': nextServer.serverFingerprint,
          'pairingSupported': 'true',
          'name': 'Skotiq',
        };
        final registration = MdnsServiceRegistration(
          name: 'Skotiq',
          port: nextServer.actualPort,
          txt: txt,
          onWarning: (msg) => logger.warning(msg, source: _logSource),
        );
        await registration.start();
        _mdnsRegistration = registration;
        if (registration.isRegistered) {
          logger.info(
            'mDNS advertisement active',
            source: _logSource,
            fields: {
              'service': '_skotiq._tcp',
              'port': nextServer.actualPort,
              'scheme': txt['scheme']!,
              'fingerprint': nextServer.serverFingerprint,
            },
          );
        }
      } catch (e) {
        logger.warning(
          'mDNS registration failed unexpectedly',
          source: _logSource,
          fields: {'error': '$e'},
        );
      }

      _collaborationSubscription = nextServer.collaborationManager.stream
          .listen((collabState) {
            container
                .read(webServerStateProvider.notifier)
                .setActiveViewers(collabState.viewers.length);
          });

      // "Is anyone connected?" is answered by the socket registry, not by the
      // co-imaging viewer list — a paired phone streaming /events all night
      // never joins a collaboration session.
      _connectedClientSubscription = nextServer.connectedClientCountStream
          .listen((count) {
            container
                .read(webServerStateProvider.notifier)
                .setConnectedClients(count);
          });
      container
          .read(webServerStateProvider.notifier)
          .setConnectedClients(nextServer.connectedClientCount);

      try {
        final pushService = container.read(pushNotificationServiceProvider);
        nextServer.setPushNotificationStream(
          pushService.notifications.map(
            (notification) => notification.toJson(),
          ),
        );
        logger.info(
          'Push notifications wired to web server',
          source: _logSource,
        );
      } catch (e) {
        logger.warning(
          'Push notification setup failed',
          source: _logSource,
          fields: {'error': '$e'},
        );
      }

      // provision the OTA update controller and bind it to the
      // server so paired phones can drive `/api/system/update/*`. The
      // controller wraps the same UpdateService that the GUI's update
      // manager widget uses; in GUI mode the LAN push receiver (started
      // separately via _startLanPushReceiver) feeds the GUI's
      // UpdateNotifier, so both transports remain functional.
      try {
        final stack = await provisionUpdateStack(
          currentVersion: appVersion,
          currentBuildNumber: appBuildNumber,
          logger: logger,
          logSource: _logSource,
          applySafetyCheck: () =>
              defaultUpdateApplySafetyCheckWithReader(container.read),
        );
        if (stack != null) {
          _updateController = stack.controller;
          nextServer.setUpdateController(stack.controller);
          logger.info(
            'OTA update endpoints wired to web server',
            source: _logSource,
            fields: {
              'channel': stack.controller.channel,
              'updateSource': stack.controller.updateSourceLabel,
            },
          );
        }
      } catch (e, st) {
        logger.warning(
          'OTA update endpoint wiring failed; /api/system/update/* '
          'will be unavailable for this session',
          source: _logSource,
          fields: {'error': '$e', 'stack': '$st'},
        );
      }

      // LAN UDP push broadcaster. GUI mode is always LAN-exposed
      // (the operator opted in via Remote access), so we always wire the
      // broadcaster here. The fingerprint we hand to it is the same one
      // computed by the server for /api/info — paired phones already
      // hold this string from the enrollment QR/handshake.
      try {
        final pushBroadcaster = LanPushBroadcaster(
          serverFingerprint: nextServer.serverFingerprint,
          logger: (level, message, {fields}) {
            switch (level) {
              case LanPushLogLevel.info:
                logger.info(message, source: _logSource, fields: fields);
                break;
              case LanPushLogLevel.warning:
                logger.warning(message, source: _logSource, fields: fields);
                break;
              case LanPushLogLevel.error:
                logger.error(message, source: _logSource, fields: fields);
                break;
            }
          },
        );
        nextServer.setLanPushBroadcaster(pushBroadcaster);
        await pushBroadcaster.start();
        logger.info(
          'LAN push broadcaster started',
          source: _logSource,
          fields: {
            'port': pushBroadcaster.port,
            'interfaces': pushBroadcaster.activeSinkCount,
          },
        );
      } catch (e) {
        logger.warning(
          'LAN push broadcaster failed to start',
          source: _logSource,
          fields: {'error': '$e'},
        );
      }

      // Phase D — wire cellular (FCM/APNs) remote push delivery. Reads
      // push_config.json from the app-support dir (or SKOTIQ_PUSH_CONFIG):
      // the real FCM/APNs senders activate when the operator has supplied a
      // service-account JSON / .p8 key. Missing cloud credentials leave
      // cellular delivery disabled; mock would-send delivery is available only
      // through an explicit `mock:true` development configuration.
      try {
        final appSupportDir = await resolveSkotiqDataDirectory();
        final delivery = await nextServer.wireRemotePushDelivery(
          appSupportDir: appSupportDir.path,
          log: (message) => logger.info(message, source: _logSource),
        );
        logger.info(
          delivery is MockRemotePushDelivery
              ? 'Cellular push delivery wired (mock — no cloud credentials)'
              : delivery == null
              ? 'Cellular push delivery not wired (no channel configured)'
              : 'Cellular push delivery wired (cloud channel configured)',
          source: _logSource,
        );
      } catch (e) {
        logger.warning(
          'Cellular push delivery failed to wire',
          source: _logSource,
          fields: {'error': '$e'},
        );
      }
    } catch (e) {
      logger.error(
        'Remote access failed to start',
        source: _logSource,
        fields: {'error': '$e'},
      );
      await nextServer.stop();
      await _stop(settings, error: 'Remote access failed to start: $e');
    }
  }
}

Future<void> _startLanPushReceiver({
  required LoggingService logger,
  required String appVersion,
  required int appBuildNumber,
}) async {
  try {
    var isReceivingLanPush = false;
    final pushSecret = await _getOrCreatePushSecret(logger);
    final lanPushReceiver = LanPushReceiver(
      currentVersion: appVersion,
      currentBuildNumber: appBuildNumber,
      pushSecret: pushSecret,
    );
    lanPushReceiver.onUpdateReceived = (manifest, stagingPath) {
      isReceivingLanPush = false;
      logger.info(
        'Update received via LAN push',
        source: _logSource,
        fields: {'version': manifest.version},
      );
      LanPushNotifier.notifyUpdateReceived(manifest, stagingPath);
    };
    lanPushReceiver.onProgress = (received, total, progress, message) {
      isReceivingLanPush = total > 0 && received < total;
      logger.debug(
        'LAN push progress',
        source: _logSource,
        fields: {
          'progress_pct': (progress * 100).toStringAsFixed(1),
          'received': received,
          'total': total,
          'message': message,
        },
      );
      LanPushNotifier.notifyProgress(received, total, progress, message);
    };
    lanPushReceiver.onError = (error) {
      isReceivingLanPush = false;
      logger.error(
        'LAN push error',
        source: _logSource,
        fields: {'error': error},
      );
      LanPushNotifier.notifyError(error);
    };
    await lanPushReceiver.startServer();
    logger.info('LAN push receiver started on port 45680', source: _logSource);

    await UpdatePushDiscovery.startResponding(
      name: 'Skotiq',
      version: appVersion,
      buildNumber: appBuildNumber,
      isReceivingCallback: () => isReceivingLanPush,
    );
    logger.info('Update push discovery responder started', source: _logSource);
  } catch (e) {
    final message = '$e';
    if (message.contains('no trusted public key compiled in')) {
      // Unsigned local/development builds deliberately disable LAN updates.
      // This is an expected capability state, not an operational failure.
      logger.info(
        'LAN push receiver disabled for this unsigned build',
        source: _logSource,
      );
    } else {
      logger.warning(
        'LAN push receiver failed',
        source: _logSource,
        fields: {'error': message},
      );
    }
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
    logger.info('Catalog manager initialised', source: _logSource);
  } catch (e) {
    logger.error(
      'Failed to initialise catalog manager',
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

/// Load or generate the LAN push authentication secret. Persisted in the app
/// data directory so it survives restarts. The same secret must be configured
/// on the push tool (dev machine) to authenticate.
///
/// the implementation moved to `headless_api/update_wiring.dart` so
/// the headless daemon can reuse it. This wrapper preserves the original
/// call sites in this file.
Future<String> _getOrCreatePushSecret(LoggingService logger) {
  return getOrCreatePushSecret(logger, logSource: _logSource);
}
