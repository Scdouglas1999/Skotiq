import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/skotiq_app.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_updater/skotiq_updater.dart';

import 'desktop_app_bootstrap.dart';
import 'desktop_logging_init.dart';
import 'headless/headless_auth_config.dart';
import 'headless/headless_auto_connect_bootstrap.dart';
import 'headless/headless_disk_watchdog_bootstrap.dart';
import 'headless/headless_discovery_bootstrap.dart';
import 'headless/headless_relay_bootstrap.dart';
import 'headless/headless_services_bootstrap.dart';
import 'headless/headless_shutdown.dart';
import 'headless_api/update_wiring.dart';
import 'headless_api_server.dart';

const _headlessLogSource = 'HeadlessMain';

/// Headless entry point for Skotiq
///
/// This entry point runs without a GUI window, suitable for:
/// - Server/daemon mode
/// - Background sequence execution
/// - Remote control via mobile app or API
///
/// Usage:
///   Windows: flutter run -d windows --target=lib/main_headless.dart
///   Linux:   flutter run -d linux --target=lib/main_headless.dart
///
///   Or build and run:
///   Windows: .\\build\\windows\\x64\\runner\\Release\\skotiq.exe --headless
///   Linux:   ./build/linux/`<arch>`/release/bundle/skotiq --headless
///
/// Authentication:
///   --auth-token=`<token>`  Set a specific authentication token
///                         (admin scope)
///   --view-token=`<token>`  Set a read-only monitoring token
///   --control-token=`<token>`
///                         Set an imaging-control token
///   --require-auth        Generate a random token
///   --allow-unauthenticated
///                         Opt into the legacy fully-open behaviour: serve EVERY
///                         endpoint without a token when none is configured.
///                         Unsafe; default is FAIL CLOSED (only the
///                         pairing/dashboard bootstrap surface is reachable until
///                         a device pairs or a token is set). A prominent warning
///                         is logged at startup when this is set.
///   --allow-unauthenticated-lan
///                         Bind to the LAN without auth. Unsafe; intended only
///                         for isolated development networks. Governs the bind
///                         interface, not authentication — pair it with
///                         --allow-unauthenticated to serve open on the LAN.
///   --cors-origin=`<origin>`
///                         Add an origin to the CORS allow-list (may be passed
///                         multiple times). Why explicit list: the dashboard's
///                         own origin is always allowed, but cross-origin
///                         control from other web apps must be opted in here.
///   --pairing-print-codes
/// Print every successful pairing code to
///                         stdout. Required for headless Pi/embedded
///                         deployments where the operator otherwise has no
///                         way to retrieve the code.
///   --tls Enable transport encryption. Generates a
///                         self-signed cert under $APPDATA/server.{crt,key}
///                         on first launch and binds HTTPS instead of HTTP.
///   --tls-cert=`<path>` Use the supplied certificate PEM instead
///                         of generating a self-signed one.
///   --tls-key=`<path>` Use the supplied private-key PEM instead
///                         of generating a self-signed one.
///   --relay-url=`<url>`     v4 couch-grade remote: dial OUT to a self-hosted
///                         Skotiq relay (ws(s)://host[:port]) so the rig
///                         is reachable from anywhere with no port-forwarding.
///                         The appliance id minted on first contact is printed
///                         to stdout/log; enter it + the relay URL in the app.
///   --relay-allow-insecure-tls
///                         Trust a self-signed relay TLS cert. Only for relays
///                         you operate yourself before getting a real cert.
///
///   Environment variables:
///   SKOTIQ_AUTH_TOKEN  Authentication token
///   SKOTIQ_VIEW_TOKEN  Optional read-only token
///   SKOTIQ_CONTROL_TOKEN
///                         Optional imaging-control token
///   SKOTIQ_SCOPED_TOKEN
///                         Fine-grained token(s). One or more
///                         `<token>=<grant-spec>` entries separated by `;`,
///                         where a grant-spec is a coarse name (`view`,
///                         `control`, `admin`) or a per-resource list such as
///                         `camera:control,mount:view`. Same effect as passing
///                         --scoped-token repeatedly. Existing coarse tokens are
///                         unchanged — a coarse token covers every resource.
///   SKOTIQ_PORT        Server port (default: 8080)
///   SKOTIQ_DATA_DIR    Native persistence root (defect maps, etc.). When
///                         unset, matches the GUI application-support path.
///   SKOTIQ_DATABASE_DIR
///                         Drift database directory. Headless systemd/Pi
///                         installs pin this under /var/lib/skotiq so the
///                         daemon does not depend on a user Documents folder.
///   SKOTIQ_BROWSE_ROOTS
///                         Semicolon-separated remote directory browse roots
///                         for headless clients, e.g.
///                         Captures=/mnt/captures;USB=/media/skotiq.
///   SKOTIQ_ALLOW_UNAUTHENTICATED=true
///                         Same as --allow-unauthenticated
///   SKOTIQ_ALLOW_UNAUTHENTICATED_LAN=true
///                         Same as --allow-unauthenticated-lan
///   SKOTIQ_TRUST_PROXY=true
///                         Believe the X-Forwarded-For / X-Real-IP headers when
///                         deriving the rate-limit / pairing-lockout key. OFF by
///                         default: in direct-bind mode those headers are client-
///                         spoofable. Set to true ONLY behind the loopback nginx
///                         reverse proxy documented in docs/remote-control.md
///                         ("TLS with nginx"); without it every proxied client
///                         shares one rate-limit/lockout bucket. Honoured only
///                         when the socket peer is loopback.
///   SKOTIQ_ALLOW_INSECURE_UPDATE_SOURCE
///                         Not an environment variable: a build-time
///                         `--dart-define` (testing builds only) that lets the
///                         OTA updater fetch over plain http. Setting it in the
///                         environment of a release build does nothing.
///   SKOTIQ_CORS_ORIGINS
///                         Comma-separated CORS allow-list (same effect as
///                         passing --cors-origin repeatedly).
///   SKOTIQ_PAIRING_PRINT_CODES=true
///                         Same as --pairing-print-codes.
///   SKOTIQ_TLS=true   Same as --tls.
///   SKOTIQ_TLS_CERT   Same as --tls-cert=`<path>`.
///   SKOTIQ_TLS_KEY    Same as --tls-key=`<path>`.
///   SKOTIQ_RELAY_URL  Same as --relay-url=`<url>`.
///   SKOTIQ_RELAY_ALLOW_INSECURE_TLS=true
///                         Same as --relay-allow-insecure-tls.
void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Operator-facing stdout banner. The LoggingService isn't bootable yet
  // (no ProviderContainer), so write directly to stdout. Once the logger
  // is initialised below, all subsequent diagnostics route through it.
  stdout.writeln('Skotiq - Headless Mode');
  stdout.writeln('==============================');

  LoggingService? logger;
  ProviderContainer? container;
  HeadlessApiServer? apiServer;
  // Push-notification stream is owned by HeadlessApiServer.stop() (it holds
  // the StreamSubscription internally and cancels it on shutdown); we keep
  // no top-level handle here.
  StreamSubscription<DiskSpaceWatchdogEvent>? diskWatchdogSubscription;
  DiskSpaceGuardService? diskGuard;
  // headless OTA update stack. Owned at the entry point so SIGINT
  // can shut both the controller and the LAN push receiver cleanly.
  UpdateStack? updateStack;
  AutoSaveService? autoSaveService;
  // v4 couch-grade remote: outbound relay uplink (optional). Owned here so
  // SIGINT/SIGTERM tear down the WebSocket cleanly. Null unless a relay URL
  // was supplied via --relay-url / SKOTIQ_RELAY_URL.
  RelayUplink? relayUplink;

  Future<void> safeRigForShutdown() async {
    final activeContainer = container;
    if (activeContainer == null) return;
    await activeContainer
        .read(safeRigServiceProvider)
        .safeTheRig(
          reason: 'Headless host is stopping',
          park: true,
          // Quitting is not a reason to move an idle mount: it parks only
          // when a run was in progress.
          idleMount: IdleMountPolicy.leave,
          closeDome: true,
          closeCover: true,
          abortExposure: true,
          disableCooling: true,
          notify: false,
        );
  }

  List<ShutdownStep> buildTeardownSteps() => [
    // First, while the container and its database are still up: hand any
    // running Darkroom pass back to the queue. A row left `running` by this
    // exit is read at the next open as a process that DIED, which re-queues it
    // and charges one of its three starts — so three ordinary restarts during
    // a dawn pass failed the night's job outright. An orderly stop is not a
    // crash, and this is where the row learns the difference.
    (
      name: 'Darkroom pass hand-back',
      action: () async {
        final activeContainer = container;
        if (activeContainer == null) return;
        await activeContainer
            .read(dawnAutopilotServiceProvider)
            .releaseRunningJobsForShutdown();
      },
    ),
    (
      name: 'disk watchdog subscription',
      action: () async => diskWatchdogSubscription?.cancel(),
    ),
    (name: 'disk guard', action: () async => diskGuard?.stop()),
    (name: 'discovery socket', action: () async => stopDiscoverySocket()),
    (name: 'mDNS advertisement', action: () async => stopMdnsAdvertisement()),
    (
      name: 'relay uplink',
      action: () async {
        await relayUplink?.stop();
        relayUplink = null;
      },
    ),
    (
      name: 'update controller detach',
      action: () async => apiServer?.setUpdateController(null),
    ),
    (name: 'API server', action: () async => apiServer?.stop()),
    (name: 'OTA update stack', action: () async => updateStack?.dispose()),
    (name: 'auto-save service', action: () async => autoSaveService?.stop()),
    (name: 'provider container', action: () async => container?.dispose()),
  ];

  try {
    final appVersion = await loadDesktopAppVersion();
    stdout.writeln('Initializing native bridge and data directories...');
    final bootPaths = await initialiseDesktopLogging();
    stdout.writeln('[OK] Native bridge initialized');
    stdout.writeln('[OK] Data directory: ${bootPaths.dataDirectory}');
    stdout.writeln('[OK] Profile and settings storage initialized');

    // Single-instance invariant. The headless service and the GUI resolve the
    // SAME default database path, so running both on one machine would put two
    // SQLite writers on one file — and the loser's SQLITE_BUSY reads as
    // corruption, quarantining the operator's real database. Refuse before any
    // service starts. Use SKOTIQ_DATABASE_DIR to give this daemon its own
    // data directory if it is genuinely meant to run alongside a GUI.
    final contended = await SingleInstanceLock.probe(
      await resolveDefaultDatabaseFile(),
    );
    if (contended != null) {
      stderr.writeln('Skotiq: ${contended.message}');
      exit(75); // EX_TEMPFAIL — retry once the other instance exits.
    }

    stdout.writeln('Initializing services...');
    container = ProviderContainer(
      overrides: [
        appVersionProvider.overrideWithValue(appVersion),
        pluginHostAppVersionOverride(appVersion.version),
        pluginNodeDispatcherOverride(),
        // even in headless mode we install the palette
        // blueprint override so an upstream UI client (mobile companion,
        // headless API consumer) sees plugin sequence nodes in the
        // palette listing.
        pluginNodePaletteBlueprintsOverride(),
        // C4 — honour the persisted plugin enable/disable choices at
        // registration time. A headless host runs the same bundled plugins
        // (Discord/Pushover/Home Assistant sequence nodes), so a plugin the
        // operator disabled must not silently re-enable when the daemon
        // restarts.
        pluginEnablementStoreOverride(),
      ],
    );
    final runtimeLogger = container.read(loggingServiceProvider);
    logger = runtimeLogger;
    await runtimeLogger.initialize();

    // A daemon has no Integrations settings screen to lazily register the
    // bundled plugins. Do this before the API server accepts sequence starts.
    try {
      await initializeBundledPluginRuntime(container);
      runtimeLogger.info(
        'Bundled plugin runtime initialized',
        source: _headlessLogSource,
      );
    } catch (e, st) {
      runtimeLogger.error(
        'Bundled plugin runtime failed to initialize: $e\n$st',
        source: _headlessLogSource,
      );
    }
    await initialiseCatalogManager(runtimeLogger);
    // The backend notifier's local-backend wiring is fire-and-forget for the
    // synchronous reads below (the rest of bootstrap reads `backendProvider`
    // synchronously and `useLocalBackend()` installs the FfiBackend before any
    // reads occur on this isolate). We
    // DO capture the future so startup auto-connect can deterministically await
    // the FfiBackend swap before it activates a profile / connects hardware,
    // instead of racing a still-`DisconnectedBackend` container.
    final localBackendReady = container
        .read(backendProvider.notifier)
        .useLocalBackend();
    runtimeLogger.info('Services initialized', source: _headlessLogSource);

    final authConfig = parseHeadlessAuthConfig(args);
    runtimeLogger.info(
      'Starting headless API server on port ${authConfig.port}',
      source: _headlessLogSource,
    );

    apiServer = await startHeadlessServices(
      container,
      logger: runtimeLogger,
      authToken: authConfig.token,
      scopedAuthTokens: authConfig.scopedTokens,
      fineGrainedAuthTokens: authConfig.fineGrainedTokens,
      requireAuth: authConfig.requireAuth,
      allowUnauthenticated: authConfig.allowUnauthenticated,
      bindLocalOnly: authConfig.bindLocalOnly,
      port: authConfig.port,
      corsAllowedOrigins: authConfig.corsAllowedOrigins,
      pairingPrintCodes: authConfig.pairingPrintCodes,
      pairingMode: authConfig.pairingMode,
      tlsEnabled: authConfig.tlsEnabled,
      tlsCertPath: authConfig.tlsCertPath,
      tlsKeyPath: authConfig.tlsKeyPath,
    );
    runtimeLogger.info(
      'Headless API server started',
      source: _headlessLogSource,
    );

    // Startup equipment auto-connect. Deterministic ordering: the API server is
    // already up (so the operator can recover remotely if a device is offline),
    // then the FfiBackend-swap readiness future AND the auto-connect attempt are
    // both handled INSIDE the fail-soft bootstrap seam, BEFORE the "running"
    // ready banner below. Passing `localBackendReady` in (rather than awaiting
    // it here) is deliberate: a readiness FAILURE must be logged loudly and
    // tolerated so the already-started server survives — awaiting it here would
    // let a readiness throw escape to the outer catch and shut the server down.
    await headlessAutoConnectBootstrap(
      container: container,
      logger: runtimeLogger,
      backendReady: localBackendReady,
    );

    // The desktop widget tree watches this provider in GUI mode. Headless mode
    // has no widget tree, so instantiate it explicitly after backend readiness
    // and startup auto-connect. Starting it inside startHeadlessServices was
    // too early: that function runs while useLocalBackend() may still be
    // swapping out DisconnectedBackend, and the one-shot read was then retired
    // before it could observe the connected camera. The initial pass here sees
    // live capabilities (for example 12-bit / 4095 ADU), and its listener owns
    // all later manual connection changes.
    container.read(scienceCameraAutoConfigProvider);
    runtimeLogger.info(
      'Science camera auto-configuration initialized',
      source: _headlessLogSource,
    );

    // There is no widget tree in daemon mode, so eagerly attach the same
    // host-only run-completion coordinator used by the GUI. Without this,
    // `post_session.auto_integrate` is silently inert on the appliance.
    container.read(autoIntegrationCoordinatorProvider);

    // Darkroom: drain the dawn jobs a previous run left queued (the DB open
    // re-queues rows a dead process abandoned mid-render), then catch up the
    // delivery rows whose retry came due while the appliance was down. Both
    // are fire-and-forget: an unreachable morning destination must never hold
    // the "running" banner below.
    resumeDarkroomWork(
      container: container,
      logger: runtimeLogger,
      logSource: _headlessLogSource,
    );

    // A headless appliance has no widget tree to lazily create services.
    // Start host-owned automatic backups explicitly from persisted settings.
    try {
      autoSaveService = await container.read(autoSaveLifecycleProvider.future);
      runtimeLogger.info(
        'Automatic backup service started',
        source: _headlessLogSource,
      );
    } catch (e, st) {
      runtimeLogger.error(
        'Automatic backup service failed to start: $e\n$st',
        source: _headlessLogSource,
      );
    }

    // v4 couch-grade remote: if a relay URL was supplied, dial OUT to the
    // self-hosted relay and proxy the loopback headless API through it so the
    // rig is reachable from anywhere with no port-forwarding. End-to-end auth
    // stays the existing pairing token / HMAC, which the relay never sees in
    // plaintext. Failures are logged-and-continue: the LAN/mDNS path is
    // unaffected if the relay is down.
    relayUplink = await startRelayUplink(
      args: args,
      logger: runtimeLogger,
      localPort: apiServer.actualPort,
      onApplianceId: (id) => apiServer?.setRelayApplianceId(id),
    );

    // register `_skotiq._tcp` via mDNS. This MUST happen after
    // `apiServer.start()` so the advertised port is the actually-bound one
    // (matters when the caller started us with port 0). Failures here are
    // logged-and-continue — UDP broadcast and manual entry remain available.
    if (!authConfig.bindLocalOnly) {
      // Refresh the static Avahi service file so the advertised <port> and
      // scheme= TXT match the actually-bound port/scheme. The file installed
      // by packaging/appliance/systemd/install.sh hardcodes 8080/http, so a
      // changed SKOTIQ_PORT or `--tls` would otherwise silently break
      // mDNS discovery. Best-effort: a missing/read-only services dir (i.e.
      // not running as the appliance) is logged-and-skipped.
      refreshAvahiServiceFile(
        logger: runtimeLogger,
        port: apiServer.actualPort,
        scheme: apiServer.isTlsActive ? 'https' : 'http',
        version: appVersion.version,
      );
      try {
        await startMdnsAdvertisement(
          logger: runtimeLogger,
          apiServer: apiServer,
          appVersion: appVersion.version,
        );
      } catch (e, st) {
        // The MdnsServiceRegistration class already swallows NsdError and
        // platform errors internally and routes them through onWarning. This
        // catch-all is a belt-and-braces guard against a programming error
        // (e.g. a future maintainer making the constructor itself throw) so
        // a coding fault in the discovery surface can't take down the whole
        // headless daemon.
        runtimeLogger.warning(
          'Unexpected mDNS registration failure: $e\n$st',
          source: _headlessLogSource,
        );
      }
    } else {
      runtimeLogger.info(
        'Headless server is loopback-only; mDNS advertisement skipped',
        source: _headlessLogSource,
      );
    }

    // Wire push notifications to the API server so weather aborts, sequence
    // failures, and guiding-lost events are delivered as
    // `type:'push_notification'` envelopes to connected phones during
    // unattended overnight runs. Parity with GUI mode
    // (desktop_app_bootstrap.dart), which wires the same stream — without it a
    // phone gets no push for a failure on a Pi-hosted server.
    try {
      final pushService = container.read(pushNotificationServiceProvider);
      apiServer.setPushNotificationStream(
        pushService.notifications.map((n) => n.toJson()),
      );
      runtimeLogger.info(
        'Push notifications wired to headless API server',
        source: _headlessLogSource,
      );
    } catch (e, st) {
      // Push wiring failure is non-fatal — the rest of the server still works
      // — but it is logged at error, not swallowed: the operator has to know
      // that overnight push notifications are off before they rely on them.
      runtimeLogger.error(
        'Failed to wire push notifications: $e\n$st',
        source: _headlessLogSource,
      );
    }

    // Architecture-unification, Subsystem 3: eager-mount the
    // NotificationRouter so the external transports (Discord, email, Telegram,
    // Pushover, MQTT, webhook) and the in-app/mobile-push fan-out fire for any
    // routed backend event even with no sequence running. On a Pi-hosted
    // headless server there is no widget tree to lazily build the router, so
    // without this read the router never attached its event subscription and
    // every external alert was dead. Push delivery to phones is wired
    // separately above (setPushNotificationStream); this read powers the
    // configurable external transports that the GUI shell mounts via its own
    // background-services bootstrap.
    try {
      container.read(notificationRouterProvider);
      runtimeLogger.info(
        'Notification router mounted (external transports active)',
        source: _headlessLogSource,
      );
    } catch (e, st) {
      runtimeLogger.error(
        'Failed to mount notification router: $e\n$st',
        source: _headlessLogSource,
      );
    }

    // The GUI shell normally owns these always-on meridian services. A
    // headless host has no widget tree, so mount them explicitly: the monitor
    // must keep polling when the operator closes the phone, and the disconnect
    // guard must clear an in-flight flip if the mount drops offline.
    try {
      container.read(meridianFlipDisconnectGuardProvider);
      container.read(meridianFlipStandaloneMonitorProvider);
      runtimeLogger.info(
        'Standalone meridian-flip monitor mounted',
        source: _headlessLogSource,
      );
    } catch (e, st) {
      runtimeLogger.error(
        'Failed to mount standalone meridian-flip monitor: $e\n$st',
        source: _headlessLogSource,
      );
    }

    // v4 couch-grade remote: eager-mount Home Assistant MQTT discovery —
    // a headless appliance is exactly where the observatory should show
    // up as native HA entities. No-op until enabled in settings.
    try {
      container.read(homeAssistantDiscoveryProvider);
    } catch (e, st) {
      runtimeLogger.error(
        'Failed to mount Home Assistant discovery: $e\n$st',
        source: _headlessLogSource,
      );
    }

    // wire the disk-space watchdog. In GUI mode the sequencer
    // controller subscribes to this stream and pauses on blocking severity;
    // in headless mode nothing was consuming it, so the rig would keep
    // imaging past the abort threshold until raw write() failures aborted
    // the sequence mid-frame. Hook the watchdog into backend.sequencerStop
    // here so overnight unattended runs halt cleanly before the disk fills.
    try {
      final guard = container.read(diskSpaceGuardProvider);
      diskGuard = guard;
      diskWatchdogSubscription = await startDiskSpaceWatchdog(
        container: container,
        guard: guard,
        logger: runtimeLogger,
      );
    } catch (e, st) {
      runtimeLogger.error(
        'Disk-space watchdog failed to start: $e\n$st',
        source: _headlessLogSource,
      );
    }

    // Eager-mount the longitude-baton scheduler so an unattended appliance
    // self-drives the hand-off: each tick evaluates every
    // active co-imaging membership's target altitude at the configured site and
    // claims/releases the baton on the rise/set, resuming/pausing the autopilot.
    // The provider is otherwise lazy, so without this read it would never tick on
    // a headless host (no widget tree to build it). No-op until the rig has
    // joined a session and a site is configured.
    try {
      container.read(coImagingBatonSchedulerProvider);
      runtimeLogger.info(
        'Co-imaging longitude-baton scheduler mounted',
        source: _headlessLogSource,
      );
    } catch (e, st) {
      runtimeLogger.error(
        'Failed to mount co-imaging baton scheduler: $e\n$st',
        source: _headlessLogSource,
      );
    }

    // provision the OTA update stack and wire it into the
    // headless API server. Without this, paired phones could not check,
    // download, or apply updates on a headless host because the entire
    // /api/system/update/* surface would 404. Failures here are logged
    // and tolerated — OTA is non-essential to imaging — but the operator
    // sees a warning so they know why the endpoints are unavailable.
    try {
      final stack = await provisionUpdateStack(
        currentVersion: appVersion.version,
        currentBuildNumber: appVersion.buildNumber,
        logger: runtimeLogger,
        logSource: _headlessLogSource,
        applySafetyCheck: () =>
            defaultUpdateApplySafetyCheckWithReader(container!.read),
      );
      if (stack != null) {
        updateStack = stack;
        apiServer.setUpdateController(stack.controller);
        runtimeLogger.info(
          'OTA update endpoints wired to headless API server',
          source: _headlessLogSource,
          fields: {
            'channel': stack.controller.channel,
            'updateSource': stack.controller.updateSourceLabel,
          },
        );

        // Best-effort start the LAN-push receiver. It requires a trusted
        // public key compiled into the build (Ed25519 signature
        // verification); when that's absent, startServer throws and we
        // log-and-continue — HTTPS pull updates still work.
        try {
          await stack.lanPushReceiver.startServer();
          runtimeLogger.info(
            'LAN push receiver started on port 45680',
            source: _headlessLogSource,
          );
        } catch (e) {
          runtimeLogger.warning(
            'LAN push receiver did not start (no trusted public key '
            'compiled in?). HTTPS pull updates remain available.',
            source: _headlessLogSource,
            fields: {'error': '$e'},
          );
        }
      } else {
        runtimeLogger.info(
          'OTA update stack not provisioned; /api/system/update/* will be '
          'unavailable.',
          source: _headlessLogSource,
        );
      }
    } catch (e, st) {
      runtimeLogger.warning(
        'OTA update stack failed to provision; /api/system/update/* '
        'will be unavailable for this session',
        source: _headlessLogSource,
        fields: {'error': '$e', 'stack': '$st'},
      );
    }

    // Operator-facing console message announcing service readiness. Logged
    // through the structured logger too so it shows up in log files alongside
    // the timestamped service-started events.
    stdout.writeln('\nSkotiq is running in headless mode.');
    stdout.writeln('Press Ctrl+C to stop.\n');
    runtimeLogger.info(
      'Headless mode running; waiting for SIGINT/SIGTERM',
      source: _headlessLogSource,
    );

    // Bounded, idempotent, repeated-signal-safe shutdown. Every teardown step
    // is time-bounded and guarded so a single hung/throwing stop() cannot wedge
    // the daemon with the exit() unreachable; a second SIGINT/SIGTERM during a
    // slow teardown forces an immediate exit instead of being swallowed. See
    // [HeadlessShutdown].
    final shutdownCoordinator = HeadlessShutdown(
      safeRig: safeRigForShutdown,
      // Order is load-bearing: quiesce the local watchdogs, then withdraw
      // discovery/mDNS and the relay uplink BEFORE the
      // HTTP server so peers stop dialing a port that is about to close, then
      // detach the update controller before stopping the server, then dispose
      // the OTA stack, auto-save, and finally the provider container.
      teardownSteps: buildTeardownSteps,
      exitProcess: (code) => exit(code),
      onInfo: (message, {error}) => logger?.info(
        error == null ? message : '$message: $error',
        source: _headlessLogSource,
      ),
      onCritical: (message, {error}) => logger?.critical(
        error == null ? message : '$message: $error',
        source: _headlessLogSource,
      ),
      onStderr: stderr.writeln,
    );

    ProcessSignal.sigint.watch().listen((_) {
      unawaited(shutdownCoordinator.request('Received SIGINT'));
    });

    if (Platform.isLinux || Platform.isMacOS) {
      ProcessSignal.sigterm.watch().listen((_) {
        unawaited(shutdownCoordinator.request('Received SIGTERM'));
      });
    }

    while (true) {
      await Future.delayed(const Duration(seconds: 1));
    }
  } catch (e, stackTrace) {
    logger?.critical(
      'Error starting headless mode: $e\n$stackTrace',
      source: _headlessLogSource,
    );
    // Always also surface to stderr — if the logger itself failed to
    // initialise (the path that often triggers this catch), the operator
    // still needs to see why the daemon refused to start.
    stderr.writeln('Error starting headless mode: $e');
    stderr.writeln('Stack trace: $stackTrace');
    // A startup failure can land after hardware auto-connect and after any
    // subset of network services has started. Reuse the same bounded,
    // attempt-every-step coordinator as SIGTERM so one throwing cleanup cannot
    // leak the API socket/relay/container, and safe any connected hardware
    // before tearing its providers down. Startup failure exits non-zero even
    // when cleanup itself succeeds.
    final startupFailureShutdown = HeadlessShutdown(
      safeRig: safeRigForShutdown,
      teardownSteps: buildTeardownSteps,
      exitProcess: (code) => exit(code),
      completionExitCode: 1,
      onInfo: (message, {error}) => logger?.info(
        error == null ? message : '$message: $error',
        source: _headlessLogSource,
      ),
      onCritical: (message, {error}) => logger?.critical(
        error == null ? message : '$message: $error',
        source: _headlessLogSource,
      ),
      onStderr: stderr.writeln,
    );
    await startupFailureShutdown.request('Startup failed');
  }
}
