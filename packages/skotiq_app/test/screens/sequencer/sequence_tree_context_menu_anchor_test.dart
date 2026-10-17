// The sequencer tree's context menu must open under the cursor.
//
// `_open` fed `details.globalPosition` straight into `showMenu`'s `position`,
// whose insets are measured against the enclosing Navigator's OVERLAY. Under
// `AppShell` that overlay starts below the title bar and right of the side
// navigation rail — the routed screen lives in the nested Navigator go_router's
// `ShellRoute` hands the shell — so the overlay's origin was added twice. The
// old comment claimed the menu opened "exactly under the cursor regardless of
// where the widget sits in the layout"; it never did.
//
// Measured live at 1920x1080 on a Take Exposures row: with the nav rail
// expanded the menu landed 147 px right and 32 px below the cursor, and with
// the rail collapsed 43 px right and 32 px below — the x term tracking the rail
// width, the y term the title bar.
//
// Both the node menu and the fold-group menu are covered, and both gestures
// (secondary tap and long press). The inset is parameterised because a fix that
// subtracted one measured constant would pass a single-inset test.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequence_fold_model.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree_context_menu.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// How far the menu may sit from the point that opened it. Not zero — the popup
/// is allowed to be nudged to stay on screen — but the defect was 43-147 px.
const double _tolerance = 24.0;

({Sequence sequence, String parentId, List<String> childIds}) _twoExposures() {
  final first = ExposureNode(name: 'first', durationSecs: 30, count: 10);
  final second = ExposureNode(name: 'second', durationSecs: 30, count: 10);
  final root = InstructionSetNode(name: 'Root');
  final tree = <String, SequenceNode>{
    first.id: first.copyWith(parentId: root.id, orderIndex: 0),
    second.id: second.copyWith(parentId: root.id, orderIndex: 1),
    root.id: root.copyWith(childIds: [first.id, second.id]),
  };
  return (
    sequence: Sequence.create(name: 'T', nodes: tree, rootNodeId: root.id),
    parentId: root.id,
    childIds: [first.id, second.id],
  );
}

