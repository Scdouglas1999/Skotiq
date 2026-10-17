// The canvas bar's overview toggle: what it hides in the density the canvas is
// drawing, what it says it will do before you press it, and what it remembers
// per density. It used to govern only the 80 px strip, which Ledger — the
// shipped default — does not draw, so in Ledger the control did nothing at all.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_minimap.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_overview_prefs.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequencer_density.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';
import '../../harness/pump_app_screen.dart';

/// The settings row the preference lives in.
const _settingsKey = 'sequence_overview_visible_v1';

/// Wide enough for the canvas bar's glyph tier (tooltips, not words) and for
/// the ledger columns to afford the gutter, so no clamp is in play.
const Size _canvas = Size(1180, 800);

/// Root -> "M 42" -> "Broadband" -> 20 differently-lengthed subs, which is a
/// tree taller than the viewport: the overview only has something to say when
/// the night does not fit on one screen.
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
    for (var i = 0; i < 20; i++)
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

/// The canvas bar over the tree it governs — the pair the toggle is a contract
/// between. Neither the density nor the overview preference is overridden:
/// both tests below turn on what they need through the real notifiers, which
/// is the path the button takes.
Future<HarnessHandle> _pumpCanvas(WidgetTester tester) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _tallSequence();

  final handle = await pumpAppScreen(
    tester,
    Builder(
      builder: (context) {
        final colors = SkotiqColors.of(context);
        return Column(
          children: [
            SequenceToolbar(colors: colors),
            Expanded(child: SequenceTree(colors: colors)),
          ],
        );
      },
    ),
    size: _canvas,
    // Live validation debounces 500 ms; drain frames by hand instead.
    settle: false,
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.idle),
      // The minute clock is a real periodic stream whose timer outlives every
      // pump in the fake-async zone.
      ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ],
  );
  await _drain(tester);
  return handle;
}

