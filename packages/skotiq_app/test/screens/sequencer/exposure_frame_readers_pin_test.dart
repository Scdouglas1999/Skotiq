// What each surface that counts an exposure step's frames shows for the same
// run state: the Sequencer's folded filter row, Tonight's plan, the tree's
// progress card and the Activity tab. All four read one core function
// (`exposureNodeFrames`); this table pins what each one shows.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/sequencer/sequence_fold_model.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_activity_tab.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_progress_panels.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _Row {
  const _Row(
    this.name, {
    this.tally,
    this.typed,
    this.line,
    this.status,
    required this.fold,
    required this.night,
    required this.card,
    required this.activity,
  });

  final String name;
  final NodeExposureTally? tally;
  final InstructionProgressDetail? typed;
  final String? line;
  final NodeStatus? status;

  /// `foldProgressText` for [L (this row), R (no data)].
  final String fold;

  /// `nightNodeFrames` as "captured/planned", or "null".
  final String night;

  /// The card: "header | completed cells | cell in flight".
  final String card;

  /// The Activity tab caption, or "absent".
  final String activity;
}

ExposureInstructionProgressDetail _typed(int frame, int total) =>
    ExposureInstructionProgressDetail(
      frame: frame,
      total: total,
      durationSecs: 60,
    );

const _planned = 4;