ProviderContainer _seed(Sequence seq) {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = seq;
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    currentSequenceProvider.overrideWith((_) => notifier),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// Mounts the menu wrapper the way `AppShell` mounts a routed screen: inside a
/// NESTED [Navigator] inset from the window by [chromeInset] on the left (the
/// nav rail) and the top (the title bar).
///
/// That inset is the entire point. Mounted at the window origin — as the
/// existing context-menu test does — the broken and the fixed maths produce
/// identical output, which is why this defect survived.
Future<Rect> _pumpShellHosted(
  WidgetTester tester,
  ProviderContainer container, {
  required String nodeId,
  required double chromeInset,
  FoldGroup? foldGroup,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  late Rect rowRect;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(height: chromeInset),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(width: chromeInset),
                    Expanded(
                      child: Navigator(
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                          builder: (_) => Align(
                            alignment: Alignment.topLeft,
                            child: SequenceTreeContextMenu(
                              nodeId: nodeId,
                              colors: SkotiqColors.dark,
                              foldGroup: foldGroup,
                              child: const SizedBox(
                                width: 420,
                                height: 44,
                                child: Text('node row'),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  rowRect = tester.getRect(find.text('node row'));
  return rowRect;
}

/// Global rect of the open menu, as the union of its items.
///
/// Read off the items rather than a `find.text`, because several menu labels
/// also appear on the sequencer's own chrome, and rather than an ancestor
/// `Material`, of which the popup route has several.
Rect _openMenuRect(WidgetTester tester) {
  // byWidgetPredicate, not byType: the menus are typed on private enums
  // (`_TreeMenuAction`, `_FoldMenuAction`) that a test cannot name, and
  // `find.byType` compares runtime types exactly.
  final items = find.byWidgetPredicate((w) => w is PopupMenuItem);
  expect(items, findsWidgets, reason: 'the context menu should be open');
  return items.evaluate().map((element) {
    final box = element.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }).reduce((a, b) => a.expandToInclude(b));
}

void _expectAnchoredAt(Rect menuRect, Offset cursor, {required String what}) {
  expect(
    (menuRect.left - cursor.dx).abs(),
    lessThanOrEqualTo(_tolerance),
    reason: '$what: menu $menuRect should open at the cursor $cursor; it is '
        '${menuRect.left - cursor.dx} px off horizontally',
  );
  expect(
    (menuRect.top - cursor.dy).abs(),
    lessThanOrEqualTo(_tolerance),
    reason: '$what: menu $menuRect should open at the cursor $cursor; it is '
        '${menuRect.top - cursor.dy} px off vertically',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final inset in <double>[0, 64, 220]) {
    testWidgets(
      'node menu opens under the cursor with the overlay inset by $inset px',
      (tester) async {
        final fixture = _twoExposures();
        final container = _seed(fixture.sequence);
        final rowRect = await _pumpShellHosted(
          tester,
          container,
          nodeId: fixture.childIds.first,
          chromeInset: inset,
        );

        final cursor = rowRect.center;
        await tester.tapAt(cursor, buttons: kSecondaryButton);
        await tester.pumpAndSettle();

        _expectAnchoredAt(
          _openMenuRect(tester),
          cursor,
          what: 'right-click, inset $inset',
        );
      },
    );
  }

  testWidgets('long-press opens the node menu under the finger',
      (tester) async {
    final fixture = _twoExposures();
    final container = _seed(fixture.sequence);
    final rowRect = await _pumpShellHosted(
      tester,
      container,
      nodeId: fixture.childIds.first,
      chromeInset: 220,
    );

    final cursor = rowRect.center;
    await tester.longPressAt(cursor);
    await tester.pumpAndSettle();

    _expectAnchoredAt(_openMenuRect(tester), cursor, what: 'long press');
  });

  testWidgets('the node menu anchor does not move with the shell chrome',
      (tester) async {
    // The live signature: the menu moved with the nav rail while the row it
    // was opened on moved by the same amount, so the cursor-to-menu offset
    // grew. A correct anchor keeps that offset constant.
    final offsets = <double>[];
    for (final inset in <double>[0, 220]) {
      final fixture = _twoExposures();
      final container = _seed(fixture.sequence);
      final rowRect = await _pumpShellHosted(
        tester,
        container,
        nodeId: fixture.childIds.first,
        chromeInset: inset,
      );
      final cursor = rowRect.center;
      await tester.tapAt(cursor, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      offsets.add(_openMenuRect(tester).left - cursor.dx);

      // Tear the whole tree down rather than dismissing the popup: at inset 0
      // the row sits at the window origin, so a "tap outside" lands on the row
      // itself, and re-pumping over a still-animating popup route leaves the
      // next iteration with no menu to measure.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }

    expect(
      offsets.first,
      closeTo(offsets.last, 1.0),
      reason: 'cursor-to-menu offset must not track the shell inset; '
          'got $offsets',
    );
  });

  for (final inset in <double>[0, 220]) {
    testWidgets(
      'fold-group menu opens under the cursor with the overlay inset by '
      '$inset px',
      (tester) async {
        final fixture = _twoExposures();
        final container = _seed(fixture.sequence);
        final group = FoldGroup(
          id: 'group-1',
          kind: FoldKind.filterRun,
          memberIds: fixture.childIds,
          memberLabels: const ['Ha', 'OIII'],
          parentId: fixture.parentId,
          firstIndex: 0,
          label: 'Ha · OIII',
          chipText: '30 s ×10 each',
          durationSecs: 30,
          count: 10,
        );
        final rowRect = await _pumpShellHosted(
          tester,
          container,
          nodeId: fixture.childIds.first,
          chromeInset: inset,
          foldGroup: group,
        );

        final cursor = rowRect.center;
        await tester.tapAt(cursor, buttons: kSecondaryButton);
        await tester.pumpAndSettle();

        _expectAnchoredAt(
          _openMenuRect(tester),
          cursor,
          what: 'fold group, inset $inset',
        );
      },
    );
  }
}
