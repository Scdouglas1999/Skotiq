// Every time-transport control carries its own accessible name on the BUTTON
// node, and the one that stops time reports that it has.
//
// An AT-SPI dump of the planetarium transport without that guarantee:
//
//   panel: Aug 13, 2026 [DISABLED]
//   button:            <- rewind / rate down
//   button:            <- step back 1 h
//   button:            <- play / pause
//   button:            <- step forward 1 h
//   button:            <- fast forward / rate up
//   button: Now
//   button: Tonight
//
// Five bare buttons with empty names, no toggle state on play/pause, and the
// date chip — the control that opens the date picker — reported as an inert
// disabled panel. The only signal that time is stopped is the string PAUSED
// merged into an unrelated text panel, which assistive tech cannot reach.
//
// `IconButton(tooltip:)` is why: the tooltip's `Semantics(label:)` is not a
// container, so it is absorbed by some ancestor node rather than by the button's
// own — producing a named panel beside an unnamed button, exactly as the dump
// shows. The assertions below therefore check the property an assistive client
// actually consumes: ONE node carrying the name, the button role and the tap
// action together.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_planetarium/src/providers/planetarium_providers.dart';
import 'package:skotiq_planetarium/src/widgets/time_control_panel.dart';

Future<ProviderContainer> _pumpTransport(WidgetTester tester) async {
  final container = ProviderContainer();
  // The sky is drawn from the observer's site; without one the view renders
  // its no-site state instead.
  container
      .read(observerLocationProvider.notifier)
      .setLocation(latitude: 40.0, longitude: -74.0);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: Center(child: TimeControlPanel())),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Every node in the compiled semantics tree, as an assistive client sees it.
List<SemanticsData> _tree(WidgetTester tester) {
  // `pipelineOwner`, not `rootPipelineOwner`: the test binding attaches the
  // widget tree's semantics owner to the former, and the root's is empty.
  // ignore: deprecated_member_use
  final root = tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
  final out = <SemanticsData>[];
  void visit(SemanticsNode node) {
    out.add(node.getSemanticsData());
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  return out;
}

/// Is there one node that is named [name] AND is an enabled, tappable button?
bool _namedButton(List<SemanticsData> tree, String name, {bool? toggled}) {
  return tree.any((d) {
    if (!d.label.contains(name)) return false;
    if (!d.hasFlag(SemanticsFlag.isButton)) return false;
    if (!d.hasAction(SemanticsAction.tap)) return false;
    if (toggled == null) return true;
    return d.hasFlag(SemanticsFlag.hasToggledState) &&
        d.hasFlag(SemanticsFlag.isToggled) == toggled;
  });
}

void main() {
  testWidgets('every transport button carries its own name', (tester) async {
    final handle = tester.ensureSemantics();
    final container = await _pumpTransport(tester);

    final tree = _tree(tester);
    for (final name in const [
      'Slower', // rewind / rate down
      'Back 1 hour',
      'Pause time',
      'Forward 1 hour',
      'Faster', // fast forward / rate up
      'Now',
      'Tonight',
    ]) {
      expect(
        _namedButton(tree, name),
        isTrue,
        reason:
            '"$name" must be the name of the button node itself, not of a '
            'panel beside it',
      );
    }

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    handle.dispose();
  });

  // Swapping the control's NAME and its toggle state together —
  // `label: running ? 'Pause' : 'Play'` with `toggled: !running` — makes
  // assistive tech announce "Play, toggle button, on" at the moment time is
  // HELD and "Pause, toggle button, off" while it is running: the name and the
  // state asserting opposite things about the same sky. The contract is an
  // action name with no toggle state, and the state published by the rate chip
  // beside the clock, which is also where it is drawn.
  testWidgets('play/pause names the action and never contradicts it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final container = await _pumpTransport(tester);

    var tree = _tree(tester);
    expect(_namedButton(tree, 'Pause time'), isTrue);
    expect(
      tree.any(
        (d) =>
            d.label.contains('Pause time') &&
            d.hasFlag(SemanticsFlag.hasToggledState),
      ),
      isFalse,
      reason: 'an action name with a toggle state is the contradiction',
    );
    expect(
      tree.any((d) => d.label.contains('Time running at')),
      isTrue,
      reason: 'the STATE of the sky is published, just not on the button',
    );

    await tester.tap(find.byIcon(LucideIcons.pause));
    await tester.pump();

    expect(container.read(observationTimeProvider).isPaused, isTrue);
    tree = _tree(tester);
    expect(
      _namedButton(tree, 'Play time'),
      isTrue,
      reason: 'pressing it now resumes, so that is what it must be called',
    );
    expect(
      tree.any((d) => d.label == 'Time paused'),
      isTrue,
      reason: 'a screen reader must be able to tell that time is stopped',
    );
    expect(
      tree.any((d) => d.label.contains('Time running at')),
      isFalse,
      reason: 'and must not be told both at once',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    handle.dispose();
  });

  // D-3's other half: the clock and the rate chip were absorbed into the sky
  // canvas's node, arriving at AT-SPI as one focusable panel named
  // "20:37:18 / 1x / Center RA: ... / Bortle: 5" and reported DISABLED. Each
  // readout is now a node of its own.
  testWidgets('the clock is its own named, non-interactive node', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final container = await _pumpTransport(tester);

    final clock = _tree(tester).where((d) => d.label.startsWith('Sky time'));
    expect(clock, isNotEmpty, reason: 'the clock must name itself');
    expect(
      clock.every(
        (d) =>
            !d.hasFlag(SemanticsFlag.isFocusable) &&
            !d.hasAction(SemanticsAction.tap),
      ),
      isTrue,
      reason: 'a readout that publishes itself as interactive is a lie',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    handle.dispose();
  });

  testWidgets('the date chip is a button, not an inert panel', (tester) async {
    final handle = tester.ensureSemantics();
    final container = await _pumpTransport(tester);

    final node = tester.getSemantics(find.byIcon(LucideIcons.calendar));
    final data = node.getSemanticsData();
    expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(data.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue);
    expect(data.hint, contains('Choose a date'));

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    handle.dispose();
  });
}
