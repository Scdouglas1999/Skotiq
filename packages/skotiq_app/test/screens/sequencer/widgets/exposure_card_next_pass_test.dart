// An exposure step's card through the event sequences a host sees: a loop's
// next pass over the same step, and a run stopped mid-burst and then Reset.
//
// A loop's next pass replaces the step's last Exposure report before any
// frame: the executor sends its adaptive-exposure report as every exposure
// step starts, budget or not.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequencer_density.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// One sequencer event, shaped exactly as the FFI bridge delivers it.
SkotiqEvent _seq(String type, Map<String, dynamic> data) => SkotiqEvent(
      timestamp: DateTime.now().microsecondsSinceEpoch,
      severity: EventSeverity.info,
      category: EventCategory.sequencer,
      eventType: type,
      data: data,
    );

SkotiqEvent _nodeStarted(String nodeId) =>
    _seq('NodeStarted', {'node_id': nodeId, 'node_type': 'Take Exposures'});

/// `SequencerEvent::InstructionProgress`, what the bridge publishes for every
/// `ExecutorEvent::NodeProgress`.
///
/// `detail_json` is **jsonEncode**d because that is the wire: the native side
/// does `payload.to_string()` (api/sequencer/event_translation.rs) into
/// `detail_json: String`, and `event_mapping.dart` copies that String onto
/// `event.data`. Feeding a ready-made Map here would let this test pass while
/// the tally reads nothing on a real host.
SkotiqEvent _structured(
  String nodeId,
  String instruction,
  String detailKind,
  double percent,
  String detail,
  Map<String, dynamic> detailJson,
) =>
    _seq('InstructionProgress', {
      'node_id': nodeId,
      'instruction': instruction,
      'progress_percent': percent,
      'detail': detail,
      'detail_kind': detailKind,
      'detail_json': jsonEncode(detailJson),
    });

SkotiqEvent _exposureProgress(String nodeId, int frame, int total) =>
    _structured(nodeId, 'Exposure', 'Exposure', frame / total * 100.0,
        'Frame $frame/$total (15.0s)', {
      'frame': frame,
      'total': total,
      'duration_secs': 15.0,
    });

/// The report the executor sends as every exposure step starts, before its
/// first frame (`emit_adaptive_exposure_event`, unconditional).
SkotiqEvent _adaptiveExposure(String nodeId) => _structured(
        nodeId,
        'AdaptiveExposure',
        'ExposureAdjusted',
        0.0,
        'Exposure 15.0s (disabled)', {
      'nominal_secs': 15.0,
      'applied_secs': 15.0,
      'reason': 'disabled',
    });

/// Push one event through what a host does with it: the run record's fold
/// (`applySequencerEventToSequenceProviders`, which keeps the tally), then the
/// executor's per-step writes for an instruction's progress
/// (`RunEventHandler._onInstructionProgress`).
void _pump(ProviderContainer container, SkotiqEvent raw) {
  applySequencerEventToSequenceProviders(container.read, raw);
  final event = sequencerEventOf(raw);
  if (event is SequencerEvent_InstructionProgress) {
    container.read(runRecordProvider.notifier)
      ..updateNodeStructuredProgress(
        event.nodeId,
        event.progressPercent,
        event.report,
      )
      ..updateNodeProgress(event.nodeId, event.progressPercent, event.detail);
  }
}

/// One Target holding [nodes].
Future<void> _pumpTree(
  WidgetTester tester,
  ProviderContainer container,
  List<SequenceNode> nodes,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 1400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  container.read(currentSequenceProvider.notifier).createSequence(name: 'run');
  final header =
      TargetHeaderNode(targetName: 'New Target', raHours: 3.0, decDegrees: 0.0);
  container.read(currentSequenceProvider.notifier).addNode(header);
  for (final node in nodes) {
    container
        .read(currentSequenceProvider.notifier)
        .addNode(node, parentId: header.id);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: SequenceTree(colors: SkotiqColors.dark)),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 600));
}

({String header, int completed, int current}) _card(WidgetTester tester) {
  final header = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .firstWhere((s) => s.endsWith(' frames'));
  final grid = tester.widget(find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_FrameGrid',
  )) as dynamic;
  return (
    header: header,
    completed: grid.completedFrames as int,
    current: grid.currentFrame as int,
  );
}

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    sequencerDensityProvider
        .overrideWith((ref) => SequencerDensity.comfortable),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  testWidgets("a loop's next pass over a step starts from no frames",
      (tester) async {
    final container = _container();
    final node = ExposureNode(durationSecs: 15, count: 3);
    await _pumpTree(tester, container, [node]);

    _pump(container, _nodeStarted(node.id));
    _pump(container, _adaptiveExposure(node.id));
    for (var frame = 1; frame <= 3; frame++) {
      _pump(container, _exposureProgress(node.id, frame, 3));
    }
    await tester.pump();
    _pump(
      container,
      _seq('NodeCompleted', {'node_id': node.id, 'status': 'success'}),
    );
    await tester.pump();
    expect(_card(tester), (header: '3 / 3 frames', completed: 3, current: 0));

    // The loop's next pass: nothing of it has landed yet.
    _pump(container, _nodeStarted(node.id));
    _pump(container, _adaptiveExposure(node.id));
    await tester.pump();
    expect(_card(tester), (header: '0 / 3 frames', completed: 0, current: 0));

    _pump(container, _exposureProgress(node.id, 1, 3));
    await tester.pump();
    expect(_card(tester), (header: '1 / 3 frames', completed: 1, current: 2));
  });

  testWidgets('a step stopped mid-burst keeps its frames after Reset',
      (tester) async {
    final container = _container();
    final node = ExposureNode(durationSecs: 15, count: 4);
    await _pumpTree(tester, container, [node]);

    _pump(container, _nodeStarted(node.id));
    _pump(container, _adaptiveExposure(node.id));
    for (var frame = 1; frame <= 2; frame++) {
      _pump(container, _exposureProgress(node.id, frame, 4));
    }
    await tester.pump();
    _pump(
      container,
      _seq('NodeCompleted', {'node_id': node.id, 'status': 'cancelled'}),
    );
    await tester.pump();
    expect(_card(tester), (header: '2 / 4 frames', completed: 2, current: 0));

    // What the executor's Reset does to the run record.
    container.read(runRecordProvider.notifier)
      ..resetProgress()
      ..resetTally();
    await tester.pump();
    expect(_card(tester), (header: '2 / 4 frames', completed: 2, current: 0));
  });
}
