import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/dialogs/import_summary_dialog.dart';
import 'package:skotiq_core/src/models/import/canonical_sequence_node.dart';
import 'package:skotiq_core/src/models/import/import_result.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

ImportResult _fakeResult({
  bool withDropped = false,
  bool withUnsupported = false,
  bool forcedImport = false,
}) {
  final dropped = <DroppedNodeRecord>[
    if (withDropped)
      const DroppedNodeRecord(
        sourceType: 'Annotation',
        name: 'TODO: review filters',
        reason: DropReason.decorative,
      ),
  ];
  final unsupported = <UnsupportedNodeRecord>[
    if (withUnsupported)
      const UnsupportedNodeRecord(
        sourceType: 'NINA.Sequencer.SequenceItem.Voodoo.CustomScriptNode',
        name: 'Vendor voodoo step',
        reason: 'No Skotiq equivalent',
      ),
  ];
  // A minimal but real Skotiq sequence so the dialog has something to
  // display as default name + drive the OverviewRow math.
  final exposure = ExposureNode(
    id: 'expo-1',
    name: 'Lum 60s',
    durationSecs: 60,
    count: 5,
  );
  final sequence = Sequence.create(
    name: 'Imported NINA run',
    nodes: {exposure.id: exposure},
    rootNodeId: exposure.id,
  );
  return ImportResult(
    sourceFormat: SourceFormat.nina,
    totalNodes: 5,
    mappingTable: const [
      MappingTableRow(
          sourceType: 'TakeExposure', skotiqType: 'TakeExposure', count: 5),
      MappingTableRow(sourceType: 'Annotation', skotiqType: null, count: 1),
    ],
    droppedNodes: dropped,
    unsupportedNodes: unsupported,
    sequence: sequence,
    forcedImport: forcedImport,
  );
}

Future<void> _pump(WidgetTester tester, ImportResult result) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => ImportSummaryDialog.show(ctx, result: result),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders mapping table rows + source format', (tester) async {
    await _pump(tester, _fakeResult());

    expect(find.textContaining('Import Sequence'), findsOneWidget);
    expect(find.textContaining('NINA'), findsAtLeastNWidgets(1));
    // Source type "TakeExposure" appears in the source column;
    // skotiqType is also "TakeExposure" so we expect two matching cells.
    expect(find.text('TakeExposure'), findsNWidgets(2));
    expect(find.text('Annotation'), findsOneWidget);
    // The DataTable surfaces a "<dropped>" cell for null skotiqType.
    expect(find.text('<dropped>'), findsOneWidget);
  });

  testWidgets('renders dropped section when there are dropped nodes',
      (tester) async {
    await _pump(tester, _fakeResult(withDropped: true));
    expect(find.textContaining('Dropped'), findsAtLeastNWidgets(1));
    expect(find.textContaining('TODO: review filters'), findsOneWidget);
  });

  testWidgets('renders unsupported section when there are unsupported nodes',
      (tester) async {
    await _pump(tester, _fakeResult(withUnsupported: true, forcedImport: true));
    expect(find.textContaining('Unsupported nodes'), findsOneWidget);
    expect(find.textContaining('Vendor voodoo step'), findsOneWidget);
    // Force-import badge in the header.
    expect(find.text('Force import'), findsOneWidget);
  });

  testWidgets('shows both dropped and unsupported sections together',
      (tester) async {
    await _pump(
      tester,
      _fakeResult(withDropped: true, withUnsupported: true, forcedImport: true),
    );
    expect(find.textContaining('Dropped'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Unsupported nodes'), findsAtLeastNWidgets(1));
  });

  testWidgets('cancel button returns a cancelled decision', (tester) async {
    ImportSummaryDecision? captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  captured = await ImportSummaryDialog.show(
                    ctx,
                    result: _fakeResult(),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.cancelled, isTrue);
  });

  testWidgets('Import button returns the chosen destination + name',
      (tester) async {
    ImportSummaryDecision? captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  captured = await ImportSummaryDialog.show(
                    ctx,
                    result: _fakeResult(),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.cancelled, isFalse);
    expect(captured!.destination, ImportDestination.openInEditor);
    expect(captured!.sequenceName, 'Imported NINA run');
  });
}
