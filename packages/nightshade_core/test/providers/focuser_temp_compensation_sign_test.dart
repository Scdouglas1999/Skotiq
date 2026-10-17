// Pins the continuous Dart focuser temperature-compensation sign convention
// to the executor-authoritative Rust instruction
// (`native/nightshade_native/sequencer/src/temperature_compensation.rs`),
// and verifies the Dart provider stands down while a sequence is running so
// the two compensators never fight over the focuser (P1: dual temp-comp sign
// clash + double-compensation).
//
// Rust authority:  new_position = current_position + (temp - baseline) * coeff
// Dart MUST match: target       = baseline_position + (temp - baseline) * coeff

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:nightshade_core/src/models/sequence/sequence_models.dart';
import 'package:nightshade_core/src/providers/equipment/focuser_state_provider.dart';
import 'package:nightshade_core/src/providers/equipment/focuser_temp_compensation_provider.dart';
import 'package:nightshade_core/src/providers/sequence/sequence_progress.dart';
import 'package:nightshade_core/src/providers/settings_provider.dart';
import 'package:nightshade_core/src/services/device_service.dart';

/// Hand-written fake (no codegen): captures focuser move targets and reports
/// no autofocus in flight. Extending [Mock] means the real (heavy)
/// DeviceService constructor never runs; the methods we care about are
/// overridden directly.
class _CapturingDeviceService extends Mock implements DeviceService {
  final List<int> moves = <int>[];

  @override
  bool get isAutofocusRunning => false;

