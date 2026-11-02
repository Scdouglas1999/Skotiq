import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/tabs/history_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  testWidgets('a run cut off by a restart is not shown as in progress',
      (tester) async {
    final started = DateTime.now().subtract(const Duration(hours: 1));
    final runs = [
      db.SequenceRun(
        id: 1,
        sequenceName: 'Cut off',
        startedAt: started,
        status: 'interrupted',
        statsJson: '{}',
      ),
      db.SequenceRun(
        id: 2,
        sequenceName: 'Live',
        startedAt: started,
        status: 'running',
        statsJson: '{}',
      ),
    ];
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          sequenceRunsProvider.overrideWith((ref) => Stream.value(runs)),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: HistoryTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('In progress'), findsOneWidget);
    expect(find.textContaining('Unknown'), findsOneWidget);
  });
}
