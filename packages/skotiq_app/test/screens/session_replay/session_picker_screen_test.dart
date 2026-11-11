import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_app/screens/session_replay/session_picker_screen.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('deduplicates runs while advancing by the raw page offset', (
    tester,
  ) async {
    final backend = _PagedBackend((offset) async {
      if (offset == 0) {
        return RemotePage(items: [_run(1), _run(2)], total: 4);
      }
      return RemotePage(items: [_run(2), _run(3)], total: 4);
    });

    await tester.pumpWidget(_app(backend));
    await tester.pumpAndSettle();
    expect(find.text('Run 1'), findsOneWidget);
    expect(find.text('Run 2'), findsOneWidget);

    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();

    expect(find.text('Run 2'), findsOneWidget);
    expect(find.text('Run 3'), findsOneWidget);
    expect(backend.offsets, [0, 2]);
    expect(find.text('Load more'), findsNothing);
  });

  testWidgets('discards an old rig response after the backend changes', (
    tester,
  ) async {
    final oldPage = Completer<RemotePage<RemoteSequenceRun>>();
    final oldBackend = _PagedBackend((_) => oldPage.future);
    final newBackend = _PagedBackend(
      (_) async => RemotePage(items: [_run(20)], total: 1),
    );
    late _MutableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith((ref) {
            notifier = _MutableBackendNotifier(ref, oldBackend);
            return notifier;
          }),
        ],
        child: _materialApp(),
      ),
    );
    await tester.pump();
    expect(oldBackend.offsets, [0]);

    notifier.replace(newBackend);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Run 20'), findsOneWidget);

    oldPage.complete(RemotePage(items: [_run(10)], total: 1));
    await tester.pumpAndSettle();
    expect(find.text('Run 20'), findsOneWidget);
    expect(find.text('Run 10'), findsNothing);
  });

  testWidgets('without a linked host it says replay needs a connected rig', (
    tester,
  ) async {
    await tester.pumpWidget(_app(DisconnectedBackend()));
    await tester.pumpAndSettle();

    expect(find.text('Replay needs a connected rig'), findsOneWidget);
    expect(find.byTooltip('Refresh the run list'), findsNothing);
  });

  testWidgets('a host with no runs says so', (tester) async {
    final backend = _PagedBackend(
      (_) async => const RemotePage<RemoteSequenceRun>(items: [], total: 0),
    );
    await tester.pumpWidget(_app(backend));
    await tester.pumpAndSettle();

    expect(find.text('No past runs yet'), findsOneWidget);
  });

  testWidgets('a failed first page explains and tries again', (tester) async {
    var fail = true;
    final backend = _PagedBackend((_) async {
      if (fail) throw const SocketException('Connection refused');
      return RemotePage(items: [_run(7)], total: 1);
    });
    await tester.pumpWidget(_app(backend));
    await tester.pumpAndSettle();

    expect(find.text('Could not load past runs'), findsOneWidget);
    expect(find.textContaining('SocketException'), findsNothing);

    fail = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Run 7'), findsOneWidget);
  });

  testWidgets('a row shows the status in words and the frame count', (
    tester,
  ) async {
    final backend = _PagedBackend(
      (_) async => RemotePage(
        items: [
          _run(
            3,
            status: 'paused-stopped',
            statsJson:
                '{"framesCaptured": 42, "targetBreakdown": {"M 31": {}}}',
          ),
          _run(4, statsJson: 'not json'),
        ],
        total: 2,
      ),
    );
    await tester.pumpWidget(_app(backend));
    await tester.pumpAndSettle();

    expect(find.text('Stopped (resumable)'), findsOneWidget);
    expect(find.text('42 frames'), findsOneWidget);
    expect(find.textContaining('M 31'), findsOneWidget);
    // Unreadable statistics leave the count out instead of claiming zero.
    expect(find.text('0 frames'), findsNothing);
  });

  testWidgets('tapping a run opens its replay', (tester) async {
    final backend = _PagedBackend(
      (_) async => RemotePage(items: [_run(9)], total: 1),
    );
    final router = GoRouter(
      initialLocation: kSessionReplayRoutePath,
      routes: [
        GoRoute(
          path: kSessionReplayRoutePath,
          builder: (_, __) => const SessionPickerScreen(),
          routes: [
            GoRoute(
              path: ':runId',
              builder: (_, state) =>
                  Text('replay of ${state.pathParameters['runId']}'),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _MutableBackendNotifier(ref, backend),
          ),
        ],
        child: MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run 9'));
    await tester.pumpAndSettle();

    expect(find.text('replay of 9'), findsOneWidget);
  });
}

Widget _app(SkotiqBackend backend) => ProviderScope(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _MutableBackendNotifier(ref, backend),
        ),
      ],
      child: _materialApp(),
    );

Widget _materialApp() =>
    MaterialApp(theme: SkotiqTheme.dark, home: const SessionPickerScreen());

RemoteSequenceRun _run(
  int id, {
  String status = 'completed',
  String? statsJson,
}) =>
    RemoteSequenceRun(
      id: id,
      sequenceName: 'Run $id',
      startedAt: DateTime.utc(2026, 7, 13, 1, id),
      endedAt: DateTime.utc(2026, 7, 13, 1, id + 1),
      status: status,
      statsJson: statsJson,
    );

class _PagedBackend extends NetworkBackend {
  final Future<RemotePage<RemoteSequenceRun>> Function(int offset) page;
  final List<int> offsets = [];

  _PagedBackend(this.page)
      : super(serverHost: '127.0.0.1', autoConnectWebSocket: false);

  @override
  Future<RemotePage<RemoteSequenceRun>> fetchSequenceRuns({
    int? sequenceId,
    int limit = 200,
    int offset = 0,
  }) {
    offsets.add(offset);
    return page(offset);
  }
}

class _MutableBackendNotifier extends BackendNotifier {
  _MutableBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }

  void replace(SkotiqBackend backend) => state = backend;
}
