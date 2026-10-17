import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/screens/sequencer/widgets/quick_start_wizard_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:mocktail/mocktail.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../../harness/provider_teardown.dart';

class _AppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

class _ProfilesNotifier extends EquipmentProfilesNotifier {
  _ProfilesNotifier(this.profile);

  final EquipmentProfileModel? profile;

  @override
  Future<EquipmentProfilesState> build() async => EquipmentProfilesState(
        profiles: profile == null ? const [] : [profile!],
        activeProfile: profile,
      );
}

class _FailingProfilesNotifier extends EquipmentProfilesNotifier {
  _FailingProfilesNotifier(this.onAttempt);

  final VoidCallback onAttempt;

  @override
  Future<EquipmentProfilesState> build() async {
    onAttempt();
    throw StateError('profile store unavailable');
  }
}

class _MockSettingsDao extends Mock implements SettingsDao {}

class _QuickStartHost extends StatelessWidget {
  const _QuickStartHost();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const QuickStartWizardDialog(),
          ),
          child: const Text('Open wizard'),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('keeps the focused target field visible above a landscape IME',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(932, 430);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(_AppSettingsNotifier.new),
          equipmentProfilesProvider.overrideWith(
            () => _ProfilesNotifier(null),
          ),
          smartNightExposureContextProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const _QuickStartHost(),
        ),
      ),
    );
    await tester.tap(find.text('Open wizard'));
    await tester.pumpAndSettle();

    final targetField = find.widgetWithText(TextField, 'Target Name');
    await tester.tap(targetField);
    tester.view.viewInsets = const FakeViewPadding(bottom: 230);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(targetField.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(targetField).dy, lessThanOrEqualTo(200));
  });

  testWidgets('uses Smart Night exposure recommendations for light filters',
      (tester) async {
    const exposureContext = SmartNightExposureContext(
      camera: CameraExposureSpec(
        readNoiseE: 1.4,
        fullWellE: 50000,
        qePeak: 0.85,
      ),
      bortleClass: 8,
      focalLengthMm: 384,
      apertureMm: 80,
      pixelSizeMicrons: 3.76,
      availableFilterNames: ['L', 'Ha', 'OIII'],
      userCapSeconds: 240,
      floorSeconds: 30,
    );
    const calculator = SmartNightExposureCalculator();
    final expectedL = calculator
        .recommend(
          ExposureCalculatorInput(
            camera: exposureContext.camera,
            filter: FilterExposureSpec.fromName('L'),
            bortleClass: exposureContext.bortleClass,
            focalLengthMm: exposureContext.focalLengthMm,
            apertureMm: exposureContext.apertureMm,
            pixelSizeMicrons: exposureContext.pixelSizeMicrons,
            userCapSeconds: exposureContext.userCapSeconds,
            floorSeconds: exposureContext.floorSeconds,
          ),
        )
        .seconds
        .round()
        .toString();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(_AppSettingsNotifier.new),
          equipmentProfilesProvider.overrideWith(
            () => _ProfilesNotifier(
              const EquipmentProfileModel(
                id: 1,
                name: 'Test Rig',
                isActive: true,
                filterNames: ['L', 'Ha', 'OIII'],
              ),
            ),
          ),
          smartNightExposureContextProvider
              .overrideWith((ref) async => exposureContext),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: QuickStartWizardDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Target Name'), 'M42');
    await tester.enterText(
        find.widgetWithText(TextField, 'Right Ascension'), '5.5');
    await tester.enterText(
        find.widgetWithText(TextField, 'Declination'), '-5.4');
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Next'));
    await tester.pumpAndSettle();

    expect(_textFieldWithText(expectedL), findsNWidgets(3));
    expect(_textFieldWithText('120'), findsNothing);
    expect(_textFieldWithText('300'), findsNothing);

    await settleProviderTeardown(tester);
  });

  testWidgets(
      'frames per filter drives the review estimate and generated loop exactly',
      (tester) async {
    final editor = CurrentSequenceNotifier();
    final settingsDao = _MockSettingsDao();
    when(() => settingsDao.getSetting(any())).thenAnswer((_) async => null);
    when(() => settingsDao.setSetting(any(), any())).thenAnswer((_) async {});
    when(() => settingsDao.setSettings(any())).thenAnswer((_) async {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          settingsDaoProvider.overrideWithValue(settingsDao),
          appSettingsProvider.overrideWith(_AppSettingsNotifier.new),
          equipmentProfilesProvider.overrideWith(
            () => _ProfilesNotifier(
              const EquipmentProfileModel(
                id: 1,
                name: 'Test Rig',
                isActive: true,
                filterNames: ['L', 'Ha'],
              ),
            ),
          ),
          smartNightExposureContextProvider.overrideWith((ref) async => null),
          currentSequenceProvider.overrideWith((ref) => editor),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: QuickStartWizardDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Target Name'),
      'X',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Right Ascension'),
      '5.5',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Declination'),
      '-5.4',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Next'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Step 2 of 5: Filters & Exposures'), findsOneWidget);

    final framesField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Frames per filter',
    );
    await tester.enterText(framesField, '3');
    await tester.pump(const Duration(milliseconds: 100));
    expect(_textFieldWithText('3'), findsOneWidget);

    for (var step = 0; step < 3; step++) {
      await tester.tap(find.widgetWithText(SkotiqButton, 'Next'));
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('Frames per filter'), findsOneWidget);
    expect(find.text('~38m'), findsOneWidget);
    expect(find.textContaining('L'), findsWidgets);
    expect(find.textContaining('Ha'), findsWidgets);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Create sequence'));
    await tester.pump(const Duration(milliseconds: 500));

    final sequence = editor.state;
    expect(sequence, isNotNull);
    final exposures = sequence!.nodes.values.whereType<ExposureNode>().toList();
    final loops = sequence.nodes.values.whereType<LoopNode>().toList();
    expect(exposures, hasLength(2));
    expect(exposures.map((node) => node.count), everyElement(1));
    expect(loops, hasLength(1));
    expect(loops.single.repeatCount, 3);
  });

  testWidgets('rejects impossible coordinates and accepts strict HMS/DMS',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(_AppSettingsNotifier.new),
          equipmentProfilesProvider.overrideWith(
            () => _ProfilesNotifier(null),
          ),
          smartNightExposureContextProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: QuickStartWizardDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Target Name'),
      'Manual target',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Right Ascension'),
      '12:99:00',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Declination'),
      '+91:00:00',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Next'));
    await tester.pump();
    expect(find.text('Step 1 of 5: Choose Your Target'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Right Ascension'),
      '05H 30M 00S',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Declination'),
      '-00D 30M 00S',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Next'));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 5: Filters & Exposures'), findsOneWidget);

    await settleProviderTeardown(tester);
  });

  testWidgets(
    'preloads cooling temperature from the active equipment profile',
    (tester) async {
      // The wizard's `_applyUserDefaults` reads
      // `activeEquipmentProfileProvider` in initState and seeds
      // `_coolingTemp` from `profile.defaultCoolingTemp`. The cooling
      // target lives on the equipment profile rather than in app settings,
      // so this is an isolated override that doesn't require the
      // sequencer-defaults DAO to be wired up.
      const profile = EquipmentProfileModel(
        id: 1,
        name: 'Test Rig',
        isActive: true,
        filterNames: ['L', 'R', 'G', 'B'],
        defaultCoolingTemp: -15.0,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            appSettingsProvider.overrideWith(_AppSettingsNotifier.new),
            equipmentProfilesProvider.overrideWith(
              () => _ProfilesNotifier(profile),
            ),
            smartNightExposureContextProvider.overrideWith((ref) async => null),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: QuickStartWizardDialog()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Drive the wizard from Step 1 -> Step 4 (Safety) where the
      // cooling-temperature input is rendered.
      await tester.enterText(
          find.widgetWithText(TextField, 'Target Name'), 'M42');
      await tester.enterText(
          find.widgetWithText(TextField, 'Right Ascension'), '5.5');
      await tester.enterText(
          find.widgetWithText(TextField, 'Declination'), '-5.4');
      await tester.pump();
      // Step 1 -> Step 2
      await tester.tap(find.widgetWithText(SkotiqButton, 'Next'));
      await tester.pumpAndSettle();
      // Step 2 -> Step 3
      await tester.tap(find.widgetWithText(SkotiqButton, 'Next'));
      await tester.pumpAndSettle();
      // Step 3 -> Step 4 (Safety)
      await tester.tap(find.widgetWithText(SkotiqButton, 'Next'));
      await tester.pumpAndSettle();

      // Cooling target reflects the active profile's -15 C, not the
      // wizard's historical -10 C fallback constant.
      expect(_textFieldWithText('-15'), findsOneWidget);
      expect(_textFieldWithText('-10'), findsNothing);

      // The "Using your saved defaults" hint is shown because the
      // profile's cooling temp diverged from the wizard's fallback.
      expect(find.textContaining('Using your saved defaults'), findsOneWidget);

      await settleProviderTeardown(tester);
    },
  );

  testWidgets('profile load failure blocks editing and offers retry',
      (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(_AppSettingsNotifier.new),
          equipmentProfilesProvider.overrideWith(
            () => _FailingProfilesNotifier(() => attempts++),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: QuickStartWizardDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not load wizard defaults'), findsOneWidget);
    expect(find.textContaining('profile store unavailable'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Retry'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Target Name'), findsNothing);
    expect(attempts, 1);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });

  testWidgets(
    'reports a requested defaults-save failure without discarding the sequence',
    (tester) async {
      final settingsDao = _MockSettingsDao();
      final editor = CurrentSequenceNotifier();
      when(() => settingsDao.getSetting(any())).thenAnswer((_) async => null);
      when(() => settingsDao.setSettings(any())).thenAnswer((_) async {});
      when(() => settingsDao.setSetting(any(), any())).thenThrow(
        StateError('settings write unavailable'),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            settingsDaoProvider.overrideWithValue(settingsDao),
            appSettingsProvider.overrideWith(_AppSettingsNotifier.new),
            equipmentProfilesProvider.overrideWith(
              () => _ProfilesNotifier(null),
            ),
            smartNightExposureContextProvider.overrideWith((ref) async => null),
            currentSequenceProvider.overrideWith((ref) => editor),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const _QuickStartHost(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open wizard'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Target Name'),
        'M',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Right Ascension'),
        '5.5',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Declination'),
        '-5.4',
      );

      for (var step = 0; step < 4; step++) {
        await tester.pump();
        await tester.tap(find.widgetWithText(SkotiqButton, 'Next'));
        await tester.pumpAndSettle();
      }

      final saveDefaultsLabel = find.textContaining(
        'Save these as my defaults',
      );
      await tester.ensureVisible(saveDefaultsLabel);
      await tester.tap(saveDefaultsLabel);
      await tester.pump();

      final createButton = find.widgetWithText(
        SkotiqButton,
        'Create sequence',
      );
      await tester.ensureVisible(createButton);
      await tester.tap(createButton);
      await tester.pumpAndSettle();

      expect(find.text('Quick-Start Sequence Wizard'), findsNothing);
      expect(editor.state?.name, 'M Sequence');
      expect(
        find.textContaining(
          'Sequence created, but defaults could not be saved: '
          'Bad state: settings write unavailable',
        ),
        findsOneWidget,
      );
      verify(() => settingsDao.setSetting('enable_meridian_flip', 'true'))
          .called(1);
    },
  );

  testWidgets('asks before replacing an unsaved editor draft', (tester) async {
    final editor = CurrentSequenceNotifier();
    editor.createSequence(name: 'Manual draft');
    editor.addNode(DelayNode(id: 'dirty-delay', seconds: 1));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(_AppSettingsNotifier.new),
          equipmentProfilesProvider.overrideWith(
            () => _ProfilesNotifier(null),
          ),
          smartNightExposureContextProvider.overrideWith((ref) async => null),
          currentSequenceProvider.overrideWith((ref) => editor),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const _QuickStartHost(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open wizard'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Target Name'),
      'M31',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Right Ascension'),
      '5.5',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Declination'),
      '-5.4',
    );
    await tester.pump();
    const nextStepTitles = [
      'Step 2 of 5: Filters & Exposures',
      'Step 3 of 5: Automation',
      'Step 4 of 5: Safety',
      'Step 5 of 5: Review & Create',
    ];
    for (var step = 0; step < nextStepTitles.length; step++) {
      final next = find.widgetWithText(SkotiqButton, 'Next');
      await tester.ensureVisible(next);
      await tester.tap(next);
      await tester.pump();
      expect(find.text(nextStepTitles[step]), findsOneWidget);
    }

    final createButton = find.widgetWithText(
      SkotiqButton,
      'Create sequence',
    );
    await tester.ensureVisible(createButton);
    await tester.tap(createButton);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    expect(editor.state?.name, 'Manual draft');
    expect(editor.isDirty, isTrue);

    final confirmation = find.byType(AlertDialog);
    await tester.tap(
      find.descendant(of: confirmation, matching: find.text('Cancel')),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Quick-Start Sequence Wizard'), findsOneWidget);
    expect(editor.state?.name, 'Manual draft');
    expect(editor.isDirty, isTrue);

    await tester.tap(createButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Discard and create'));
    await tester.pumpAndSettle();

    expect(find.text('Quick-Start Sequence Wizard'), findsNothing);
    expect(editor.state?.name, 'M31 Sequence');
    expect(editor.isDirty, isFalse);

    await settleProviderTeardown(tester);
  });
}

Finder _textFieldWithText(String value) {
  return find.byWidgetPredicate(
    (widget) => widget is TextField && widget.controller?.text == value,
    description: 'TextField with controller text "$value"',
  );
}
