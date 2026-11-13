// Temperature compensation on the owner's rig moved the focuser by one step
// every reading: a 0.1 °C probe at -12 steps/°C rounds to a step on every
// change, and the compensator then took a new reference, so the fraction was
// thrown away and noise walked the focuser back and forth. Reproduced on the
// simulator with a cooling night (6 °C/h, 30 s readings): +1 step every 30 s,
// 20 steps per °C instead of 12, and a focuser moved by hand to 25300 driven
// straight back to 25007, as an autofocus result would be.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:skotiq_core/src/providers/autofocus_progress_provider.dart';
import 'package:skotiq_core/src/providers/equipment/focuser_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/focuser_temp_compensation_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/device_service.dart';
import 'package:skotiq_core/src/settings/app_settings_state.g.dart';

/// Moves the simulated focuser where it is told, the way a real one reports
/// its arrival.
class _Device extends Mock implements DeviceService {
  _Device(this.arrive);
  final void Function(int position) arrive;
  final List<int> moves = <int>[];

  @override
  bool get isAutofocusRunning => false;

  @override
  Future<void> moveFocuserTo(int position) async {
    moves.add(position);
    arrive(position);
  }
}

class _Settings extends AppSettingsNotifier {
  _Settings(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

class _Overlay extends AutofocusOverlayNotifier {
  _Overlay(super.ref, {required bool running}) {
    if (running) onAutofocusStarted();
  }
}

class _Rig {
  _Rig(this.container, this.device);
  final ProviderContainer container;
  final _Device device;

  FocuserStateNotifier get focuser =>
      container.read(focuserStateProvider.notifier);

  Future<void> read(double temperature) async {
    focuser.updateTemperature(temperature);
    await Future<void>.delayed(Duration.zero);
  }
}

Future<_Rig> _rig({
  double coefficient = -12.0,
  int? minSteps,
  bool autofocusRunning = false,
}) async {
  late final ProviderContainer container;
  final device = _Device(
    (position) =>
        container.read(focuserStateProvider.notifier).updatePosition(position),
  );
  container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(
        () => _Settings(
          minSteps == null
              ? AppSettingsState(
                  tempCompensation: true,
                  tempCoefficient: coefficient,
                )
              : AppSettingsState(
                  tempCompensation: true,
                  tempCoefficient: coefficient,
                  tempCompensationMinSteps: minSteps,
                ),
        ),
      ),
      deviceServiceProvider.overrideWithValue(device),
      autofocusOverlayProvider.overrideWith(
        (ref) => _Overlay(ref, running: autofocusRunning),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(appSettingsProvider.future);
  container.read(focuserTempCompensationProvider);
  final rig = _Rig(container, device);
  rig.focuser
    ..setConnecting('focuser-1')
    ..setConnected()
    ..updatePosition(5000);
  await rig.read(15.0); // the reference: 5000 at 15.0 °C
  return rig;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the default smallest move is 5 steps', () {
    expect(const AppSettingsState().tempCompensationMinSteps, 5);
  });

  test('probe noise of a tenth of a degree never moves the focuser', () async {
    final rig = await _rig();
    for (final t in [15.1, 14.9, 15.0, 15.1, 14.9, 15.1, 15.0, 14.9]) {
      await rig.read(t);
    }
    expect(rig.device.moves, isEmpty);
  });

  test(
    'slow cooling moves in 5-step corrections that keep their fractions',
    () async {
      final rig = await _rig();
      // A cooling night read every 30 s: 0.05 °C per reading, one degree.
      for (var i = 1; i <= 20; i++) {
        await rig.read(15.0 - 0.05 * i);
      }
      // 0.05 °C is 0.6 steps: nothing moves until 5 steps are owed, and one
      // degree ends 12 steps out, not the 20 a step-per-reading made.
      expect(rig.device.moves, <int>[5005, 5010]);
      await rig.read(13.9); // 1.1 °C: 13 owed from 5000, 3 from 5010
      expect(rig.device.moves, <int>[5005, 5010]);
      await rig.read(13.5); // 1.5 °C: 18 → 5018
      expect(rig.device.moves.last, 5018);
    },
  );

  test('a move made by something else is kept, not undone', () async {
    final rig = await _rig();
    await rig.read(14.0); // +12 → 5012
    expect(rig.device.moves, <int>[5012]);

    // An autofocus lands the focuser at 6000.
    rig.focuser.updatePosition(6000);
    await rig.read(14.0);
    expect(rig.device.moves, <int>[5012], reason: 'no move back toward 5012');

    // Drift from here is measured from the new focus.
    await rig.read(13.5); // -0.5 °C → +6
    expect(rig.device.moves.last, 6006);
  });

  // Changing filter by hand between runs moves the focuser by the filters'
  // offset. That read as "something else moved the focuser", so the
  // reference was taken again and the correction still under the smallest
  // move was dropped at every change (the run's rule was fixed in 94b249898;
  // the app's idle copy was not).
  test('a filter focus offset keeps the correction owed', () async {
    final rig = await _rig();
    await rig.read(14.7); // 3.6 → 4 owed, under the smallest move
    expect(rig.device.moves, isEmpty);

    // What DeviceService does around an offset move of +30. The focuser's
    // readings during the move (its arrival included) are not judged.
    final idle = rig.container.read(idleFocusCompensationProvider);
    idle.beginOffsetMove();
    rig.focuser.updatePosition(5030);
    await Future<void>.delayed(Duration.zero);
    idle.endOffsetMove(appliedSteps: 30);
    await rig.read(14.75);
    expect(rig.device.moves, isEmpty, reason: 'still under 5 owed, from 5030');

    await rig.read(14.6); // 4.8 → 5 owed since the reference
    expect(rig.device.moves, <int>[5035]);
    expect(
      rig.container.read(focuserTempCompensationBaselineProvider)!.position,
      5030,
      reason: 'the reference moved with the offset and was not taken again',
    );
    expect(
      rig.container.read(focuserTempCompensationBaselineProvider)!.temperature,
      15.0,
    );
  });

  test('an offset move that failed leaves the judging to the next reading', () async {
    final rig = await _rig();
    final idle = rig.container.read(idleFocusCompensationProvider);
    idle.beginOffsetMove();
    rig.focuser.updatePosition(5017); // stalled part-way
    await Future<void>.delayed(Duration.zero);
    idle.endOffsetMove(appliedSteps: 0);

    await rig.read(14.9);
    expect(rig.device.moves, isEmpty);
    expect(
      rig.container.read(focuserTempCompensationBaselineProvider)!.position,
      5017,
      reason: 'the focuser is not where compensation left it: a new reference',
    );
  });

  test('nothing moves while an autofocus started elsewhere runs', () async {
    final rig = await _rig(autofocusRunning: true);
    await rig.read(10.0);
    expect(rig.device.moves, isEmpty);
  });

  test('the smallest move is the operator\'s setting', () async {
    final fine = await _rig(minSteps: 1);
    await fine.read(14.9); // 1.2 → 1 step
    expect(fine.device.moves, <int>[5001]);

    final coarse = await _rig(minSteps: 20);
    await coarse.read(14.0); // 12 owed
    expect(coarse.device.moves, isEmpty);
    await coarse.read(13.0); // 24 owed
    expect(coarse.device.moves, <int>[5024]);
  });
}
