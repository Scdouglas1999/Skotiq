import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/night_story_timeline.dart';
import 'package:skotiq_app/widgets/narrator/narrator_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

NarratorEvent _event({
  required int id,
  required DateTime timestamp,
  NarratorCategory category = NarratorCategory.quality,
  NarratorSeverity severity = NarratorSeverity.info,
  String? headline,
  bool pinned = false,
}) {
  return NarratorEvent(
    id: id,
    sessionId: 7,
    timestamp: timestamp,
    eventType: '${category.name}.test',
    category: category,
    severity: severity,
    headline: headline ?? 'Event $id (${category.name})',
    dedupeKey: 'k$id',
    pinned: pinned,
  );
}

Future<void> _pumpTimeline(
  WidgetTester tester, {
  required int? sessionId,
  List<NarratorEvent> events = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (sessionId != null)
          narratorFeedProvider(sessionId).overrideWith(
            (ref) => Stream.value(events),
          ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: NightStoryTimeline(sessionId: sessionId),
            ),
          ),
        ),
      ),
    ),
  );
  // Let the StreamProvider deliver its first value.
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fixed local timestamps in two different hours of the same evening.
  DateTime at(int hour, int minute) => DateTime(2026, 6, 11, hour, minute);

  group('groupNightStoryByHour', () {
    test('buckets by local hour and orders chronologically', () {
      // Deliberately out of order on input (feed is pinned/newest-first).
      final events = [
        _event(id: 1, timestamp: at(22, 15)),
        _event(id: 2, timestamp: at(21, 5)),
        _event(id: 3, timestamp: at(21, 40)),
        _event(id: 4, timestamp: at(22, 2)),
      ];

      final groups = groupNightStoryByHour(events);

      expect(groups.map((g) => g.label).toList(), ['21:00', '22:00']);
      // Within the 21:00 bucket: oldest -> newest (21:05 then 21:40).
      expect(groups[0].events.map((e) => e.id).toList(), [2, 3]);
      // Within the 22:00 bucket: 22:02 then 22:15.
      expect(groups[1].events.map((e) => e.id).toList(), [4, 1]);
    });

    test('empty input yields no groups', () {
      expect(groupNightStoryByHour(const []), isEmpty);
    });

    test('pads single-digit hours to two digits', () {
      final groups =
          groupNightStoryByHour([_event(id: 1, timestamp: at(9, 3))]);
      expect(groups.single.label, '09:00');
    });
  });

  group('filterNightStoryEvents', () {
    final events = [
      _event(id: 1, timestamp: at(21, 0), category: NarratorCategory.discovery),
      _event(id: 2, timestamp: at(21, 5), category: NarratorCategory.milestone),
      _event(id: 3, timestamp: at(21, 9), category: NarratorCategory.quality),
    ];

    test('all / empty passes everything through', () {
      expect(filterNightStoryEvents(events, {NightStoryFilter.all}), events);
      expect(filterNightStoryEvents(events, {}), events);
    });

    test('single category narrows to matching events', () {
      final result =
          filterNightStoryEvents(events, {NightStoryFilter.discovery});
      expect(result.map((e) => e.id).toList(), [1]);
    });

    test('multi-select unions the selected categories', () {
      final result = filterNightStoryEvents(
        events,
        {NightStoryFilter.discovery, NightStoryFilter.quality},
      );
      expect(result.map((e) => e.id).toList(), [1, 3]);
    });
  });

  group('summarizeNightStory', () {
    test('counts categories and folds warning+critical into warnings', () {
      final summary = summarizeNightStory([
        _event(
            id: 1,
            timestamp: at(21, 0),
            category: NarratorCategory.discovery,
            severity: NarratorSeverity.celebrate),
        _event(
            id: 2,
            timestamp: at(21, 1),
            category: NarratorCategory.milestone,
            severity: NarratorSeverity.success),
        _event(
            id: 3,
            timestamp: at(21, 2),
            category: NarratorCategory.equipment,
            severity: NarratorSeverity.warning),
        _event(
            id: 4,
            timestamp: at(21, 3),
            category: NarratorCategory.equipment,
            severity: NarratorSeverity.critical),
      ]);

      expect(summary.discoveries, 1);
      expect(summary.milestones, 1);
      expect(summary.equipment, 2);
      expect(summary.warnings, 2); // warning + critical
      expect(summary.total, 4);
    });
  });

  group('NightStoryTimeline widget', () {
    testWidgets('null session shows the empty state', (tester) async {
      await _pumpTimeline(tester, sessionId: null);
      expect(
          find.textContaining('No story yet for this session'), findsOneWidget);
      expect(find.byType(NarratorCard), findsNothing);
    });

    testWidgets('empty feed shows the empty state', (tester) async {
      await _pumpTimeline(tester, sessionId: 7, events: const []);
      expect(
          find.textContaining('No story yet for this session'), findsOneWidget);
      expect(find.byType(NarratorCard), findsNothing);
      // The empty state alone: a count strip saying "No events yet" and a
      // row of filter chips with nothing to filter said it twice more.
      expect(find.text('No events yet this session.'), findsNothing);
      expect(find.text('Discoveries'), findsNothing);
    });

    testWidgets('renders hour headers, summary strip and filter chips',
        (tester) async {
      final events = [
        _event(
            id: 1,
            timestamp: at(21, 5),
            category: NarratorCategory.discovery,
            severity: NarratorSeverity.celebrate,
            headline: 'Moving object detected'),
        _event(
            id: 2,
            timestamp: at(21, 40),
            category: NarratorCategory.milestone,
            headline: 'Calibration locked'),
        _event(
            id: 3,
            timestamp: at(22, 2),
            category: NarratorCategory.quality,
            severity: NarratorSeverity.warning,
            headline: 'Reject burst'),
      ];

      await _pumpTimeline(tester, sessionId: 7, events: events);

      // Hour headers (two distinct hours).
      expect(find.text('21:00'), findsOneWidget);
      expect(find.text('22:00'), findsOneWidget);

      // Absolute HH:MM times appear on the rows.
      expect(find.text('21:05'), findsOneWidget);
      expect(find.text('22:02'), findsOneWidget);

      // Summary strip counts (discovery, milestone, warning).
      expect(
        find.textContaining('1 discovery'),
        findsOneWidget,
      );
      expect(
        find.textContaining('1 warning'),
        findsOneWidget,
      );

      // One card per event, and the chip row is present.
      expect(find.byType(NarratorCard), findsNWidgets(3));
      expect(find.widgetWithText(ChoiceChip, 'All'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Discoveries'), findsOneWidget);
    });

    testWidgets('tapping a category chip filters the timeline', (tester) async {
      final events = [
        _event(
            id: 1,
            timestamp: at(21, 5),
            category: NarratorCategory.discovery,
            headline: 'A discovery'),
        _event(
            id: 2,
            timestamp: at(21, 40),
            category: NarratorCategory.milestone,
            headline: 'A milestone'),
      ];

      await _pumpTimeline(tester, sessionId: 7, events: events);
      expect(find.byType(NarratorCard), findsNWidgets(2));

      // Select only Discoveries — the milestone row should drop out.
      await tester.tap(find.widgetWithText(ChoiceChip, 'Discoveries'));
      await tester.pumpAndSettle();

      expect(find.byType(NarratorCard), findsOneWidget);
      expect(find.text('A discovery'), findsOneWidget);
      expect(find.text('A milestone'), findsNothing);

      // The 22:00-less story now only has the 21:00 header.
      expect(find.text('21:00'), findsOneWidget);
    });
  });
}