final _rows = <_Row>[
  const _Row('nothing reported',
      fold: '', night: 'null', card: '0 / 4 | 0 | 0', activity: 'absent'),
  const _Row('running, nothing reported',
      status: NodeStatus.running,
      fold: 'L 0/4 · R 0/4',
      night: 'null',
      card: '0 / 4 | 0 | 0',
      activity: '0 of 4 done'),
  const _Row('success, nothing reported',
      status: NodeStatus.success,
      fold: 'L 4/4 · R 0/4',
      night: 'null',
      card: '4 / 4 | 4 | 0',
      activity: '4 of 4 done'),
  const _Row('cancelled, nothing reported',
      status: NodeStatus.cancelled,
      fold: 'L 0/4 · R 0/4',
      night: 'null',
      card: '0 / 4 | 0 | 0',
      activity: '0 of 4 done'),
  const _Row('tally 2/4 running',
      tally: NodeExposureTally(captured: 2, planned: 4),
      status: NodeStatus.running,
      fold: 'L 0/4 · R 0/4',
      night: '2/4',
      card: '2 / 4 | 2 | 3',
      activity: '2 of 4 done · capturing 3'),
  _Row('tally, typed and line agree, running',
      tally: const NodeExposureTally(captured: 2, planned: 4),
      typed: _typed(2, 4),
      line: 'Completed 2/4',
      status: NodeStatus.running,
      fold: 'L 2/4 · R 0/4',
      night: '2/4',
      card: '2 / 4 | 2 | 3',
      activity: '2 of 4 done · capturing 3'),
  const _Row('tally 4/4 success',
      tally: NodeExposureTally(captured: 4, planned: 4),
      status: NodeStatus.success,
      fold: 'L 4/4 · R 0/4',
      night: '4/4',
      card: '4 / 4 | 4 | 0',
      activity: '4 of 4 done'),
  const _Row('tally 2/4 cancelled',
      tally: NodeExposureTally(captured: 2, planned: 4),
      status: NodeStatus.cancelled,
      fold: 'L 0/4 · R 0/4',
      night: '2/4',
      card: '2 / 4 | 2 | 0',
      activity: '2 of 4 done'),
  // The typed `frame` counts frames captured: the native executor reports
  // it after saving the frame. Every surface reads it that way.
  _Row('typed 2/4 running, no tally',
      typed: _typed(2, 4),
      status: NodeStatus.running,
      fold: 'L 2/4 · R 0/4',
      night: '2/4',
      card: '2 / 4 | 2 | 3',
      activity: '2 of 4 done · capturing 3'),
  _Row('typed 2/4 cancelled, no tally',
      typed: _typed(2, 4),
      status: NodeStatus.cancelled,
      fold: 'L 2/4 · R 0/4',
      night: '2/4',
      card: '2 / 4 | 2 | 0',
      activity: '2 of 4 done'),
  _Row('typed 4/4 success, no tally',
      typed: _typed(4, 4),
      status: NodeStatus.success,
      fold: 'L 4/4 · R 0/4',
      night: '4/4',
      card: '4 / 4 | 4 | 0',
      activity: '4 of 4 done'),
  _Row('typed 4/4 running, no tally',
      typed: _typed(4, 4),
      status: NodeStatus.running,
      fold: 'L 4/4 · R 0/4',
      night: '4/4',
      card: '4 / 4 | 4 | 0',
      activity: '4 of 4 done'),
  _Row('typed 2/4, no status',
      typed: _typed(2, 4),
      fold: 'L 2/4 · R 0/4',
      night: '2/4',
      card: '2 / 4 | 2 | 0',
      activity: '2 of 4 done'),
  _Row('typed 2/6 running, total differs from the node',
      typed: _typed(2, 6),
      status: NodeStatus.running,
      fold: 'L 2/6 · R 0/4',
      night: '2/6',
      card: '2 / 6 | 2 | 3',
      activity: '2 of 6 done · capturing 3'),
  // A typed report with no total is not a frame count (the native executor
  // never sends one: it reports frame n of a burst of count >= n).
  _Row('typed 2/0 running',
      typed: _typed(2, 0),
      status: NodeStatus.running,
      fold: 'L 0/4 · R 0/4',
      night: 'null',
      card: '0 / 4 | 0 | 0',
      activity: '0 of 4 done'),
  _Row('tally 1/4 and typed 3/4 disagree, running',
      tally: const NodeExposureTally(captured: 1, planned: 4),
      typed: _typed(3, 4),
      status: NodeStatus.running,
      fold: 'L 3/4 · R 0/4',
      night: '1/4',
      card: '1 / 4 | 1 | 2',
      activity: '1 of 4 done · capturing 2'),
  const _Row('line Frame 3/4 running',
      line: 'Frame 3/4 (R)',
      status: NodeStatus.running,
      fold: 'L 2/4 · R 0/4',
      night: '2/4',
      card: '3 / 4 | 2 | 3',
      activity: '2 of 4 done · capturing 3'),
  const _Row('line Completed 3/4 running',
      line: 'Completed 3/4',
      status: NodeStatus.running,
      fold: 'L 3/4 · R 0/4',
      night: '3/4',
      card: '3 / 4 | 3 | 0',
      activity: '3 of 4 done'),
  const _Row('line Completed 4/4 running',
      line: 'Completed 4/4',
      status: NodeStatus.running,
      fold: 'L 4/4 · R 0/4',
      night: '4/4',
      card: '4 / 4 | 4 | 0',
      activity: '4 of 4 done'),
  const _Row('line Frame 3/4 success',
      line: 'Frame 3/4 (R)',
      status: NodeStatus.success,
      fold: 'L 2/4 · R 0/4',
      night: '2/4',
      card: '4 / 4 | 4 | 0',
      activity: '4 of 4 done'),
  const _Row('line Frame 3/4 cancelled',
      line: 'Frame 3/4 (R)',
      status: NodeStatus.cancelled,
      fold: 'L 2/4 · R 0/4',
      night: '2/4',
      card: '3 / 4 | 2 | 3',
      activity: '2 of 4 done · capturing 3'),
  const _Row('native line Frame 3/12 running',
      line: 'Frame 3/12 (180.0s)',
      status: NodeStatus.running,
      fold: 'L 2/12 · R 0/4',
      night: '2/12',
      card: '3 / 12 | 2 | 3',
      activity: '2 of 12 done · capturing 3'),
  const _Row('another instruction\'s line, running',
      line: 'Budget 0% of 3600s',
      status: NodeStatus.running,
      fold: 'L 0/4 · R 0/4',
      night: 'null',
      card: '0 / 4 | 0 | 0',
      activity: '0 of 4 done'),
];

