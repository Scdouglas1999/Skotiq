// The canvas bar's overview toggle: Ledger has no overview and no toggle; the
// other two densities show the 80 px map strip on request and remember the
// answer per density.
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
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';
import '../../harness/pump_app_screen.dart';

/// The settings row the preference lives in.
const _settingsKey = 'sequence_overview_visible_v1';

/// Wide enough for the canvas bar's glyph tier (tooltips, not words) and for
/// all four ledger columns, so no clamp is in play.
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
      // The minute clock is a real periodic stream whose timer outlives every
      // pump in the fake-async zone.
      ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ],
  );
  await _drain(tester);
  return handle;
}

/// Past the debounced validation, the post-frame density publish and the
/// strip's own open/close, so every assertion reads a settled canvas.
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

  testWidgets('ledger draws no overview and offers no toggle for one',
      (tester) async {
    await _pumpCanvas(tester);
    expect(_toggle(), findsNothing);
    expect(find.byType(SequenceMinimap), findsNothing);
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

    // Comfortable: on, against its off-by-default.
    await _setDensity(tester, handle, SequencerDensity.comfortable);
    expect(find.byType(SequenceMinimap), findsNothing);
    await tester.tap(_toggle());
    await _drain(tester);
    expect(find.byType(SequenceMinimap), findsOneWidget);

    // Compact never had it chosen, so it is still off.
    await _setDensity(tester, handle, SequencerDensity.compact);
    expect(find.byType(SequenceMinimap), findsNothing);

    // Ledger never shows it.
    await _setDensity(tester, handle, SequencerDensity.ledger);
    expect(find.byType(SequenceMinimap), findsNothing);

    await _setDensity(tester, handle, SequencerDensity.comfortable);
    expect(find.byType(SequenceMinimap), findsOneWidget);

    expect(
      jsonDecode(
          (await SettingsDao(handle.database).getSetting(_settingsKey))!),
      {'comfortable': true},
    );
  });

  testWidgets('the labeled tier names the thing it toggles', (tester) async {
    final notifier = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    notifier.state = _tallSequence();
    final handle = await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SequenceToolbar(colors: SkotiqColors.of(context)),
      ),
      // Wide enough for the toggles to carry words rather than glyphs.
      size: const Size(1400, 800),
      settle: false,
      extraOverrides: [currentSequenceProvider.overrideWith((_) => notifier)],
    );
    await _drain(tester);
    expect(
      find.byWidgetPredicate(
        (w) => w is SkotiqButton && w.icon == LucideIcons.map,
      ),
      findsNothing,
      reason: 'Ledger has no overview to toggle',
    );
    await _setDensity(tester, handle, SequencerDensity.compact);

    final button = tester.widget<SkotiqButton>(
      find.byWidgetPredicate(
        (w) => w is SkotiqButton && w.icon == LucideIcons.map,
      ),
    );
    expect(button.label, 'Map');
    expect(button.semanticsHint, 'Show the map');
  });

  test('a fresh store is off everywhere, and Ledger is never on', () async {
    final db = mockDatabase();
    addTearDown(db.close);
    final container =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);

    final prefs = await container.read(sequenceOverviewPrefsProvider.future);
    expect(prefs.visibleIn(SequencerDensity.ledger), isFalse);
    expect(prefs.visibleIn(SequencerDensity.comfortable), isFalse);
    expect(prefs.visibleIn(SequencerDensity.compact), isFalse);
    expect(container.read(sequenceOverviewVisibleProvider), isFalse);
    expect(
      prefs
          .withVisibility(SequencerDensity.ledger, true)
          .visibleIn(SequencerDensity.ledger),
      isFalse,
    );
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
