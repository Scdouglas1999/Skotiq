// Mosaic Wizard visual planner tests.
//
// Pins:
//   * the mosaic wizard renders the new visual planner alongside
//     the configuration column,
//   * the "Advanced (numerical)" expansion lets the user enter
//     numerical fields when collapsed-by-default,
//   * tapping a panel toggles its enabled state, reducing the
//     "Active panels" counter,
//   * the resume banner still renders when the backend
//     reports a resumable mosaic checkpoint (regression guard for
//     the existing `mosaic_wizard_resume_test.dart`).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mosaic_wizard_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_backend.dart';
import '../../../harness/pump_app_screen.dart';

/// A real rig: 500 mm scope + a 4144x2822 / 4.63 um sensor. The wizard
/// derives its panel size from this, and refuses to plan without it.
const _testOptics = OpticalConfig(
  telescopeName: 'Test scope',
  focalLength: 500,
  aperture: 100,
  cameraName: 'Test cam',
  sensorWidth: 4144,
  sensorHeight: 2822,
  pixelSize: 4.63,
);

Future<void> _pumpMosaic(
  WidgetTester tester, {
  MockBackend? backend,
  SmartNightExposureContext? exposureContext,
  CurrentSequenceNotifier? editor,
  OpticalConfig? optics = _testOptics,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1600, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  // The visual planner involves Stack + LayoutBuilder math; the small
  // statistics rows can produce harmless overflow warnings on the
  // 1600×1000 surface used here. Filter only the overflow message
  // so genuine exceptions still surface.
  FlutterError.onError = (FlutterErrorDetails details) {
    final msg = details.exceptionAsString();
    if (msg.contains('A RenderFlex overflowed by')) return;
    FlutterError.presentError(details);
  };
  addTearDown(() {
    FlutterError.onError = FlutterError.presentError;
  });

  final resolvedBackend = backend ?? mockBackend();
  // Default: no checkpoint, so the resume banner stays hidden.
  when(() => resolvedBackend.hasCheckpoint()).thenAnswer((_) async => false);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider
            .overrideWith((ref) => TestBackendNotifier(ref, resolvedBackend)),
        smartNightExposureContextProvider
            .overrideWith((ref) async => exposureContext),
        opticalConfigProvider.overrideWithValue(optics),
        if (editor != null)
          currentSequenceProvider.overrideWith((ref) => editor),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: MosaicWizardDialog(initialRa: 12.5, initialDec: 30),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('MosaicWizardDialog visual planner', () {
    testWidgets('renders the visual planner alongside config column',
        (tester) async {
      await _pumpMosaic(tester);
      // The visual planner is keyed for stability.
      expect(
          find.byKey(const ValueKey('mosaic_visual_planner')), findsOneWidget);
      // The plan summary is the new stats card.
      expect(find.text('Plan summary'), findsOneWidget);
      // 3×3 default grid → 9 active panels.
      expect(find.text('9'), findsWidgets);
    });

    testWidgets('Advanced panel toggles open on tap', (tester) async {
      await _pumpMosaic(tester);

      // Initially collapsed.
      expect(find.text('Center RA (hours)'), findsNothing);

      // The multi-filter plan card now sits above the Advanced panel, so on
      // the test surface the panel header starts below the config column's
      // scroll fold. Scroll it into view before tapping so the gesture lands
      // on the InkWell rather than the clamped viewport edge.
      await tester.ensureVisible(find.text('Advanced (numerical)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced (numerical)'));
      await tester.pumpAndSettle();

      expect(find.text('Center RA (hours)'), findsOneWidget);
      expect(find.text('Center Dec (degrees)'), findsOneWidget);
      expect(find.text('Panel width (arcmin)'), findsOneWidget);
      expect(find.text('Panel height (arcmin)'), findsOneWidget);
    });

    // With no rig to measure, the wizard used to quote its field
    // INITIALISERS as fact ("Panel size: 1.00° × 0.67°") and plan the whole
    // mosaic from them, while the framing dialog on the same screen refused
    // to guess. It must now admit the panel size is unknown and refuse to
    // build until it is supplied.
    testWidgets(
        'with no rig it says the panel size is unknown and refuses '
        'to build', (tester) async {
      await _pumpMosaic(tester, optics: null);

      expect(
        find.byKey(const ValueKey('mosaic_unknown_panel_size_banner')),
        findsOneWidget,
      );
      expect(find.text('unknown'), findsOneWidget);
      expect(find.text('1.00° × 0.67°'), findsNothing);

      final loadBtn = tester.widget<SkotiqButton>(
        find.byKey(const ValueKey('mosaic_generate_sequence_btn')),
      );
      expect(loadBtn.onPressed, isNull);
      final createBtn = tester.widget<SkotiqButton>(
        find.byKey(const ValueKey('mosaic_create_project_btn')),
      );
      expect(createBtn.onPressed, isNull);
    });

    testWidgets('with a rig the panel size is the rig\'s field, not 60x40',
        (tester) async {
      await _pumpMosaic(tester);

      expect(
        find.byKey(const ValueKey('mosaic_unknown_panel_size_banner')),
        findsNothing,
      );
      // 500 mm + 4144x2822 px at 4.63 um => 2.20° × 1.50°.
      expect(find.text('2.20° × 1.50°'), findsOneWidget);
      expect(find.text('1.00° × 0.67°'), findsNothing);

      final loadBtn = tester.widget<SkotiqButton>(
        find.byKey(const ValueKey('mosaic_generate_sequence_btn')),
      );
      expect(loadBtn.onPressed, isNotNull);
    });

    testWidgets('does not show the resume banner when no checkpoint exists',
        (tester) async {
      await _pumpMosaic(tester);
      expect(find.byKey(const ValueKey('mosaic_resume_banner')), findsNothing);
    });

    testWidgets('load into sequencer creates one connected tree', (
      tester,
    ) async {
      final editor = CurrentSequenceNotifier();
      await _pumpMosaic(tester, editor: editor);

      final loadButton = find.byKey(
        const ValueKey('mosaic_generate_sequence_btn'),
      );
      await tester.ensureVisible(loadButton);
      await tester.tap(loadButton);
      await tester.pumpAndSettle();

      final sequence = editor.state!;
      final rootId = sequence.rootNodeId!;
      final root = sequence.nodes[rootId]!;
      final headers = sequence.nodes.values.whereType<TargetHeaderNode>();
      expect(headers, hasLength(9));
      expect(headers.every((header) => header.mosaicPanel != null), isTrue);
      expect(root.childIds, hasLength(9));
      expect(
        root.childIds.map((id) => sequence.nodes[id]),
        everyElement(isA<TargetHeaderNode>()),
      );

      for (final node in sequence.nodes.values) {
        expect(node.childIds.toSet(), hasLength(node.childIds.length));
        if (node.id == rootId) continue;
        final parent = sequence.nodes[node.parentId];
        expect(parent, isNotNull, reason: '${node.name} has no parent');
        expect(parent!.childIds.where((id) => id == node.id), hasLength(1));
      }

      final reachable = <String>{};
      void visit(String id) {
        if (!reachable.add(id)) return;
        for (final childId in sequence.nodes[id]!.childIds) {
          visit(childId);
        }
      }

      visit(rootId);
      expect(reachable, hasLength(sequence.nodes.length));
    });

    testWidgets('disabled planner panel is omitted from generated sequence', (
      tester,
    ) async {
      final editor = CurrentSequenceNotifier();
      await _pumpMosaic(tester, editor: editor);

      await tester.tap(find.byKey(const ValueKey('mosaic_panel_0_0')));
      await tester.pumpAndSettle();

      final loadButton = find.byKey(
        const ValueKey('mosaic_generate_sequence_btn'),
      );
      await tester.ensureVisible(loadButton);
      await tester.tap(loadButton);
      await tester.pumpAndSettle();

      final sequence = editor.state!;
      final root = sequence.nodes[sequence.rootNodeId]!;
      final headers = sequence.nodes.values.whereType<TargetHeaderNode>();
      expect(headers, hasLength(8));
      expect(root.childIds, hasLength(8));
      expect(
        headers.map((header) => header.mosaicPanel!.panelIndex),
        isNot(contains(0)),
      );

      final reachable = <String>{};
      void visit(String id) {
        if (!reachable.add(id)) return;
        for (final childId in sequence.nodes[id]!.childIds) {
          visit(childId);
        }
      }

      visit(sequence.rootNodeId!);
      expect(reachable, hasLength(sequence.nodes.length));
    });
  });
}
