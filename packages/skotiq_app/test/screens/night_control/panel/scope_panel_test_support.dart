// Shared fixtures for the Mount, Guide and Solve tab tests: a 300 x 758
// panel host, a recording action API and the action-bar inputs.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/models/command_action_result.dart';
import 'package:skotiq_app/screens/night_control/actions/manual_action_gating.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

/// The right panel's size at the owner's window.
const Size kPanelSize = Size(300, 758);

const String kMountId = 'mount-1';

/// A fixed "now" so the LST and countdown readouts do not tick.
final DateTime kPanelNow = DateTime.utc(2026, 10, 19, 4, 30);

/// The action-bar inputs with a connected rig and nothing in flight.
NightActionInputs panelInputs({
  bool canCommand = true,
  SequenceExecutionState runState = SequenceExecutionState.idle,
  ManualActionState action = ManualActionState.idle,
  bool cameraConnected = true,
  bool mountConnected = true,
  bool guiderConnected = true,
  bool isGuiding = false,
  bool mountParked = false,
  bool mountTracking = true,
  bool hasTarget = true,
  bool hasFrame = false,
}) =>
    NightActionInputs(
      canCommand: canCommand,
      runState: runState,
      action: action,
      cameraConnected: cameraConnected,
      mountConnected: mountConnected,
      focuserConnected: true,
      guiderConnected: guiderConnected,
      isGuiding: isGuiding,
      mountParked: mountParked,
      mountTracking: mountTracking,
      hasTarget: hasTarget,
      hasFrame: hasFrame,
      targetName: hasTarget ? 'M74' : null,
    );

/// Every mount capability the tabs ask about.
const MountCapabilities kFullMount = MountCapabilities(
  canSlew: true,
  canSlewAsync: true,
  canSync: true,
  canPark: true,
  canUnpark: true,
  canFindHome: true,
  canSetTracking: true,
  canSetTrackingRate: true,
  supportedTrackingRates: [
    TrackingRate.sidereal,
    TrackingRate.lunar,
    TrackingRate.solar,
  ],
  canAbortSlew: true,
  canMoveAxis: true,
  canPulseGuide: true,
  maxSlewRate: 4.0,
);

/// A mount that is connected, unparked and tracking at sidereal.
const MountState kTrackingMount = MountState(
  connectionState: DeviceConnectionState.connected,
  deviceId: kMountId,
  deviceName: 'NYX-101',
  ra: 1.6328,
  dec: 15.911,
  altitude: 62.8,
  azimuth: 171.2,
  isTracking: true,
  isParked: false,
  sideOfPier: 'West',
  canSetTrackingRate: true,
);

class PanelMountNotifier extends MountStateNotifier {
  PanelMountNotifier(super.ref, MountState initial) {
    state = initial;
  }

  void put(MountState next) => state = next;
}

/// Records what the tabs ask of the action controller.
class RecordingActionApi implements NightActionApi {
  final List<String> calls = [];

  @override
  ManualActionState get state => ManualActionState.idle;

  @override
  DateTime? get armedStartAt => null;

  Future<void> _record(String name) async => calls.add(name);

  @override
  Future<void> run(ManualActionId id) => _record('run:${id.name}');
  @override
  Future<void> snapshot() => _record('snapshot');
  @override
  Future<void> toggleLoop() => _record('toggleLoop');
  @override
  Future<void> autofocus() => _record('autofocus');
  @override
  Future<void> solve() => _record('solve');
  @override
  Future<void> solveAndSync() => _record('solveAndSync');
  @override
  Future<void> center() => _record('center');
  @override
  Future<void> dither() => _record('dither');
  @override
  Future<void> flipNow() => _record('flipNow');
  @override
  Future<void> toggleTracking() => _record('toggleTracking');
  @override
  Future<void> toggleCooler() => _record('toggleCooler');
  @override
  Future<void> cancel() => _record('cancel');
  @override
  Future<void> armStartAtDark() => _record('armStartAtDark');
  @override
  void cancelArmedStart() => calls.add('cancelArmedStart');
}

