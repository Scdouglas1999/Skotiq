import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/equipment/camera_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/focuser_state_provider.dart';
import 'package:skotiq_core/src/providers/focuser_backlash_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

import '../harness/in_memory_database.dart';
import 'fixtures.dart';

class _FixedFocuserState extends FocuserStateNotifier {
  _FixedFocuserState(super.ref, FocuserState initial) {
    state = initial;
  }
}

class _FixedCameraState extends CameraStateNotifier {
  _FixedCameraState(super.ref, CameraStateSnapshot initial) {
    state = initial;
  }
}

const _connectedFocuser = FocuserState(
  connectionState: DeviceConnectionState.connected,
  deviceId: 'zwo-eaf-1',
  deviceName: 'ZWO EAF',
  position: 6600,
);

const _connectedCamera = CameraStateSnapshot(
  connectionState: DeviceConnectionState.connected,
  deviceId: 'zwo-asi2600mm-1',
);

ProviderContainer makeContainer({
  FocuserState focuser = _connectedFocuser,
  CameraStateSnapshot camera = _connectedCamera,
}) {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      focuserStateProvider.overrideWith(
        (ref) => _FixedFocuserState(ref, focuser),
      ),
      cameraStateProvider.overrideWith((ref) => _FixedCameraState(ref, camera)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Let both asynchronous inputs the offer depends on settle.
Future<void> settle(ProviderContainer container) async {
  await container.read(appSettingsProvider.future);
  await container.read(savedFocuserBacklashProvider.future);
}

void main() {
  test('offers on a connected, uncalibrated focuser', () async {
    final container = makeContainer();
    await settle(container);

    expect(container.read(focuserBacklashOfferProvider), isTrue);
  });

  test('stays closed while the stored state is still loading', () async {
    // A synchronous read before the async load lands reports "nothing
    // dismissed" and "nothing measured", which is how a dismissed prompt
    // comes back on every cold start. It has to fail closed instead.
    final container = makeContainer();

    expect(container.read(focuserBacklashOfferProvider), isFalse);

    await settle(container);
    expect(container.read(focuserBacklashOfferProvider), isTrue);
  });

  test('never offers with no focuser connected', () async {
    final container = makeContainer(focuser: const FocuserState());
    await settle(container);

    expect(container.read(focuserBacklashOfferProvider), isFalse);
  });

  test('never offers with no camera connected', () async {
    // Measuring backlash means measuring star sizes.
    final container = makeContainer(camera: const CameraStateSnapshot());
    await settle(container);

    expect(container.read(focuserBacklashOfferProvider), isFalse);
  });

  test('does not offer once this focuser has been measured', () async {
    final container = makeContainer();
    await settle(container);
    await container
        .read(settingsDaoProvider)
        .saveFocuserBacklashCalibration('zwo-eaf-1', recordFor());
    container.invalidate(savedFocuserBacklashProvider);
    await settle(container);

    expect(container.read(focuserBacklashOfferProvider), isFalse);
  });

  test('still offers when only ANOTHER focuser has been measured', () async {
    final container = makeContainer();
    await settle(container);
    await container
        .read(settingsDaoProvider)
        .saveFocuserBacklashCalibration('pegasus-focuscube-2', recordFor());
    container.invalidate(savedFocuserBacklashProvider);
    await settle(container);

    expect(container.read(focuserBacklashOfferProvider), isTrue);
  });

  test('does not offer when the operator entered their own figure', () async {
    // They have already answered this question.
    final container = makeContainer();
    await settle(container);
    await container.read(appSettingsProvider.notifier).setAfBacklashIn(350);

    expect(container.read(focuserBacklashOfferProvider), isFalse);
  });

  group('declining', () {
    test('"not now" holds for this session only', () async {
      final container = makeContainer();
      await settle(container);

      await container
          .read(focuserBacklashOfferSessionProvider.notifier)
          .declineOffer(never: false);

      expect(container.read(focuserBacklashOfferProvider), isFalse);
      // Nothing persisted: a later session asks again.
      expect(
        container
            .read(appSettingsProvider)
            .requireValue
            .focuserBacklashOfferMode,
        'ask',
      );
    });

    test('"never" is remembered across a restart', () async {
      final container = makeContainer();
      await settle(container);

      await container
          .read(focuserBacklashOfferSessionProvider.notifier)
          .declineOffer(never: true);

      expect(container.read(focuserBacklashOfferProvider), isFalse);
      expect(
        container
            .read(appSettingsProvider)
            .requireValue
            .focuserBacklashOfferMode,
        'never',
      );

      // A fresh settings load over the same database — the cold start that
      // used to resurrect the prompt.
      container.invalidate(appSettingsProvider);
      await settle(container);
      expect(
        container
            .read(appSettingsProvider)
            .requireValue
            .focuserBacklashOfferMode,
        'never',
      );
      expect(container.read(focuserBacklashOfferProvider), isFalse);
    });
  });

  group('re-offering after repeated landing failures', () {
    const verificationFailure =
        'Autofocus moved to 6610 but the frame taken there measures HFR 8.40, '
        "against the curve's 3.10 (tolerance 1.60x). The focuser did not end "
        'up where the curve was measured.';

    test('one failure is not enough to ask again', () async {
      final container = makeContainer();
      await settle(container);
      final offers = container.read(
        focuserBacklashOfferSessionProvider.notifier,
      );
      await offers.declineOffer(never: false);

      offers.noteAutofocusOutcome(
        focuserId: 'zwo-eaf-1',
        failureMessage: verificationFailure,
      );

      expect(container.read(focuserBacklashOfferProvider), isFalse);
    });

    test('two in a row on the same focuser reopens the offer', () async {
      final container = makeContainer();
      await settle(container);
      final offers = container.read(
        focuserBacklashOfferSessionProvider.notifier,
      );
      await offers.declineOffer(never: false);

      for (var i = 0; i < autofocusVerificationFailuresBeforeReoffer; i++) {
        offers.noteAutofocusOutcome(
          focuserId: 'zwo-eaf-1',
          failureMessage: verificationFailure,
        );
      }

      expect(container.read(focuserBacklashOfferProvider), isTrue);
    });

    test('failures on a different focuser do not reopen it', () async {
      final container = makeContainer();
      await settle(container);
      final offers = container.read(
        focuserBacklashOfferSessionProvider.notifier,
      );
      await offers.declineOffer(never: false);

      for (var i = 0; i < 4; i++) {
        offers.noteAutofocusOutcome(
          focuserId: 'pegasus-focuscube-2',
          failureMessage: verificationFailure,
        );
      }

      expect(container.read(focuserBacklashOfferProvider), isFalse);
    });

    test('a clean landing clears the count', () async {
      final container = makeContainer();
      await settle(container);
      final offers = container.read(
        focuserBacklashOfferSessionProvider.notifier,
      );
      await offers.declineOffer(never: false);

      offers.noteAutofocusOutcome(
        focuserId: 'zwo-eaf-1',
        failureMessage: verificationFailure,
      );
      offers.noteAutofocusOutcome(focuserId: 'zwo-eaf-1');
      offers.noteAutofocusOutcome(
        focuserId: 'zwo-eaf-1',
        failureMessage: verificationFailure,
      );

      expect(container.read(focuserBacklashOfferProvider), isFalse);
    });

    test('some other autofocus failure says nothing about the gear', () async {
      final container = makeContainer();
      await settle(container);
      final offers = container.read(
        focuserBacklashOfferSessionProvider.notifier,
      );
      await offers.declineOffer(never: false);

      for (var i = 0; i < 4; i++) {
        offers.noteAutofocusOutcome(
          focuserId: 'zwo-eaf-1',
          failureMessage:
              'Autofocus found only 2 stars at 6600, below the 10 required',
        );
      }

      expect(container.read(focuserBacklashOfferProvider), isFalse);
    });

    test('"never" outranks any amount of new evidence', () async {
      final container = makeContainer();
      await settle(container);
      final offers = container.read(
        focuserBacklashOfferSessionProvider.notifier,
      );
      await offers.declineOffer(never: true);

      for (var i = 0; i < 4; i++) {
        offers.noteAutofocusOutcome(
          focuserId: 'zwo-eaf-1',
          failureMessage: verificationFailure,
        );
      }

      expect(container.read(focuserBacklashOfferProvider), isFalse);
    });

    test('the marker matches the sentence native actually writes', () {
      expect(
        verificationFailure,
        contains(autofocusLandingVerificationFailureMarker),
      );
    });
  });

  group('the effective figure', () {
    test('is none until both inputs have loaded', () async {
      final container = makeContainer();

      final loading = container.read(effectiveFocuserBacklashProvider);
      expect(loading.origin, FocuserBacklashOrigin.none);
      expect(loading.hasFigure, isFalse);

      await settle(container);
      expect(
        container.read(effectiveFocuserBacklashProvider).origin,
        FocuserBacklashOrigin.none,
      );
    });

    test('reads the measured record for the connected focuser', () async {
      final container = makeContainer();
      await settle(container);
      await container
          .read(settingsDaoProvider)
          .saveFocuserBacklashCalibration('zwo-eaf-1', recordFor());
      container.invalidate(savedFocuserBacklashProvider);
      await settle(container);

      final effective = container.read(effectiveFocuserBacklashProvider);
      expect(effective.origin, FocuserBacklashOrigin.measured);
      expect(effective.steps, 105);
      expect(effective.provenance, contains('position 6620'));
      expect(container.read(measuredFocuserBacklashStepsProvider), 105);
    });

    test('the operator figure wins, and the wire still carries ours', () async {
      final container = makeContainer();
      await settle(container);
      await container
          .read(settingsDaoProvider)
          .saveFocuserBacklashCalibration('zwo-eaf-1', recordFor());
      container.invalidate(savedFocuserBacklashProvider);
      await settle(container);
      await container.read(appSettingsProvider.notifier).setAfBacklashIn(350);

      expect(
        container.read(effectiveFocuserBacklashProvider).origin,
        FocuserBacklashOrigin.operatorEntered,
      );
      expect(container.read(effectiveFocuserBacklashProvider).steps, 350);
      // Native decides the precedence, so the measurement still goes on the
      // wire and the engine's log describes what was known.
      expect(container.read(measuredFocuserBacklashStepsProvider), 105);
    });

    test('a no-measurable-backlash record puts nothing on the wire', () async {
      final container = makeContainer();
      await settle(container);
      await container
          .read(settingsDaoProvider)
          .saveFocuserBacklashCalibration(
            'zwo-eaf-1',
            recordFor(steps: 0, measurable: false),
          );
      container.invalidate(savedFocuserBacklashProvider);
      await settle(container);

      expect(container.read(measuredFocuserBacklashStepsProvider), isNull);
      expect(
        container.read(effectiveFocuserBacklashProvider).origin,
        FocuserBacklashOrigin.none,
      );
    });

    test('another focuser\'s figure is never inherited', () async {
      final container = makeContainer();
      await settle(container);
      await container
          .read(settingsDaoProvider)
          .saveFocuserBacklashCalibration('pegasus-focuscube-2', recordFor());
      container.invalidate(savedFocuserBacklashProvider);
      await settle(container);

      expect(container.read(measuredFocuserBacklashStepsProvider), isNull);
      expect(
        container.read(effectiveFocuserBacklashProvider).origin,
        FocuserBacklashOrigin.none,
      );
    });
  });
}
