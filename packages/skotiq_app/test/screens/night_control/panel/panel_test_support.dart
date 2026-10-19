// Shared setup for the right-panel widget tests: view-model fixtures for the
// Camera and Focus tabs (the board values), fakes for the panel's device
// commands and the action controller, and a pump that overrides every
// provider the panel reads.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/before_you_start_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/conditions_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/equipment_summary_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/last_frame_metrics_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/night_log_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_events_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_stats_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/camera/camera_panel_vm.dart';
import 'package:skotiq_app/screens/night_control/panel/focus/focus_panel_vm.dart';
import 'package:skotiq_app/screens/night_control/panel/night_right_panel.dart';
import 'package:skotiq_app/screens/night_control/panel/panel_ops.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../fixtures/night_fixtures.dart';

/// Records every command instead of reaching a device.
class FakePanelOps implements NightPanelOps {
  final List<String> calls = <String>[];
  ExposureSettings? lastExposure;
  Object? failWith;

  Future<void> _record(String call) async {
    calls.add(call);
    if (failWith != null) throw failWith!;
  }

  @override
  Future<void> setCoolerSetpoint(double targetTemp) =>
      _record('setpoint $targetTemp');

  @override
  Future<void> warmUpCamera() => _record('warmUp');

  @override
  Future<void> coolerOff() => _record('coolerOff');

  @override
  void updateManualExposure(ExposureSettings settings) {
    calls.add('exposure');
    lastExposure = settings;
  }

  @override
  Future<void> setFilterSlot(int slot) => _record('filter $slot');

  @override
  Future<void> moveFocuserBy(int steps) => _record('jog $steps');

  @override
  Future<void> moveFocuserTo(int position) => _record('goTo $position');

  @override
  Future<void> haltFocuser() => _record('halt');

  @override
  Future<void> cancelAutofocus() => _record('cancelAutofocus');

  @override
  Future<void> startGuiderLoop() => _record('guiderLoop');
}

/// The action controller's surface, recording what the panel asks of it.
class FakeActionApi implements NightActionApi {
  final List<String> calls = <String>[];

  @override
  ManualActionState get state => ManualActionState.idle;

  @override
  Future<void> run(ManualActionId id) async => calls.add('run ${id.name}');

  @override
  Future<void> cancel() async => calls.add('cancel');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The Camera tab's view models.
abstract final class PanelFixtures {
  static const List<String> slots = <String>[
    'L',
    'R',
    'G',
    'B',
    'Ha',
    'SII',
    'OIII',
    'Dark',
  ];

  static const NightFilterSlotsVm wheel = NightFilterSlotsVm(
    connected: true,
    names: slots,
    current: 4,
    offsets: <String, int>{'L': 0, 'Ha': 40},
    referenceFilter: 'L',
  );

  /// TonightCamera.dc.html: the run is on step 7, Ha 180 s.
  static const NightCameraPanelVm cameraRunning = NightCameraPanelVm(
    canCommand: true,
    runLive: true,
    connected: true,
    deviceName: 'ASI1600MM',
    coolerState: NightCoolerState.atSetpoint,
    sensorTemp: -10,
    setpoint: -10,
    coolerPower: 20,
    defaultSetpoint: -10,
    step: NightCaptureValues(
      exposureSecs: 180,
      gain: 139,
      offset: 21,
      frameType: FrameType.light,
      binning: 1,
      filter: 'Ha',
    ),
    stepNodeId: 'step-7',
    stepLabel: 'Ha 60 × 180 s',
    stepIndex: 7,
    filters: wheel,
    sensorSpecs: '4656 × 3520 · 3.80 µm',
    savesTo: '/data/Skotiq/M74/Ha',
    diskFreeBytes: 639 * 1024 * 1024 * 1024,
    nightsOfSpace: 11,
  );

  /// No run: the manual settings drive the fields.
  static const NightCameraPanelVm cameraIdle = NightCameraPanelVm(
    canCommand: true,
    runLive: false,
    connected: true,
    deviceName: 'ASI1600MM',
    coolerState: NightCoolerState.cooling,
    sensorTemp: -7.4,
    setpoint: -10,
    coolerPower: 64,
    defaultSetpoint: -10,
    manual: ExposureSettings(exposureTime: 5, gain: 139, offset: 21),
    filters: NightFilterSlotsVm(
      connected: true,
      names: slots,
      current: 0,
      offsets: <String, int>{'L': 0, 'Ha': 40},
      referenceFilter: 'L',
    ),
    sensorSpecs: '4656 × 3520 · 3.80 µm',
    savesTo: '/data/Skotiq',
    diskFreeBytes: 639 * 1024 * 1024 * 1024,
  );

  static const NightCameraPanelVm cameraDisconnected = NightCameraPanelVm(
    canCommand: true,
    runLive: false,
    connected: false,
    coolerState: NightCoolerState.notConnected,
    manual: ExposureSettings(exposureTime: 5, gain: 139, offset: 21),
    filters: NightFilterSlotsVm(connected: false),
  );

  /// Sensor readings from 19:20, ramping to −10 and holding.
  static NightSeriesVm coolerHistory() {
    final from = NightFixtures.at(19, 20);
    return NightSeriesVm(
      lines: <SeriesLineVm>[
        SeriesLineVm(
          id: NightSeriesId.sensorTemp,
          tone: SeriesTone.secondary,
          points: <SeriesPoint>[
            for (var m = 0; m <= 60; m += 5)
              SeriesPoint(
                from.add(Duration(minutes: m)),
                m < 15 ? 12 - 22 * m / 15 : -10,
              ),
          ],
        ),
      ],
      from: from,
      to: from.add(const Duration(minutes: 60)),
    );
  }

