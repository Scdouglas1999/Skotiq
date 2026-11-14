import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/startup/always_on_services.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../headless/headless_auth_config.dart';
import '../startup_timeline.dart';
import 'host_server.dart';

/// The two processes that own the hardware.
enum HostKind {
  /// A desktop window.
  gui,

  /// The windowless daemon.
  daemon,
}

enum HostStartupPhase {
  /// Before the GUI creates its window. Keep this short: it is time the
  /// operator spends looking at nothing.
  core,

  /// Everything else. The GUI starts these and shows its window without
  /// waiting; the daemon runs them before it reports itself running.
  services,
}

/// One thing to undo at shutdown.
typedef HostStop = ({String name, Future<void> Function() action});

class HostStartupStep {
  const HostStartupStep({
    required this.name,
    required this.phase,
    required this.run,
    this.needs = const [],
    this.only,
    this.because,
    this.fatalFor = const {},
    this.waitedFor = const {HostKind.gui, HostKind.daemon},
  }) : assert(
         (only == null) == (because == null),
         'a step limited to one host says why',
       );

  final String name;
  final HostStartupPhase phase;
  final Future<void> Function(HostStartup host) run;

  /// Names of earlier steps this one relies on having run.
  final List<String> needs;

  /// The one host that runs this step; null for both.
  final HostKind? only;

  /// Why the other host does not run it.
  final String? because;

  /// Hosts where a failure here stops start-up. Elsewhere it is logged and
  /// the next step runs.
  final Set<HostKind> fatalFor;

  /// Hosts that wait for this step before starting the next one.
  final Set<HostKind> waitedFor;

  bool appliesTo(HostKind kind) => only == null || only == kind;
}

/// What the steps of one host start-up share.
class HostStartup {
  HostStartup({
    required this.kind,
    required this.container,
    required this.logger,
    required this.logSource,
    required this.appVersion,
    required this.args,
    this.daemonConfig,
    this.forceServe = false,
  }) : assert((kind == HostKind.daemon) == (daemonConfig != null));

  final HostKind kind;
  final ProviderContainer container;
  final LoggingService logger;
  final String logSource;
  final AppVersionInfo appVersion;

  final List<String> args;

  /// The daemon's command-line server configuration.
  final HeadlessAuthConfig? daemonConfig;

  /// GUI: `--serve` turns remote access on for this run only.
  final bool forceServe;

  /// Completes when the local backend has replaced the disconnected one.
  Future<void>? backendReady;

  /// The daemon's server, once its step has run.
  RunningHostServer? daemonServer;

  /// The daemon's always-on services, once started.
  AlwaysOnServices? alwaysOn;

  final List<HostStop> _stops = [];
  final Map<String, Duration> _timings = {};

  /// Registers how something a step started is stopped.
  void onStop(String name, Future<void> Function() action) {
    _stops.add((name: name, action: action));
  }

  /// Everything registered so far, last started first.
  List<HostStop> get teardownSteps => _stops.reversed.toList();

  /// How long each finished step took.
  Map<String, Duration> get timings => Map.unmodifiable(_timings);
}

/// Runs the [phase] steps of [steps] that apply to this host, in order.
///
/// Each step is timed and logged by name. A step that fails stops start-up
/// only where it is marked fatal; otherwise the failure is logged and the next
/// step runs, so one broken service never takes the rest of the host with it.
Future<void> runHostStartup(
  HostStartup host,
  HostStartupPhase phase,
  List<HostStartupStep> steps,
) async {
  for (final step in steps) {
    if (step.phase != phase || !step.appliesTo(host.kind)) continue;
    final clock = Stopwatch()..start();

    Future<void> run() async {
      try {
        await step.run(host);
        host._timings[step.name] = clock.elapsed;
        startupTimeline.mark('step: ${step.name}');
        host.logger.info(
          'Start-up step done: ${step.name}',
          source: host.logSource,
          fields: {'ms': clock.elapsedMilliseconds},
        );
      } catch (error, stack) {
        host.logger.error(
          'Start-up step failed: ${step.name}: $error',
          source: host.logSource,
          fields: {'stack': '$stack'},
        );
        if (step.fatalFor.contains(host.kind)) rethrow;
      }
    }

    if (step.waitedFor.contains(host.kind)) {
      await run();
    } else {
      // Not fatal by construction: nothing waits to hear about it.
      assert(!step.fatalFor.contains(host.kind));
      unawaited(run());
    }
  }
}
