import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_timeline.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _SettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

void main() {
  testWidgets('uses wall-clock timing and does not duplicate rooted targets',
      (tester) async {
    final exposure = ExposureNode(
      name: 'Light frame',
      durationSecs: 59,
      count: 1,
      ditherEvery: null,
    );
    final target = TargetHeaderNode(
      name: 'M31',
      targetName: 'M31',
      raHours: 0.7,
      decDegrees: 41.2,
      childIds: [exposure.id],
    );
    final root = InstructionSetNode(
      name: 'Root',
      childIds: [target.id],
    );
    final sequence = Sequence.create(
      name: 'Timeline test',
      rootNodeId: root.id,
      nodes: {
        root.id: root,
        target.id: target.copyWith(parentId: root.id),
        exposure.id: exposure.copyWith(parentId: target.id),
      },
    );
    final editor = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    editor.state = sequence;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        currentSequenceProvider.overrideWith((_) => editor),
        appSettingsProvider.overrideWith(_SettingsNotifier.new),
        sequencerOverheadConfigProvider.overrideWithValue(
          const SequenceOverheadConfig(
            downloadOverheadPerExposureSecs: 2,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SequenceTimeline(
              colors: SkotiqColors.dark,
              showAstronomicalOverlay: false,
            ),
          ),
        ),
      ),
    );
    await container.read(appSettingsProvider.future);
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            widget.message?.startsWith('Light frame\n') == true,
      ),
      findsOneWidget,
      reason: 'the rooted target subtree must be traversed exactly once',
    );
    expect(
      find.text('1m total'),
      findsOneWidget,
      reason: '59s integration plus 2s download overhead is over one minute',
    );
  });
}