/// Past the debounced validation, the post-frame density publish and the
/// gutter's own open/close, so every assertion reads a settled canvas.
Future<void> _drain(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Finder _toggle() => find.byWidgetPredicate(
      (w) => w is SkotiqIconButton && w.icon == LucideIcons.map,
    );

String? _toggleTooltip(WidgetTester tester) =>
    tester.widget<SkotiqIconButton>(_toggle()).tooltip;

bool _toggleSelected(WidgetTester tester) =>
    tester.widget<SkotiqIconButton>(_toggle()).selected;

Finder _gutter() => find.byKey(sequenceGutterMapKey);

/// The width the rows themselves are laid out in — the tree's own scroll
/// viewport, not the canvas bar's (the bar scrolls its chips horizontally).
double _rowsWidth(WidgetTester tester) => tester
    .getSize(
      find
          .descendant(
            of: find.byType(SequenceTree),
            matching: find.byType(SingleChildScrollView),
          )
          .first,
    )
    .width;

Future<void> _setDensity(
  WidgetTester tester,
  HarnessHandle handle,
  SequencerDensity density,
) async {
  await handle.container
      .read(sequencerDensityPrefsProvider.notifier)
      .setDensity(density);
  await _drain(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ledger: the toggle hides the gutter and the rows take its width',
      (tester) async {
    await _pumpCanvas(tester);

    expect(_gutter(), findsOneWidget);
    expect(_toggleSelected(tester), isTrue);
    expect(_toggleTooltip(tester), 'Hide the overview gutter');
    final rowsWithGutter = _rowsWidth(tester);

    await tester.tap(_toggle());
    await _drain(tester);

    expect(_gutter(), findsNothing);
    expect(_toggleSelected(tester), isFalse);
    expect(_toggleTooltip(tester), 'Show the overview gutter');
    expect(
      _rowsWidth(tester) - rowsWithGutter,
      34.0,
      reason: 'the ledger columns get the gutter\'s width back, to the pixel',
    );

    await tester.tap(_toggle());
    await _drain(tester);

    expect(_gutter(), findsOneWidget);
    expect(_rowsWidth(tester), rowsWithGutter);
  });

  testWidgets('comfortable: the toggle shows the 80 px strip', (tester) async {
    final handle = await _pumpCanvas(tester);
    await _setDensity(tester, handle, SequencerDensity.comfortable);

    expect(find.byType(SequenceMinimap), findsNothing);
    expect(_toggleSelected(tester), isFalse);
    expect(_toggleTooltip(tester), 'Show the map');

    await tester.tap(_toggle());
    await _drain(tester);

    expect(find.byType(SequenceMinimap), findsOneWidget);
    expect(tester.getSize(find.byType(SequenceMinimap)).height, 80.0);
    expect(_toggleSelected(tester), isTrue);
    expect(_toggleTooltip(tester), 'Hide the map');
  });

  testWidgets('each density keeps its own answer across a switch',
      (tester) async {
    final handle = await _pumpCanvas(tester);

    // Ledger: off, against its on-by-default.
    await tester.tap(_toggle());
    await _drain(tester);
    expect(_gutter(), findsNothing);

    // Comfortable: on, against its off-by-default.
    await _setDensity(tester, handle, SequencerDensity.comfortable);
    expect(find.byType(SequenceMinimap), findsNothing);
    await tester.tap(_toggle());
    await _drain(tester);
    expect(find.byType(SequenceMinimap), findsOneWidget);

    // Neither choice reaches the other density, in either direction.
    await _setDensity(tester, handle, SequencerDensity.ledger);
    expect(_gutter(), findsNothing);
    expect(find.byType(SequenceMinimap), findsNothing);

    await _setDensity(tester, handle, SequencerDensity.comfortable);
    expect(find.byType(SequenceMinimap), findsOneWidget);

    // And both survived the trip through the database.
    expect(
      jsonDecode(
          (await SettingsDao(handle.database).getSetting(_settingsKey))!),
      {'ledger': false, 'comfortable': true},
    );
  });

  testWidgets('the labelled tier names the thing it toggles', (tester) async {
    final notifier = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    notifier.state = _tallSequence();
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) =>
            SequenceToolbar(colors: SkotiqColors.of(context)),
      ),
      // Wide enough for the toggles to carry words rather than glyphs.
      size: const Size(1400, 800),
      settle: false,
      extraOverrides: [currentSequenceProvider.overrideWith((_) => notifier)],
    );
    await _drain(tester);

    final button = tester.widget<SkotiqButton>(
      find.byWidgetPredicate(
        (w) => w is SkotiqButton && w.icon == LucideIcons.map,
      ),
    );
    expect(button.label, 'Gutter');
    expect(button.semanticsHint, 'Hide the overview gutter');
  });

  test('the wording follows the density and the current state', () {
    expect(
      sequenceOverviewToggleLabel(
          density: SequencerDensity.ledger, visible: true),
      'Hide the overview gutter',
    );
    expect(
      sequenceOverviewToggleLabel(
          density: SequencerDensity.ledger, visible: false),
      'Show the overview gutter',
    );
    for (final density in [
      SequencerDensity.comfortable,
      SequencerDensity.compact,
    ]) {
      expect(
        sequenceOverviewToggleLabel(density: density, visible: true),
        'Hide the map',
      );
      expect(
        sequenceOverviewToggleLabel(density: density, visible: false),
        'Show the map',
      );
      expect(sequenceOverviewButtonLabel(density), 'Map');
    }
    expect(sequenceOverviewButtonLabel(SequencerDensity.ledger), 'Gutter');
  });

  test('a fresh store is gutter-on in ledger, strip-off elsewhere', () async {
    final db = mockDatabase();
    addTearDown(db.close);
    final container =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);

    final prefs = await container.read(sequenceOverviewPrefsProvider.future);
    expect(prefs.visibleIn(SequencerDensity.ledger), isTrue);
    expect(prefs.visibleIn(SequencerDensity.comfortable), isFalse);
    expect(prefs.visibleIn(SequencerDensity.compact), isFalse);
    // The synchronous view answers for the density on screen while hydrating.
    expect(container.read(sequenceOverviewVisibleProvider), isTrue);
  });

  test('a choice per density survives a fresh notifier', () async {
    final db = mockDatabase();
    addTearDown(db.close);
    final container =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);

    final notifier = container.read(sequenceOverviewPrefsProvider.notifier);
    await notifier.setVisible(SequencerDensity.ledger, false);
    await notifier.setVisible(SequencerDensity.compact, true);

    expect(container.read(sequenceOverviewVisibleProvider), isFalse);
    expect(jsonDecode((await SettingsDao(db).getSetting(_settingsKey))!),
        {'ledger': false, 'compact': true});

    final container2 =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container2.dispose);
    final rehydrated =
        await container2.read(sequenceOverviewPrefsProvider.future);
    expect(rehydrated.visibleIn(SequencerDensity.ledger), isFalse);
    expect(rehydrated.visibleIn(SequencerDensity.compact), isTrue);
    // Untouched, so it still follows the default rather than a stored copy
    // of it.
    expect(rehydrated.visibleIn(SequencerDensity.comfortable), isFalse);
  });

  test('a stored value that names no density is ignored, not fatal', () async {
    final db = mockDatabase();
    addTearDown(db.close);
    await SettingsDao(db)
        .setSetting(_settingsKey, '{"ledger":false,"sidebyside":true}');
    final container =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);

    final prefs = await container.read(sequenceOverviewPrefsProvider.future);
    expect(prefs.visibleIn(SequencerDensity.ledger), isFalse);
    expect(prefs.visibleIn(SequencerDensity.comfortable), isFalse);
  });
}
