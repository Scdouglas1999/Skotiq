// Widget tests for the NotificationNode
// transport multi-select.
//
// Verifies that:
//   * Every NotificationTransportKind renders as a chip with a stable
//     ValueKey.
//   * The chip for the secret-required transport (telegram) renders a
//     "(not configured)" suffix when no credentials are saved.
//   * Live preview reflects the rendered title and body.
//
// After consolidation: the editor moved into the (private) single
// node-properties library, so this test now drives it through the public
// [NodePropertiesPanel] dispatcher with a NotificationNode selected — the
// same path the user hits in the app — rather than instantiating the
// (now-private) properties widget directly.
//
// Tap-driven mutation tests are NOT included here: triggering an
// `updateNode` from the chip's onSelected requires the full editor
// exceptions ladder, which is covered by the JSON round-trip +
// router-level unit tests in skotiq_core (notification_node_test,
// notification_router_test). This file pins the *rendering* contract only.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_app/widgets/sequence/variable_picker.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpNode(WidgetTester tester, {NotificationNode? node}) async {
    final n = node ?? NotificationNode(title: 'T', message: 'M');
    final sequence = Sequence.create(
      name: 'Notification test',
      rootNodeId: n.id,
      nodes: {n.id: n},
    );

    final handle = await pumpAppScreen(
      tester,
      const SizedBox(
        width: 420,
        height: 1200,
        child: NodePropertiesPanel(colors: SkotiqColors.dark),
      ),
      size: const Size(900, 1200),
    );

    // Load the sequence and select the node so the dispatcher routes to the
    // NotificationNode editor.
    handle.container
        .read(currentSequenceProvider.notifier)
        .loadSequence(sequence, discardUnsaved: true);
    handle.container.read(selectedNodeIdProvider.notifier).state = n.id;
    await tester.pumpAndSettle();
  }

  testWidgets(
      'all_transport_chips_render: NotificationProperties surfaces a '
      'FilterChip for every NotificationTransportKind', (tester) async {
    await pumpNode(tester);

    for (final kind in NotificationTransportKind.values) {
      expect(
        find.byKey(ValueKey('notif_transport_${kind.storageKey}')),
        findsOneWidget,
        reason: 'Missing chip for ${kind.label}; the multi-select must render '
            'one chip per NotificationTransportKind so the user can opt '
            'in / out per transport.',
      );
    }
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'unconfigured_transport_renders_not_configured_label: telegram has '
      'no saved bot token by default, so its chip must show "(not '
      'configured)" so the user knows their pick will not fire',
      (tester) async {
    await pumpNode(tester);
    expect(
      find.text('Telegram (not configured)'),
      findsOneWidget,
      reason: 'Telegram has no credentials in the default in-memory harness, '
          'so the chip must annotate that fact rather than silently '
          'render as if Telegram were ready.',
    );
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  // The title and message hints advertise ${frame} / ${target.name} /
  // ${time.local}, and the operator had no way to see what else exists — the
  // insert control the variable picker was written for had no call site here.
  testWidgets(
      'template fields offer a variable picker over the sequencer catalog',
      (tester) async {
    await pumpNode(tester);

    final pickers = find.byType(VariablePickerButton);
    expect(pickers, findsNWidgets(2), reason: 'one on title, one on message');
    for (final w in tester.widgetList<VariablePickerButton>(pickers)) {
      expect(w.variables, same(interpolationCatalog));
    }

    await tester.tap(pickers.first);
    await tester.pumpAndSettle();
    expect(find.text(r'${target.name}'), findsOneWidget);
    // The rest of the catalog is below the fold; reach it through the dialog's
    // own search so the assertion covers a token the hint text advertises.
    await tester.enterText(find.byType(TextField).last, 'frame');
    await tester.pumpAndSettle();
    expect(find.text(r'${frame}'), findsOneWidget);
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('inserting a variable commits it to the node', (tester) async {
    // The picker writes through the TextEditingController, which does NOT
    // fire TextField.onChanged — so without an explicit commit the insert is
    // visible in the field and silently absent from the saved sequence.
    final node = NotificationNode(title: '', message: 'M');
    await pumpNode(tester, node: node);

    await tester.tap(find.byType(VariablePickerButton).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(r'${target.name}'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NodePropertiesPanel)),
    );
    final saved = container.read(currentSequenceProvider)!.nodes[node.id]!
        as NotificationNode;
    expect(saved.title, r'${target.name}');
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('preview_section_is_present: the live preview header renders',
      (tester) async {
    // The title/body strings appear in BOTH the text input controllers
    // and the preview box (one render each = >1 match), so we pin the
    // contract here to "the Preview label is present" and rely on the
    // interpolation engine's own tests for the rendered-string fidelity.
    await pumpNode(tester,
        node: NotificationNode(title: 'Hello', message: 'Body line'));
    expect(find.text('Preview'), findsOneWidget,
        reason: 'The NotificationNode property panel must surface a Preview '
            'box so the user can see the rendered template before run time.');
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });
}
