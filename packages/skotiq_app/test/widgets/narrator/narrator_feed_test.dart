import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/narrator/narrator_card.dart';
import 'package:skotiq_app/widgets/narrator/narrator_feed.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

NarratorEvent _event({
  required int id,
  required String headline,
  bool pinned = false,
  DateTime? timestamp,
}) {
  return NarratorEvent(
    id: id,
    timestamp: timestamp ?? DateTime.now(),
    eventType: 'quality.reject_burst',
    category: NarratorCategory.quality,
    severity: NarratorSeverity.warning,
    headline: headline,
    dedupeKey: 'k$id',
    pinned: pinned,
  );
}

Future<void> _pumpFeed(WidgetTester tester, Widget feed) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SizedBox(width: 360, height: 600, child: feed),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty feed shows the watcher empty state', (tester) async {
    await _pumpFeed(
      tester,
      const NarratorFeed(events: <NarratorEvent>[]),
    );
    expect(
      find.textContaining('The Narrator is watching'),
      findsOneWidget,
    );
    expect(find.byType(NarratorCard), findsNothing);
  });

  testWidgets('renders one card per event in the given order', (tester) async {
    final now = DateTime.now();
    // Provider hands these already ordered (pinned first, then newest first).
    final events = [
      _event(id: 3, headline: 'Pinned discovery', pinned: true),
      _event(
        id: 2,
        headline: 'Newest unpinned',
        timestamp: now.subtract(const Duration(minutes: 1)),
      ),
      _event(
        id: 1,
        headline: 'Older unpinned',
        timestamp: now.subtract(const Duration(minutes: 10)),
      ),
    ];
    await _pumpFeed(tester, NarratorFeed(events: events));

    expect(find.byType(NarratorCard), findsNWidgets(3));

    // The feed trusts the incoming order: pinned card sits above the others.
    final pinnedY = tester.getTopLeft(find.text('Pinned discovery')).dy;
    final newestY = tester.getTopLeft(find.text('Newest unpinned')).dy;
    final olderY = tester.getTopLeft(find.text('Older unpinned')).dy;
    expect(pinnedY, lessThan(newestY));
    expect(newestY, lessThan(olderY));
  });

  testWidgets('compact feed caps the rendered events', (tester) async {
    final events = List.generate(
      12,
      (i) => _event(id: i, headline: 'Event $i'),
    );
    await _pumpFeed(
      tester,
      NarratorFeed.compact(events: events, maxEvents: 8),
    );
    expect(find.byType(NarratorCard), findsNWidgets(8));
  });

  group('formatNarratorRelativeTime', () {
    final t0 = DateTime(2026, 6, 11, 22, 0, 0);
    test('just now under 45s', () {
      expect(
        formatNarratorRelativeTime(
          t0.subtract(const Duration(seconds: 20)),
          now: t0,
        ),
        'just now',
      );
    });
    test('minutes', () {
      expect(
        formatNarratorRelativeTime(
          t0.subtract(const Duration(minutes: 4)),
          now: t0,
        ),
        '4m ago',
      );
    });
    test('hours', () {
      expect(
        formatNarratorRelativeTime(
          t0.subtract(const Duration(hours: 2)),
          now: t0,
        ),
        '2h ago',
      );
    });
    test('days', () {
      expect(
        formatNarratorRelativeTime(
          t0.subtract(const Duration(days: 3)),
          now: t0,
        ),
        '3d ago',
      );
    });
    test('future timestamps clamp to just now', () {
      expect(
        formatNarratorRelativeTime(
          t0.add(const Duration(minutes: 5)),
          now: t0,
        ),
        'just now',
      );
    });
  });
}
