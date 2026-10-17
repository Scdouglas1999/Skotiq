// Widget tests for ConnectedDeviceCard "Rotate To Angle" range wiring (C11).
//
// Mirrors the imaging RotatorPanel range wiring (C10) for the equipment
// connected-device card. The rotate dialog's target-angle validation and the
// input hint must come from the rotator's reported RotatorCapabilities
// (min/maxAngleDeg) and fall back to a full 0..360 turn when those bounds are
// absent or degenerate (min >= max).
//
// Scope:
//   1. caps_window_honored — with minAngleDeg=0/maxAngleDeg=270, the hint
//      reflects the window, an in-range angle dispatches rotatorMoveTo, and an
//      out-of-range angle is rejected (no dispatch, dialog stays open).
//   2. null_caps_falls_back_to_full_turn — with null caps the hint and the
//      validation fall back to 0..360; 360 is accepted, 361 is rejected.
//   3. inverted_caps_range_falls_back — degenerate driver data (min >= max) is
//      treated as missing and uses the 0..360 window.
//
// We assert on the dispatched move via a stubbed backend.rotatorMoveTo (the
// card calls `ref.read(deviceBackendProvider).rotatorMoveTo` directly) and on
// the rendered hint text. Validation is pure and runs inside the dialog's
// Rotate button before any backend call, so these are direct, non-flaky
// checks of exactly the range behavior C11 owns.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'device_action_finder.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../harness/harness.dart';

const _kDeviceId = 'simulator:rotator:0';

/// A [RotatorStateNotifier] seeded to a connected, idle rotator so the card
/// renders the "Rotate to..." action and resolves capabilities for the
/// matching device id.
class _ConnectedRotatorNotifier extends RotatorStateNotifier {
  _ConnectedRotatorNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const RotatorState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _kDeviceId,
      deviceName: 'Simulated Rotator',
      position: 0,
    );
  }
}

List<Override> _overrides(RotatorCapabilities? caps) => [
      rotatorStateProvider.overrideWith(_ConnectedRotatorNotifier.new),
      equipmentRotatorCapabilitiesProvider(_kDeviceId)
          .overrideWith((ref) async => caps),
    ];

RotatorCapabilities _caps({double? minAngle, double? maxAngle}) =>
    RotatorCapabilities(
      canMoveAbsolute: true,
      minAngleDeg: minAngle,
      maxAngleDeg: maxAngle,
    );

