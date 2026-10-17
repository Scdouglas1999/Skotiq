// The jog pad must SLEW while held, not fire a single pulse guide on tap: a
// pulse is about four arcseconds at guide rate, invisible on the RA/Dec
// readout, and a 2 s press-and-hold produces exactly one.
//
// These tests drive the real MountControlCard with pointer down/up gestures and
// assert on the backend calls, so restoring pulseGuide-on-tap fails them.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/models/command_action_result.dart';
import 'package:skotiq_app/screens/dashboard/widgets/mount_control_card.dart';
import 'package:skotiq_app/screens/dashboard/widgets/mount_jog.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

const _mountId = 'simulator:mount:0';

class _ConnectedMountNotifier extends MountStateNotifier {
  _ConnectedMountNotifier(super.ref, {bool parked = false}) {
    // ignore: invalid_use_of_protected_member
    state = MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _mountId,
      deviceName: 'Simulated Mount',
      isParked: parked,
      isTracking: !parked,
      trackingRate: TrackingRate.sidereal,
      canSetTrackingRate: true,
    );
  }

  /// Drop the connection, which is what removes the jog pad from the card while
  /// the rest of the app (and its providers) keep running.
  void goOffline() {
    // ignore: invalid_use_of_protected_member
    state = const MountState(
      connectionState: DeviceConnectionState.disconnected,
    );
  }
}

/// Records the axis traffic the pad produces. Everything else on the backend
/// contract is irrelevant here and throws loudly if reached.
class _RecordingBackend implements DeviceBackend {
  final List<({String deviceId, int axis, double rate})> moveAxisCalls = [];

  @override
  Future<void> mountMoveAxis(String deviceId, int axis, double rate) async {
    // Recorded, not asserted: this can run from an async continuation outside
    // the test's expect zone, where a matcher throws "Guarded function
    // conflict" instead of failing the test.
    moveAxisCalls.add((deviceId: deviceId, axis: axis, rate: rate));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '${invocation.memberName} not used in this test');
}

class _NoDeviceService implements DeviceService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '${invocation.memberName} not used in this test');
}

/// Records the guide pulses the pulse-fallback issues.
class _RecordingMountCommands extends MountCommandService {
  _RecordingMountCommands(super.ref, DeviceBackend backend)
      : super(backend: backend, deviceService: _NoDeviceService());

  final List<({String direction, int durationMs})> pulseCalls = [];

  @override
  Future<CommandActionResult> pulseGuide(
    String direction, {
    int durationMs = 500,
  }) async {
    pulseCalls.add((direction: direction, durationMs: durationMs));
    return CommandActionResult.ok;
  }
}

class _Recorders {
  _Recorders(this.backend, this.commands, this.container);
  final _RecordingBackend backend;
  final _RecordingMountCommands commands;
  final ProviderContainer container;

  List<({String deviceId, int axis, double rate})> get moveAxisCalls =>
      backend.moveAxisCalls;
  List<({String direction, int durationMs})> get pulseCalls =>
      commands.pulseCalls;
}

