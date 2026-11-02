// "Cool to" named the cooler's live setpoint, so during and after a warm-up
// it read "Cool to -8°C" and cooled there (qa-pair QP-21). It names the
// cooling goal: the user's choice this session, else the profile's setpoint.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  ProviderContainer containerWith({double? profileTarget}) {
    final container = ProviderContainer(
      overrides: [
        activeEquipmentProfileProvider.overrideWithValue(
          EquipmentProfileModel(
            name: 'Sim Rig',
            defaultCoolingTemp: profileTarget,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    // A warm-up has stepped the live setpoint to -8.
    container.read(cameraStateProvider.notifier).setTargetTemp(-8);
    return container;
  }

  test('the profile setpoint, not the warm-up ramp', () {
    final container = containerWith(profileTarget: -10);
    expect(container.read(cameraCoolToTargetProvider), -10);
  });

  test("the user's own goal outranks the profile", () {
    final container = containerWith(profileTarget: -10);
    container.read(cameraCoolingGoalProvider.notifier).state = -15;
    expect(container.read(cameraCoolToTargetProvider), -15);
  });

  test('with no goal and no profile setpoint, the live setpoint', () {
    final container = containerWith();
    expect(container.read(cameraCoolToTargetProvider), -8);
  });
}
