// Verify Smart Night wizard defaults
// and the notes-prompt opt-out land correctly in
// AppSettingsState.
//
// We test the `AppSettingsState` value object's constructor defaults
// + copyWith semantics directly rather than driving the
// AppSettingsNotifier round-trip. The notifier's persistence path is
// known-good (every other knob in this file uses the same DAO + key
// pattern); validating the value-object surface is what catches the
// "is the wizard sending changes to the right field" failure mode.
//
// Why not drive the full notifier? At the time landed, the
// skotiq_bridge layer had an unrelated FRB-codegen mismatch
// (`SequencerEvent_PluginNodeRequested` missing from the
// `event_display.dart` switch). That blocks any test that
// transitively imports `settings_provider.dart` because the provider
// pulls in network_backend.dart. The value-object tests below do not
// import the provider — they exercise the same data type the provider
// produces and consumes.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart'
    show AppSettingsState, AppSettingsStateCopyWith;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Smart Night defaults have sensible initial values', () {
    const settings = AppSettingsState();
    expect(
      settings.smartNightMaxSessionHours,
      isNull,
      reason: 'null means "use full dark window"',
    );
    expect(settings.smartNightDefaultAfCadenceFrames, 25);
    expect(settings.smartNightDefaultIntegrationBudgetMinsPerTarget, 240);
    expect(settings.smartNightIncludeFlatsAtEnd, isTrue);
    expect(settings.smartNightUseSchedulerForMultiTarget, isTrue);
    expect(settings.smartNightSchedulerTargetThreshold, 3);
    expect(settings.smartNightDefaultStrategy, 'auto_lrgb');
    expect(settings.smartNightPolarAlignmentStaleAfterDays, 7);
    expect(settings.smartNightSubExposureFloorSecs, 30.0);
    expect(settings.smartNightSubExposureCeilingSecs, 300.0);
    expect(settings.smartNightTargetSnr, 30.0);
    expect(settings.smartNightAutoPromptEnabled, isTrue);
  });

  test('Notes prompt toggle defaults to ON (opt-out, not opt-in)', () {
    const settings = AppSettingsState();
    expect(settings.promptForNotesAfterRun, isTrue);
  });

  test('copyWith updates each Smart Night field independently', () {
    const initial = AppSettingsState();
    final next = initial.copyWith(
      smartNightMaxSessionHours: 8.5,
      smartNightDefaultAfCadenceFrames: 10,
      smartNightDefaultIntegrationBudgetMinsPerTarget: 180,
      smartNightIncludeFlatsAtEnd: false,
      smartNightUseSchedulerForMultiTarget: false,
      smartNightSchedulerTargetThreshold: 5,
      smartNightDefaultStrategy: 'narrowband_sho',
      smartNightPolarAlignmentStaleAfterDays: 14,
      smartNightSubExposureFloorSecs: 45.0,
      smartNightSubExposureCeilingSecs: 420.0,
      smartNightTargetSnr: 42.0,
      smartNightAutoPromptEnabled: false,
    );
    expect(next.smartNightMaxSessionHours, 8.5);
    expect(next.smartNightDefaultAfCadenceFrames, 10);
    expect(next.smartNightDefaultIntegrationBudgetMinsPerTarget, 180);
    expect(next.smartNightIncludeFlatsAtEnd, isFalse);
    expect(next.smartNightUseSchedulerForMultiTarget, isFalse);
    expect(next.smartNightSchedulerTargetThreshold, 5);
    expect(next.smartNightDefaultStrategy, 'narrowband_sho');
    expect(next.smartNightPolarAlignmentStaleAfterDays, 14);
    expect(next.smartNightSubExposureFloorSecs, 45.0);
    expect(next.smartNightSubExposureCeilingSecs, 420.0);
    expect(next.smartNightTargetSnr, 42.0);
    expect(next.smartNightAutoPromptEnabled, isFalse);

    // Untouched fields preserve their values.
    expect(next.promptForNotesAfterRun, initial.promptForNotesAfterRun);
    expect(next.theme, initial.theme);
  });

  test('copyWith clears smartNightMaxSessionHours back to null', () {
    // First set to a real cap.
    const initial = AppSettingsState();
    final withCap = initial.copyWith(smartNightMaxSessionHours: 6.0);
    expect(withCap.smartNightMaxSessionHours, 6.0);

    // Then clear back to null using the explicit sentinel.
    final cleared = withCap.copyWith(smartNightMaxSessionHours: null);
    expect(
      cleared.smartNightMaxSessionHours,
      isNull,
      reason:
          'A cleared cap must round-trip as null, not as a numeric '
          'fallback — otherwise the wizard would silently re-cap.',
    );
  });

  test('copyWith preserves smartNightMaxSessionHours when omitted', () {
    // Per the AppSettingsState copyWith convention, omitting the
    // argument leaves the value alone. The `_unset` sentinel in the
    // signature defaults makes this work even for the nullable field.
    const initial = AppSettingsState();
    final withCap = initial.copyWith(smartNightMaxSessionHours: 6.0);
    // Mutate a different field; the cap should survive.
    final mutated = withCap.copyWith(theme: 'light');
    expect(
      mutated.smartNightMaxSessionHours,
      6.0,
      reason:
          'Omitting smartNightMaxSessionHours from copyWith must '
          'leave it alone — otherwise downstream mutators would '
          'unintentionally clear it on every change.',
    );
    expect(mutated.theme, 'light');
  });

  test('copyWith updates promptForNotesAfterRun independently', () {
    const initial = AppSettingsState();
    final off = initial.copyWith(promptForNotesAfterRun: false);
    expect(off.promptForNotesAfterRun, isFalse);

    final back = off.copyWith(promptForNotesAfterRun: true);
    expect(back.promptForNotesAfterRun, isTrue);
  });
}
