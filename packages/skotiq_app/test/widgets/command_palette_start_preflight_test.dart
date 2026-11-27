// The palette's "Start sequence" goes through pre-flight like every other
// interactive Start: it opens the pre-flight dialog instead of
// starting the run.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/widgets/preflight_validation_dialog.dart';
import 'package:skotiq_app/screens/shell/command_palette/command_entry.dart';
import 'package:skotiq_app/screens/shell/command_palette/command_palette.dart';
import 'package:skotiq_app/screens/shell/command_palette/command_sources.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Start sequence opens the pre-flight checks', (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showCommandPalette(context),
            child: const Text('palette'),
          ),
        ),
      ),
      size: const Size(1920, 1080),
    );
    await tester.tap(find.text('palette'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Start sequence');
    await tester.pump();
    await tester.tap(find.text('Start sequence').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(PreFlightValidationDialog), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  // A stop under way, or one that failed, is still a run: Start would open
  // the checks whose Start unparks the mount, and Stop is the way out.
  for (final lifecycle in [
    SequenceExecutionState.stopping,
    SequenceExecutionState.stopFailed,
    SequenceExecutionState.cleanupFailed,
  ]) {
    testWidgets('while ${lifecycle.name} the palette offers Stop, not Start',
        (tester) async {
      final backend = mockBackend();
      late List<CommandEntry> entries;
      late WidgetRef palRef;
      late BuildContext palContext;
      await pumpAppScreen(
        tester,
        Consumer(
          builder: (context, ref, _) {
            entries = buildActionEntries(context, ref);
            palRef = ref;
            palContext = context;
            return const SizedBox.expand();
          },
        ),
        size: const Size(1920, 1080),
        backend: backend,
        extraOverrides: [
          runRecordProvider.overrideWith(
            (ref) => RunRecordNotifier(ref, RunRecord(lifecycle: lifecycle)),
          ),
        ],
      );

      CommandEntry entry(String id) => entries.singleWhere((e) => e.id == id);
      final start = entry('action:sequence-start');
      final stop = entry('action:sequence-stop');
      expect(start.enabled, isFalse);
      expect(start.disabledReason, isNotNull);
      expect(
        stop.enabled,
        isTrue,
        reason: 'Stop stays offered until the run has stopped',
      );

      // The row is disabled, and its action refuses on its own too.
      start.invoke(palContext, palRef);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PreFlightValidationDialog), findsNothing);
      verifyNever(() => backend.mountUnpark(any()));
    });
  }
}
