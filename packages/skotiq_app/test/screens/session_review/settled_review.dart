import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';

/// Wait until the review [read] returns has loaded its subs and its smart data.
///
/// The loads run on the database's real-time queue, so real time has to pass;
/// how much depends on the machine's load, so this polls up to 10 s and then
/// fails, rather than giving up after a fixed budget and letting the caller
/// assert on a half-loaded state.
Future<SessionReviewState> settledReview(
  SessionReviewState Function() read,
) async {
  bool busy() => read().loading || read().loadingSmartData;
  for (var i = 0; i < 1000 && busy(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(busy(), isFalse, reason: 'the review did not finish loading in 10 s');
  return read();
}