  @override
  Future<void> moveFocuserTo(int position) async {
    moves.add(position);
  }
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

Future<ProviderContainer> _buildContainer({
  required double coefficient,
  required _CapturingDeviceService device,
  SequenceExecutionState sequenceState = SequenceExecutionState.idle,
}) async {
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(
        () => _FakeAppSettingsNotifier(
          AppSettingsState(
            tempCompensation: true,
            tempCoefficient: coefficient,
          ),
        ),
      ),
      deviceServiceProvider.overrideWithValue(device),
    ],
  );
  await container.read(appSettingsProvider.future);
  container.read(sequenceExecutionStateProvider.notifier).state = sequenceState;
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defers compensation until an existing focuser move finishes', () async {
    final device = _CapturingDeviceService();
    final container = await _buildContainer(coefficient: -12, device: device);
    addTearDown(container.dispose);
    container.read(focuserTempCompensationProvider);
    final focuser = container.read(focuserStateProvider.notifier);
    focuser.setConnecting('focuser-1');
    focuser.setConnected();
    focuser.updatePosition(5000);
    focuser.updateTemperature(15);
    focuser.setMoving(true);
    focuser.updateTemperature(14);
    await Future<void>.delayed(Duration.zero);
    focuser.updateTemperature(13);
    await Future<void>.delayed(Duration.zero);
    expect(device.moves, isEmpty);
    focuser.setMoving(false);
    await Future<void>.delayed(Duration.zero);
    expect(device.moves, [5024]);
  });

  group('FocuserTempCompensator sign convention (matches Rust executor)', () {
    test('negative coefficient + temperature DROP moves focuser OUTWARD '
        '(target > baseline), matching Rust current+delta*coeff', () async {
      final device = _CapturingDeviceService();
      final container = await _buildContainer(
        coefficient: -12.0,
        device: device,
      );
      addTearDown(container.dispose);
      container.read(focuserTempCompensationProvider);

      final focuser = container.read(focuserStateProvider.notifier);
      focuser.setConnecting('focuser-1');
      focuser.setConnected();
      focuser.updatePosition(5000);
      focuser.updateTemperature(15.0); // establishes baseline
      await Future<void>.delayed(Duration.zero);

      // Temperature drops 2°C: delta = (13 - 15) * (-12) = +24 steps.
      // Rust would compute new = 5000 + 24 = 5024. Dart MUST agree.
      focuser.updateTemperature(13.0);
      await Future<void>.delayed(Duration.zero);

      expect(
        device.moves,
        isNotEmpty,
        reason: 'a temperature change beyond 1 step should trigger a move',
      );
      expect(
        device.moves.single,
        5024,
        reason:
            'Dart must add the same delta the Rust executor adds; '
            'subtracting would move the focuser the wrong direction',
      );
    });

    test('negative coefficient + temperature RISE moves focuser INWARD '
        '(target < baseline)', () async {
      final device = _CapturingDeviceService();
      final container = await _buildContainer(
        coefficient: -12.0,
        device: device,
      );
      addTearDown(container.dispose);
      container.read(focuserTempCompensationProvider);

      final focuser = container.read(focuserStateProvider.notifier);
      focuser.setConnecting('focuser-1');
      focuser.setConnected();
      focuser.updatePosition(5000);
      focuser.updateTemperature(15.0);
      await Future<void>.delayed(Duration.zero);

      // Temperature rises 2°C: delta = (17 - 15) * (-12) = -24 steps.
      // new = 5000 + (-24) = 4976.
      focuser.updateTemperature(17.0);
      await Future<void>.delayed(Duration.zero);

      expect(device.moves.single, 4976);
    });

    test('positive coefficient inverts the direction symmetrically', () async {
      final device = _CapturingDeviceService();
      final container = await _buildContainer(
        coefficient: 10.0,
        device: device,
      );
      addTearDown(container.dispose);
      container.read(focuserTempCompensationProvider);

      final focuser = container.read(focuserStateProvider.notifier);
      focuser.setConnecting('focuser-1');
      focuser.setConnected();
      focuser.updatePosition(8000);
      focuser.updateTemperature(10.0);
      await Future<void>.delayed(Duration.zero);

      // delta = (8 - 10) * 10 = -20 → new = 8000 - 20 = 7980.
      focuser.updateTemperature(8.0);
      await Future<void>.delayed(Duration.zero);

      expect(device.moves.single, 7980);
    });

    test(
      'baseline advances to the applied move so deltas do not double-count',
      () async {
        final device = _CapturingDeviceService();
        final container = await _buildContainer(
          coefficient: -12.0,
          device: device,
        );
        addTearDown(container.dispose);
        container.read(focuserTempCompensationProvider);

        final focuser = container.read(focuserStateProvider.notifier);
        focuser.setConnecting('focuser-1');
        focuser.setConnected();
        focuser.updatePosition(5000);
        focuser.updateTemperature(15.0);
        await Future<void>.delayed(Duration.zero);

        focuser.updateTemperature(13.0); // → 5024
        await Future<void>.delayed(Duration.zero);
        // Next step computed against the NEW baseline (13.0 / 5024), not 15.0.
        focuser.updateTemperature(12.0); // delta = (12-13)*-12 = +12 → 5036
        await Future<void>.delayed(Duration.zero);

        expect(device.moves, <int>[5024, 5036]);
      },
    );
  });

  group('FocuserTempCompensator stands down during a sequence', () {
    test('does not move the focuser while the sequencer is running '
        '(Rust instruction is authoritative)', () async {
      final device = _CapturingDeviceService();
      final container = await _buildContainer(
        coefficient: -12.0,
        device: device,
        sequenceState: SequenceExecutionState.running,
      );
      addTearDown(container.dispose);
      container.read(focuserTempCompensationProvider);

      final focuser = container.read(focuserStateProvider.notifier);
      focuser.setConnecting('focuser-1');
      focuser.setConnected();
      focuser.updatePosition(5000);
      focuser.updateTemperature(15.0);
      await Future<void>.delayed(Duration.zero);
      focuser.updateTemperature(10.0); // large drift
      await Future<void>.delayed(Duration.zero);

      expect(
        device.moves,
        isEmpty,
        reason:
            'while a sequence runs the Rust temperature_compensation '
            'instruction owns the focuser; the Dart provider must not '
            'also issue moves (double-compensation)',
      );
    });

    test(
      'resumes compensation once the sequence is no longer active',
      () async {
        final device = _CapturingDeviceService();
        final container = await _buildContainer(
          coefficient: -12.0,
          device: device,
          sequenceState: SequenceExecutionState.running,
        );
        addTearDown(container.dispose);
        container.read(focuserTempCompensationProvider);

        final focuser = container.read(focuserStateProvider.notifier);
        focuser.setConnecting('focuser-1');
        focuser.setConnected();
        focuser.updatePosition(5000);
        focuser.updateTemperature(
          15.0,
        ); // baseline captured even mid-sequence? No.
        await Future<void>.delayed(Duration.zero);
        expect(device.moves, isEmpty);

        // Sequence ends; the next temperature tick captures the baseline and
        // then compensates on the subsequent tick.
        container.read(sequenceExecutionStateProvider.notifier).state =
            SequenceExecutionState.completed;
        focuser.updateTemperature(15.0); // baseline (5000 / 15.0)
        await Future<void>.delayed(Duration.zero);
        focuser.updateTemperature(13.0); // delta = +24 → 5024
        await Future<void>.delayed(Duration.zero);

        expect(device.moves.single, 5024);
      },
    );
  });
}
