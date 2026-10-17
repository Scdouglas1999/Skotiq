// Sticky ancestors (spec §5): the target and loop a row belongs to stay on
// screen after their own rows have scrolled past the top of the viewport.
//
// Every case drives the real scroll view — the pins are computed from live
// render boxes, so a synthesized scroll offset would prove nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequencer_density.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// A viewport short enough that a target's own row leaves it after a modest
/// scroll, which is the whole condition the feature turns on.
const Size _shortCanvas = Size(1200, 300);

/// Root -> "M 42" -> "Broadband" -> 30 exposures: ~900 px of ledger rows in a
/// 300 px viewport, three levels deep.
///
/// Every sub is a different length on purpose: exposures that share a capture
/// spec fold into ONE row in Ledger (spec §6), and thirty subs collapsed to a
/// single row is a tree that fits its viewport — nothing scrolls out, so
/// nothing pins, and every case in this file would pass or fail for the wrong
/// reason.
Sequence _tallSequence() {
  final target = TargetHeaderNode(
    name: 'M 42',
    targetName: 'Orion',
    raHours: 5.5,
    decDegrees: -5.4,
  );
  final loop = LoopNode(
    name: 'Broadband',
    conditionType: LoopConditionType.count,
    repeatCount: 1,
  );
  final root = InstructionSetNode(name: 'Root');
  final exposures = <ExposureNode>[
    for (var i = 0; i < 30; i++)
      ExposureNode(name: 'Sub $i', durationSecs: 60.0 + i, count: 1)
          .copyWith(parentId: loop.id, orderIndex: i),
  ];
  return Sequence.create(
    name: 'Tall',
    rootNodeId: root.id,
    nodes: {
      for (final exposure in exposures) exposure.id: exposure,
      loop.id: loop.copyWith(
        parentId: target.id,
        orderIndex: 0,
        childIds: [for (final exposure in exposures) exposure.id],
      ),
      target.id: target.copyWith(
        parentId: root.id,
        orderIndex: 0,
        childIds: [loop.id],
      ),
      root.id: root.copyWith(childIds: [target.id]),
    },
  );
}

/// The same shape as [_tallSequence], but with a folded run at the bottom of a
/// deep branch: `M 42` -> `Broadband` -> 20 padding subs + `Ha · OIII · SII`.
///
/// The padding subs differ in length so they stay individual rows and the tree
/// still scrolls; the last three share a capture spec and fold into one.
Sequence _foldedRunSequence() {
  final target = TargetHeaderNode(
    name: 'M 42',
    targetName: 'Orion',
    raHours: 5.5,
    decDegrees: -5.4,
  );
  final loop = LoopNode(
    name: 'Broadband',
    conditionType: LoopConditionType.count,
    repeatCount: 1,
  );
  final root = InstructionSetNode(name: 'Root');
  final padding = <ExposureNode>[
    for (var i = 0; i < 20; i++)
      ExposureNode(name: 'Sub $i', durationSecs: 60.0 + i, count: 1),
  ];
  final run = <ExposureNode>[
    for (final filter in ['Ha', 'OIII', 'SII'])
      ExposureNode(
        name: '$filter subs',
        filter: filter,
        durationSecs: 300,
        count: 12,
        ditherEvery: 0,
      ),
  ];
  final children = <ExposureNode>[...padding, ...run];
  return Sequence.create(
    name: 'Folded',
    rootNodeId: root.id,
    nodes: {
      for (var i = 0; i < children.length; i++)
        children[i].id: children[i].copyWith(parentId: loop.id, orderIndex: i),
      loop.id: loop.copyWith(
        parentId: target.id,
        orderIndex: 0,
        childIds: [for (final child in children) child.id],
      ),
      target.id: target.copyWith(
        parentId: root.id,
        orderIndex: 0,
        childIds: [loop.id],
      ),
      root.id: root.copyWith(childIds: [target.id]),
    },
  );
}

