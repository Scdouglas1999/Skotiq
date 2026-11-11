import 'package:skotiq_ui/skotiq_ui.dart' show SkotiqColors;
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/skotiq_app.dart';
import 'package:skotiq_app/startup/app_overrides.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show kDefaultHeadlessPort;
import 'package:skotiq_updater/skotiq_updater.dart'
    show setUpdateRelaunchArguments;
import 'package:window_manager/window_manager.dart';

import 'desktop_app_bootstrap.dart';
import 'desktop_last_gasp.dart';
import 'desktop_shutdown_safing.dart';
import 'desktop_logging_init.dart';
import 'desktop_relaunch.dart';
import 'frame_timing_probe.dart';
import 'host/host_startup.dart';
import 'host/host_steps.dart';
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
  final String? name;
  final String? fingerprint;

  /// True when the target came from the rig the connect flow remembered.
  final LinkedRig? rememberedRig;

  const _RemoteClientTarget({
    required this.host,
    required this.port,
    this.token,
    this.scheme = 'http',
    this.name,
    this.fingerprint,
    this.rememberedRig,
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
    port: int.tryParse(portRaw ?? '') ?? kDefaultHeadlessPort,
    token: (token == null || token.isEmpty) ? null : token,
    scheme: scheme,
  );
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // A role switch restarts the app with --relaunched-from=<pid>. It is about
  // this one start only, so it is not part of how the app was "started".
  final relaunchedFrom = relaunchedFromPid(args);
  final launchArgs = [
    for (final arg in args)
      if (!arg.startsWith('$relaunchedFromFlag=')) arg,
  ];
  // An update restarts the app through the updater, which needs to know how
  // it was started (for example --headless --port=...) to start it the same way.
  setUpdateRelaunchArguments(launchArgs);

  final isHeadless =
      args.contains('--headless') ||
      Platform.environment['SKOTIQ_HEADLESS'] == '1';

  if (isHeadless) {
    headless.main(args);
    return;
  }

  final explicitTarget = _parseRemoteTarget(args);
  final serveRequested = _parseServeFlag(args);

  // Single-owner invariant: one instance cannot both OWN the hardware (master)
  // and be a thin client of another rig (slave). Refuse the contradictory
  // combination loudly instead of silently picking one.
  if (serveRequested && explicitTarget != null) {
    stderr.writeln(
      'Skotiq: --serve/--master cannot be combined with --remote-host '
      '(an instance cannot be both a hardware-owning master and a remote '
      'slave). Aborting.',
    );
    exitCode = 64; // EX_USAGE
    return;
  }

  if (relaunchedFrom != null) {
    // This start replaces process $relaunchedFrom, which is still closing. It
    // must be gone before anything here opens a store: logging init already
    // opens native stores that allow one process, and failed with "already
    // open" when the restart raced the old window's teardown.
    final databaseFile = await resolveDefaultDatabaseFile();
    await waitForPreviousInstance(() async {
      if (processStillRunning(relaunchedFrom)) return true;
      return await SingleInstanceLock.probe(databaseFile) != null;
    });
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
  final databaseFile = await resolveDefaultDatabaseFile();
  final contended = await SingleInstanceLock.probe(databaseFile);
  final heldBy = contended;
  if (heldBy != null) {
    stderr.writeln('Skotiq: ${heldBy.message}');
    developer.log(
      heldBy.message,
      name: 'desktop.main',
      level: 1000,
      error: heldBy,
    );
    // exit(), not `exitCode = …; return;`: the native bridge has already
    // started its hot-plug poll watcher and USB hotplug listener by the time
    // main() runs, and those keep the Dart isolate alive forever. Returning
    // here leaves a windowless process running against the other instance's
    // rig — verified on Linux, where the refused launch sat at 0% CPU
    // indefinitely instead of exiting.
    exit(75); // EX_TEMPFAIL — try again once the other instance exits.
  }

  // The role, decided once for the life of this process. Flags and variables
  // win; without them, the rig the connect flow remembered makes this a linked
  // client; otherwise this computer is its own host.
  final linkedRigStore = LinkedRigStore(
    dataDirectory: () async => Directory(bootPaths.dataDirectory),
  );
  var remoteTarget = explicitTarget;
  if (remoteTarget == null && !serveRequested) {
    final rig = await linkedRigStore.load();
    if (rig != null && rig.active) {
      remoteTarget = _RemoteClientTarget(
        host: rig.host,
        port: rig.port,
        scheme: rig.scheme,
        token: await linkedRigStore.readToken(),
        name: rig.name,
        fingerprint: rig.fingerprint,
        rememberedRig: rig,
      );
    }
  }

  final appVersion = await loadDesktopAppVersion();

  // Pointed at the app logger once it exists.
  void Function(String message) relaunchLog = (message) =>
      developer.log(message, name: 'desktop.relaunch');

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
    backgroundColor: SkotiqColors.dark.background,
    skipTaskbar: false,
    titleBarStyle: ShellChrome.usesSystemDecorations
        ? TitleBarStyle.normal
        : TitleBarStyle.hidden,
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
      remoteLaunchTargetProvider.overrideWithValue(
        remoteTarget == null
            ? null
            : RemoteLaunchTarget(
                host: remoteTarget.host,
                port: remoteTarget.port,
                token: remoteTarget.token,
                scheme: remoteTarget.scheme,
                name: remoteTarget.name,
                expectedFingerprint: remoteTarget.fingerprint,
                remembered: remoteTarget.rememberedRig != null,
              ),
      ),
      linkedRigStoreProvider.overrideWithValue(linkedRigStore),
      launchLinkedRigProvider.overrideWithValue(remoteTarget?.rememberedRig),
      // Connecting to a rig, or "Use this computer instead", restarts the app
      // so the role is chosen again from the top of main.
      appRelauncherProvider.overrideWithValue(
        DesktopAppRelauncher(
          launchArguments: launchArgs,
          log: (message) => relaunchLog(message),
        ),
      ),
      // A host's backend is installed by the 'local backend' start-up step; a
      // linked client connects below, once the container exists, so the
      // handshake can be awaited.
      ...appProviderOverrides(appVersion),
    ],
  );

  final logger = container.read(loggingServiceProvider);
  await logger.ensureInitialized();
  relaunchLog = (message) => logger.info(message, source: 'desktop.relaunch');
  if (remoteTarget?.rememberedRig != null) {
    logger.info(
      'Starting as the linked client of ${remoteTarget!.name} '
      '(${remoteTarget.host}:${remoteTarget.port}), the rig remembered by '
      'Connect to an imaging computer',
      source: 'desktop.main',
    );
  }

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
      final safed = await safeRigForDesktopShutdown(container);
      if (!safed) {
        logger.info(
          'Linked or disconnected: this app owns no rig, so nothing is safed '
          'on the way out',
          source: 'desktop.shutdown',
        );
      }
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
    ownsRig: remoteTarget == null,
  );
  final previousSession = lastGasp.readPreviousSession();
  final previousReport = previousSessionShutdownReport(
    previousSession,
    thisLaunchOwnsRig: remoteTarget == null,
  );
  if (previousSession != null && previousReport != null) {
    final fields = {
      'endedAt': previousSession.at.toIso8601String(),
      if (previousSession.version != null) 'version': previousSession.version!,
      'lastError': previousSession.lastError ?? 'none recorded',
    };
    if (previousReport.checkTheRig) {
      logger.error(
        previousReport.message,
        source: 'desktop.shutdown',
        fields: fields,
      );
    } else {
      logger.warning(
        previousReport.message,
        source: 'desktop.shutdown',
        fields: fields,
      );
    }
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

  // The window is prepared while the host start-up's core steps run, so
  // neither waits for the other. It is NOT shown yet: showing a
  // TitleBarStyle.hidden surface before runApp paints leaves a black,
  // undraggable window on Linux (no Flutter chrome / DragToMoveArea yet). The
  // GTK runner also defers gtk_widget_show until first-frame for the same
  // reason.
  final windowReady = windowManager.waitUntilReadyToShow(
    windowOptions,
    () async {},
  );

  // A host runs the shared host start-up; a linked client owns no hardware
  // and needs only its catalogs.
  final host = remoteTarget != null
      ? null
      : HostStartup(
          kind: HostKind.gui,
          container: container,
          logger: logger,
          logSource: 'desktop.main',
          appVersion: appVersion,
          args: launchArgs,
          forceServe: serveRequested,
        );
  if (host != null) {
    await runHostStartup(host, HostStartupPhase.core, hostStartupSteps);
  } else {
    await initialiseCatalogManager(logger);
  }

  final shouldMinimize = await shouldStartMinimized(container);

  await windowReady;

  // Remote-client mode: connect to the headless rig now that the container is
  // live, then invalidate the host-backed providers so they re-fetch against
  // the open NetworkBackend connection (equipment profiles, app settings, and
  // anything else keyed on the backend). Without this refresh they keep the
  // empty value they resolved while the backend was still DisconnectedBackend,
  // which is why profiles/devices appeared missing. Mirrors the mobile
  // post-connect sequence (invalidate appSettings + equipmentProfiles).
  if (remoteTarget != null) {
    // A failed connect is shown in the window (with Retry) by the shell's
    // connection banner; the status notifier keeps retrying an unreachable
    // host on its own.
    final connected = await container
        .read(remoteLaunchStatusProvider.notifier)
        .connect();
    if (!connected) {
      final status = container.read(remoteLaunchStatusProvider);
      logger.warning(
        'Remote connect to ${remoteTarget.scheme}://'
        '${remoteTarget.host}:${remoteTarget.port} failed '
        '(${status.failure?.name}): ${status.detail}',
        source: 'desktop.main',
      );
    }
    container.invalidate(appSettingsProvider);
    container.invalidate(equipmentProfilesProvider);
  }

  if (host != null) {
    // --serve/--master turns the embedded host server on for this run only;
    // the stored Remote Access setting stays as the user left it.
    container.read(remoteAccessForcedProvider.notifier).state = serveRequested;
    // Not awaited: the window does not wait for the server, the update
    // receiver or a device scan.
    unawaited(
      runHostStartup(host, HostStartupPhase.services, hostStartupSteps),
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
  Widget appRoot = Platform.isLinux && !ShellChrome.usesSystemDecorations
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
