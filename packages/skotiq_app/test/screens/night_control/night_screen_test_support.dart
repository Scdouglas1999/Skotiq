// The whole Tonight screen inside the real app shell, fed the board view
// models: every provider the header, plan column, center and the six panel
// tabs read, overridden from the fixtures so a test pins a board state and a
// tab and nothing else varies.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/screens/night_control/actions/night_rig_ops.dart';
import 'package:skotiq_app/screens/night_control/center/frame_stage.dart';
import 'package:skotiq_app/screens/night_control/center/frame_strip.dart';
import 'package:skotiq_app/screens/night_control/center/session_charts_row.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_target_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_timeline_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_progress_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/upcoming_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/before_you_start_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/conditions_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/equipment_summary_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/guide_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/last_frame_metrics_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/night_log_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_frames_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_stats_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/night_control_screen.dart';
import 'package:skotiq_app/screens/night_control/panel/camera/camera_panel_vm.dart';
import 'package:skotiq_app/screens/night_control/panel/focus/focus_panel_vm.dart';
import 'package:skotiq_app/screens/night_control/panel/night_right_panel.dart';
import 'package:skotiq_app/screens/night_control/panel/panel_ops.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_app/screens/shell/widgets/side_navigation.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_app/widgets/startup_splash_gate.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_backend.dart';
import 'center/center_test_support.dart' show FakeNightActionApi;
import 'fixtures/night_fixtures.dart';
import 'panel/panel_test_support.dart' show FakePanelOps, PanelFixtures;
import 'panel/scope_panel_test_support.dart' as scope;

/// The board states the owner window test and the capture goldens show.
enum NightScreenState {
  /// TonightReady.dc.html: a plan loaded, before dark.
  ready,

  /// Tonight.dc.html: the run on step 7.
  running,

  /// TonightFocus.dc.html: the operator's autofocus holds the run.
  focus,
}

NightBoard nightBoard(NightScreenState state) => switch (state) {
      NightScreenState.ready => NightFixtures.ready(),
      NightScreenState.running => NightFixtures.running(),
      NightScreenState.focus => NightFixtures.autofocus(),
    };

/// A 466 x 352 frame: sky background with noise and a few dozen stars, so a
/// capture shows something that reads as a frame.
CapturedImageData starField() {
  const width = 466;
  const height = 352;
  final random = math.Random(74);
  final luma = Float64List(width * height);
  for (var i = 0; i < luma.length; i++) {
    luma[i] = 18 + random.nextDouble() * 10;
  }
  for (var s = 0; s < 60; s++) {
    final cx = random.nextDouble() * width;
    final cy = random.nextDouble() * height;
    final peak = 60 + random.nextDouble() * 195;
    final sigma = 0.8 + random.nextDouble() * 1.4;
    final r = (sigma * 4).ceil();
    for (var y = (cy - r).floor(); y <= cy + r; y++) {
      for (var x = (cx - r).floor(); x <= cx + r; x++) {
        if (x < 0 || y < 0 || x >= width || y >= height) continue;
        final d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy);
        luma[y * width + x] += peak * math.exp(-d2 / (2 * sigma * sigma));
      }
    }
  }
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < luma.length; i++) {
    final v = luma[i].clamp(0, 255).toInt();
    rgba[i * 4] = v;
    rgba[i * 4 + 1] = v;
    rgba[i * 4 + 2] = v;
    rgba[i * 4 + 3] = 255;
  }
  return CapturedImageData(
    width: width,
    height: height,
    displayData: rgba,
    histogram: List<int>.filled(256, 0),
    stats: const ImageStats(
      hfr: 2.13,
      starCount: 412,
      median: 528,
      mean: 534,
      stdDev: 40,
      min: 0,
      max: 65535,
    ),
    capturedAt: NightFixtures.at(23, 49, 12),
    settings: const ExposureSettings(
      exposureTime: 180,
      gain: 139,
      offset: 21,
      filter: 'Ha',
    ),
    isColor: false,
    filePath: '/data/Skotiq/M74/Ha/M74_Ha_0043.fits',
  );
}

class _ConnectedGuider extends GuiderStateNotifier {
  _ConnectedGuider(super.ref, {required bool guiding}) {
    state = GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: kPhd2CanonicalId,
      deviceName: 'PHD2',
      isGuiding: guiding,
    );
  }
}

class _GuideSamples extends NightGuideSamplesNotifier {
  _GuideSamples(super.ref) {
    final t0 = NightFixtures.at(23, 40).toUtc();
    final random = math.Random(7);
    state = [
      for (var i = 0; i < 120; i++)
        NightGuideSample(
          t0.add(Duration(seconds: 3 * i)),
          (random.nextDouble() - 0.5) * 0.6,
          (random.nextDouble() - 0.5) * 0.5,
        ),
    ];
  }
}

