// Smoke tests for the pre-flight validation dialog
// extensions. We don't drive the unified validator end-to-end here
// (that's covered by the rule unit tests in `skotiq_core`); instead
// we override `sequenceValidatorProvider` with a fake that returns a
// canned `ValidationResult` and verify the dialog renders the new
// Dark library / Equipment health / Optical train sections.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/preflight_validation_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _FakeValidator implements SequenceValidatorService {
  _FakeValidator(this._result);
  final ValidationResult _result;

  @override
  Future<ValidationResult> validate(Sequence sequence) async => _result;

  @override
  ValidationResult validateSync(Sequence sequence) => _result;
}

ValidationResult _result(List<ValidationIssue> issues) {
  return ValidationResult(issues: issues, validatedAt: DateTime(2026, 1, 1));
}

Sequence _sequence() {
  final root = InstructionSetNode(name: 'root');
  final expo = ExposureNode().copyWith(parentId: root.id);
  final placedRoot = root.copyWith(childIds: [expo.id]);
  return Sequence.create(
    name: 'Test',
    nodes: {placedRoot.id: placedRoot, expo.id: expo},
    rootNodeId: placedRoot.id,
  );
}

class _SeedingNotifier extends CurrentSequenceNotifier {
  _SeedingNotifier(Ref ref, Sequence seed) : super(ref: ref) {
    loadSequence(seed, discardUnsaved: true);
  }
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);

  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

class _FailingAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async {
    throw StateError('settings database offline');
  }
}

