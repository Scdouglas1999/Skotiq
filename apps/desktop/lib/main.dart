import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/skotiq_app.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_updater/skotiq_updater.dart'
    show setUpdateRelaunchArguments;
import 'package:window_manager/window_manager.dart';

import 'desktop_app_bootstrap.dart';
import 'desktop_last_gasp.dart';
import 'desktop_logging_init.dart';
import 'frame_timing_probe.dart';
import 'main_headless.dart' as headless;

/// A remote rig the desktop GUI should drive as a thin client instead of
/// connecting local hardware. Populated from `--remote-host=` / `--remote-port=`
/// / `--remote-token=` / `--remote-scheme=` flags (or the matching
/// SKOTIQ_REMOTE_* env vars). When set, the GUI runs against the headless
/// rig's NetworkBackend and does NOT start its own embedded host server.
class _RemoteClientTarget {
  final String host;
  final int port;
  final String? token;
  final String scheme;

  const _RemoteClientTarget({
    required this.host,
    required this.port,
    this.token,
    this.scheme = 'http',
  });
}

/// Resolve `--flag=value` from [args], falling back to [envKey]. Returns null
/// when neither is present so callers can apply their own defaults.
String? _flagValue(List<String> args, String flag, String envKey) {
  final prefix = '--$flag=';
  for (final arg in args) {
    if (arg.startsWith(prefix)) {
      return arg.substring(prefix.length);
    }
  }
  final env = Platform.environment[envKey];
  return (env != null && env.isNotEmpty) ? env : null;
}

/// True when the operator asked this instance to be a MASTER — i.e. own the
/// hardware AND expose the embedded remote-access server so slave clients (and
/// the mobile app) can connect. Accepts `--serve` / `--master` (presence or
/// `=1`/`=true`) and the `SKOTIQ_SERVE` env var. This is the easy, reliable
/// switch for Pi / scripted launches: it forces the effective
/// `web_server_enabled` setting true for this run WITHOUT flipping the global
/// default (so a plain desktop launch never silently exposes a LAN server).
bool _parseServeFlag(List<String> args) {
  for (final flag in const ['serve', 'master']) {
    final prefix = '--$flag';
    for (final arg in args) {
      if (arg == prefix) {
        return true;
      }
      if (arg.startsWith('$prefix=')) {
        final value = arg.substring(prefix.length + 1).toLowerCase();
        return value == '1' || value == 'true' || value.isEmpty;
      }
    }
  }
  final env = Platform.environment['SKOTIQ_SERVE'];
  return env == '1' || env == 'true';
}

