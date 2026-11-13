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
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_app/services/command_action_result.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import '../../harness/mock_backend.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../../harness/pump_app_screen.dart' show TestBackendNotifier;
import '../night_control/panel/scope_panel_test_support.dart'
    show PanelMountNotifier, RecordingMountCommands, kTrackingMount;

class _FailingUnpark extends RecordingMountCommands {
  _FailingUnpark(super.ref);

  @override
  Future<CommandActionResult> unpark() async {
    calls.add('unpark');
    return const CommandActionResult.failure('The mount reported a fault');
  }
}

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

  late ProviderContainer lastContainer;

  Future<void> pumpDialog({
    required WidgetTester tester,
    required List<ValidationIssue> issues,
    AppSettingsState settings = const AppSettingsState(
      latitude: 40,
      longitude: -75,
    ),
    Sequence? sequence,
    Size size = const Size(1200, 1000),
    List<String>? wheelFilters,
  }) async {
    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      if (wheelFilters != null)
        effectiveFiltersProvider.overrideWithValue(wheelFilters),
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
    lastContainer = container;
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
          description: 'No matching darks found for 1 exposure combination:\n  • 120 s darks at gain 100, offset 10, -10.0°C, binning 1x1',
          resolutionHint: 'Capture darks for the missing combinations',
        ),
      ],
    );
    expect(find.text('Dark library'), findsOneWidget);
    expect(find.text('Missing Dark Frames'), findsOneWidget);
    expect(find.textContaining('Capture missing darks'), findsOneWidget);
  });

  // The walk-through's dialog opened on four "Loop Repeats Once" notes; the
  // two errors that blocked the run were below the fold.
  testWidgets('lists what blocks the run first and notes last',
      (tester) async {
    ValidationIssue issue(
      ValidationSeverity severity,
      ValidationCategory category,
      String title,
    ) =>
        ValidationIssue(
          severity: severity,
          category: category,
          title: title,
          description: title,
        );
    await pumpDialog(
      tester: tester,
      issues: [
        issue(ValidationSeverity.info, ValidationCategory.structure,
            'Loop Repeats Once'),
        issue(ValidationSeverity.warning, ValidationCategory.equipment,
            'Filter Not in Wheel'),
        issue(ValidationSeverity.info, ValidationCategory.equipmentHealth,
            'Time Sync Check Unavailable'),
        issue(ValidationSeverity.error, ValidationCategory.equipment,
            'No plate solver'),
        issue(ValidationSeverity.error, ValidationCategory.opticalTrain,
            'Tilt changed'),
      ],
    );

    double top(String text) => tester.getTopLeft(find.text(text).first).dy;
    expect(top('No plate solver'), lessThan(top('Filter Not in Wheel')));
    expect(top('Filter Not in Wheel'), lessThan(top('Loop Repeats Once')));
    // A section holding an error comes before one holding only notes.
    expect(top('Tilt changed'), lessThan(top('Time Sync Check Unavailable')));
  });

  testWidgets('a blocked start does not wear the start color', (tester) async {
    await pumpDialog(
      tester: tester,
      issues: const [
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.equipment,
          title: 'No plate solver',
          description: 'No plate solver',
        ),
      ],
    );
    final start = tester.widget<SkotiqButton>(find.byWidgetPredicate(
      (widget) =>
          widget is SkotiqButton && widget.label.startsWith('Start sequence'),
    ));
    expect(start.onPressed, isNull);
    expect(start.variant, isNot(ButtonVariant.start));
  });

  // The M51 starter said "Filter Not in Wheel" for "Lum" on an L/R/G/B wheel
  // and offered nothing but "Change the filter name".
  testWidgets('a filter the wheel spells differently is matched in one press',
      (tester) async {
    final root = InstructionSetNode(name: 'root');
    final lights = ExposureNode(filter: 'Lum').copyWith(parentId: root.id);
    final placedRoot = root.copyWith(childIds: [lights.id]);
    await pumpDialog(
      tester: tester,
      wheelFilters: const ['L', 'R', 'G', 'B'],
      sequence: Sequence.create(
        name: 'M51',
        nodes: {placedRoot.id: placedRoot, lights.id: lights},
        rootNodeId: placedRoot.id,
      ),
      issues: [
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.equipment,
          title: 'Filter Not in Wheel',
          description: '"Lights" uses filter "Lum"',
          affectedNodeId: lights.id,
          code: kFilterNameMismatchCode,
        ),
      ],
    );

    await tester.ensureVisible(find.text('Match filter names (Lum → L)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Match filter names (Lum → L)'));
    await tester.pumpAndSettle();

    final matched = lastContainer.read(currentSequenceProvider)!;
    expect((matched.nodes[lights.id]! as ExposureNode).filter, 'L');
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
          description: 'No matching darks found for 1 exposure combination:\n  • 120 s darks at gain 100, offset 10, -10.0°C, binning 1x1',
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

  group('a parked mount', () {
    const parked = MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'mount-1',
      isParked: true,
    );

    Future<({ProviderContainer container, List<String> started})> pumpParked(
      WidgetTester tester, {
      bool failUnpark = false,
      MountState mount = parked,
    }) async {
      final started = <String>[];
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, mockBackend()),
        ),
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
        mountStateProvider.overrideWith(
          (ref) => PanelMountNotifier(ref, mount),
        ),
        mountCommandServiceProvider.overrideWith(
          (ref) =>
              failUnpark ? _FailingUnpark(ref) : RecordingMountCommands(ref),
        ),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        _wrap(
          container,
          PreFlightValidationDialog(
            onStartSequence: () => started.add('start'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (container: container, started: started);
    }

    List<String> mountCalls(ProviderContainer container) =>
        (container.read(mountCommandServiceProvider) as RecordingMountCommands)
            .calls;

    testWidgets('is listed in the check, and Start unparks it, then starts',
        (tester) async {
      final h = await pumpParked(tester);
      expect(find.textContaining('The mount is parked'), findsOneWidget);

      await tester.tap(
        find.textContaining(RegExp(r'^Start (sequence|anyway)$')),
      );
      await tester.pumpAndSettle();

      expect(mountCalls(h.container), <String>['unpark']);
      expect(h.started, <String>['start']);
      // No second gate: the countdown dialog is gone.
      expect(find.text('Unpark now'), findsNothing);
    });

    testWidgets('a failed unpark starts nothing and says why in the check',
        (tester) async {
      final h = await pumpParked(tester, failUnpark: true);
      await tester.tap(
        find.textContaining(RegExp(r'^Start (sequence|anyway)$')),
      );
      await tester.pumpAndSettle();

      expect(mountCalls(h.container), <String>['unpark']);
      expect(h.started, isEmpty);
      expect(find.textContaining('The run did not start'), findsOneWidget);
      expect(find.textContaining('The mount reported a fault'), findsOneWidget);
    });

    testWidgets('an unparked mount is not mentioned and not commanded',
        (tester) async {
      final h = await pumpParked(tester, mount: kTrackingMount);
      expect(find.textContaining('The mount is parked'), findsNothing);
      await tester.tap(
        find.textContaining(RegExp(r'^Start (sequence|anyway)$')),
      );
      await tester.pumpAndSettle();
      expect(mountCalls(h.container), isEmpty);
      expect(h.started, <String>['start']);
    });
  });
}