  static const List<VCurvePoint> sixPoints = <VCurvePoint>[
    VCurvePoint(position: 45184, hfr: 3.10),
    VCurvePoint(position: 45259, hfr: 2.62),
    VCurvePoint(position: 45334, hfr: 2.25),
    VCurvePoint(position: 45409, hfr: 2.04),
    VCurvePoint(position: 45484, hfr: 1.99),
    VCurvePoint(position: 45559, hfr: 2.08),
  ];

  /// TonightFocus.dc.html: the operator's autofocus at point 6 of 9.
  static NightFocusPanelVm focusRunning({
    bool startedHere = true,
    List<int?>? starCounts,
  }) =>
      NightFocusPanelVm(
        canCommand: true,
        runLive: true,
        status: NightAutofocusStatus.running,
        point: 6,
        totalPoints: 9,
        points: sixPoints,
        starCounts: starCounts,
        startedHere: startedHere,
        focuserConnected: true,
        focuserName: 'EAF',
        position: 45559,
        maxPosition: 600000,
        focuserTemp: 12,
        focuserMoving: true,
        tempComp: const NightTempCompVm(
          coefficient: -18,
          referenceTemp: 13.1,
          movedSince: 20,
        ),
        recentRuns: <NightAutofocusRun>[
          NightAutofocusRun(
            at: NightFixtures.at(23, 10),
            position: 45484,
            hfr: 1.98,
            duration: const Duration(minutes: 2, seconds: 40),
          ),
          NightAutofocusRun(
            at: NightFixtures.at(21, 40),
            position: 45502,
            hfr: 2.02,
          ),
        ],
      );

  /// No run, no autofocus, compensation off.
  static const NightFocusPanelVm focusIdle = NightFocusPanelVm(
    canCommand: true,
    runLive: false,
    status: NightAutofocusStatus.idle,
    focuserConnected: true,
    focuserName: 'EAF',
    position: 45484,
    maxPosition: 600000,
    focuserTemp: 12,
  );
}

/// The tab body P7 will supply, for the panel tests.
class StubTab extends StatelessWidget {
  const StubTab(this.name, {super.key});

  final String name;

  @override
  Widget build(BuildContext context) => Center(child: Text('$name body'));
}

/// Every override the panel reads, from [board] plus the Camera and Focus
/// view models.
List<Override> panelOverrides({
  required NightBoard board,
  NightCameraPanelVm camera = PanelFixtures.cameraRunning,
  NightFocusPanelVm? focus,
  NightSeriesVm? coolerHistory,
  NightConditionsVm? conditions,
  FakePanelOps? ops,
  FakeActionApi? api,
  bool focusActive = false,
  bool guideAlert = false,
}) =>
    <Override>[
      nightRunPhaseProvider.overrideWithValue(board.phase),
      nightHeaderProvider.overrideWithValue(board.header),
      nightLastFrameProvider.overrideWithValue(board.lastFrame),
      nightSessionStatsProvider.overrideWithValue(board.session),
      nightEquipmentProvider.overrideWithValue(board.equipment),
      nightConditionsProvider.overrideWithValue(
        conditions ?? board.conditions,
      ),
      nightLogProvider.overrideWithValue(board.log),
      nightBeforeYouStartProvider.overrideWithValue(board.checklist),
      nightManualActionsProvider.overrideWithValue(board.actions),
      nightActionStateProvider.overrideWithValue(board.actionState),
      nightActionApiProvider.overrideWithValue(api ?? FakeActionApi()),
      nightCameraPanelProvider.overrideWithValue(camera),
      nightCoolerHistoryProvider.overrideWithValue(
        coolerHistory ?? PanelFixtures.coolerHistory(),
      ),
      nightFocusPanelProvider.overrideWithValue(
        focus ?? PanelFixtures.focusRunning(),
      ),
      nightPanelOpsProvider.overrideWithValue(ops ?? FakePanelOps()),
      nightFocusActiveProvider.overrideWithValue(focusActive),
      nightGuideAlertProvider.overrideWithValue(guideAlert),
    ];

/// Pumps [child] at the panel's size (300 × 758 by default) inside a router,
/// so a navigation lands on a stub page whose path the test can read.
Future<GoRouter> pumpPanel(
  WidgetTester tester, {
  required Widget child,
  required List<Override> overrides,
  Size size = const Size(300, 758),
  ThemeData? theme,
  ProviderContainer? container,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(body: child),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const Scaffold(body: Text('settings')),
      ),
      GoRoute(
        path: '/sequencer',
        builder: (context, state) => const Scaffold(body: Text('sequencer')),
      ),
    ],
  );
  addTearDown(router.dispose);
  final app = MaterialApp.router(
    theme: theme ?? SkotiqTheme.dark,
    localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
    supportedLocales: SkotiqLocalizations.supportedLocales,
    routerConfig: router,
  );
  await tester.pumpWidget(
    container == null
        ? ProviderScope(overrides: overrides, child: app)
        : UncontrolledProviderScope(container: container, child: app),
  );
  await tester.pump();
  return router;
}

/// The location the router is on.
String routerLocation(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

/// Lets a toast's timers run out so the test ends with none pending.
Future<void> settleToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
}