Widget _wrap(
  ProviderContainer container,
  Widget child, {
  Size size = const Size(1200, 1000),
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Center(child: child),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDialog({
    required WidgetTester tester,
    required List<ValidationIssue> issues,
    AppSettingsState settings = const AppSettingsState(
      latitude: 40,
      longitude: -75,
    ),
    Sequence? sequence,
    Size size = const Size(1200, 1000),
  }) async {
    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith(
        (ref) => _SeedingNotifier(ref, sequence ?? _sequence()),
      ),
      sequenceValidatorProvider
          .overrideWith((ref) => _FakeValidator(_result(issues))),
      appSettingsProvider
          .overrideWith(() => _FakeAppSettingsNotifier(settings)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _wrap(container, const PreFlightValidationDialog(), size: size),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders the dark library section with capture button',
      (tester) async {
    await pumpDialog(
      tester: tester,
      issues: const [
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.darkLibrary,
          title: 'Missing Dark Frames',
          description: 'No matching darks for gain=100 offset=10',
          resolutionHint: 'Capture darks for the missing combinations',
        ),
      ],
    );
    expect(find.text('Dark library'), findsOneWidget);
    expect(find.text('Missing Dark Frames'), findsOneWidget);
    expect(find.textContaining('Capture missing darks'), findsOneWidget);
  });

  testWidgets('renders compact simulation summary when location is set',
      (tester) async {
    final target = TargetHeaderNode(
      id: 'target-m31',
      targetName: 'M31',
      raHours: 0.7,
      decDegrees: 41.3,
      childIds: const ['exp-l'],
    );
    final sequence = Sequence.create(
      name: 'Simulation',
      nodes: {
        target.id: target,
        'exp-l': ExposureNode(
          id: 'exp-l',
          parentId: target.id,
          durationSecs: 120,
          count: 2,
        ),
      },
    );

    await pumpDialog(
      tester: tester,
      issues: const [],
      sequence: sequence,
    );

    expect(find.text('Simulation'), findsOneWidget);
    // `Readout` renders its label uppercase (05 §3).
    expect(find.text('DURATION'), findsOneWidget);
    expect(find.text('SEGMENTS'), findsOneWidget);
    expect(find.text('TARGETS'), findsOneWidget);
    expect(find.text('ISSUES'), findsOneWidget);
  });

  testWidgets('simulation section degrades cleanly without observer location',
      (tester) async {
    await pumpDialog(
      tester: tester,
      issues: const [],
      settings: const AppSettingsState(),
    );

    expect(find.text('Simulation'), findsOneWidget);
    expect(
      find.textContaining('Set observer latitude and longitude'),
      findsOneWidget,
    );
  });

  testWidgets('renders the equipment health section', (tester) async {
    await pumpDialog(
      tester: tester,
      issues: const [
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.equipmentHealth,
          title: 'USB Stability Concern',
          description: 'Camera saw 5 disconnects in the last 24h.',
        ),
      ],
    );
    expect(find.text('Equipment health'), findsOneWidget);
    expect(find.text('USB Stability Concern'), findsOneWidget);
  });

  testWidgets('renders the optical train section', (tester) async {
    await pumpDialog(
      tester: tester,
      issues: const [
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.opticalTrain,
          title: 'Optical Train Has Shifted',
          description: 'Tilt/collimation moved 12.4 units.',
        ),
      ],
    );
    expect(find.text('Optical train'), findsOneWidget);
    expect(find.text('Optical Train Has Shifted'), findsOneWidget);
  });

  testWidgets('history lookup failure blocks start until operator decides',
      (tester) async {
    var started = false;
    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith(
        (ref) => _SeedingNotifier(ref, _sequence()),
      ),
      sequenceValidatorProvider.overrideWith(
        (ref) => _FakeValidator(_result(const [])),
      ),
      appSettingsProvider.overrideWith(
        () => _FakeAppSettingsNotifier(
          const AppSettingsState(latitude: 40, longitude: -75),
        ),
      ),
      sessionCarryOverProvider.overrideWith(
        (ref) => throw StateError('history database offline'),
      ),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _wrap(
        container,
        PreFlightValidationDialog(onStartSequence: () => started = true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.textContaining(RegExp(r'^Start (sequence|anyway)$')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Prior-session history unavailable'), findsOneWidget);
    expect(find.textContaining('history database offline'), findsOneWidget);
    expect(started, isFalse);

    final confirmDialog = find.ancestor(
      of: find.text('Prior-session history unavailable'),
      matching: find.byType(SkotiqDialog),
    );
    await tester.tap(
      find.descendant(
        of: confirmDialog,
        matching: find.widgetWithText(SkotiqButton, 'Cancel'),
      ),
    );
    await tester.pumpAndSettle();
    expect(started, isFalse);
    expect(find.text('Pre-flight check'), findsOneWidget);
  });

  testWidgets('disabled auto-prompt does not read carry-over history',
      (tester) async {
    var started = false;
    var historyReads = 0;
    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith(
        (ref) => _SeedingNotifier(ref, _sequence()),
      ),
      sequenceValidatorProvider.overrideWith(
        (ref) => _FakeValidator(_result(const [])),
      ),
      appSettingsProvider.overrideWith(
        () => _FakeAppSettingsNotifier(
          const AppSettingsState(
            latitude: 40,
            longitude: -75,
            sessionHandoffAutoPrompt: false,
          ),
        ),
      ),
      sessionCarryOverProvider.overrideWith((ref) {
        historyReads++;
        throw StateError('history should not be read');
      }),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _wrap(
        container,
        PreFlightValidationDialog(onStartSequence: () => started = true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.textContaining(RegExp(r'^Start (sequence|anyway)$')),
    );
    await tester.pumpAndSettle();

    expect(started, isTrue);
    expect(historyReads, 0);
    expect(find.text('Prior-session history unavailable'), findsNothing);
  });

  testWidgets('settings authority failure becomes validation retry state',
      (tester) async {
    var started = false;
    var historyReads = 0;
    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith(
        (ref) => _SeedingNotifier(ref, _sequence()),
      ),
      sequenceValidatorProvider.overrideWith(
        (ref) => _FakeValidator(_result(const [])),
      ),
      appSettingsProvider.overrideWith(_FailingAppSettingsNotifier.new),
      sessionCarryOverProvider.overrideWith((ref) {
        historyReads++;
        return const <SessionCarryOver>[];
      }),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _wrap(
        container,
        PreFlightValidationDialog(onStartSequence: () => started = true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not validate sequence'), findsOneWidget);
    expect(find.textContaining('settings database offline'), findsOneWidget);
    expect(
      find.widgetWithText(SkotiqButton, 'Retry validation'),
      findsOneWidget,
    );
    final start = find.widgetWithText(SkotiqButton, 'Start sequence');
    expect(start, findsOneWidget);
    expect(tester.widget<SkotiqButton>(start).onPressed, isNull);
    expect(started, isFalse);
    expect(historyReads, 0);
  });

  testWidgets('explicit start without history sets one-shot authorization',
      (tester) async {
    var started = false;
    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith(
        (ref) => _SeedingNotifier(ref, _sequence()),
      ),
      sequenceValidatorProvider.overrideWith(
        (ref) => _FakeValidator(_result(const [])),
      ),
      appSettingsProvider.overrideWith(
        () => _FakeAppSettingsNotifier(
          const AppSettingsState(latitude: 40, longitude: -75),
        ),
      ),
      sessionCarryOverProvider.overrideWith(
        (ref) => throw StateError('history database offline'),
      ),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _wrap(
        container,
        PreFlightValidationDialog(onStartSequence: () => started = true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.textContaining(RegExp(r'^Start (sequence|anyway)$')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start without prior progress'));
    await tester.pumpAndSettle();

    expect(started, isTrue);
    expect(container.read(sessionHandoffIgnoreUnavailableOnceProvider), isTrue);
  });

  testWidgets('lays out without overflow at 700px', (tester) async {
    await pumpDialog(
      tester: tester,
      size: const Size(700, 800),
      issues: const [
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.equipmentHealth,
          title: 'Daylight Gate',
          description: 'The sun is above the configured altitude limit.',
          resolutionHint: 'Wait for astronomical dusk, or lower the sun limit.',
        ),
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.darkLibrary,
          title: 'Missing Dark Frames',
          description: 'No matching darks for gain=100 offset=10',
        ),
      ],
    );

    // No FlutterError was swallowed above: a RenderFlex overflow would have
    // failed the pump. This just proves the dialog actually rendered.
    expect(find.text('Pre-flight check'), findsOneWidget);
    expect(find.text('Cannot start', findRichText: true), findsOneWidget);
  });

  // A bare GestureDetector for the green primary printed `panel: Start anyway` —
  // no role, no state — right beside its own siblings `button: Re-check` and
  // `button: Cancel`, and could not be reached from the keyboard at all. The
  // primary is a `SkotiqButton` now; this pins that it still publishes
  // the role and the live state.
  testWidgets('Start anyway announces itself as an enabled button',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpDialog(
      tester: tester,
      issues: const [
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.equipmentHealth,
          title: 'USB Stability Concern',
          description: 'Camera saw 5 disconnects in the last 24h.',
        ),
      ],
    );

    expect(find.text('Start anyway'), findsOneWidget);
    final node = tester.getSemantics(find.text('Start anyway'));
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(node.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);
    expect(
      node.label.trim(),
      'Start anyway',
      reason: 'nothing blocks a warnings-only run, so no reason is announced',
    );
    handle.dispose();
  });

  // The counter-case to the above: with an ERROR on the board the same button
  // is inert, and an undeclared one probes as `Start Sequence` with `sensitive`
  // and no `enabled` — a blocked primary indistinguishable from a live one,
  // carrying no reason, while clicking it produces no dialog change, no run, no
  // toast and no log line.
  testWidgets('a blocked Start announces why it cannot run', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpDialog(
      tester: tester,
      issues: const [
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.equipmentHealth,
          title: 'Daylight Gate',
          description: 'The sun is above the configured altitude limit.',
        ),
      ],
    );

    expect(find.text('Start sequence'), findsOneWidget);
    final node = tester.getSemantics(find.text('Start sequence'));
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(node.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isEnabled), isFalse);
    expect(
      node.label.trim(),
      'Start sequence — unavailable: fix the 1 pre-flight error above first',
    );
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.tap),
      isFalse,
      reason: 'a blocked primary that still offers a tap action reads as live',
    );
    handle.dispose();
  });
}
