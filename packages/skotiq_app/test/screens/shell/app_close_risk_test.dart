import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_core/models.dart';

void main() {
  bool hasRisk({
    bool sequence = false,
    bool session = false,
    Phd2State guider = Phd2State.stopped,
    bool camera = false,
    bool mount = false,
    bool flats = false,
    bool autofocus = false,
  }) {
    return appCloseHasActiveOperations(
      sequenceOwnsHardware: sequence,
      sessionBusy: session,
      guider: guider,
      cameraBusy: camera,
      mountBusy: mount,
      flatWizardBusy: flats,
      autofocusBusy: autofocus,
    );
  }

  test('idle equipment does not require active-operation confirmation', () {
    expect(hasRisk(), isFalse);
  });

  test('every independently active operation requires confirmation', () {
    expect(hasRisk(sequence: true), isTrue);
    expect(hasRisk(session: true), isTrue);
    expect(hasRisk(camera: true), isTrue);
    expect(hasRisk(mount: true), isTrue);
    expect(hasRisk(flats: true), isTrue);
    expect(hasRisk(autofocus: true), isTrue);
  });

  test('a guide session started from any screen requires confirmation', () {
    for (final state in [
      Phd2State.calibrating,
      Phd2State.guiding,
      Phd2State.settling,
      Phd2State.paused,
      Phd2State.lostLock,
      Phd2State.unknown,
    ]) {
      expect(hasRisk(guider: state), isTrue, reason: state.name);
    }
    for (final state in [
      Phd2State.stopped,
      Phd2State.selected,
      Phd2State.looping,
    ]) {
      expect(hasRisk(guider: state), isFalse, reason: state.name);
    }
  });

  test('idle app never prompts regardless of preference availability', () {
    expect(
      appCloseShouldConfirm(
        hasActiveOperations: false,
        confirmBeforeClosing: true,
      ),
      isFalse,
    );
    expect(
      appCloseShouldConfirm(
        hasActiveOperations: false,
        confirmBeforeClosing: null,
      ),
      isFalse,
    );
  });

  test('only an authoritative opt-out bypasses an active-operation prompt', () {
    expect(
      appCloseShouldConfirm(
        hasActiveOperations: true,
        confirmBeforeClosing: false,
      ),
      isFalse,
    );
    expect(
      appCloseShouldConfirm(
        hasActiveOperations: true,
        confirmBeforeClosing: true,
      ),
      isTrue,
    );
    expect(
      appCloseShouldConfirm(
        hasActiveOperations: true,
        confirmBeforeClosing: null,
      ),
      isTrue,
      reason: 'Loading or failed settings must not masquerade as opt-out.',
    );
  });
}
