import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unmount the widget tree and let drift's stream-close timer run.
///
/// Why this is needed: once a test gives its `ProviderScope` a real (in-memory)
/// database, any provider that watches a drift query stream holds a live
/// subscription. Disposing the scope cancels it, and drift schedules a
/// **zero-duration** `Timer` inside `StreamQueryStore.markAsClosed` to finish
/// the teardown. Flutter's test binding then fails the test with
/// `'!timersPending'` — a pending timer, reported against whatever assertion
/// happened to be last, so it reads like a failure in the thing under test
/// rather than in its teardown.
///
/// A `tearDown` cannot fix it: the binding checks for pending timers *before*
/// tear-downs run. The drain has to happen inside the test body, which is what
/// this is.
///
/// The second pump takes a non-zero duration on purpose. A bare `pump()` does
/// not advance the fake clock, so a timer scheduled for *now* is still queued
/// when the invariant runs and the test fails anyway.
Future<void> settleProviderTeardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}
