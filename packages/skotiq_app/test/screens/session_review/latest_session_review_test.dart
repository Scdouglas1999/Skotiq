// Live (u1-audit): Session review from the command palette opened a session
// that does not exist and raised "FOREIGN KEY constraint failed". With no
// session in the link it opens the last night, or says there is none.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/session_review_screen.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester, int? latest) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          latestReviewSessionIdProvider.overrideWith((ref) async => latest),
          sessionReviewControllerProvider(
            const SessionReviewScope.session(7),
          ).overrideWith((ref) => throw StateError('opened session 7')),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const LatestSessionReviewScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('with no night yet it says so', (tester) async {
    await pump(tester, null);
    expect(find.text('No night to review yet'), findsOneWidget);
  });

  testWidgets('it opens the most recent night', (tester) async {
    await pump(tester, 7);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SessionReviewScreen &&
            w.scope == const SessionReviewScope.session(7),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isA<StateError>());
  });
}
