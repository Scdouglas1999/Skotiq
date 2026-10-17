import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/narrator_ticker.dart';
import 'package:skotiq_app/widgets/narrator/narrator_feed.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Fixed-state session notifier so the ticker resolves a stable
/// [SessionState.dbSessionId] without touching the real session service.
class _FakeSessionNotifier extends StateNotifier<SessionState>
    implements SessionStateNotifier {
  _FakeSessionNotifier(int? dbSessionId)
      : super(SessionState(dbSessionId: dbSessionId));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _sessionId = 42;

NarratorEvent _event({
  required int id,
  required String headline,
  required Duration age,
  NarratorCategory category = NarratorCategory.quality,
  NarratorSeverity severity = NarratorSeverity.info,
  bool pinned = false,
}) {
  return NarratorEvent(
    id: id,
    timestamp: DateTime.now().subtract(age),
    eventType: 'quality.test',
    category: category,
    severity: severity,
    headline: headline,
    dedupeKey: 'k$id',
    sessionId: _sessionId,
    pinned: pinned,
  );
}

Future<void> _pumpTicker(
  WidgetTester tester, {
  required List<NarratorEvent> events,
  int? sessionId = _sessionId,
  List<NarratorEvent> sessionlessEvents = const [],
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1000, 700);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionStateProvider
            .overrideWith((ref) => _FakeSessionNotifier(sessionId)),
        if (sessionId != null)
          narratorFeedProvider(sessionId)
              .overrideWith((ref) => Stream.value(events)),
        recentNarratorFeedProvider
            .overrideWith((ref) => Stream.value(sessionlessEvents)),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: NarratorTicker(),
          ),
        ),
      ),
    ),
  );
  // Let the overridden stream emit its first value.
  await tester.pump();
}

void main() {
  testWidgets('hidden when the feed is empty', (tester) async {
    await _pumpTicker(tester, events: const []);

    expect(find.byType(NarratorTicker), findsOneWidget);
    expect(tester.getSize(find.byType(NarratorTicker)), Size.zero);
  });

  // Manual captures on the imaging screen never open a DB session — only the
  // sequencer calls startSession — so the narrator writes their insights into
  // the sessionless bucket. Reading only the session feed left the strip
  // permanently blank for a hand-driven night.
  testWidgets('speaks the sessionless feed when there is no DB session',
      (tester) async {
    await _pumpTicker(
      tester,
      sessionId: null,
      events: const [],
      sessionlessEvents: [
        _event(
          id: 9,
          headline: 'Cooling reached −10.0 °C',
          age: const Duration(seconds: 20),
        ),
      ],
    );

    expect(find.text('Cooling reached −10.0 °C'), findsOneWidget);
  });

  testWidgets('sessionless strip stays quiet on a stale bucket',
      (tester) async {
    // The sessionless bucket outlives the app, so its newest entry may be from
    // a previous night; there is no run to scope it to, and resting on it would
    // put last week's headline over tonight's canvas.
    await _pumpTicker(
      tester,
      sessionId: null,
      events: const [],
      sessionlessEvents: [
        _event(
          id: 8,
          headline: 'Last week',
          age: const Duration(days: 6),
        ),
      ],
    );

    expect(tester.getSize(find.byType(NarratorTicker)), Size.zero);
  });

  // The window has to be re-checked on a clock, not only when the feed
  // changes. recentNarratorFeedProvider is a DB watch: on a hand-driven night
  // it emits once when an insight is written and then stays silent, so an
  // admission-time-only check left that headline — and its "1m ago" label —
  // pinned over the canvas for the rest of the night.
  testWidgets('sessionless headline retires once it ages out of the window',
      (tester) async {
    var now = DateTime(2026, 8, 9, 22, 0, 0);
    NarratorTicker.clock = () => now;
    addTearDown(() => NarratorTicker.clock = DateTime.now);

    await _pumpTicker(
      tester,
      sessionId: null,
      events: const [],
      sessionlessEvents: [
        NarratorEvent(
          id: 11,
          timestamp: now.subtract(const Duration(minutes: 1)),
          eventType: 'quality.test',
          category: NarratorCategory.quality,
          severity: NarratorSeverity.info,
          headline: 'Guiding settled at 0.6"',
          dedupeKey: 'k11',
        ),
      ],
    );

    expect(find.text('Guiding settled at 0.6"'), findsOneWidget);

    // A quiet stretch: no new narrator rows, so the feed stream never emits.
    now = now.add(const Duration(minutes: 20));
    await tester.pump(const Duration(seconds: 7));

    expect(find.text('Guiding settled at 0.6"'), findsNothing);
    expect(tester.getSize(find.byType(NarratorTicker)), Size.zero);
  });

  testWidgets('shows the newest event headline', (tester) async {
    await _pumpTicker(
      tester,
      events: [
        _event(
          id: 2,
          headline: 'Best seeing of the night — FWHM 1.8"',
          age: const Duration(seconds: 5),
        ),
        _event(
          id: 1,
          headline: 'Older insight',
          age: const Duration(minutes: 3),
        ),
      ],
    );

    expect(
      find.text('Best seeing of the night — FWHM 1.8"'),
      findsOneWidget,
    );
  });

  testWidgets('counter chip appears with more than one recent event',
      (tester) async {
    await _pumpTicker(
      tester,
      events: [
        _event(id: 3, headline: 'Event three', age: const Duration(seconds: 5)),
        _event(id: 2, headline: 'Event two', age: const Duration(minutes: 1)),
        _event(id: 1, headline: 'Event one', age: const Duration(minutes: 2)),
      ],
    );

    // Rotation count = 3.
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('no counter chip with a single recent event', (tester) async {
    await _pumpTicker(
      tester,
      events: [
        _event(id: 1, headline: 'Solo event', age: const Duration(seconds: 5)),
      ],
    );

    expect(find.text('Solo event'), findsOneWidget);
    expect(find.text('1'), findsNothing);
  });

  testWidgets('rotation advances to the next event after the interval',
      (tester) async {
    await _pumpTicker(
      tester,
      events: [
        _event(
            id: 2, headline: 'Newest event', age: const Duration(seconds: 5)),
        _event(
            id: 1, headline: 'Second event', age: const Duration(minutes: 1)),
      ],
    );

    expect(find.text('Newest event'), findsOneWidget);

    // Advance past the 6s rotation interval and let the switcher settle.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Second event'), findsOneWidget);
  });

  testWidgets('tap opens a bottom sheet with the full feed', (tester) async {
    await _pumpTicker(
      tester,
      events: [
        _event(
            id: 2,
            headline: 'Tap target headline',
            age: const Duration(seconds: 5)),
        _event(
            id: 1,
            headline: 'Feed-only headline',
            age: const Duration(minutes: 2)),
      ],
    );

    await tester.tap(find.byType(NarratorTicker));
    await tester.pumpAndSettle();

    // The sheet hosts the shared NarratorFeed; both events render in it.
    expect(find.byType(NarratorFeed), findsOneWidget);
    expect(find.text('Night narrator'), findsOneWidget);
    expect(find.text('Feed-only headline'), findsWidgets);
  });
}
