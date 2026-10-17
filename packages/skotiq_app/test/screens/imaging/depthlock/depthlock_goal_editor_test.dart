// The goal editor: presets in front, parameters behind Advanced, a floor that
// is derived rather than typed, and calibration described rather than pathed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_goal_editor.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_pickers.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_presets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'depthlock_test_doubles.dart';

Future<void> _openEditor(
  WidgetTester tester, {
  required FakeDepthLockBackend backend,
  required DepthLockGoalDefinition definition,
  DepthLockGoal? existing,
  List<String> filterChoices = const <String>['L', 'Ha'],
  DepthLockMasterChoice? dark,
  DepthLockMasterChoice? flat,
  VoidCallback? onEditRegion,
  Future<String?> Function(String title)? filePicker,
}) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        depthLockBackendProvider.overrideWithValue(backend),
        depthLockEventStreamProvider.overrideWithValue(
          const Stream<SkotiqEvent>.empty(),
        ),
        if (filePicker != null)
          depthLockFilePickerProvider.overrideWithValue(filePicker),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => DepthLockGoalEditor.show(
                context,
                initialDefinition: definition,
                existing: existing,
                filterChoices: filterChoices,
                dark: dark,
                flat: flat,
                onEditRegion: onEditRegion,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _openAdvanced(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(SkotiqButton, 'Advanced'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the three presets are offered and named in observing terms', (
    tester,
  ) async {
    await _openEditor(
      tester,
      backend: FakeDepthLockBackend(),
      // 10 arcsec at this fixture's 1.04 arcsec/px is the Faint preset, so the
      // control opens on it rather than on "custom".
      definition: depthLockDefinitionFixture(scaleArcsec: 10, threshold: 5),
    );

    expect(find.text('Faint'), findsOneWidget);
    expect(find.text('Very faint'), findsOneWidget);
    expect(find.text('Extreme'), findsOneWidget);
    expect(
      find.textContaining('Wisps you can already glimpse in a stretched sub'),
      findsOneWidget,
    );
  });

  testWidgets('choosing a preset sets both of its numbers', (tester) async {
    final backend = FakeDepthLockBackend();
    // The fixture opens on Faint's pair for this plate scale.
    await _openEditor(
      tester,
      backend: backend,
      definition: depthLockDefinitionFixture(scaleArcsec: 10, threshold: 5),
    );

    await tester.tap(find.text('Very faint'));
    await tester.pumpAndSettle();

    expect(backend.lastChecked?.scaleArcsec, 20);
    expect(backend.lastChecked?.threshold, 4);
    expect(
      find.textContaining(
          'Structure that is only hinted at becomes believable'),
      findsOneWidget,
    );
    // The floor is per-aperture, so a new preset re-derives it.
    expect(backend.lastFloorScaleArcsec, 20);
  });

  testWidgets('the parameters live behind Advanced, not on the front', (
    tester,
  ) async {
    await _openEditor(
      tester,
      backend: FakeDepthLockBackend(),
      definition: depthLockDefinitionFixture(scaleArcsec: 10),
    );

    expect(find.text('Aperture'), findsNothing);
    expect(find.text('Coverage'), findsNothing);

    await _openAdvanced(tester);

    expect(find.text('Aperture'), findsOneWidget);
    expect(find.text('Coverage'), findsOneWidget);
    expect(
      find.text('9.6 native pixels across (the sampler accepts 4 to 64)'),
      findsOneWidget,
    );
  });

  testWidgets('the error floor is derived from the masters, not typed', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend();
    await _openEditor(
      tester,
      backend: backend,
      definition: depthLockDefinitionFixture(),
    );

    expect(
      find.text('Error floor 0.42 ADU — from your masters'),
      findsOneWidget,
    );
    expect(backend.lastFloorScaleArcsec, 7.5);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Show working'));
    await tester.pumpAndSettle();
    expect(find.text('1.800 ADU/px'), findsOneWidget);
    expect(find.text('9.6 px across'), findsOneWidget);
    expect(
      find.text(
        'Derived from master dark and flat at 10.0 arcsec apertures',
      ),
      findsOneWidget,
    );
  });

  testWidgets('create stores the derived floor and its derivation', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend();
    await _openEditor(
      tester,
      backend: backend,
      definition: depthLockDefinitionFixture(label: 'Tidal tail'),
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Create goal'));
    await tester.pumpAndSettle();

    final sent = backend.createdDefinition!;
    expect(sent.label, 'Tidal tail');
    expect(sent.measurement.systematicFloorAdu, 0.42);
    expect(
      sent.measurement.systematicFloorSource,
      'Derived from master dark and flat at 10.0 arcsec apertures',
    );
    expect(sent.measurement.minCoverage, kDepthLockDefaultCoverage);
    expect(sent.automaticCompletion, isFalse);
  });

  testWidgets('a floor that cannot be derived says why and asks for one', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend()
      ..floorError = const SkotiqError(
        category: BackendErrorCategory.io,
        message: 'Master flat is not normalised to unit mean',
      );
    await _openEditor(
      tester,
      backend: backend,
      definition: depthLockDefinitionFixture(),
    );

    expect(
      find.textContaining(
        'The error floor could not be derived Master flat is not normalised '
        'to unit mean',
      ),
      findsOneWidget,
    );
    // Advanced is opened for them, because that is where the two fields are.
    expect(find.text('Error floor'), findsOneWidget);
    expect(find.text('Floor source'), findsOneWidget);
  });

  testWidgets('a typed floor overrides the suggestion and says so', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend();
    await _openEditor(
      tester,
      backend: backend,
      definition: depthLockDefinitionFixture(),
    );
    await _openAdvanced(tester);

    await tester.enterText(
        find.widgetWithText(SkotiqTextField, '0.42'), '1.10');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      find.text('Error floor 1.10 ADU — yours (masters suggest 0.42)'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Use suggested'));
    await tester.pumpAndSettle();
    expect(
      find.text('Error floor 0.42 ADU — from your masters'),
      findsOneWidget,
    );
  });

  testWidgets('a matched master is described, never pathed', (tester) async {
    await _openEditor(
      tester,
      backend: FakeDepthLockBackend(),
      definition: depthLockDefinitionFixture(),
      dark: const DepthLockMasterChoice(
        path: '/data/masters/dark_120s.fits',
        summary: '20 × 120 s · -10 °C · gain 100',
      ),
      flat: const DepthLockMasterChoice(
        path: '/data/masters/flat_L.fits',
        summary: '24 frames · L · sky flat',
      ),
    );

    expect(
      find.text('20 × 120 s · -10 °C · gain 100 · matched to this sub'),
      findsOneWidget,
    );
    expect(
      find.text('24 frames · L · sky flat · matched to this sub'),
      findsOneWidget,
    );
    expect(find.text('/data/masters/dark_120s.fits'), findsNothing);
    expect(find.widgetWithText(SkotiqButton, 'Change…'), findsNWidgets(2));
  });

  testWidgets('an unmatched master shows the picker and the reason', (
    tester,
  ) async {
    await _openEditor(
      tester,
      backend: FakeDepthLockBackend(),
      definition: depthLockDefinitionFixture(),
      dark: const DepthLockMasterChoice(
        path: '',
        unmatchedReason: 'No master dark matches gain 100 / offset 50',
      ),
      flat: const DepthLockMasterChoice(path: '/data/masters/flat.fits'),
    );

    expect(
      find.text('No master dark matches gain 100 / offset 50'),
      findsOneWidget,
    );
    expect(find.widgetWithText(SkotiqButton, 'Choose…'), findsOneWidget);
  });

  testWidgets('a refused geometry is explained in the engine\'s own words', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend()
      ..checkError = const SkotiqError(
        category: BackendErrorCategory.validation,
        message: 'Background circumscribed circles must be disjoint',
      );
    await _openEditor(
      tester,
      backend: backend,
      definition: depthLockDefinitionFixture(),
    );

    expect(
      find.textContaining(
        'This region cannot be measured Background circumscribed circles must '
        'be disjoint',
      ),
      findsOneWidget,
    );
    final create = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Create goal'),
    );
    expect(create.onPressed, isNull);
  });

  testWidgets('a create that the host refuses keeps the form and its message', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend()
      ..mutationError = const SkotiqError(
        category: BackendErrorCategory.io,
        message: 'Master dark is not a Skotiq master (FRAMETYP missing)',
      );
    await _openEditor(
      tester,
      backend: backend,
      definition: depthLockDefinitionFixture(),
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Create goal'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'The goal was not created Master dark is not a Skotiq master '
        '(FRAMETYP missing)',
      ),
      findsOneWidget,
    );
    expect(find.text('New DepthLock goal'), findsOneWidget);
  });

  testWidgets('editing an existing goal warns that the evidence restarts', (
    tester,
  ) async {
    final goal = depthLockGoalFixture(revision: 4);
    final backend = FakeDepthLockBackend(goals: <DepthLockGoal>[goal]);
    await _openEditor(
      tester,
      backend: backend,
      definition: goal.definition,
      existing: goal,
    );

    expect(find.text('Edit DepthLock goal'), findsOneWidget);
    expect(
      find.textContaining('Saving this starts the evidence over'),
      findsOneWidget,
    );
    expect(
      find.textContaining('exposures collected for revision 4 are archived'),
      findsOneWidget,
    );

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Save new revision'),
    );
    await tester.pumpAndSettle();

    expect(backend.revised?.goalId, 'goal-1');
    expect(backend.revised?.revision, 4);
  });

  testWidgets('Edit region closes the editor and hands back to the tool', (
    tester,
  ) async {
    var asked = false;
    final goal = depthLockGoalFixture();
    await _openEditor(
      tester,
      backend: FakeDepthLockBackend(goals: <DepthLockGoal>[goal]),
      definition: goal.definition,
      existing: goal,
      onEditRegion: () => asked = true,
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Edit region'));
    await tester.pumpAndSettle();

    expect(asked, isTrue);
    expect(find.text('Edit DepthLock goal'), findsNothing);
  });

  testWidgets('the automatic-completion switch says what it does', (
    tester,
  ) async {
    await _openEditor(
      tester,
      backend: FakeDepthLockBackend(),
      definition: depthLockDefinitionFixture(),
    );

    expect(
      find.textContaining(
        'finish this filter early once the goal is reliably achieved',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'count, time, visibility and safety limits still apply',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'masters chosen after opening hand the floor to the suggestion, and a '
    'hand-picked master is named',
    (tester) async {
      // Open with neither master known — the seed floor is a placeholder,
      // not the operator's number, so once both files are chosen the
      // masters' suggestion must take over.
      await _openEditor(
        tester,
        backend: FakeDepthLockBackend(),
        definition: depthLockDefinitionFixture(),
        dark: const DepthLockMasterChoice(path: '', unmatchedReason: 'none'),
        flat: const DepthLockMasterChoice(path: '', unmatchedReason: 'none'),
        filePicker: (title) async => title.contains('dark')
            ? '/data/masters/master_dark.fits'
            : '/data/masters/master_flat.fits',
      );
      expect(find.textContaining('from your masters'), findsNothing);

      await tester.tap(find.widgetWithText(SkotiqButton, 'Choose…').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SkotiqButton, 'Choose…').first);
      await tester.pumpAndSettle();

      expect(
        find.text('Error floor 0.42 ADU — from your masters'),
        findsOneWidget,
      );
      expect(find.textContaining('yours (masters suggest'), findsNothing);
      expect(find.text('master_dark.fits · chosen by you'), findsOneWidget);
      expect(find.text('master_flat.fits · chosen by you'), findsOneWidget);
    },
  );

  testWidgets('a revision keeps a floor the operator typed as theirs', (
    tester,
  ) async {
    final definition = depthLockDefinitionFixture();
    final typed = definition.copyWith(
      measurement: definition.measurement.copyWith(
        systematicFloorAdu: 0.9,
        systematicFloorSource: 'Measured from my own residuals',
      ),
    );
    await _openEditor(
      tester,
      backend: FakeDepthLockBackend(),
      definition: typed,
      existing: depthLockGoalFixture(definition: typed),
      dark: const DepthLockMasterChoice(path: '/data/masters/dark.fits'),
      flat: const DepthLockMasterChoice(path: '/data/masters/flat.fits'),
    );
    expect(
      find.text('Error floor 0.90 ADU — yours (masters suggest 0.42)'),
      findsOneWidget,
    );
  });
}