/// Pumps the rotator card and drains the capability FutureProvider override so
/// the synchronous `valueOrNull` read inside `_showRotateDialog` sees the
/// resolved capabilities.
Future<HarnessHandle> _pumpCard(
  WidgetTester tester,
  RotatorCapabilities? caps,
) async {
  final backend = mockBackend();
  var commandedAngle = 0.0;
  when(() => backend.rotatorMoveTo(any(), any()))
      .thenAnswer((invocation) async {
    commandedAngle = invocation.positionalArguments[1] as double;
  });
  when(() => backend.getRotatorStatus(_kDeviceId)).thenAnswer(
    (_) async => RotatorStatus(
      connected: true,
      position: commandedAngle,
      moving: false,
      mechanicalPosition: commandedAngle,
      isMoving: false,
      canReverse: true,
    ),
  );

  final handle = await pumpAppScreen(
    tester,
    const ConnectedDeviceCard(type: ConnectedDeviceType.rotator),
    backend: backend,
    extraOverrides: _overrides(caps),
    settle: false,
  );
  // The card resolves capabilities lazily inside `_showRotateDialog` via a
  // synchronous `ref.read(...).valueOrNull` — nothing in the card's build
  // watches the FutureProvider, so without forcing it to resolve here the
  // read would see a still-pending (null) value. Await the provider through
  // the container so the dialog observes the resolved capabilities, exactly
  // as production does once the capability prefetch has settled.
  await handle.container.read(
    equipmentRotatorCapabilitiesProvider(_kDeviceId).future,
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  return handle;
}

/// Opens the rotate dialog, enters [value], and taps the dialog's Rotate
/// button, draining the resulting frames so the tree settles without tripping
/// a periodic-animation pumpAndSettle timeout.
Future<void> _rotateTo(WidgetTester tester, String value) async {
  await tapDeviceAction(tester, 'Rotate to…');
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.enterText(find.byType(TextField), value);
  await tester.pump();
  // The dialog action button is labeled 'Rotate' (distinct from the card's
  // 'Rotate to…' action).
  await tester.tap(find.text('Rotate'));
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Opens the rotate dialog without dispatching, returning so the caller can
/// assert on the rendered hint text.
Future<void> _openDialog(WidgetTester tester) async {
  await tapDeviceAction(tester, 'Rotate to…');
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _waitForDialogToClose(WidgetTester tester) async {
  for (var i = 0;
      i < 20 && find.text('Rotate To Angle').evaluate().isNotEmpty;
      i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'caps_window_honored: hint + validation use 0..270, in-range dispatches',
      (tester) async {
    final handle = await _pumpCard(tester, _caps(minAngle: 0, maxAngle: 270));
    final backend = handle.backend;

    // Hint reflects the caps-derived window.
    await _openDialog(tester);
    expect(find.text('Enter target angle (0 - 270 degrees):'), findsOneWidget,
        reason: 'The dialog hint must mirror the caps-derived range.');

    // In-range angle dispatches the move.
    await tester.enterText(find.byType(TextField), '200');
    await tester.pump();
    await tester.tap(find.text('Rotate'));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    verify(() => backend.rotatorMoveTo(_kDeviceId, 200)).called(1);
    await _waitForDialogToClose(tester);
    expect(find.text('Rotate To Angle'), findsNothing);
  });

  testWidgets('caps_window_honored: 300 rejected for 0..270 caps (no dispatch)',
      (tester) async {
    final handle = await _pumpCard(tester, _caps(minAngle: 0, maxAngle: 270));
    final backend = handle.backend;

    await _rotateTo(tester, '300');

    // The dialog rejects out-of-range input by not popping, so no move is
    // dispatched and the dialog hint is still on screen.
    verifyNever(() => backend.rotatorMoveTo(any(), any()));
    expect(find.text('Enter target angle (0 - 270 degrees):'), findsOneWidget,
        reason: 'A rejected angle must leave the dialog open.');
  });

  testWidgets(
      'null_caps_falls_back_to_full_turn: hint 0..360, 360 ok, 361 rejected',
      (tester) async {
    final handle = await _pumpCard(tester, _caps());
    final backend = handle.backend;

    await _openDialog(tester);
    expect(find.text('Enter target angle (0 - 360 degrees):'), findsOneWidget,
        reason: 'A null angle range must fall back to a 0..360 hint.');

    // 360 sits on the inclusive upper bound of the fallback window.
    await tester.enterText(find.byType(TextField), '360');
    await tester.pump();
    await tester.tap(find.text('Rotate'));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    verify(() => backend.rotatorMoveTo(_kDeviceId, 360)).called(1);
    await _waitForDialogToClose(tester);

    // 361 exceeds the fallback ceiling and must be rejected.
    await _rotateTo(tester, '361');
    verifyNever(() => backend.rotatorMoveTo(_kDeviceId, 361));
  });

  testWidgets('inverted_caps_range_falls_back: min>=max uses 0..360 window',
      (tester) async {
    final handle = await _pumpCard(tester, _caps(minAngle: 300, maxAngle: 100));
    final backend = handle.backend;

    await _openDialog(tester);
    expect(find.text('Enter target angle (0 - 360 degrees):'), findsOneWidget,
        reason: 'Inverted range must fall back to the 0..360 hint.');

    // 350 is valid under the 0..360 fallback (and out of the raw 100..300).
    await tester.enterText(find.byType(TextField), '350');
    await tester.pump();
    await tester.tap(find.text('Rotate'));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    verify(() => backend.rotatorMoveTo(_kDeviceId, 350)).called(1);
    await _waitForDialogToClose(tester);
    expect(find.text('Rotate To Angle'), findsNothing);
  });
}
