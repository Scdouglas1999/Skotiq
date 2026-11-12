import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_desktop/headless/headless_auth_config.dart';
import 'package:skotiq_desktop/host/host_startup.dart';
import 'package:skotiq_desktop/host/host_steps.dart';

HostStartup _host(HostKind kind) {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return HostStartup(
    kind: kind,
    container: container,
    logger: container.read(loggingServiceProvider),
    logSource: 'test',
    appVersion: const AppVersionInfo(version: '0.0.0', buildNumber: 1),
    args: const [],
    daemonConfig: kind == HostKind.daemon ? HeadlessAuthConfig() : null,
  );
}

HostStartupStep _step(
  String name,
  List<String> ran, {
  HostStartupPhase phase = HostStartupPhase.services,
  HostKind? only,
  Set<HostKind> fatalFor = const {},
  Set<HostKind> waitedFor = const {HostKind.gui, HostKind.daemon},
  Future<void> Function()? body,
}) => HostStartupStep(
  name: name,
  phase: phase,
  only: only,
  because: only == null ? null : 'test',
  fatalFor: fatalFor,
  waitedFor: waitedFor,
  run: (host) async {
    await body?.call();
    ran.add(name);
  },
);

void main() {
  group('the host start-up table', () {
    test('names each step once', () {
      final names = hostStartupSteps.map((s) => s.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('a step only needs steps that run before it', () {
      final seen = <String>{};
      for (final step in hostStartupSteps) {
        for (final need in step.needs) {
          expect(seen, contains(need), reason: '${step.name} needs $need');
        }
        seen.add(step.name);
      }
    });

    test('core steps come before service steps', () {
      final phases = hostStartupSteps.map((s) => s.phase).toList();
      final firstService = phases.indexOf(HostStartupPhase.services);
      expect(
        phases.sublist(firstService),
        everyElement(HostStartupPhase.services),
      );
    });

    test('a step for one host says why the other does not run it', () {
      for (final step in hostStartupSteps.where((s) => s.only != null)) {
        expect(step.because, isNotEmpty, reason: step.name);
      }
    });

    test('the GUI host and the daemon run the same steps, bar the marked '
        'ones', () {
      Set<String> stepsOf(HostKind kind) => {
        for (final step in hostStartupSteps)
          if (step.appliesTo(kind)) step.name,
      };
      final gui = stepsOf(HostKind.gui);
      final daemon = stepsOf(HostKind.daemon);

      expect(daemon.difference(gui), {
        'sequencer checkpoints',
        'open plan',
        'always-on services',
        'disk-space watchdog',
      });
      expect(gui.difference(daemon), {'device discovery at launch'});
      // The two that had drifted: both hosts now run them.
      expect(
        gui.intersection(daemon),
        containsAll([
          'remote access server',
          'update receiver',
          'equipment auto-connect',
          'Darkroom work',
        ]),
      );
    });

    test('nothing a host does not wait for can stop its start-up', () {
      for (final step in hostStartupSteps) {
        expect(step.waitedFor, containsAll(step.fatalFor), reason: step.name);
      }
    });
  });

  group('interrupted-work recovery', () {
    for (final kind in HostKind.values) {
      test('opening the database leaves a dead run alone; the ${kind.name} '
          'step closes it', () async {
        final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(db)],
        );
        addTearDown(container.dispose);
        addTearDown(db.close);
        final runId = await db.sequenceRunsDao.startRun(
          sequenceId: null,
          sequenceName: 'left running',
        );
        Future<String> status() async => (await (db.select(
          db.sequenceRuns,
        )..where((r) => r.id.equals(runId))).getSingle()).status;
        expect(await status(), 'running');

        final host = HostStartup(
          kind: kind,
          container: container,
          logger: container.read(loggingServiceProvider),
          logSource: 'test',
          appVersion: const AppVersionInfo(version: '0.0.0', buildNumber: 1),
          args: const [],
          daemonConfig: kind == HostKind.daemon ? HeadlessAuthConfig() : null,
        );
        await runHostStartup(host, HostStartupPhase.core, [
          hostStartupSteps.singleWhere(
            (s) => s.name == 'interrupted-work recovery',
          ),
        ]);
        expect(await status(), 'interrupted');
      });
    }
  });

  group('running', () {
    test('runs the steps of the phase and the host, in order', () async {
      final ran = <String>[];
      await runHostStartup(_host(HostKind.gui), HostStartupPhase.services, [
        _step('core', ran, phase: HostStartupPhase.core),
        _step('one', ran),
        _step('daemon only', ran, only: HostKind.daemon),
        _step('two', ran),
      ]);
      expect(ran, ['one', 'two']);
    });

    test('a failed step is skipped over where it is not fatal', () async {
      final ran = <String>[];
      await runHostStartup(_host(HostKind.gui), HostStartupPhase.services, [
        _step(
          'breaks',
          ran,
          fatalFor: {HostKind.daemon},
          body: () async => throw StateError('offline'),
        ),
        _step('next', ran),
      ]);
      expect(ran, ['next']);
    });

    test('a failed step stops start-up where it is fatal', () async {
      final ran = <String>[];
      await expectLater(
        runHostStartup(_host(HostKind.daemon), HostStartupPhase.services, [
          _step(
            'breaks',
            ran,
            fatalFor: {HostKind.daemon},
            body: () async => throw StateError('no database'),
          ),
          _step('next', ran),
        ]),
        throwsStateError,
      );
      expect(ran, isEmpty);
    });

    test('a step the host does not wait for does not hold the next', () async {
      final ran = <String>[];
      final release = Completer<void>();
      await runHostStartup(_host(HostKind.gui), HostStartupPhase.services, [
        _step(
          'slow',
          ran,
          waitedFor: {HostKind.daemon},
          body: () => release.future,
        ),
        _step('next', ran),
      ]);
      expect(ran, ['next']);

      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(ran, ['next', 'slow']);
    });

    test('what was started is undone last started first', () async {
      final host = _host(HostKind.daemon);
      await runHostStartup(host, HostStartupPhase.services, [
        HostStartupStep(
          name: 'server',
          phase: HostStartupPhase.services,
          run: (h) async => h.onStop('server', () async {}),
        ),
        HostStartupStep(
          name: 'discovery',
          phase: HostStartupPhase.services,
          run: (h) async => h.onStop('discovery', () async {}),
        ),
      ]);
      expect(host.teardownSteps.map((s) => s.name), ['discovery', 'server']);
      expect(host.timings.keys, ['server', 'discovery']);
    });
  });
}
