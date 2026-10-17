import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/smart_exposure_properties.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _exposureContext = SmartNightExposureContext(
  camera: CameraExposureSpec(
    readNoiseE: 1.4,
    fullWellE: 50000,
    qePeak: 0.85,
  ),
  bortleClass: 8,
  focalLengthMm: 384,
  apertureMm: 80,
  pixelSizeMicrons: 3.76,
  availableFilterNames: ['L', 'Ha'],
  userCapSeconds: 240,
  floorSeconds: 30,
);

class _CaptureSpy {
  int calls = 0;
  ExposureSettings? settings;
  String? targetName;
}

class _FakeImagingService extends ImagingService {
  _FakeImagingService(super.ref, this.spy);

  final _CaptureSpy spy;

  @override
  Future<CapturedImageData?> captureImage({
    required ExposureSettings settings,
    String? targetName,
    int? frameNumber,
    String? producingNodeId,
    String? producingRunId,
  }) async {
    spy
      ..calls += 1
      ..settings = settings
      ..targetName = targetName;

    return CapturedImageData(
      width: 1,
      height: 1,
      displayData: Uint8List.fromList(const [0, 0, 0, 255]),
      histogram: const [1],
      stats: const ImageStats(mean: 42),
      capturedAt: DateTime(2026, 1, 2, 3, 4, 5),
      settings: settings,
      targetName: targetName,
      filePath: 'test-exposure.fits',
    );
  }
}

ProviderContainer _seed(
  Sequence sequence, {
  _CaptureSpy? captureSpy,
}) {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = sequence;
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith((_) => notifier),
      activeEquipmentProfileProvider.overrideWithValue(
        const EquipmentProfileModel(
          name: 'Test rig',
          focalLength: 384,
          aperture: 80,
          filterNames: ['L', 'Ha'],
          defaultGain: 100,
          defaultOffset: 50,
        ),
      ),
      smartNightExposureContextProvider.overrideWith(
        (ref) async => _exposureContext,
      ),
      if (captureSpy != null)
        imagingServiceProvider.overrideWith(
          (ref) => _FakeImagingService(ref, captureSpy),
        ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(child: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Pumps the public [NodePropertiesPanel] (the dispatcher) inside a bounded
/// box. The panel's desktop layout uses an Expanded child, so it needs a
/// finite height — it provides its own internal scroll view for the editor
/// body, so `ensureVisible` still works for off-screen controls.
Future<void> _pumpPanel(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 880,
            height: 2400,
            child: NodePropertiesPanel(colors: SkotiqColors.dark),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('Exposure properties can apply shared Smart Night recommendation',
      (tester) async {
    final exposure = ExposureNode(
      id: 'exp-l',
      durationSecs: 360,
      count: 5,
      filter: 'L',
    );
    final root = InstructionSetNode(id: 'root', childIds: [exposure.id]);
    final sequence = Sequence.create(
      name: 'Exposure Recommendation Test',
      rootNodeId: root.id,
      nodes: {
        root.id: root,
        exposure.id: exposure.copyWith(parentId: root.id),
      },
    );
    final container = _seed(sequence);
    container.read(selectedNodeIdProvider.notifier).state = exposure.id;

    await _pumpPanel(tester, container);

    expect(find.text('Recommended exposure'), findsOneWidget);
    expect(find.text('Apply 30s'), findsOneWidget);

    await tester.tap(find.text('Apply 30s'));
    await tester.pump();

    final updated = container.read(currentSequenceProvider)!.nodes[exposure.id]
        as ExposureNode;
    expect(updated.durationSecs, 30);
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Smart Exposure added rows use shared exposure recommendation',
      (tester) async {
    final smart = SmartExposureNode(
      id: 'smart-exp',
      plans: const [],
    );
    final root = InstructionSetNode(id: 'root', childIds: [smart.id]);
    final sequence = Sequence.create(
      name: 'Smart Exposure Recommendation Test',
      rootNodeId: root.id,
      nodes: {
        root.id: root,
        smart.id: smart.copyWith(parentId: root.id),
      },
    );
    final container = _seed(sequence);

    await _pump(
      tester,
      container,
      SmartExposureProperties(colors: SkotiqColors.dark, node: smart),
    );

    await tester.tap(find.text('Add Filter Plan'));
    await tester.pump();

    final updated = container.read(currentSequenceProvider)!.nodes[smart.id]
        as SmartExposureNode;
    expect(updated.plans.single.durationSecs, 30);
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Exposure properties can run non-counting test exposure',
      (tester) async {
    final exposure = ExposureNode(
      id: 'exp-test',
      durationSecs: 180,
      count: 5,
      filter: 'Ha',
      binning: BinningMode.two,
    );
    final root = InstructionSetNode(id: 'root', childIds: [exposure.id]);
    final sequence = Sequence.create(
      name: 'Test Exposure Sequence',
      rootNodeId: root.id,
      nodes: {
        root.id: root,
        exposure.id: exposure.copyWith(parentId: root.id),
      },
    );
    final spy = _CaptureSpy();
    final container = _seed(sequence, captureSpy: spy);
    container.read(selectedNodeIdProvider.notifier).state = exposure.id;

    await _pumpPanel(tester, container);

    await tester.ensureVisible(find.text('Run test exposure'));
    await tester.tap(find.text('Run test exposure'));
    await tester.pumpAndSettle();

    expect(spy.calls, 1);
    expect(spy.settings?.exposureTime, 180);
    expect(spy.settings?.gain, 100);
    expect(spy.settings?.offset, 50);
    expect(spy.settings?.binningX, 2);
    expect(spy.settings?.binningY, 2);
    expect(spy.settings?.filter, 'Ha');
    expect(spy.settings?.frameType, FrameType.snapshot);

    final unchanged = container
        .read(currentSequenceProvider)!
        .nodes[exposure.id] as ExposureNode;
    expect(unchanged.durationSecs, 180);
    expect(unchanged.count, 5);

    final displayed = container.read(currentImageProvider);
    expect(displayed?.filePath, 'test-exposure.fits');
    expect(displayed?.stats.mean, 42);
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });
}
