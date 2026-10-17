import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/narrator/narrator_card.dart';
import 'package:skotiq_app/widgets/narrator/narrator_detail_sheet.dart';
import 'package:skotiq_app/widgets/narrator/narrator_explainers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/services/science/narrator/narrator_detectors.dart'
    show buildDefaultNarratorEngine;
import 'package:skotiq_ui/skotiq_ui.dart';

NarratorEvent _event({
  int id = 1,
  String eventType = 'milestone.best_seeing',
  NarratorCategory category = NarratorCategory.milestone,
  NarratorSeverity severity = NarratorSeverity.success,
  String headline = 'Best seeing of the night — FWHM 1.8"',
  String? body,
  NarratorEvidence? evidence,
  bool pinned = false,
  DateTime? timestamp,
}) {
  return NarratorEvent(
    id: id,
    timestamp: timestamp ?? DateTime.now().subtract(const Duration(minutes: 4)),
    eventType: eventType,
    category: category,
    severity: severity,
    headline: headline,
    body: body,
    evidence: evidence,
    dedupeKey: '$eventType:$id',
    pinned: pinned,
  );
}

Future<void> _pumpCard(WidgetTester tester, NarratorEvent event) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: NarratorCard(event: event, relativeTime: '4m ago'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NarratorCard evidence kinds', () {
    testWidgets('renders a sparkline evidence payload', (tester) async {
      await _pumpCard(
        tester,
        _event(
          evidence: NarratorEvidence.sparkline(
            points: const [1.0, 1.2, 0.9, 1.4, 1.1],
            unit: '%',
          ),
        ),
      );
      // The card and its headline render without throwing on the painter path.
      expect(find.byType(NarratorCard), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.text('4m ago'), findsOneWidget);
    });

    testWidgets('renders a delta evidence payload (from/to values)',
        (tester) async {
      await _pumpCard(
        tester,
        _event(
          evidence: NarratorEvidence.delta(
            from: 18.6,
            to: 19.2,
            unit: 'mag',
            direction: 'up',
          ),
        ),
      );
      expect(find.textContaining('18.6'), findsOneWidget);
      expect(find.textContaining('19.2'), findsOneWidget);
    });

    testWidgets('renders a vector evidence payload with its label',
        (tester) async {
      await _pumpCard(
        tester,
        _event(
          category: NarratorCategory.equipment,
          severity: NarratorSeverity.warning,
          evidence: NarratorEvidence.vector(
            directionDeg: 45,
            magnitude: 0.3,
            label: 'NE corner',
          ),
        ),
      );
      expect(find.text('NE corner'), findsOneWidget);
    });

    testWidgets('renders a scalar evidence payload with value, unit, context',
        (tester) async {
      await _pumpCard(
        tester,
        _event(
          evidence: NarratorEvidence.scalar(
            value: 1.8,
            unit: '"',
            context: 'session best',
          ),
        ),
      );
      expect(find.textContaining('1.8'), findsOneWidget);
      expect(find.text('session best'), findsOneWidget);
    });
  });

  group('NarratorCard severity styling', () {
    testWidgets('celebrate vs warning produce different accent colours',
        (tester) async {
      // Resolve both accents against the dark palette the same way the card
      // does, and assert they differ — the visible distinction in styling.
      final celebrate = NarratorVisuals.accentFor(
        NarratorSeverity.celebrate,
        SkotiqColors.dark,
      );
      final warning = NarratorVisuals.accentFor(
        NarratorSeverity.warning,
        SkotiqColors.dark,
      );
      expect(celebrate, isNot(equals(warning)));

      // And both render without error.
      await _pumpCard(
        tester,
        _event(
          eventType: 'discovery.moving_object',
          category: NarratorCategory.discovery,
          severity: NarratorSeverity.celebrate,
          pinned: true,
          evidence: NarratorEvidence.scalar(value: 2.1, unit: '"/min'),
        ),
      );
      expect(find.byType(NarratorCard), findsOneWidget);
    });

    testWidgets('celebrate card uses a gradient edge (distinct treatment)',
        (tester) async {
      await _pumpCard(
        tester,
        _event(
          category: NarratorCategory.discovery,
          severity: NarratorSeverity.celebrate,
        ),
      );
      // A celebrate card paints a gradient somewhere in its edge decoration.
      final containers = tester.widgetList<Container>(find.byType(Container));
      final hasGradient = containers.any((c) {
        final d = c.decoration;
        return d is BoxDecoration && d.gradient != null;
      });
      expect(hasGradient, isTrue,
          reason: 'celebrate severity gets a gradient edge accent.');
    });
  });

  group('NarratorCard interaction', () {
    testWidgets('tapping opens the detail sheet with the explainer',
        (tester) async {
      const eventType = 'equipment.tilt';
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                child: NarratorCard(
                  event: _event(
                    eventType: eventType,
                    category: NarratorCategory.equipment,
                    severity: NarratorSeverity.warning,
                    headline: 'Possible sensor tilt toward NE',
                    body: 'Stars in the top-right are ~30% softer.',
                  ),
                  relativeTime: '4m ago',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byType(NarratorCard));
      await tester.pumpAndSettle();

      // The explainer text for this event type appears in the sheet.
      expect(find.text('WHY THIS MATTERS'), findsOneWidget);
      final explainer = narratorExplainers[eventType]!;
      // Match a distinctive fragment of the explainer copy.
      expect(
        find.textContaining(explainer.substring(0, 24)),
        findsOneWidget,
      );
    });
  });

  group('showNarratorDetailSheet', () {
    testWidgets('shows headline, body, and explainer for a known event type',
        (tester) async {
      const eventType = 'milestone.calibration_locked';
      final event = _event(
        eventType: eventType,
        category: NarratorCategory.milestone,
        severity: NarratorSeverity.success,
        headline: 'Photometric calibration locked: ZP stable to ±0.03',
        body: 'Your zero-point has held steady across recent frames.',
        evidence: NarratorEvidence.delta(from: 0.06, to: 0.03, unit: 'mag'),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showNarratorDetailSheet(context, event),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(event.headline), findsOneWidget);
      expect(find.text(event.body!), findsOneWidget);
      expect(find.text('WHY THIS MATTERS'), findsOneWidget);
    });
  });

  group('narratorExplainers catalog', () {
    // Drive off the actual detector ids the engine instantiates, plus the
    // per-stage `quality.pipeline_failure.<stage>` permutations the
    // PipelineFailureDetector emits — every one must resolve via the same
    // helper the detail sheet uses, so no card loses its explainer/action.
    final engine = buildDefaultNarratorEngine();
    final eventTypes = <String>{
      for (final d in engine.detectors) d.id,
      for (final stage in ScienceStage.values)
        'quality.pipeline_failure.${stage.name}',
    };

    test('every emitted event type resolves an explainer via the helper', () {
      for (final type in eventTypes) {
        final explainer = narratorExplainerFor(type);
        expect(explainer, isNotNull,
            reason: '$type must resolve a "why this matters" explainer.');
        expect(explainer, isNotEmpty,
            reason: '$type must have non-empty explainer copy.');
      }
    });

    test('per-stage pipeline failures resolve the pipeline action', () {
      for (final stage in ScienceStage.values) {
        final type = 'quality.pipeline_failure.${stage.name}';
        final action = narratorActionFor(type);
        expect(action, isNotNull,
            reason: '$type must resolve the pipeline-failure action button.');
        expect(action!.route, '/analytics?tab=diagnostics');
      }
    });
  });
}
