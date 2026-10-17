// Widget tests for the built-in guider config editor's pulse-range bounds
// (component C12).
//
// Scope:
//   1. max_pulse_rejected_with_caps_window — when the connected mount reports
//      maxPulseGuideMs=900, entering Max Pulse=1200 surfaces an out-of-range
//      error and never pushes a new BuiltinGuiderConfig.
//   2. min_pulse_rejected_with_caps_window — entering Min Pulse below the
//      mount's minPulseGuideMs is rejected and blocks the save.
//   3. in_range_accepted_with_caps_window — values inside the mount window
//      are accepted and pushed to the config notifier unchanged.
//   4. null_caps_uses_default_bounds — with no mount caps the existing
//      75..1200 envelope applies: 1200 is accepted, 1201 is rejected.
//   5. hint_reflects_caps_window / hint_absent_without_caps — the supported
//      range hint is shown only when the mount actually reports a range.
//
// We assert on the error-snackbar text (validation is pure and runs before
// any notifier write) and on a recording config notifier that captures the
// pushed BuiltinGuiderConfig — a direct, non-flaky check of exactly the
// bounds-validation behavior C12 owns. Crucially, the editor bounds the input
// only; it never mutates the BuiltinGuiderConfig clamps coming from Rust.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/guiding_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

const _kMountDeviceId = 'simulator:mount:0';

/// Seeded config the editor renders. minPulseMs/maxPulseMs match the Rust
/// defaults so the in-range fixtures start from a valid baseline.
const _kSeedConfig = BuiltinGuiderConfig(
  exposureSecs: 1.0,
  gain: 100,
  offset: 10,
  binning: 1,
  calibrationMs: 250,
  settleSleepMs: 200,
  minPulseMs: 100.0,
  maxPulseMs: 800.0,
);

/// A [BuiltinGuiderConfigNotifier] that starts in a known data state and
/// records pushed configs instead of round-tripping through the backend, so
/// blocked-vs-accepted saves are observable without a live FfiBackend.
class _RecordingConfigNotifier extends BuiltinGuiderConfigNotifier {
  _RecordingConfigNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const AsyncValue.data(_kSeedConfig);
  }

  final List<BuiltinGuiderConfig> pushed = [];

  @override
  Future<void> updateConfig(BuiltinGuiderConfig newConfig) async {
    pushed.add(newConfig);
    // ignore: invalid_use_of_protected_member
    state = AsyncValue.data(newConfig);
  }
}

/// A [MountStateNotifier] seeded to a connected mount so the editor resolves
/// capabilities for [_kMountDeviceId].
class _ConnectedMountNotifier extends MountStateNotifier {
  _ConnectedMountNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _kMountDeviceId,
      deviceName: 'Simulated Mount',
    );
  }
}

List<Override> _overrides(MountCapabilities? caps) => [
      // Force the built-in guider config section to render.
      isBuiltinGuiderProvider.overrideWithValue(true),
      builtinGuiderConfigProvider
          .overrideWith((ref) => _RecordingConfigNotifier(ref)),
      mountStateProvider.overrideWith(_ConnectedMountNotifier.new),
      mountCapabilitiesProvider(_kMountDeviceId)
          .overrideWith((ref) async => caps),
    ];

/// Pumps the panel, expands the (collapsed-by-default) config section, and
/// returns the recording config notifier so tests can assert on pushed configs.
Future<_RecordingConfigNotifier> _pumpAndExpand(
  WidgetTester tester,
  MountCapabilities? caps,
) async {
  final handle = await pumpAppScreen(
    tester,
    const GuidingPanel(colors: SkotiqColors.dark),
    extraOverrides: _overrides(caps),
    settle: false,
  );
  // Drain the capability FutureProvider override into the tree.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }

  // The config section is collapsed by default; expand it to reveal the form.
  await tester.tap(find.text('Guider Configuration'));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }

  return handle.container.read(builtinGuiderConfigProvider.notifier)
      as _RecordingConfigNotifier;
}

MountCapabilities _caps({double? minPulse, double? maxPulse}) =>
    MountCapabilities(
      minPulseGuideMs: minPulse,
      maxPulseGuideMs: maxPulse,
    );