_RemoteClientTarget? _parseRemoteTarget(List<String> args) {
  final host = _flagValue(args, 'remote-host', 'SKOTIQ_REMOTE_HOST');
  if (host == null || host.isEmpty) {
    return null;
  }
  final portRaw = _flagValue(args, 'remote-port', 'SKOTIQ_REMOTE_PORT');
  final token = _flagValue(args, 'remote-token', 'SKOTIQ_REMOTE_TOKEN');
  final scheme =
      _flagValue(args, 'remote-scheme', 'SKOTIQ_REMOTE_SCHEME') ?? 'http';
  return _RemoteClientTarget(
    host: host,
    port: int.tryParse(portRaw ?? '') ?? 8080,
    token: (token == null || token.isEmpty) ? null : token,
    scheme: scheme,
  );
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // An update restarts the app through the updater, which needs to know how
  // it was started (for example --headless --port=...) to start it the same way.
  setUpdateRelaunchArguments(args);

  final isHeadless =
      args.contains('--headless') ||
      Platform.environment['SKOTIQ_HEADLESS'] == '1';

  if (isHeadless) {
    headless.main(args);
    return;
  }

  final remoteTarget = _parseRemoteTarget(args);
  final serveRequested = _parseServeFlag(args);

  // Single-owner invariant: one instance cannot both OWN the hardware (master)
  // and be a thin client of another rig (slave). Refuse the contradictory
  // combination loudly instead of silently picking one.
  if (serveRequested && remoteTarget != null) {
    stderr.writeln(
      'Skotiq: --serve/--master cannot be combined with --remote-host '
      '(an instance cannot be both a hardware-owning master and a remote '
      'slave). Aborting.',
    );
    exitCode = 64; // EX_USAGE
    return;
  }

  final bootPaths = await initialiseDesktopLogging();

  // Single-instance invariant, checked before any window or database work.
  // The GUI and the headless service resolve the SAME default database path,
  // so launching twice would point two SQLite writers at one file — and the
  // second opener's SQLITE_BUSY reads as corruption, which quarantines the
  // operator's real database and replaces it with an empty one. Refuse here,
  // in the same shape as the --serve/--remote-host conflict above, so the
  // operator gets a sentence instead of a data-loss incident.
  //
  // Advisory: the authoritative claim is taken when the database is actually
  // opened, so a launch that races past this still fails safely.
  final contended = await SingleInstanceLock.probe(
    await resolveDefaultDatabaseFile(),
  );
  if (contended != null) {
    stderr.writeln('Skotiq: ${contended.message}');
    developer.log(
      contended.message,
      name: 'desktop.main',
      level: 1000,
      error: contended,
    );
    // exit(), not `exitCode = …; return;`: the native bridge has already
    // started its hot-plug poll watcher and USB hotplug listener by the time
    // main() runs, and those keep the Dart isolate alive forever. Returning
    // here leaves a windowless process running against the other instance's
    // rig — verified on Linux, where the refused launch sat at 0% CPU
    // indefinitely instead of exiting.
    exit(75); // EX_TEMPFAIL — try again once the other instance exits.
  }

  final appVersion = await loadDesktopAppVersion();

  await windowManager.ensureInitialized();

  final initialSize = initialWindowSize(
    ui.PlatformDispatcher.instance.displays,
  );
  final windowOptions = WindowOptions(
    size: initialSize,
    minimumSize: Size(
      math.min(1200, initialSize.width),
      math.min(700, initialSize.height),
    ),
    center: true,
    // Opaque theme background — Colors.transparent + TitleBarStyle.hidden
    // composites to an undraggable black hole on Linux/Wayland when the first
    // Flutter frame is delayed. Match SkotiqColors.dark.background.
    backgroundColor: Color(0xFF0B0D12),
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
    title: 'Skotiq',
  );

  final container = ProviderContainer(
    overrides: [
      // The role this launch established, published for the surfaces that must
      // decide whose data they are editing. It is NOT the same fact as "a
      // remote connection is open": between launch and the first successful
      // handshake — and after any drop — a `--remote-host` client is not
      // connected, and a screen that reads the connection instead of the role
      // offers it the imaging host's editor over its own empty database.
      remoteClientLaunchProvider.overrideWithValue(remoteTarget != null),
      // Initialize backendProvider for the desktop GUI. Default: the local
      // FfiBackend (this machine owns the hardware). With --remote-host, run as
      // a thin client against a remote headless rig via NetworkBackend instead,
      // so the GUI drives that rig as if its devices were attached locally.
      backendProvider.overrideWith((ref) {
        final notifier = BackendNotifier(ref);
        // In remote mode we connect explicitly AFTER the container is built (see
        // below) so we can await the handshake and then invalidate the
        // host-backed providers — doing it here, fire-and-forget, lets profiles
        // and settings cache an empty disconnected value that never refreshes.
        if (remoteTarget == null) {
          notifier.useLocalBackend();
        }
        return notifier;
      }),
      // Why: appVersionProvider throws by default to surface misconfiguration
      // loudly (an unset version masks OTA update logic). The desktop entry
      // is the canonical place to wire it.
      appVersionProvider.overrideWithValue(appVersion),
      pluginHostAppVersionOverride(appVersion.version),
      // wire `pluginNodeDispatcherProvider` (defined in
      // skotiq_core) to the real `PluginNodeExecutor` (defined in
      // skotiq_plugins). Without this override the Rust executor would
      // receive a structured "dispatcher not wired" failure for every
      // PluginNode invocation.
      pluginNodeDispatcherOverride(),
      // surface plugin-contributed sequence nodes in the
      // sequencer palette. Without this override the palette never shows
      // plugin nodes even when the dispatcher above is fully wired (the
      // user could not author a sequence containing a plugin node from
      // the GUI).
      pluginNodePaletteBlueprintsOverride(),
      // C4 — make the bundled-plugin registration honour the user's
      // persisted enable/disable choices. Without this override C3's
      // `pluginEnablementStoreProvider` resolves to the default
      // `AllEnabledPluginEnablementStore`, which reports every plugin
      // enabled, so a plugin the user disabled on the Integrations page
      // would silently come back ENABLED on the next launch. The
      // settings-backed store reads the persisted `plugin_enablement`
      // map so the registration-time decision matches the saved state.
      pluginEnablementStoreOverride(),
    ],
  );

  final logger = container.read(loggingServiceProvider);
  await logger.ensureInitialized();

  // A GUI that dies with devices connected must not leave nothing behind: no
  // shutdown record, no safing, a log whose last line is an unrelated warning.
  // Two halves prevent that. (1) Every session stamps a record and a normal
  // quit marks it clean, so a session that just vanishes is visible at the
  // NEXT launch instead of being indistinguishable from a normal one. (2) The
  // death paths this process can actually see — a stop signal from a logout,
  // `systemctl stop`, or Ctrl+C on a terminal launch — record and safe the rig
  // on the way out, as the headless daemon does. Framework errors are
  // recorded, never acted on: an overflow is not a reason to park a mount
  // mid-sequence.
  final lastGasp = DesktopLastGasp(
    recordFile: resolveDesktopSessionRecordFile(bootPaths.dataDirectory),
    safeRig: () async {
      await container
          .read(safeRigServiceProvider)
          .safeTheRig(
            reason: 'Skotiq is shutting down',
            park: true,
            closeDome: true,
            closeCover: true,
            abortExposure: true,
            disableCooling: true,
            notify: false,
          );
    },
    exitProcess: exit,
    // The GUI drains the same dawn queue the daemon does (see
    // desktop_app_bootstrap's resumeDarkroomWork), so it owes the same hand-back
    // the daemon's teardown makes: a pass left `running` by an orderly quit is
    // read at the next open as a dead process and charged one of the job's three
    // starts.
    releaseDarkroomJobs: () async {
      await container
          .read(dawnAutopilotServiceProvider)
          .releaseRunningJobsForShutdown();
    },
    onInfo: (message, {error}) =>
        logger.info(message, source: 'desktop.shutdown'),
    onCritical: (message, {error}) => logger.error(
      message,
      source: 'desktop.shutdown',
      fields: {if (error != null) 'error': '$error'},
    ),
    version: appVersion.version,
    pid: pid,
  );
  final previousSession = lastGasp.readPreviousSession();
  if (previousSession != null && previousSession.endedWithoutShutdownPath) {
    logger.error(
      'The previous Skotiq session ended without a shutdown record: '
      'nothing was safed on the way out. Check the rig.',
      source: 'desktop.shutdown',
      fields: {
        'endedAt': previousSession.at.toIso8601String(),
        if (previousSession.version != null)
          'version': previousSession.version!,
        'lastError': previousSession.lastError ?? 'none recorded',
      },
    );
  }
  lastGasp.markRunning();
  lastGasp.install(
    signals: [
      ProcessSignal.sigint,
      // SIGTERM cannot be watched on Windows; install() logs and moves on.
      if (!Platform.isWindows) ProcessSignal.sigterm,
    ],
  );
  // The shell owns the close decision (confirmation + edit flush); it tells us
  // when the operator's quit was accepted so a normal exit is never reported as
  // a silent death.
  ShellExit.register(lastGasp.recordCleanExit);

  // Plugin nodes execute on the machine that owns the imaging hardware, so
  // bundled plugins must be registered before the UI can start a sequence.
  if (remoteTarget == null) {
    try {
      await initializeBundledPluginRuntime(container);
      logger.info('Bundled plugin runtime initialized', source: 'desktop.main');
    } catch (error, stackTrace) {
      logger.error(
        'Bundled plugin runtime failed to initialize: $error\n$stackTrace',
        source: 'desktop.main',
      );
    }
  }

  await initialiseCatalogManager(logger);

  final shouldMinimize = await shouldStartMinimized(container);

  // Prepare the window but do NOT show it yet. Showing a TitleBarStyle.hidden
  // surface before runApp paints leaves a black, undraggable window on Linux
  // (no Flutter chrome / DragToMoveArea yet). The GTK runner also defers
  // gtk_widget_show until first-frame for the same reason.
  await windowManager.waitUntilReadyToShow(windowOptions, () async {});

  // Remote-client mode: connect to the headless rig now that the container is
  // live, then invalidate the host-backed providers so they re-fetch against
  // the open NetworkBackend connection (equipment profiles, app settings, and
  // anything else keyed on the backend). Without this refresh they keep the
  // empty value they resolved while the backend was still DisconnectedBackend,
  // which is why profiles/devices appeared missing. Mirrors the mobile
  // post-connect sequence (invalidate appSettings + equipmentProfiles).
  if (remoteTarget != null) {
    try {
      await container
          .read(backendProvider.notifier)
          .connect(
            remoteTarget.host,
            remoteTarget.port,
            authToken: remoteTarget.token,
            scheme: remoteTarget.scheme,
          );
    } catch (error) {
      developer.log(
        'Remote connect to ${remoteTarget.scheme}://'
        '${remoteTarget.host}:${remoteTarget.port} failed: $error',
        name: 'desktop.main',
        level: 1000,
        error: error,
      );
    }
    container.invalidate(appSettingsProvider);
    container.invalidate(equipmentProfilesProvider);
  }

  // In remote-client mode this GUI is a consumer of a remote rig, not a host,
  // so it must NOT stand up its own embedded API server / discovery / host-side
  // seed listeners (those belong to the machine that owns the hardware).
  if (remoteTarget == null) {
    // Automatic backups are host-owned and must start even when the Settings
    // screen is never opened. Do NOT await this before first paint: a Riverpod
    // future that transitively waits on the widget tree / first frame will
    // hang main() forever and leave a blank frameless window (same class of
    // bug as awaiting appSettingsProvider.future before runApp below).
    unawaited(() async {
      try {
        await container.read(autoSaveLifecycleProvider.future);
      } catch (error, stackTrace) {
        logger.error(
          'Automatic backup service failed to start',
          source: 'desktop.main',
          fields: {'error': '$error', 'stack': '$stackTrace'},
        );
      }
    }());

    // --serve/--master: force the effective web-server setting ON for this run
    // so the embedded host server starts and slave clients can connect. We do
    // NOT flip the global default — we await the settings notifier, persist
    // web_server_enabled=true, and patch in-memory state BEFORE
    // startBackgroundServices attaches its fireImmediately listener, so the
    // server comes up on launch. A normal (no-flag) launch is untouched and
    // honours whatever the user toggled in Settings → Remote Access.
    if (serveRequested) {
      try {
        // Persist web_server_enabled=true straight to the settings DAO. We must
        // NOT await appSettingsProvider.future here: that provider may not
        // resolve until after the first frame (its build can depend on the
        // backend swap that is still in flight), so awaiting it before runApp
        // hangs main() forever and the shown window stays blank. The DAO is the
        // source the lifecycle listener (attached in startBackgroundServices
        // below, fireImmediately) reads, so writing it here — before that
        // listener attaches — is sufficient for the embedded server to come up
        // on launch, and it never blocks the UI.
        await container
            .read(settingsDaoProvider)
            .setSetting('web_server_enabled', 'true');
      } catch (error) {
        developer.log(
          '--serve: failed to force web_server_enabled on; the embedded '
          'remote-access server may not start: $error',
          name: 'desktop.main',
          level: 1000,
          error: error,
        );
      }
    }
    startBackgroundServices(
      container,
      appVersion: appVersion.version,
      appBuildNumber: appVersion.buildNumber,
    );
  }

  // Inert unless SKOTIQ_FRAME_TIMING=1. Armed before runApp so the very
  // first frames are counted too.
  startFrameTimingProbe();

  // The window is frameless (TitleBarStyle.hidden, the app draws its own
  // chrome), and a frameless window only resizes where something answers the
  // edge hit-test. On Windows and macOS the window_manager plugin answers it
  // natively; on Linux nothing does, so without these edge zones the window
  // is simply not resizable by mouse — found by the first human to grab a
  // corner after a campaign of harness runs that resized via xdotool, which
  // bypasses the window manager and masked the gap.
  //
  // [WindowResizeEdges] paints no Directionality-requiring widget: the grips
  // are Positioned by absolute left/right/top/bottom, so the app root needs
  // no direction context of its own.
  Widget appRoot = Platform.isLinux
      ? const WindowResizeEdges(child: SkotiqApp(isDesktop: true))
      : const SkotiqApp(isDesktop: true);

  // Windows accessibility bridge spam: Flutter logs
  // `[ERROR:flutter/shell/platform/common/accessibility_bridge.cc(114)]
  // Failed to update ui::AXTree, error: N will not be in the tree and is
  // not the new root` whenever semantics nodes churn (tooltips, overlays,
  // live telemetry). Engine bug, not a Skotiq fault; ExcludeSemantics
  // stops those updates reaching AXTree. Screen-reader users can opt back
  // in with SKOTIQ_ENABLE_SEMANTICS=1.
  final enableSemantics =
      Platform.environment['SKOTIQ_ENABLE_SEMANTICS'] == '1';
  if (Platform.isWindows && !enableSemantics) {
    appRoot = ExcludeSemantics(child: appRoot);
  }

  runApp(UncontrolledProviderScope(container: container, child: appRoot));

  // Reveal the frameless window only after Flutter has built at least one
  // frame so the custom title bar (drag target) and scaffold are present.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await windowManager.show();
    await windowManager.focus();
    if (shouldMinimize) {
      await windowManager.minimize();
    }
  });
}

/// The first window's size: 1600 x 900, shrunk to fit the display it opens on.
///
/// A 1920 x 1080 laptop at 125% scaling is 1536 x 864 logical pixels. Centering
/// a larger frameless window there pushes its top edge, and with it the window
/// controls, off the screen. The margins leave room for the taskbar.
@visibleForTesting
Size initialWindowSize(Iterable<ui.Display> displays) {
  const preferred = Size(1600, 900);
  if (displays.isEmpty) return preferred;
  final display = displays.first;
  final screen = display.size / display.devicePixelRatio;
  return Size(
    math.min(preferred.width, (screen.width * 0.94).floorToDouble()),
    math.min(preferred.height, (screen.height * 0.88).floorToDouble()),
  );
}