Future<_Recorders> _pump(
  WidgetTester tester,
  MountCapabilities? capabilities, {
  bool parked = false,
}) async {
  final backend = _RecordingBackend();
  final handle = await pumpAppScreen(
    tester,
    const SizedBox(
      width: 420,
      child: MountControlCard(colors: SkotiqColors.dark),
    ),
    extraOverrides: [
      mountStateProvider
          .overrideWith((ref) => _ConnectedMountNotifier(ref, parked: parked)),
      mountCapabilitiesProvider(_mountId)
          .overrideWith((_) async => capabilities),
      deviceBackendProvider.overrideWithValue(backend),
      mountCommandServiceProvider
          .overrideWith((ref) => _RecordingMountCommands(ref, backend)),
    ],
    settle: false,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  return _Recorders(
    backend,
    handle.container.read(mountCommandServiceProvider)
        as _RecordingMountCommands,
    handle.container,
  );
}

/// The east arrow, which the audit pressed.
Finder get _eastButton => find.byKey(mountJogButtonKey('east'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const slewCapable = MountCapabilities(
    canMoveAxis: true,
    canPulseGuide: true,
    maxSlewRate: 4.0,
  );

  testWidgets('holding an arrow slews the axis and releasing stops it',
      (tester) async {
    final backend = await _pump(tester, slewCapable);

    final gesture = await tester.startGesture(tester.getCenter(_eastButton));
    await tester.pump(const Duration(milliseconds: 50));

    expect(backend.pulseCalls, isEmpty,
        reason: 'an arrow pad must slew, not fire a guide pulse');
    expect(backend.moveAxisCalls, hasLength(1));
    expect(backend.moveAxisCalls.single.deviceId, _mountId);
    // East is the primary axis in the positive direction.
    expect(backend.moveAxisCalls.single.axis, 0);
    expect(backend.moveAxisCalls.single.rate, greaterThan(0));

    // Still moving two seconds in: a single 500 ms pulse would be long over.
    await tester.pump(const Duration(seconds: 2));
    expect(backend.moveAxisCalls, hasLength(1));

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));

    expect(backend.moveAxisCalls, hasLength(2));
    expect(backend.moveAxisCalls.last.axis, 0);
    expect(backend.moveAxisCalls.last.rate, 0.0,
        reason: 'releasing must stop the axis');
  });

  testWidgets('the jog speed selector is what sets the slew rate',
      (tester) async {
    final backend = await _pump(tester, slewCapable);

    // Default is the centring speed.
    expect(find.textContaining('8x'), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<MountJogRate>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('64x').last);
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(_eastButton));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      backend.moveAxisCalls.first.rate,
      closeTo(64 * kSiderealDegPerSec, 1e-9),
    );
  });

  testWidgets('north and south drive the secondary axis with opposite signs',
      (tester) async {
    final backend = await _pump(tester, slewCapable);

    var gesture = await tester
        .startGesture(tester.getCenter(find.byKey(mountJogButtonKey('north'))));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 20));

    gesture = await tester
        .startGesture(tester.getCenter(find.byKey(mountJogButtonKey('south'))));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 20));

    expect(backend.moveAxisCalls[0].axis, 1);
    expect(backend.moveAxisCalls[0].rate, greaterThan(0));
    expect(backend.moveAxisCalls[1].rate, 0.0);
    expect(backend.moveAxisCalls[2].axis, 1);
    expect(backend.moveAxisCalls[2].rate, lessThan(0));
    expect(backend.moveAxisCalls[3].rate, 0.0);
  });

  testWidgets('a held jog is stopped by the watchdog rather than running on',
      (tester) async {
    final backend = await _pump(tester, slewCapable);

    final gesture = await tester.startGesture(tester.getCenter(_eastButton));
    await tester.pump(const Duration(milliseconds: 50));
    expect(backend.moveAxisCalls, hasLength(1));

    await tester.pump(kMountJogMaxHold + const Duration(seconds: 1));
    await tester.pump();

    expect(backend.moveAxisCalls.last.rate, 0.0,
        reason: 'a MoveAxis with no matching stop drives into the pier');

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('tearing the card down mid-press still stops the axis',
      (tester) async {
    final backend = await _pump(tester, slewCapable);

    await tester.startGesture(tester.getCenter(_eastButton));
    await tester.pump(const Duration(milliseconds: 50));
    expect(backend.moveAxisCalls, hasLength(1));

    // The pad leaving the tree (here: the mount dropping its connection, but
    // equally a layout change or a navigation) must not leave the axis running.
    (backend.container.read(mountStateProvider.notifier)
            as _ConnectedMountNotifier)
        .goOffline();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(backend.moveAxisCalls.last.rate, 0.0);
  });

  testWidgets('a mount with no MoveAxis repeats guide pulses and says so',
      (tester) async {
    final backend = await _pump(
      tester,
      const MountCapabilities(
        canPulseGuide: true,
        minPulseGuideMs: 1.0,
        maxPulseGuideMs: 8000.0,
      ),
    );

    expect(
      find.textContaining('Guide pulses'),
      findsOneWidget,
      reason: 'a pad that guide-pulses must not look like a slew pad',
    );
    expect(find.byType(DropdownButton<MountJogRate>), findsNothing);

    final gesture = await tester.startGesture(tester.getCenter(_eastButton));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 600));

    expect(backend.moveAxisCalls, isEmpty);
    expect(
      backend.pulseCalls.length,
      greaterThan(1),
      reason: 'holding must keep pulsing, not fire once and stop',
    );
    expect(backend.pulseCalls.first.direction, 'east');

    // ...and releasing must actually end the train.
    final afterRelease = backend.pulseCalls.length;
    await tester.pump(const Duration(milliseconds: 1200));
    expect(backend.pulseCalls.length, afterRelease);
  });

  testWidgets('a screen-reader tap jogs and then stops on its own',
      (tester) async {
    // Assistive tech cannot hold a button down, so the semantics tap action has
    // to perform a bounded nudge — including its own release.
    final semantics = tester.ensureSemantics();
    final backend = await _pump(tester, slewCapable);

    final node = tester.getSemantics(find.bySemanticsLabel('Jog E'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    // RendererBinding.rootPipelineOwner exposes no semanticsOwner to drive an
    // action through on the Flutter version this repo pins.
    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.tap,
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(backend.moveAxisCalls, hasLength(1));
    expect(backend.moveAxisCalls.single.rate, greaterThan(0));

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(backend.moveAxisCalls, hasLength(2));
    expect(backend.moveAxisCalls.last.rate, 0.0);

    semantics.dispose();
  });

  testWidgets('a mount that can do neither disables the pad and explains',
      (tester) async {
    final backend = await _pump(tester, const MountCapabilities());

    expect(
      find.textContaining('neither axis slewing nor guide pulses'),
      findsOneWidget,
    );

    final gesture = await tester.startGesture(tester.getCenter(_eastButton));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));

    expect(backend.moveAxisCalls, isEmpty);
    expect(backend.pulseCalls, isEmpty);
  });

  // A parked mount refuses every move command, so the pad is gated off — and
  // says so. Being inert is correct; being inert and mute (identical pixels, no
  // tooltip change, no toast, no log line) is the defect.
  group('parked mount', () {
    testWidgets('says why the arrows are inert instead of looking live',
        (tester) async {
      await _pump(tester, slewCapable, parked: true);

      expect(find.text('Mount is parked — unpark first.'), findsOneWidget,
          reason: 'the pad must state the reason it cannot move');

      final tooltip = tester.widget<Tooltip>(_eastButton);
      expect(tooltip.message, 'Mount is parked — unpark first.',
          reason: 'a "Hold to slew E" tooltip over an inert arrow is a lie');

      // The whole pad dims, not just the icon colour: textPrimary -> textMuted
      // is not readable as "disabled" on the dark theme.
      final veil = tester.widget<Opacity>(find.byKey(mountJogDisabledVeilKey));
      expect(veil.opacity, lessThan(1.0));
    });

    testWidgets('answers a press instead of swallowing it', (tester) async {
      final backend = await _pump(tester, slewCapable, parked: true);

      final gesture = await tester.startGesture(tester.getCenter(_eastButton));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pump();

      expect(backend.moveAxisCalls, isEmpty,
          reason: 'a parked mount must not be commanded to move');
      expect(backend.pulseCalls, isEmpty);
      expect(find.text('Mount is parked — unpark first.'), findsWidgets,
          reason: 'the press must surface the reason, not vanish');
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('unparking restores the live pad', (tester) async {
      final backend = await _pump(tester, slewCapable);

      expect(find.byKey(mountJogDisabledVeilKey), findsNothing);
      expect(find.text('Mount is parked — unpark first.'), findsNothing);

      final gesture = await tester.startGesture(tester.getCenter(_eastButton));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));

      expect(backend.moveAxisCalls, isNotEmpty);
    });
  });

  group('rate ladder', () {
    test('drops rates the driver cannot reach and offers its real maximum', () {
      final rates = mountJogRates(0.5);
      expect(rates.map((r) => r.label), ['1x', '8x', '64x', 'Max']);
      expect(rates.last.degPerSec, 0.5);
    });

    test('offers the full ladder when the driver reports no ceiling', () {
      expect(
        mountJogRates(null).map((r) => r.label),
        ['1x', '8x', '64x', '400x'],
      );
    });

    test('unknown capabilities fail closed rather than guessing', () {
      expect(mountJogModeFor(null), MountJogMode.unavailable);
    });
  });
}
