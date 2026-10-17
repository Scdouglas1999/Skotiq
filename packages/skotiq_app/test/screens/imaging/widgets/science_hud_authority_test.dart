import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/science_hud.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _ActiveSession extends SessionStateNotifier {
  _ActiveSession(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const SessionState(isActive: true, dbSessionId: 42);
  }
}

class _LoadedScienceSettings extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async => const ScienceSettings();
}

class _LoadedSelection extends SciencePhotometrySelectionNotifier {
  @override
  Future<SciencePhotometrySelection> build() async =>
      const SciencePhotometrySelection();
}

class _FailingSelectionWrite extends SciencePhotometrySelectionNotifier {
  @override
  Future<SciencePhotometrySelection> build() async =>
      const SciencePhotometrySelection();

  @override
  Future<void> setDifferentialEnabled(bool enabled) async {
    throw StateError('selection write failed');
  }
}

class _FailingConfigController extends ScienceSessionConfigController {
  _FailingConfigController(super.ref);

  int attempts = 0;

  @override
  Future<void> save(int sessionId, ScienceSessionConfig config) async {
    attempts++;
    throw StateError('session config write failed');
  }
}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

class _PendingConfigController extends ScienceSessionConfigController {
  _PendingConfigController(super.ref);

  final writes = <Completer<void>>[];

  @override
  Future<void> save(int sessionId, ScienceSessionConfig config) {
    final write = Completer<void>();
    writes.add(write);
    return write.future;
  }
}

Widget _harness(List<Override> overrides) {
  return ProviderScope(
    overrides: [
      sessionStateProvider.overrideWith((ref) => _ActiveSession(ref)),
      scienceSettingsProvider.overrideWith(_LoadedScienceSettings.new),
      sciencePhotometrySelectionProvider.overrideWith(_LoadedSelection.new),
      activeScienceSessionConfigProvider.overrideWith(
        (ref) => const AsyncValue.data(
          ScienceSessionConfig(
            transparencyEnabled: false,
            movingObjectsEnabled: true,
            narrowbandEnabled: true,
          ),
        ),
      ),
      ...overrides,
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: const Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 600,
            child: ScienceHudPanel(colors: SkotiqColors.dark),
          ),
        ),
      ),
    ),
  );
}

void _setViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'session-config outage is visible, retryable, and disables writes',
      (tester) async {
    _setViewport(tester);
    var attempts = 0;

    await tester.pumpWidget(
      _harness([
        activeScienceSessionConfigProvider.overrideWith((ref) {
          attempts++;
          return AsyncValue<ScienceSessionConfig?>.error(
            StateError('session config unavailable'),
            StackTrace.current,
          );
        }),
      ]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.textContaining('Some science controls are unavailable'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Bad state: session config unavailable'),
      findsOneWidget,
    );
    final switches = tester.widgetList<SkotiqSwitch>(
      find.byType(SkotiqSwitch),
    );
    expect(switches, hasLength(7));
    for (final toggle in switches) {
      expect(toggle.enabled, isFalse);
      expect(toggle.onChanged, isNull);
    }
    expect(attempts, 1);

    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(attempts, 2);
  });

  testWidgets('failed config save leaves switch and runtime mode unchanged',
      (tester) async {
    _setViewport(tester);
    late _FailingConfigController controller;

    await tester.pumpWidget(
      _harness([
        scienceSessionConfigControllerProvider.overrideWith((ref) {
          controller = _FailingConfigController(ref);
          return controller;
        }),
      ]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final movingToggle = find.byType(SkotiqSwitch).first;
    expect(tester.widget<SkotiqSwitch>(movingToggle).value, isTrue);

    await tester.tap(movingToggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(controller.attempts, 1);
    expect(tester.widget<SkotiqSwitch>(movingToggle).value, isTrue);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ScienceHudPanel)),
    );
    expect(
      container.read(scienceModeStateProvider).movingObjectModeEnabled,
      isFalse,
    );
    expect(
      find.textContaining(
        'Could not save science session: Bad state: session config write failed',
      ),
      findsOneWidget,
    );
  });

  testWidgets('failed selection save cannot start differential runtime mode',
      (tester) async {
    _setViewport(tester);
    await tester.pumpWidget(
      _harness([
        sciencePhotometrySelectionProvider.overrideWith(
          _FailingSelectionWrite.new,
        ),
      ]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Start Differential Photometry'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ScienceHudPanel)),
    );
    expect(
      container.read(scienceModeStateProvider).differentialPhotometryActive,
      isFalse,
    );
    expect(
      find.textContaining(
        'Could not save photometry setup: Bad state: selection write failed',
      ),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SkotiqButton, 'Start Differential Photometry'),
      findsOneWidget,
    );
  });

  testWidgets(
      'host switch retires an old config save without blocking the new host',
      (tester) async {
    _setViewport(tester);
    late _SwappableBackendNotifier backendNotifier;
    late _PendingConfigController controller;

    await tester.pumpWidget(
      _harness([
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwappableBackendNotifier(
            ref,
            DisconnectedBackend(),
          );
          return backendNotifier;
        }),
        scienceSessionConfigControllerProvider.overrideWith((ref) {
          controller = _PendingConfigController(ref);
          return controller;
        }),
      ]),
    );
    await tester.pumpAndSettle();

    SkotiqSwitch movingToggle() => tester.widget<SkotiqSwitch>(
          find.byType(SkotiqSwitch).first,
        );

    await tester.tap(find.byType(SkotiqSwitch).first);
    await tester.pump();
    expect(controller.writes, hasLength(1));
    expect(movingToggle().enabled, isFalse);

    backendNotifier.switchTo(DisconnectedBackend());
    await tester.pump();
    expect(movingToggle().enabled, isTrue);

    await tester.tap(find.byType(SkotiqSwitch).first);
    await tester.pump();
    expect(controller.writes, hasLength(2));
    expect(movingToggle().enabled, isFalse);

    controller.writes.first.completeError(StateError('old host failed'));
    await tester.pump();
    expect(find.textContaining('old host failed'), findsNothing);
    expect(movingToggle().enabled, isFalse);

    controller.writes.last.complete();
    await tester.pump();
    await tester.pump();
    expect(movingToggle().enabled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
