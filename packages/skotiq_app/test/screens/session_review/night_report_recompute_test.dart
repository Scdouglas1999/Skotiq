// The Night Doctor verdict must not be computed once per session and never
// again: a stored report written by an older detector — or written on first
// view, before grading finished — otherwise survives every visit, and Refresh
// re-renders the same stale row rather than recomputing.
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart';

import '../../harness/mock_database.dart';

const _staleHeadline = 'A clean night — no problems detected (stale)';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ProviderContainer container;
  late int sessionId;
  final capturedAt = DateTime(2026, 8, 13, 20, 53);

  setUp(() async {
    db = mockDatabase();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );

    sessionId = await container.read(sessionsDaoProvider).createSession(
          ImagingSessionsCompanion.insert(startTime: capturedAt),
        );
    final images = container.read(imagesDaoProvider);
    for (var i = 0; i < 4; i++) {
      await images.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/subs/s$i.fits',
          fileName: 's$i.fits',
          sessionId: Value(sessionId),
          exposureDuration: 60,
          frameType: const Value('light'),
          hfr: Value(9.0 + i),
          isAccepted: const Value(true),
          capturedAt: capturedAt.add(Duration(minutes: i)),
        ),
      );
    }
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> seedStoredReport(DateTime createdAt) {
    return container.read(nightReportsDaoProvider).insertReport(
          sessionId: sessionId,
          score: 100,
          headline: _staleHeadline,
          createdAt: createdAt,
        );
  }

  SessionReviewController controller() => container.read(
        sessionReviewControllerProvider(SessionReviewScope.session(sessionId))
            .notifier,
      );

  SessionReviewState state() => container.read(
        sessionReviewControllerProvider(SessionReviewScope.session(sessionId)),
      );

  Future<void> waitUntilLoaded() async {
    for (var i = 0;
        i < 100 && (state().loading || state().loadingSmartData);
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('Refresh recomputes the verdict instead of re-reading it', () async {
    // Written after the last sub, so the staleness rule alone would keep it.
    await seedStoredReport(capturedAt.add(const Duration(hours: 1)));

    controller();
    await waitUntilLoaded();
    expect(
      state().nightReport?.headline,
      _staleHeadline,
      reason: 'a report that post-dates every sub is reused, by design',
    );

    await controller().refresh();
    await waitUntilLoaded();

    expect(
      state().nightReport?.headline,
      isNot(_staleHeadline),
      reason: 'Refresh is the operator saying "this verdict is wrong"',
    );
  });

  test('a report older than the frames it judges is recomputed on sight',
      () async {
    // The harder case: nobody thinks to press Refresh. A report written before
    // the run finished cannot have seen these subs.
    await seedStoredReport(capturedAt.subtract(const Duration(minutes: 1)));

    controller();
    await waitUntilLoaded();

    expect(
      state().nightReport?.headline,
      isNot(_staleHeadline),
      reason: 'it was written before three of the four subs existed',
    );
  });
}
