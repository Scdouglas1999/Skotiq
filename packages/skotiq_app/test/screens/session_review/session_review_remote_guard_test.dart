import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/session_review_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('remote review is guarded before its local DAO controller starts',
      (tester) async {
    const scope = SessionReviewScope.session(42);
    final backend = _MockNetworkBackend();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          sessionReviewControllerProvider(scope).overrideWith(
            (ref) => throw StateError(
              'The local SessionReviewController must not start remotely',
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const SessionReviewScreen(scope: scope),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text('Open Session Review on the imaging host'),
      findsOneWidget,
    );
    expect(find.textContaining('Remote Session Review is unavailable'),
        findsOneWidget);
  });

  testWidgets(
    'a --remote-host client that has not reached its rig is guarded too, and '
    'is offered no control that would run a pass on its own database',
    (tester) async {
      // The gate read `backend is NetworkBackend` — a CONNECTION fact. A
      // desktop launched with `--remote-host` is `Disconnected` until its
      // handshake and again after every drop, so for that whole window this
      // screen opened over the CLIENT's own database with every rig-executing
      // control live: pressing "Process now" ran a full Darkroom pass AND its
      // delivery there, writing a `darkroom_jobs` row and nine
      // `delivery_journal` rows no dawn job on the rig will ever read.
      const scope = SessionReviewScope.session(42);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            remoteClientLaunchProvider.overrideWithValue(true),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, DisconnectedBackend()),
            ),
            sessionReviewControllerProvider(scope).overrideWith(
              (ref) => throw StateError(
                'The local SessionReviewController must not start on a client',
              ),
            ),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const SessionReviewScreen(scope: scope),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text('Open Session Review on the imaging host'),
        findsOneWidget,
      );
      // Every rig-executing control this screen carries is inside the arm the
      // gate returns before, so naming the pass is enough to prove the class:
      // the Stop, the integration runs, the finishing steps, the master
      // library's accumulate/finalize/delete and its Darkroom buttons are all
      // built by the same subtree.
      expect(
        find.byKey(const ValueKey('session_review_process_now')),
        findsNothing,
      );
      expect(find.text('Refresh'), findsNothing);
      expect(find.text('Workbench'), findsNothing);
    },
  );
}