/// Returns the [TextField] paired with [label] in a config input row.
Finder _fieldFor(String label) => find.descendant(
      of: find.widgetWithText(Row, label),
      matching: find.byType(TextField),
    );

/// Enter [value] into the field for [label] and tap Apply, draining the
/// resulting snackbar / state frames so the tree settles.
Future<void> _setAndApply(
  WidgetTester tester,
  String label,
  String value,
) async {
  await tester.enterText(_fieldFor(label), value);
  await tester.pump();
  // The panel is a scroll view; bring Apply into view before tapping so the
  // hit test lands on the button rather than empty space below the fold.
  final apply = find.text('Apply');
  await tester.ensureVisible(apply);
  await tester.pump();
  await tester.tap(apply);
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'max_pulse_rejected_with_caps_window: 1200 blocked for maxPulse=900',
      (tester) async {
    final notifier =
        await _pumpAndExpand(tester, _caps(minPulse: 75, maxPulse: 900));

    await _setAndApply(tester, 'Max pulse', '1200');

    expect(
      find.text('Max pulse 1200 ms exceeds the mount maximum of 900 ms'),
      findsOneWidget,
      reason: 'A max pulse above the mount ceiling must surface an error.',
    );
    expect(notifier.pushed, isEmpty,
        reason: 'A rejected save must never push a new config.');
  });

  testWidgets('min_pulse_rejected_with_caps_window: 40 blocked for minPulse=75',
      (tester) async {
    final notifier =
        await _pumpAndExpand(tester, _caps(minPulse: 75, maxPulse: 900));

    await _setAndApply(tester, 'Min pulse', '40');

    expect(
      find.text('Min pulse 40 ms is below the mount minimum of 75 ms'),
      findsOneWidget,
      reason: 'A min pulse below the mount floor must surface an error.',
    );
    expect(notifier.pushed, isEmpty,
        reason: 'A rejected save must never push a new config.');
  });

  testWidgets('in_range_accepted_with_caps_window: 600 max pushed for 75..900',
      (tester) async {
    final notifier =
        await _pumpAndExpand(tester, _caps(minPulse: 75, maxPulse: 900));

    await _setAndApply(tester, 'Max pulse', '600');

    expect(find.textContaining('exceeds the mount maximum'), findsNothing,
        reason: 'An in-range max pulse must not surface the range error.');
    expect(notifier.pushed, hasLength(1),
        reason: 'An in-range save must push exactly one config.');
    expect(notifier.pushed.single.maxPulseMs, 600.0,
        reason: 'The pushed config must carry the entered max pulse verbatim '
            '(the editor bounds the input, it does not re-clamp).');
    expect(notifier.pushed.single.minPulseMs, _kSeedConfig.minPulseMs,
        reason: 'Untouched fields must be preserved.');
  });

  testWidgets('null_caps_uses_default_bounds: 1200 accepted, 1201 rejected',
      (tester) async {
    final notifier = await _pumpAndExpand(tester, null);

    // 1200 sits on the inclusive ceiling of the 75..1200 default window.
    await _setAndApply(tester, 'Max pulse', '1200');
    expect(notifier.pushed, hasLength(1),
        reason: 'With null caps the default ceiling is 1200, so 1200 passes.');
    expect(notifier.pushed.single.maxPulseMs, 1200.0);

    // 1201 is past the default ceiling and must be rejected.
    await _setAndApply(tester, 'Max pulse', '1201');
    expect(
      find.text('Max pulse 1201 ms exceeds the mount maximum of 1200 ms'),
      findsOneWidget,
      reason: '1201 exceeds the 75..1200 default and must be rejected.',
    );
    expect(notifier.pushed, hasLength(1),
        reason: 'The rejected 1201 must not push a second config.');
  });

  testWidgets('hint_reflects_caps_window: shows mount-supported range',
      (tester) async {
    await _pumpAndExpand(tester, _caps(minPulse: 75, maxPulse: 900));

    expect(find.text('Mount supports 75-900 ms'), findsNWidgets(2),
        reason: 'Both the Min and Max pulse fields must show the range hint.');
  });

  testWidgets('hint_absent_without_caps: no range hint when caps are null',
      (tester) async {
    await _pumpAndExpand(tester, null);

    expect(find.textContaining('Mount supports'), findsNothing,
        reason: 'Without reported caps the hint must not fabricate a range.');
  });
}