SequenceProgress _progressFor(_Row row, String nodeId) => SequenceProgress(
      nodeStatuses: {if (row.status != null) nodeId: row.status!},
      nodeProgressStructuredDetail: {if (row.typed != null) nodeId: row.typed!},
      nodeProgressDetail: {if (row.line != null) nodeId: row.line!},
    );

ExposureNode _exp(String filter) =>
    ExposureNode(filter: filter, count: _planned, durationSecs: 60);

String _fold(_Row row) {
  final l = _exp('L');
  final r = _exp('R');
  final root = InstructionSetNode(name: 'Sequence');
  final sequence = Sequence.create(
    name: 'T',
    rootNodeId: root.id,
    nodes: {
      l.id: l.copyWith(parentId: root.id, orderIndex: 0),
      r.id: r.copyWith(parentId: root.id, orderIndex: 1),
      root.id: root.copyWith(childIds: [l.id, r.id]),
    },
  );
  final group = foldChildren(
    sequence,
    root.id,
    unfoldedGroupIds: const <String>{},
  ).whereType<FoldedEntry>().single.group;
  return foldProgressText(group, _progressFor(row, l.id));
}

String _night(_Row row) {
  const id = 'node';
  final frames = nightNodeFrames(
    id,
    tally: {if (row.tally != null) id: row.tally!},
    progress: _progressFor(row, id),
  );
  return frames == null ? 'null' : '${frames.captured}/${frames.planned}';
}

Future<String> _card(WidgetTester tester, _Row row) async {
  await tester.pumpWidget(MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: getProgressPanelForNode(
        node: _exp('L'),
        colors: SkotiqColors.dark,
        progressPercent: 0,
        progressDetail: row.line,
        structuredProgressDetail: row.typed,
        nodeStatus: row.status,
        exposureTally: row.tally,
      ),
    ),
  ));
  final header = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .firstWhere((s) => s.endsWith(' frames'));
  final grid = tester.widget(find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_FrameGrid',
  )) as dynamic;
  final completed = (grid.completedFrames as int).clamp(0, 1 << 20);
  return '${header.replaceAll(' frames', '')} | $completed | '
      '${grid.currentFrame}';
}

Future<String> _activity(WidgetTester tester, _Row row) async {
  final node = _exp('L');
  final handle = await pumpAppScreen(
    tester,
    SizedBox(
      width: 400,
      height: 800,
      child: NodeActivityTab(colors: SkotiqColors.dark, node: node),
    ),
    size: const Size(420, 900),
  );
  final run = handle.container.read(runRecordProvider.notifier);
  if (row.status != null) run.updateNodeStatus(node.id, row.status!);
  if (row.typed != null) {
    run.updateNodeStructuredProgress(node.id, 0, row.typed!);
  }
  if (row.line != null) run.updateNodeProgress(node.id, 0, row.line!);
  final tally = row.tally;
  if (tally != null) {
    run.recordFrames(node.id, captured: tally.captured, planned: tally.planned);
  }
  await tester.pump();
  final caption = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .where((s) => s.contains(' done'))
      .toList();
  return caption.isEmpty ? 'absent' : caption.single;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final row in _rows) {
    test('fold row and Tonight: ${row.name}', () {
      expect(_fold(row), row.fold, reason: 'fold');
      expect(_night(row), row.night, reason: 'Tonight');
    });

    testWidgets('card: ${row.name}', (tester) async {
      expect(await _card(tester, row), row.card);
    });

    testWidgets('Activity tab: ${row.name}', (tester) async {
      expect(await _activity(tester, row), row.activity);
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
