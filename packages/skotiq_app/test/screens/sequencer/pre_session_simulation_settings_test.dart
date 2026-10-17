import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/preflight_validation_dialog.dart';
import 'package:skotiq_app/screens/sequencer/widgets/visual_timeline.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart' as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _FakeValidator implements SequenceValidatorService {
  @override
  Future<ValidationResult> validate(Sequence sequence) async =>
      ValidationResult(issues: const [], validatedAt: DateTime(2026, 5, 21));

  @override
  ValidationResult validateSync(Sequence sequence) =>
      ValidationResult(issues: const [], validatedAt: DateTime(2026, 5, 21));
}

class _FakeSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        latitude: 40,
        longitude: -75,
        effectiveHorizonDeg: 60,
      );
}

class _LowHorizonSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        latitude: 40,
        longitude: -75,
        effectiveHorizonDeg: 0,
      );
}

class _SeedingNotifier extends CurrentSequenceNotifier {
  _SeedingNotifier(Ref ref) : super(ref: ref) {
    loadSequence(_sequence(), discardUnsaved: true);
  }
}

class _CustomSequenceNotifier extends CurrentSequenceNotifier {
  _CustomSequenceNotifier(Ref ref, Sequence seed) : super(ref: ref) {
    loadSequence(seed, discardUnsaved: true);
  }
}

Sequence _sequence() {
  final target = TargetHeaderNode(
    id: 'target-equator',
    name: 'Equator Target',
    targetName: 'Equator Target',
    raHours: 12,
    decDegrees: 0,
  );
  return Sequence.create(
    name: 'High Horizon Test',
    nodes: {target.id: target},
    rootNodeId: target.id,
  );
}

Sequence _longSequence() {
  final target = TargetHeaderNode(
    id: 'target-long',
    name: 'Long Target',
    targetName: 'Long Target',
    raHours: 12,
    decDegrees: 40,
  );
  final exposure = ExposureNode(
    id: 'exp-long',
    name: 'Long Exposure',
    parentId: target.id,
    durationSecs: 300,
    count: 10,
  );
  return Sequence.create(
    name: 'Dark Window Test',
    nodes: {
      target.id: target.copyWith(childIds: [exposure.id]),
      exposure.id: exposure,
    },
    rootNodeId: target.id,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('timeline simulation uses the configured effective horizon', () async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        // The overhead model these surfaces bill against. Overridden so the
        // simulation does not reach through SequencerDefaultsNotifier into the
        // settings DAO, which has no path_provider under flutter_test.
        sequencerOverheadConfigProvider.overrideWithValue(
          const SequenceOverheadConfig(),
        ),
        currentSequenceProvider.overrideWith(_SeedingNotifier.new),
        appSettingsProvider.overrideWith(_FakeSettingsNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final simulation = container.read(sequenceTimelineProvider);

    expect(simulation, isNotNull);
    expect(simulation!.hasBlockingIssues, isTrue);
    expect(
      simulation.issues.map((issue) => issue.message),
      contains(contains('never rises above')),
    );
  });

  testWidgets('preflight simulation uses the configured effective horizon',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          // The overhead model these surfaces bill against. Overridden so the
          // simulation does not reach through SequencerDefaultsNotifier into the
          // settings DAO, which has no path_provider under flutter_test.
          sequencerOverheadConfigProvider.overrideWithValue(
            const SequenceOverheadConfig(),
          ),
          currentSequenceProvider.overrideWith(_SeedingNotifier.new),
          appSettingsProvider.overrideWith(_FakeSettingsNotifier.new),
          sequenceValidatorProvider.overrideWith((ref) => _FakeValidator()),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: PreFlightValidationDialog(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('never rises above'), findsOneWidget);
  });

  testWidgets('visual timeline surfaces simulation issues without segments',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          // The overhead model these surfaces bill against. Overridden so the
          // simulation does not reach through SequencerDefaultsNotifier into the
          // settings DAO, which has no path_provider under flutter_test.
          sequencerOverheadConfigProvider.overrideWithValue(
            const SequenceOverheadConfig(),
          ),
          currentSequenceProvider.overrideWith(_SeedingNotifier.new),
          appSettingsProvider.overrideWith(_FakeSettingsNotifier.new),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: VisualTimeline(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('never rises above'), findsOneWidget);
    expect(find.text('No timeline data available'), findsNothing);
  });

  testWidgets('preflight simulation blocking issues disable sequence start',
      (tester) async {
    var started = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          // The overhead model these surfaces bill against. Overridden so the
          // simulation does not reach through SequencerDefaultsNotifier into the
          // settings DAO, which has no path_provider under flutter_test.
          sequencerOverheadConfigProvider.overrideWithValue(
            const SequenceOverheadConfig(),
          ),
          currentSequenceProvider.overrideWith(_SeedingNotifier.new),
          appSettingsProvider.overrideWith(_FakeSettingsNotifier.new),
          sequenceValidatorProvider.overrideWith((ref) => _FakeValidator()),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: PreFlightValidationDialog(
              onStartSequence: () => started = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('never rises above'), findsOneWidget);
    // The verdict is one `SkotiqBanner`, whose title lives in a
    // `Text.rich` span rather than in a `Text.data`.
    expect(find.text('Cannot start', findRichText: true), findsOneWidget);
    expect(find.text('All checks passed', findRichText: true), findsNothing);

    final start = find.widgetWithText(SkotiqButton, 'Start sequence');
    expect(start, findsOneWidget);
    expect(tester.widget<SkotiqButton>(start).onPressed, isNull);
    expect(started, isFalse);
  });

  test('timeline simulation warns when plan overruns dark window', () async {
    final dawn = DateTime.now().add(const Duration(minutes: 5));
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        // The overhead model these surfaces bill against. Overridden so the
        // simulation does not reach through SequencerDefaultsNotifier into the
        // settings DAO, which has no path_provider under flutter_test.
        sequencerOverheadConfigProvider.overrideWithValue(
          const SequenceOverheadConfig(),
        ),
        currentSequenceProvider.overrideWith(
          (ref) => _CustomSequenceNotifier(ref, _longSequence()),
        ),
        appSettingsProvider.overrideWith(_LowHorizonSettingsNotifier.new),
        preSessionTwilightTimesProvider.overrideWithValue(
          planetarium.TwilightTimes(astronomicalDawn: dawn),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final simulation = container.read(sequenceTimelineProvider);

    expect(simulation, isNotNull);
    expect(
      simulation!.issues.map((issue) => issue.message),
      contains(contains('dark window')),
    );
  });

  testWidgets('preflight simulation warns when plan overruns dark window',
      (tester) async {
    final dawn = DateTime.now().add(const Duration(minutes: 5));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          // The overhead model these surfaces bill against. Overridden so the
          // simulation does not reach through SequencerDefaultsNotifier into the
          // settings DAO, which has no path_provider under flutter_test.
          sequencerOverheadConfigProvider.overrideWithValue(
            const SequenceOverheadConfig(),
          ),
          currentSequenceProvider.overrideWith(
            (ref) => _CustomSequenceNotifier(ref, _longSequence()),
          ),
          appSettingsProvider.overrideWith(_LowHorizonSettingsNotifier.new),
          sequenceValidatorProvider.overrideWith((ref) => _FakeValidator()),
          preSessionTwilightTimesProvider.overrideWithValue(
            planetarium.TwilightTimes(astronomicalDawn: dawn),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: PreFlightValidationDialog(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('dark window'), findsOneWidget);
  });
}
