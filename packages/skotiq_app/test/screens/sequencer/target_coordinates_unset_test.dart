// Unset target coordinates must never read as a settled pointing.
//
// A Target node is created at RA 0h / Dec +0° because TargetHeaderNode has no
// nullable coordinate. Typing "M31" into Target Name must not leave that
// placeholder untouched while downstream surfaces render it as a real sky
// position — a run built that way tracks a random patch of Pisces all night.
//
// These tests pin three halves: the Slew/Center confirmation refuses to go
// green, the tree card says "Not set", and the target editor both warns and
// offers a working name -> coordinates lookup.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_coordinates.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_header_card.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_node_properties.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// M31's real J2000 position, used both as the seeded library row and as the
/// expected result of resolving the name.
const _m31RaHours = 0.712306;
const _m31DecDegrees = 41.26875;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Slew editor refuses to confirm a target still on the 0h/+0 default',
      (tester) async {
    final target = TargetHeaderNode(
      id: 'target',
      name: 'M31',
      targetName: 'M31',
      raHours: 0,
      decDegrees: 0,
      childIds: const ['slew'],
    );
    final slew = SlewNode(id: 'slew', parentId: 'target');
    final sequence = Sequence.create(
      name: 'Unset coordinates',
      rootNodeId: target.id,
      nodes: {target.id: target, slew.id: slew},
    );

    final handle = await pumpAppScreen(
      tester,
      const SizedBox(
        width: 880,
        height: 1400,
        child: NodePropertiesPanel(colors: SkotiqColors.dark),
      ),
      size: const Size(1000, 1400),
    );
    handle.container
        .read(currentSequenceProvider.notifier)
        .loadSequence(sequence, discardUnsaved: true);
    handle.container.read(selectedNodeIdProvider.notifier).state = slew.id;
    await tester.pumpAndSettle();

    expect(find.textContaining('Will use target'), findsNothing);
    expect(find.textContaining('has no coordinates set'), findsOneWidget);

    // The same panel must still confirm a target that really is aimed, so the
    // guard is about the placeholder and not about suppressing the preview.
    handle.container.read(currentSequenceProvider.notifier).updateNode(
          target.copyWith(
            raHours: _m31RaHours,
            decDegrees: _m31DecDegrees,
          ),
        );
    await tester.pumpAndSettle();

    expect(find.textContaining('Will use target: M31'), findsOneWidget);
    expect(find.textContaining('has no coordinates set'), findsNothing);
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('tree card prints "Not set" rather than 00h 00m 00s',
      (tester) async {
    final target = TargetHeaderNode(
      id: 'target',
      name: 'M31',
      targetName: 'M31',
      raHours: 0,
      decDegrees: 0,
    );

    await pumpAppScreen(
      tester,
      TargetHeaderCard(
        node: target,
        colors: SkotiqColors.dark,
        // Mobile hides the altitude chart, keeping this test on the coordinate
        // row instead of the whole ephemeris stack.
        isMobile: true,
      ),
      size: const Size(420, 900),
    );

    expect(find.text('00h 00m 00s'), findsNothing);
    expect(find.text('+00° 00\' 00"'), findsNothing);
    expect(find.text('Not set'), findsNWidgets(2));
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('target editor warns about the placeholder and resolves the name',
      (tester) async {
    final target = TargetHeaderNode(
      id: 'target',
      name: 'M31',
      targetName: 'M31',
      raHours: 0,
      decDegrees: 0,
    );
    final root = InstructionSetNode(id: 'root', childIds: [target.id]);
    final sequence = Sequence.create(
      name: 'Resolve by name',
      rootNodeId: root.id,
      nodes: {root.id: root, target.id: target.copyWith(parentId: root.id)},
    );

    final handle = await pumpAppScreen(
      tester,
      SingleChildScrollView(
        child: TargetGroupProperties(
          colors: SkotiqColors.dark,
          node: target,
        ),
      ),
      size: const Size(900, 1600),
    );
    handle.container
        .read(currentSequenceProvider.notifier)
        .loadSequence(sequence, discardUnsaved: true);
    await tester.pumpAndSettle();

    expect(find.textContaining('Coordinates not set'), findsOneWidget);

    // Framing a target the app cannot locate rendered an unrelated patch of
    // sky under the target's name, so the affordance is off until it can.
    final frameButton = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Frame target'),
    );
    expect(frameButton.onPressed, isNull);

    await handle.container.read(targetsDaoProvider).createTarget(
          TargetsCompanion.insert(
            name: 'M31 Andromeda Galaxy',
            ra: _m31RaHours,
            dec: _m31DecDegrees,
            catalogId: const Value('M31'),
          ),
        );

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Look up coordinates'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('M31 Andromeda Galaxy'));
    await tester.pumpAndSettle();

    final updated = handle.container
        .read(currentSequenceProvider)!
        .nodes[target.id] as TargetHeaderNode;
    expect(updated.raHours, closeTo(_m31RaHours, 1e-9));
    expect(updated.decDegrees, closeTo(_m31DecDegrees, 1e-9));
    expect(targetCoordinatesUnset(updated), isFalse);
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });
}