/// Every provider the screen reads, for [state] with [tab] selected.
List<Override> nightScreenOverrides(
  NightScreenState state, {
  NightPanelTab tab = NightPanelTab.overview,
}) {
  final board = nightBoard(state);
  final running = state != NightScreenState.ready;
  final runState = switch (state) {
    NightScreenState.ready => SequenceExecutionState.idle,
    NightScreenState.running => SequenceExecutionState.running,
    NightScreenState.focus => SequenceExecutionState.paused,
  };
  final now = board.timeline?.now ?? NightFixtures.at(23, 52);
  return <Override>[
    nightPanelTabProvider.overrideWith((ref) => tab),
    clockProvider.overrideWithValue(const SystemClock()),
    nightNowProvider.overrideWithValue(now.toUtc()),

    // Header and plan column.
    nightRunPhaseProvider.overrideWithValue(board.phase),
    nightHeaderProvider.overrideWithValue(board.header),
    nightTimelineProvider.overrideWithValue(board.timeline),
    nightTargetProvider.overrideWithValue(board.target),
    nightPlanProgressProvider.overrideWithValue(board.plan),
    nightPlanStepsProvider.overrideWithValue(board.steps),
    nightUpcomingProvider.overrideWithValue(board.upcoming),

    // Center.
    nightSessionFramesProvider.overrideWithValue(board.frames),
    nightFrameSeriesProvider.overrideWithValue(board.frameSeries),
    nightGuideSeriesProvider.overrideWithValue(board.guideSeries),
    nightTemperatureSeriesProvider.overrideWithValue(board.temperatureSeries),
    nightCoolerHistoryProvider.overrideWithValue(
      running
          ? PanelFixtures.coolerHistory()
          : const NightSeriesVm(lines: <SeriesLineVm>[]),
    ),
    nightManualActionsProvider.overrideWithValue(board.actions),
    nightActionStateProvider.overrideWithValue(board.actionState),
    nightActionApiProvider.overrideWithValue(FakeNightActionApi()),
    nightStageImageProvider.overrideWithValue(running ? starField() : null),
    nightStageExposureProvider.overrideWithValue(
      state == NightScreenState.running
          ? const NightExposureVm(elapsed: 72, total: 180)
          : null,
    ),
    nightStageAutofocusProvider.overrideWithValue(
      state == NightScreenState.focus
          ? const NightAutofocusVm(point: 6, points: 9, hfr: 1.99)
          : null,
    ),
    nightStageSolveProvider.overrideWithValue(null),
    nightStageStretchProvider.overrideWithValue(false),
    nightLastSessionProvider.overrideWithValue(
      running
          ? null
          : NightLastSessionVm(
              startedAt: NightFixtures.at(19, 50).subtract(
                const Duration(days: 1),
              ),
              name: 'NGC 891',
              frames: 38,
              integrationSecs: 38 * 300,
              averageHfr: 2.21,
            ),
    ),
    nightLastAutofocusProvider.overrideWithValue(
      running
          ? null
          : const NightAutofocusCurveVm(
              points: <(int, double)>[
                (45184, 3.10),
                (45259, 2.62),
                (45334, 2.25),
                (45409, 2.04),
                (45484, 1.99),
                (45559, 2.08),
                (45634, 2.31),
              ],
              bestPosition: 45484,
              bestHfr: 1.99,
              temperature: 12,
            ),
    ),
    nightGuiderIdleProvider.overrideWithValue(
      const NightGuiderIdleVm(
        connected: true,
        canCommand: true,
        state: Phd2State.stopped,
      ),
    ),
    stretchedImageProvider.overrideWith((ref) async => null),
    isRemoteModeProvider.overrideWithValue(false),

    // Overview, Camera and Focus.
    nightLastFrameProvider.overrideWithValue(board.lastFrame),
    nightSessionStatsProvider.overrideWithValue(board.session),
    nightEquipmentProvider.overrideWithValue(board.equipment),
    nightConditionsProvider.overrideWithValue(board.conditions),
    nightLogProvider.overrideWithValue(board.log),
    nightBeforeYouStartProvider.overrideWithValue(board.checklist),
    nightCameraPanelProvider.overrideWithValue(
      running ? PanelFixtures.cameraRunning : PanelFixtures.cameraIdle,
    ),
    nightFocusPanelProvider.overrideWithValue(
      state == NightScreenState.focus
          ? PanelFixtures.focusRunning()
          : PanelFixtures.focusIdle,
    ),
    nightPanelOpsProvider.overrideWithValue(FakePanelOps()),
    nightFocusActiveProvider.overrideWithValue(state == NightScreenState.focus),
    nightGuideAlertProvider.overrideWithValue(false),

    // Mount, Guide and Solve.
    mountStateProvider.overrideWith(
      (ref) => scope.PanelMountNotifier(ref, scope.kTrackingMount),
    ),
    mountCapabilitiesProvider(scope.kMountId)
        .overrideWith((_) async => scope.kFullMount),
    nightActionInputsProvider.overrideWithValue(
      scope.panelInputs(runState: runState, hasFrame: running),
    ),
    nightCenterTargetProvider.overrideWithValue(
      const NightCenterTarget(name: 'M74', raHours: 1.611, decDegrees: 15.783),
    ),
    mountCommandServiceProvider.overrideWith(scope.RecordingMountCommands.new),
    guiderStateProvider.overrideWith(
      (ref) => _ConnectedGuider(ref, guiding: running),
    ),
    // Stopped, so the guide-star poll does not start in a widget test.
    phd2StateProvider.overrideWith((ref) => Phd2State.stopped),
    nightGuideSamplesProvider.overrideWith(_GuideSamples.new),
    sequenceExecutionStateProvider.overrideWith((ref) => runState),
  ];
}