Future<void> _pumpTree(
  WidgetTester tester,
  Sequence sequence, {
  SequencerDensity density = SequencerDensity.ledger,
  bool disableAnimations = false,
}) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = sequence;

  await pumpAppScreen(
    tester,
    Builder(
      builder: (context) {
        final tree = SequenceTree(colors: SkotiqColors.of(context));
        if (!disableAnimations) return tree;
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: tree,
        );
      },
    ),
    size: _shortCanvas,
    // Live validation debounces 500 ms; drain frames by hand instead.
    settle: false,
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.idle),
      // The minute clock is a real periodic stream whose timer outlives every
      // pump in the fake-async zone.
      ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      sequencerDensityProvider.overrideWith((ref) => density),
    ],
  );
  await _drain(tester);
}

/// Drain the validation debounce, the scroll's ballistic phase and the
/// post-frame sticky pass in one go.
///
/// The leading zero-length pump matters: an `ensureVisible` started by the
/// frame before this one has not ticked yet, and its controller takes its
/// start time from its FIRST tick — jumping the clock a second without that
/// tick leaves the animation at zero and the tree exactly where it was.
Future<void> _drain(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  // A pin created by the previous frame's post-frame pass takes its first tick
  // in the frame above; this is the one that carries its entrance to the end.
  await tester.pump(const Duration(seconds: 1));
  // And a pin that STOPPED being pinned leaves rather than vanishing (spec §9):
  // the frame above starts its exit, this one carries it to the end and the
  // stack drops it.
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _scrollBy(WidgetTester tester, double dy) async {
  await tester.drag(find.byType(Scrollable).first, Offset(0, dy));
  await _drain(tester);
}

Finder _pinnedStack() => find.byKey(sequenceStickyAncestorsKey);

/// How many of the tall fixture's two containers are standing in the stack.
int _pinCount() {
  var pinned = 0;
  for (final name in const ['M 42', 'Broadband']) {
    if (find
        .descendant(of: _pinnedStack(), matching: find.text(name))
        .evaluate()
        .isNotEmpty) {
      pinned += 1;
    }
  }
  return pinned;
}

ScrollPosition _treePosition(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('nothing pins until an ancestor row scrolls out of view',
      (tester) async {
    await _pumpTree(tester, _tallSequence());

    expect(_pinnedStack(), findsNothing);
    expect(find.text('M 42'), findsOneWidget);
  });

  testWidgets('scrolling past the target pins it, and scrolling back unpins it',
      (tester) async {
    await _pumpTree(tester, _tallSequence());

    await _scrollBy(tester, -400);
    expect(_pinnedStack(), findsOneWidget);
    expect(
      find.descendant(of: _pinnedStack(), matching: find.text('M 42')),
      findsOneWidget,
      reason: 'the operator must still be able to see which target these '
          'subs belong to',
    );
    expect(
      find.descendant(of: _pinnedStack(), matching: find.text('Broadband')),
      findsOneWidget,
      reason: 'the loop is an ancestor too, and pins under the target',
    );
    expect(
      tester.getRect(_pinnedStack()).bottom,
      closeTo(tester.getTopLeft(find.byType(SingleChildScrollView)).dy, 0.01),
      reason: 'the entrance slide has to end flush with the scroll viewport, '
          'which gives up exactly the stack\'s height while it is up — 6 px '
          'either way means the slide is still running or the reservation is '
          'the wrong size',
    );

    await _scrollBy(tester, 400);
    expect(_pinnedStack(), findsNothing);
  });

  testWidgets('a pinned row is out of the accessibility traversal order',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpTree(tester, _tallSequence());
    await _scrollBy(tester, -400);

    expect(_pinnedStack(), findsOneWidget);
    // The tree announces the target exactly once — through its real row, which
    // is scrolled away but still mounted. The pin adds no second node, or a
    // reader would hear every ancestor twice.
    expect(find.bySemanticsLabel(RegExp('M 42')), findsOneWidget);
    expect(
      find.descendant(
        of: _pinnedStack(),
        matching: find.bySemanticsLabel(RegExp('M 42')),
      ),
      findsNothing,
    );

    // And no anonymous tappable node either. Each pin is a tap-to-scroll
    // GestureDetector wrapped around the IgnorePointer'd row it stands for;
    // left in the semantics tree those contribute one UNLABELLED tappable node
    // per pin, ahead of every step in the tree — the row's own content is
    // already excluded, so there would be nothing to announce them by.
    final pinDetectors = find.descendant(
      of: _pinnedStack(),
      matching: find.byWidgetPredicate(
        (widget) => widget is GestureDetector && widget.child is IgnorePointer,
      ),
    );
    expect(pinDetectors, findsNWidgets(2));
    for (final element in pinDetectors.evaluate()) {
      expect(
        (element.widget as GestureDetector).excludeFromSemantics,
        isTrue,
        reason: 'a pin is a pointer affordance, not a control',
      );
    }
    handle.dispose();
  });

  testWidgets('tapping an INNER pin lands its row clear of the stack above it',
      (tester) async {
    await _pumpTree(tester, _tallSequence());
    await _scrollBy(tester, -400);
    expect(_pinnedStack(), findsOneWidget);

    // "Broadband" is the second of the two pins: tapping it scrolls its row
    // back, but "M 42" is still above it and stays pinned — so alignment 0
    // would deliver the row the operator asked for underneath the pin that is
    // still there.
    await tester.tap(
      find.descendant(of: _pinnedStack(), matching: find.text('Broadband')),
      warnIfMissed: false,
    );
    await _drain(tester);

    expect(
      find.descendant(of: _pinnedStack(), matching: find.text('M 42')),
      findsOneWidget,
      reason: 'the target is still scrolled away, so it is still pinned',
    );
    expect(
      find.descendant(of: _pinnedStack(), matching: find.text('Broadband')),
      findsNothing,
      reason: 'the loop row is back on screen, so nothing stands in for it',
    );

    final realRow = tester.getRect(
      find
          .ancestor(
            of: find.text('Broadband'),
            matching: find.byWidgetPredicate(
              (w) => w is SizedBox && w.height == 28.0 && w.width == null,
            ),
          )
          .first,
    );
    expect(
      realRow.top,
      greaterThanOrEqualTo(tester.getRect(_pinnedStack()).bottom),
      reason: 'the row the operator clicked for must not arrive under the '
          'pin that is still up',
    );
  });

  testWidgets('the stack reserves its height instead of covering rows',
      (tester) async {
    await _pumpTree(tester, _tallSequence());
    await _scrollBy(tester, -400);
    expect(_pinnedStack(), findsOneWidget);

    final stackBottom = tester.getRect(_pinnedStack()).bottom;
    // Every ledger row that is drawn at all is drawn below the stack: the
    // reserved top padding is what stops the pins painting over the rows they
    // exist to explain.
    final rows = find.byWidgetPredicate(
      (w) => w is SizedBox && w.height == 28.0 && w.width == null,
    );
    final viewport = tester.getRect(find.byType(SingleChildScrollView));
    for (final row in rows.evaluate()) {
      final rect = tester.getRect(find.byElementPredicate((e) => e == row));
      // Rows scrolled out of the viewport keep their box; only the ones the
      // operator can actually see are the subject here.
      if (rect.bottom <= viewport.top || rect.top >= viewport.bottom) continue;
      expect(
        rect.bottom,
        greaterThan(stackBottom - 0.01),
        reason: 'a visible row must not sit under the pinned stack',
      );
    }
  });

  testWidgets('a folded run pins and stands as the topmost row',
      (tester) async {
    // Folding and pinning meet here: the fold row answers to its FIRST
    // member's registry key, which is the id the visible order keeps as the
    // run's stand-in — so the sticky pass, which walks that order and those
    // keys, has to find the fold row where a member row used to be.
    await _pumpTree(tester, _foldedRunSequence());
    await _scrollBy(tester, -400);

    expect(_pinnedStack(), findsOneWidget);
    expect(
      find.descendant(of: _pinnedStack(), matching: find.text('M 42')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _pinnedStack(), matching: find.text('Broadband')),
      findsOneWidget,
      reason: 'the loop holding the run is an ancestor like any other',
    );
    // The run itself is one row, drawn under the stack it just pinned.
    expect(find.text('Ha · OIII · SII'), findsOneWidget);
  });

  testWidgets('tapping a pinned row brings its real row back to the top',
      (tester) async {
    await _pumpTree(tester, _tallSequence());
    await _scrollBy(tester, -400);
    expect(_pinnedStack(), findsOneWidget);

    await tester.tap(
      find.descendant(of: _pinnedStack(), matching: find.text('M 42')),
      // The pinned row is deliberately behind an IgnorePointer — the tap
      // belongs to the stack around it, which is what receives this.
      warnIfMissed: false,
    );
    await _drain(tester);

    expect(
      _pinnedStack(),
      findsNothing,
      reason: 'the real row is back on screen, so nothing stands in for it',
    );
    final viewportTop =
        tester.getTopLeft(find.byType(SingleChildScrollView)).dy;
    expect(
      tester.getTopLeft(find.text('M 42')).dy,
      greaterThanOrEqualTo(viewportTop),
    );
  });

  testWidgets('compact density pins a single-line ancestor row',
      (tester) async {
    await _pumpTree(
      tester,
      _tallSequence(),
      density: SequencerDensity.compact,
    );

    // Compact keeps the cards, and the target's card is several hundred pixels
    // tall, so it takes a longer scroll to clear the viewport than a 28 px
    // ledger row does.
    await _scrollBy(tester, -900);
    expect(_pinnedStack(), findsOneWidget);
    expect(
      find.descendant(of: _pinnedStack(), matching: find.text('Orion')),
      findsOneWidget,
      reason: 'the pin names the target its card names',
    );
  });

  testWidgets('comfortable density never pins', (tester) async {
    await _pumpTree(
      tester,
      _tallSequence(),
      density: SequencerDensity.comfortable,
    );

    await _scrollBy(tester, -900);
    expect(_pinnedStack(), findsNothing);
  });

  testWidgets('the pinned stack builds with animations disabled',
      (tester) async {
    await _pumpTree(tester, _tallSequence(), disableAnimations: true);

    await _scrollBy(tester, -400);
    expect(_pinnedStack(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Un-pinning happens on every upward scroll, and a stack that loses a row
  // between two frames reads as a glitch at the top of the canvas.
  testWidgets('an unpinned row leaves rather than vanishing', (tester) async {
    await _pumpTree(tester, _tallSequence());
    await _scrollBy(tester, -400);
    expect(_pinCount(), 2);

    // Back to the top. The pins are no longer wanted, but they are still there
    // for the length of their exit.
    _treePosition(tester).jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(
      _pinCount(),
      greaterThan(0),
      reason: 'the stack fades its rows out; it does not drop them',
    );

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(_pinnedStack(), findsNothing);
  });

  // A container whose row is only HALF under the stack is the case the strict
  // "the row has gone entirely" test got wrong: its name is cut in two by the
  // stack's bottom edge, and nothing at the top of the screen says which
  // container the rows below it belong to for the 28 px of scrolling it takes
  // to finish leaving. It pins the moment its top passes instead.
  testWidgets('a container pins while its own row is still partly on screen',
      (tester) async {
    await _pumpTree(tester, _tallSequence());
    final position = _treePosition(tester);

    var pinnedAt = -1.0;
    for (var offset = 0.0; offset <= 200.0; offset += 1.0) {
      position.jumpTo(offset);
      await _drain(tester);
      if (_pinCount() == 2) {
        pinnedAt = offset;
        break;
      }
    }
    expect(pinnedAt, greaterThan(0), reason: 'the fixture never pinned both');

    // The loop's own row, not its stand-in: the pin carries the same name.
    final realRow = find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.text('Broadband'),
    );
    expect(
      tester.getRect(realRow).bottom,
      greaterThan(tester.getRect(_pinnedStack()).bottom),
      reason: 'the pin arrives while the row it stands for is still half out '
          'from under the stack, not a row-height later',
    );
  });

  // The pin set is a function of the scroll offset and nothing else. It would
  // not be if the stack's own height fed back into it: a pin grows the stack,
  // which insets the viewport, which moves the rows — and a set computed
  // against the un-inset geometry would then push the row that caused the pin
  // back over the line, flap, and flap again on the next frame.
  testWidgets('the pinned set never shrinks as the tree scrolls down',
      (tester) async {
    await _pumpTree(tester, _tallSequence());
    final position = _treePosition(tester);

    var previous = 0;
    for (var offset = 0.0; offset <= 140.0; offset += 1.0) {
      position.jumpTo(offset);
      await _drain(tester);
      final pinned = _pinCount();
      expect(
        pinned,
        greaterThanOrEqualTo(previous),
        reason: 'the stack lost a pin between $previous and $offset px',
      );
      previous = pinned;
    }
    expect(previous, 2, reason: 'both containers are gone by 140 px');
  });
}
