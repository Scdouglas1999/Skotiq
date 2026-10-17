import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_mobile/screens/replay/session_picker_screen.dart';
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
}

Widget _app(SkotiqBackend backend) => ProviderScope(
  overrides: [
    backendProvider.overrideWith(
      (ref) => _MutableBackendNotifier(ref, backend),
    ),
  ],
  child: _materialApp(),
);

Widget _materialApp() => MaterialApp(
  theme: ThemeData.dark().copyWith(extensions: const [SkotiqColors.dark]),
  home: const SessionPickerScreen(),
);

RemoteSequenceRun _run(int id) => RemoteSequenceRun(
  id: id,
  sequenceName: 'Run $id',
  startedAt: DateTime.utc(2026, 7, 13, 1, id),
  endedAt: DateTime.utc(2026, 7, 13, 1, id + 1),
  status: 'completed',
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
