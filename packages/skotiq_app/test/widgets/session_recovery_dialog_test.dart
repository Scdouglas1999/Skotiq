import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/widgets/session_recovery_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockSessionService extends Mock implements SessionService {}

SessionRecoveryInfo _session(int id, String name) => SessionRecoveryInfo(
      sessionId: id,
      sessionName: name,
      startTime: DateTime(2026, 7, 12, 22),
      stats: SessionStats(lastUpdated: DateTime(2026, 7, 12, 23)),
    );

Widget _app(_MockSessionService service, List<SessionRecoveryInfo> sessions) {
  return ProviderScope(
    overrides: [sessionServiceProvider.overrideWithValue(service)],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: SessionRecoveryDialog(incompleteSessions: sessions)),
    ),
  );
}

void main() {
  testWidgets('failed Resume stays open and can be retried', (tester) async {
    final service = _MockSessionService();
    when(() => service.recoverSession(7))
        .thenThrow(StateError('database unavailable'));

    await tester.pumpWidget(_app(service, [_session(7, 'M31 interrupted')]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Resume'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(SessionRecoveryDialog), findsOneWidget);
    expect(find.text('M31 interrupted'), findsOneWidget);
    expect(
        find.textContaining('Could not recover the session'), findsOneWidget);

    await tester.tap(find.text('Resume'));
    await tester.pump();
    verify(() => service.recoverSession(7)).called(2);
  });

  testWidgets('Discard All keeps only failed sessions available for retry',
      (tester) async {
    final service = _MockSessionService();
    when(() => service.markSessionAborted(1)).thenAnswer((_) async {});
    when(() => service.markSessionAborted(2))
        .thenThrow(StateError('write failed'));

    await tester.pumpWidget(
      _app(service, [_session(1, 'Succeeded'), _session(2, 'Still pending')]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Discard all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(SessionRecoveryDialog), findsOneWidget);
    expect(find.text('Succeeded'), findsNothing);
    expect(find.text('Still pending'), findsOneWidget);
    expect(find.textContaining('still available to retry'), findsOneWidget);
    verify(() => service.markSessionAborted(1)).called(1);
    verify(() => service.markSessionAborted(2)).called(1);
  });

  testWidgets('pending recovery disables every exit and competing action',
      (tester) async {
    final service = _MockSessionService();
    final recovery = Completer<void>();
    when(() => service.recoverSession(1)).thenAnswer((_) => recovery.future);

    await tester.pumpWidget(
      _app(service, [_session(1, 'Recovering'), _session(2, 'Other')]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Resume').first);
    await tester.pump();

    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
    await tester.tap(find.text('Decide later'));
    await tester.tap(find.text('Discard all'));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(SessionRecoveryDialog), findsOneWidget);
    verifyNever(() => service.markSessionAborted(any()));

    recovery.complete();
    await tester.pump();
  });
}
