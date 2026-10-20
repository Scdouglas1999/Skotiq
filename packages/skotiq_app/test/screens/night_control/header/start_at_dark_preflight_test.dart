// Start at dark runs the same pre-flight as Start now before it arms
// anything: errors keep it from arming, and a parked mount is left parked
// until the armed start fires.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/actions/armed_start_provider.dart';
import 'package:skotiq_app/screens/night_control/header/night_header_bar.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../data/plan/plan_test_support.dart' show TwoTargetPlan;
import '../fixtures/night_fixtures.dart';
import '../left/night_widget_test_support.dart';

class _Validator implements SequenceValidatorService {
  _Validator(this.issues);
  final List<ValidationIssue> issues;

  ValidationResult get _result =>
      ValidationResult(issues: issues, validatedAt: DateTime.utc(2026, 10, 19));

  @override
  Future<ValidationResult> validate(Sequence sequence) async => _result;

  @override
  ValidationResult validateSync(Sequence sequence) => _result;
}

class _Plan extends CurrentSequenceNotifier {
  _Plan(Ref ref) : super(ref: ref) {
    loadSequence(TwoTargetPlan().sequence, discardUnsaved: true);
  }
}

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(sessionHandoffAutoPrompt: false);
}

class _ParkedMount extends MountStateNotifier {
  _ParkedMount(super.ref) {
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'mount-1',
      isParked: true,
    );
  }
}

/// 19:48 local, as a UTC instant.
final _dark = DateTime(2026, 10, 19, 19, 48).toUtc();

Future<NightHarness> _pump(
  WidgetTester tester, {
  List<ValidationIssue> issues = const [],
  NightText? armError,
}) async {
  final harness = NightHarness(
    board: NightFixtures.ready(),
    header: headerFor(NightRunPhase.ready),
    extra: <Override>[
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith(_Plan.new),
      sequenceValidatorProvider.overrideWith((ref) => _Validator(issues)),
      appSettingsProvider.overrideWith(_Settings.new),
      mountStateProvider.overrideWith(_ParkedMount.new),
      nightAstroDarkProvider.overrideWithValue(_dark),
    ],
  );
  harness.api.armError = armError;
  await harness.pump(
    tester,
    const NightHeaderBar(),
    size: const Size(1316, 900),
  );
  await tester.tap(find.widgetWithText(SkotiqButton, 'Start at dark'));
  await tester.pumpAndSettle();
  return harness;
}

Finder get _arm => find.widgetWithText(SkotiqButton, 'Arm for 19:48');

void main() {
  testWidgets('arming waits for the pre-flight and leaves the park alone',
      (tester) async {
    final harness = await _pump(tester);
    expect(find.text('Pre-flight check'), findsOneWidget);
    expect(harness.api.calls, isEmpty, reason: 'nothing armed yet');

    await tester.tap(_arm);
    await tester.pumpAndSettle();

    expect(harness.api.calls, <String>['arm']);
    expect(find.textContaining('Unpark'), findsNothing,
        reason: 'the armed start unparks when it fires, not now');
  });

  testWidgets('a pre-flight error keeps Start at dark from arming',
      (tester) async {
    final harness = await _pump(tester, issues: const [
      ValidationIssue(
        severity: ValidationSeverity.error,
        category: ValidationCategory.equipment,
        title: 'No camera in the profile',
        description: 'The plan captures frames but no camera is set.',
      ),
    ]);
    expect(find.text('No camera in the profile'), findsOneWidget);
    final arm = tester.widget<SkotiqButton>(_arm);
    expect(arm.onPressed, isNull);

    await tester.tap(_arm, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(harness.api.calls, isEmpty);
  });

  testWidgets('a refused arm shows the controller\'s reason', (tester) async {
    await _pump(tester, armError: const NightText('nightActErrArmNoPlan'));
    await tester.tap(_arm);
    await tester.pumpAndSettle();
    expect(
      find.text('Load a plan before arming Start at dark'),
      findsOneWidget,
    );
  });
}