/// A connected backend with nothing behind it. The shell reads the
/// checkpoint API on startup; that stays quiet.
MockBackend _quietBackend() {
  final backend = mockBackend();
  when(() => backend.sequencerSetCheckpointDir(any())).thenAnswer((_) async {});
  when(() => backend.hasCheckpoint()).thenAnswer((_) async => false);
  return backend;
}

class _StubBackendNotifier extends BackendNotifier {
  _StubBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

/// Settings with the navigation rail open or closed.
class _RailSettings extends AppSettingsNotifier {
  _RailSettings({required this.collapsed});
  final bool collapsed;

  @override
  Future<AppSettingsState> build() async =>
      AppSettingsState(sidebarCollapsed: collapsed);
}

/// The owner's window: a 1920 x 1080 panel at 125 %.
const Size kOwnerWindow = Size(1536, 864);

/// Pumps Tonight on `/dashboard` inside the real [AppShell] at [size], DPR 1,
/// under a [RepaintBoundary] keyed [boundaryKey] for a capture.
Future<void> pumpNightShell(
  WidgetTester tester, {
  required List<Override> overrides,
  required bool railCollapsed,
  Size size = kOwnerWindow,
  GlobalKey? boundaryKey,
}) async {
  final root = Directory.systemTemp.createTempSync('sk-night-shell-');
  addTearDown(() => root.deleteSync(recursive: true));
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    pathProvider,
    (call) async => root.path,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(pathProvider, null));
  // The desktop shell's window calls (close guard, title bar) have no host.
  const windowManager = MethodChannel('window_manager');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    windowManager,
    (call) async => null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(windowManager, null));

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);

  final router = GoRouter(
    initialLocation: kTonightRoutePath,
    routes: <RouteBase>[
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: <RouteBase>[
          GoRoute(
            path: kTonightRoutePath,
            builder: (context, state) => const NightControlScreen(),
          ),
          for (final path in const <String>[
            '/sequencer',
            '/settings',
            '/imaging',
            '/equipment',
          ])
            GoRoute(
              path: path,
              builder: (context, state) => Text(path),
            ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _StubBackendNotifier(ref, _quietBackend()),
        ),
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '0.0.0-test', buildNumber: 0),
        ),
        appSettingsProvider.overrideWith(
          () => _RailSettings(collapsed: railCollapsed),
        ),
        activeTransientAlertsProvider.overrideWith(
          (ref) => Stream.value(const <TransientAlert>[]),
        ),
        railWeatherUnsafeProvider.overrideWithValue(false),
        railAnyDeviceConnectedProvider.overrideWithValue(true),
        ...overrides,
      ],
      child: RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: SkotiqTheme.dark,
          localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
          supportedLocales: SkotiqLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    ),
  );
  // Past the brand splash: its draw runs on a timer, then it fades.
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  for (var i = 0;
      i < 80 &&
          container.read(skotiqSplashPhaseProvider) != SkotiqSplashPhase.done;
      i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(container.read(skotiqSplashPhaseProvider), SkotiqSplashPhase.done,
      reason: 'the splash still covers the shell');
  // A frame on the stage decodes on the engine, outside the fake clock.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Unmounts inside the test body so the timers the shell's providers
/// schedule on dispose can drain before the binding checks for leaks.
Future<void> unmountNightShell(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pump(const Duration(milliseconds: 10));
}
