// Saving a plan is Ctrl+S and the canvas bar's floppy, as in every editor.
//
// The walk-through edited a starter, pressed Ctrl+S (nothing happened), then
// the floppy (a native "Save File" dialog: it was Export), and found the real
// library save on the Saved tab. A user who stops at either of the first two
// believes the plan is saved when it is not.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

class _MockSequenceRepository extends Mock implements SequenceRepository {}

Sequence _plan({int? databaseId, bool isTemplate = false}) {
  final exposure = ExposureNode(name: 'Lum', durationSecs: 120, count: 10);
  final root = InstructionSetNode(name: 'Root');
  return Sequence.create(
    name: 'Whirlpool',
    databaseId: databaseId,
    isTemplate: isTemplate,
    nodes: {
      exposure.id: exposure.copyWith(parentId: root.id),
      root.id: root.copyWith(childIds: [exposure.id]),
    },
    rootNodeId: root.id,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => registerFallbackValue(Sequence.create(name: 'fallback')));

  late _MockSequenceRepository repository;

  setUp(() {
    repository = _MockSequenceRepository();
    when(() => repository.saveSequence(any(),
        isTemplate: any(named: 'isTemplate'))).thenAnswer((_) async => 7);
    when(() => repository.snapshotVersionOnSave(any()))
        .thenAnswer((_) async => 1);
  });

  Future<HarnessHandle> pumpWith(WidgetTester tester, Sequence plan) async {
    final handle = await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(1600, 1000),
      extraOverrides: [
        currentSequenceProvider
            .overrideWith((ref) => CurrentSequenceNotifier(ref: ref)),
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.idle),
        sequenceRepositoryProvider.overrideWithValue(repository),
        ledgerClockProvider
            .overrideWith((ref) => const Stream<DateTime>.empty()),
      ],
      settle: false,
    );
    handle.container.read(currentSequenceProvider.notifier).loadSequence(plan);
    await tester.pump(const Duration(milliseconds: 600));
    return handle;
  }

  Future<void> pressCtrlS(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('Ctrl+S writes a plan that is in the library over its row',
      (tester) async {
    final handle = await pumpWith(tester, _plan(databaseId: 7));
    final editor = handle.container.read(currentSequenceProvider.notifier);
    editor.setName('Whirlpool LRGB');
    await tester.pump();
    expect(
      handle.container.read(sequenceHasUnsavedChangesProvider),
      isTrue,
    );
    expect(find.text('· unsaved changes'), findsOneWidget);

    await pressCtrlS(tester);

    final saved = verify(() => repository.saveSequence(captureAny(),
        isTemplate: false)).captured.single as Sequence;
    expect(saved.databaseId, 7);
    expect(saved.name, 'Whirlpool LRGB');
    expect(find.text('Saved "Whirlpool LRGB"'), findsOneWidget);
    expect(editor.isDirty, isFalse);
    expect(find.text('· unsaved changes'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an edit made while Ctrl+S is writing stays unsaved',
      (tester) async {
    final write = Completer<int>();
    when(() => repository.saveSequence(any(),
        isTemplate: any(named: 'isTemplate'))).thenAnswer((_) => write.future);
    final handle = await pumpWith(tester, _plan(databaseId: 7));
    final editor = handle.container.read(currentSequenceProvider.notifier);
    editor.setName('Whirlpool LRGB');
    await tester.pump();

    await pressCtrlS(tester);
    editor.setName('Whirlpool LRGB v2');
    write.complete(7);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Saved "Whirlpool LRGB"'), findsOneWidget);
    expect(editor.state?.name, 'Whirlpool LRGB v2');
    expect(editor.isDirty, isTrue);
    expect(find.text('· unsaved changes'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Ctrl+S asks for a name the first time a plan is saved',
      (tester) async {
    await pumpWith(tester, _plan());

    await pressCtrlS(tester);

    expect(find.text('Save sequence'), findsOneWidget);
    verifyNever(() => repository.saveSequence(any(),
        isTemplate: any(named: 'isTemplate')));
    await tester.tap(find.widgetWithText(SkotiqButton, 'Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    verify(() => repository.saveSequence(any(), isTemplate: false)).called(1);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('saving an open template keeps it a template', (tester) async {
    await pumpWith(tester, _plan(databaseId: 7, isTemplate: true));

    await tester.tap(find.byWidgetPredicate((widget) =>
        widget is SkotiqIconButton &&
        widget.tooltip == 'Save to the library (Ctrl+S)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    verify(() => repository.saveSequence(any(), isTemplate: true)).called(1);
    await tester.pump(const Duration(seconds: 5));
  });
}