class _NoBackend implements DeviceBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '${invocation.memberName} not used in this test');
}

class _NoDeviceService implements DeviceService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '${invocation.memberName} not used in this test');
}

/// Records mount commands instead of sending them.
class RecordingMountCommands extends MountCommandService {
  RecordingMountCommands(super.ref)
      : super(backend: _NoBackend(), deviceService: _NoDeviceService());

  final List<String> calls = [];

  Future<CommandActionResult> _ok(String name) async {
    calls.add(name);
    return CommandActionResult.ok;
  }

  @override
  Future<CommandActionResult> park() => _ok('park');
  @override
  Future<CommandActionResult> unpark() => _ok('unpark');
  @override
  Future<CommandActionResult> togglePark() => _ok('togglePark');
  @override
  Future<CommandActionResult> findHome() => _ok('findHome');
  @override
  Future<CommandActionResult> setTracking(bool enabled) =>
      _ok('setTracking:$enabled');
  @override
  Future<CommandActionResult> setTrackingRate(TrackingRate rate) =>
      _ok('setTrackingRate:${rate.name}');
  @override
  Future<CommandActionResult> slewTo(double ra, double dec,
          {bool showFeedback = true}) =>
      _ok('slewTo');
  @override
  Future<CommandActionResult> sync(double ra, double dec) => _ok('sync');
  @override
  Future<CommandActionResult> abortSlew({bool showFeedback = true}) =>
      _ok('abortSlew');
}

/// The overrides every tab test shares.
List<Override> panelOverrides({
  MountState mount = kTrackingMount,
  MountCapabilities? capabilities = kFullMount,
  NightActionInputs? inputs,
  RecordingActionApi? api,
  ManualActionState action = ManualActionState.idle,
}) =>
    [
      mountStateProvider.overrideWith((ref) => PanelMountNotifier(ref, mount)),
      mountCapabilitiesProvider(kMountId)
          .overrideWith((_) async => capabilities),
      nightActionInputsProvider.overrideWithValue(inputs ?? panelInputs()),
      nightActionApiProvider.overrideWithValue(api ?? RecordingActionApi()),
      nightActionStateProvider.overrideWithValue(action),
      nightCenterTargetProvider.overrideWithValue(null),
      nightNowProvider.overrideWithValue(kPanelNow),
      mountCommandServiceProvider.overrideWith(RecordingMountCommands.new),
    ];

/// Pumps [tab] in a 300 x 758 panel, optionally at [textScale].
Future<HarnessHandle> pumpPanelTab(
  WidgetTester tester,
  Widget tab, {
  List<Override> overrides = const [],
  double textScale = 1.0,
}) async {
  final handle = await pumpAppScreen(
    tester,
    Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(size: kPanelSize, child: tab),
        ),
      ),
    ),
    size: const Size(1280, 800),
    extraOverrides: overrides,
  );
  await tester.pump(const Duration(milliseconds: 50));
  return handle;
}

/// Fails on any exception the layout threw (an overflow among them).
void expectCleanLayout(WidgetTester tester) {
  final error = tester.takeException();
  expect(error, isNull, reason: 'the tab threw while laying out: $error');
}

/// The tooltip message of the panel button with [key].
String? tooltipOf(WidgetTester tester, Key key) {
  final tooltip = tester.widget<Tooltip>(
    find.descendant(of: find.byKey(key), matching: find.byType(Tooltip)).first,
  );
  return tooltip.message;
}

/// Whether the button with [key] would act on a tap.
bool isEnabled(WidgetTester tester, Key key) {
  final button = tester.widget(
    find.descendant(of: find.byKey(key), matching: find.byType(SkotiqButton)),
  ) as SkotiqButton;
  return button.onPressed != null;
}
