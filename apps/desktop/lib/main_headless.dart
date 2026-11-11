import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/startup/app_overrides.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'desktop_logging_init.dart';
import 'headless/headless_auth_config.dart';
import 'headless/headless_shutdown.dart';
import 'host/host_startup.dart';
import 'host/host_steps.dart';

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
  HostStartup? host;

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

  // Every start-up step registered how it stops; they are undone last
  // started first, and the container goes last of all. That order withdraws
  // discovery, mDNS and the relay before the server's socket closes, detaches
  // the update controller before the server stops, and hands a running
  // Darkroom pass back while the database is still up.
  List<ShutdownStep> buildTeardownSteps() => [
    ...?host?.teardownSteps,
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
    final activeContainer = container = ProviderContainer(
      overrides: appProviderOverrides(appVersion),
    );
    final runtimeLogger = activeContainer.read(loggingServiceProvider);
    logger = runtimeLogger;
    await runtimeLogger.initialize();

    final startup = host = HostStartup(
      kind: HostKind.daemon,
      container: activeContainer,
      logger: runtimeLogger,
      logSource: _headlessLogSource,
      appVersion: appVersion,
      args: args,
      daemonConfig: parseHeadlessAuthConfig(args),
    );
    await runHostStartup(startup, HostStartupPhase.core, hostStartupSteps);
    await runHostStartup(startup, HostStartupPhase.services, hostStartupSteps);

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

    // The signal handlers above end the process.
    await Completer<void>().future;
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
