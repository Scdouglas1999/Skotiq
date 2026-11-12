// The Starters section used to promise something it does not do.
//
// Caption: "Tap a card to copy one into your current sequence."
// Behaviour: _useStarter calls loadSequence, which REPLACES the current
// sequence outright. "Copy into" reads as append/merge, which is the one
// reading that would make an operator tap it with work already loaded.
//
// This pins the caption and the button label to what the code actually does,
// and asserts the replace behaviour in the same test so the words cannot be
// made true by weakening them.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/tabs/templates_tab.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockSequenceRepository extends Mock implements SequenceRepository {}

SampleSequence _starter({Sequence? template}) => SampleSequence(
      id: 'starter',
      displayName: 'Safe Starter',
      description: 'A starter sequence',
      iconName: 'camera',
      skillLevel: SampleSequenceSkillLevel.beginner,
      expectedTotalTime: '10 min',
      assetPath: 'unused',
      template: template ?? Sequence.create(name: 'Safe Starter'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CurrentSequenceNotifier> pump(
    WidgetTester tester, {
    SampleSequence? starter,
    List<String> wheel = const [],
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final repository = _MockSequenceRepository();
    when(() => repository.loadAllTemplates()).thenAnswer((_) async => []);
    final editor = CurrentSequenceNotifier();
    editor.loadSequence(Sequence.create(name: 'Work in progress'));
    // Saved, so the discard confirmation does not intercept the tap.
    editor.markSaved();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sequenceRepositoryProvider.overrideWithValue(repository),
          currentSequenceProvider.overrideWith((ref) => editor),
          allSnippetsProvider.overrideWithValue(const []),
          sampleSequencesProvider
              .overrideWith((ref) async => [starter ?? _starter()]),
          filterNamesToMatchProvider.overrideWithValue(wheel),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: TemplatesTab()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return editor;
  }

  testWidgets('the Starters caption says replace, not copy-into',
      (tester) async {
    await pump(tester);

    expect(
      find.textContaining('copy one into your current sequence'),
      findsNothing,
    );
    expect(
      find.textContaining('replaces your current sequence'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SkotiqButton, 'Use this starter'),
      findsOneWidget,
    );
  });

  testWidgets('and the action really does replace the whole sequence',
      (tester) async {
    final editor = await pump(tester);
    final before = editor.state!.id;

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Use this starter'),
    );
    await tester.pump();

    expect(find.text('Discard unsaved changes?'), findsNothing);
    expect(editor.state!.name, 'Safe Starter');
    expect(editor.state!.id, isNot(before));
  });

  // Starters name L/R/G/B; a wheel that calls them Luminance/Red/... gets
  // the plan in its own names instead of a pre-flight that fails.
  testWidgets('a starter takes the wheel\'s names for its filters',
      (tester) async {
    final root = InstructionSetNode(name: 'Root');
    final lights = ExposureNode(name: 'Lights', filter: 'L');
    final editor = await pump(
      tester,
      wheel: const ['Luminance', 'Red', 'Green', 'Blue'],
      starter: _starter(
        template: Sequence.create(
          name: 'Safe Starter',
          rootNodeId: root.id,
          nodes: {
            root.id: root.copyWith(childIds: [lights.id]),
            lights.id: lights.copyWith(parentId: root.id),
          },
        ),
      ),
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Use this starter'));
    await tester.pump();

    final loaded = editor.state!.nodes.values.whereType<ExposureNode>().single;
    expect(loaded.filter, 'Luminance');
    expect(find.textContaining('L → Luminance'), findsOneWidget);
  });
}
