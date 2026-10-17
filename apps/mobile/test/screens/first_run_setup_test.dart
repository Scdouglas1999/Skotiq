// Tests for the first-run setup detection.
//
// The wizard itself shells into widgets that depend on network calls
// against a live NetworkBackend; full-stack rendering is exercised by
// the dashboard widget test. Here we lock down the two pieces of
// detection logic that govern *whether* the wizard runs:
//
//   1. [FirstRunSetupNeeds.hasAnyMissing] — pure boolean.
//   2. [MobilePreferences.firstRunCompleted] — persisted latch.
//
// Coverage for both is enough to guarantee the gate flips correctly;
// the wizard UI itself is covered by a smoke render test.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_mobile/screens/setup/first_run_setup_screen.dart';
import 'package:skotiq_mobile/services/mobile_preferences.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FirstRunSetupNeeds.hasAnyMissing', () {
    test('returns false when nothing is missing', () {
      const needs = FirstRunSetupNeeds(
        missingImageOutputPath: false,
        missingProfiles: false,
        missingCatalogs: false,
      );
      expect(needs.hasAnyMissing, isFalse);
    });

    test('returns true when image output path is missing', () {
      const needs = FirstRunSetupNeeds(
        missingImageOutputPath: true,
        missingProfiles: false,
        missingCatalogs: false,
      );
      expect(needs.hasAnyMissing, isTrue);
    });

    test('returns true when profiles are missing', () {
      const needs = FirstRunSetupNeeds(
        missingImageOutputPath: false,
        missingProfiles: true,
        missingCatalogs: false,
      );
      expect(needs.hasAnyMissing, isTrue);
    });

    test('returns true when catalogs are missing', () {
      const needs = FirstRunSetupNeeds(
        missingImageOutputPath: false,
        missingProfiles: false,
        missingCatalogs: true,
      );
      expect(needs.hasAnyMissing, isTrue);
    });

    test('none sentinel is fully populated', () {
      expect(FirstRunSetupNeeds.none.hasAnyMissing, isFalse);
      expect(FirstRunSetupNeeds.none.missingImageOutputPath, isFalse);
      expect(FirstRunSetupNeeds.none.missingProfiles, isFalse);
      expect(FirstRunSetupNeeds.none.missingCatalogs, isFalse);
    });
  });

  group('MobilePreferences.firstRunCompleted', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('defaults to false on a fresh install', () async {
      final prefs = MobilePreferences(await SharedPreferences.getInstance());
      expect(prefs.firstRunCompleted, isFalse);
    });

    test('setter persists the latch', () async {
      final prefs = MobilePreferences(await SharedPreferences.getInstance());
      await prefs.setFirstRunCompleted(true);

      // A fresh wrapper over the same SharedPreferences singleton must
      // observe the persisted value. We re-read SharedPreferences.getInstance
      // (which returns the same instance) and rebuild the MobilePreferences
      // wrapper to simulate a process restart.
      final reread = MobilePreferences(await SharedPreferences.getInstance());
      expect(reread.firstRunCompleted, isTrue);
    });

    test('setter can revert the latch', () async {
      final prefs = MobilePreferences(await SharedPreferences.getInstance());
      await prefs.setFirstRunCompleted(true);
      await prefs.setFirstRunCompleted(false);
      expect(prefs.firstRunCompleted, isFalse);
    });
  });

  test('first-run detection fails closed when server checks fail', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = MobilePreferences(await SharedPreferences.getInstance());
    final backend = _DetectionFailureBackend();
    final container = ProviderContainer(
      overrides: [
        mobilePreferencesProvider.overrideWith((ref) async => prefs),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(mobilePreferencesProvider.future);
    final needs = await container.read(shouldRunFirstRunSetupProvider.future);

    expect(needs.missingImageOutputPath, isTrue);
    expect(needs.missingProfiles, isTrue);
    expect(needs.missingCatalogs, isTrue);
  });

  test('first-run detection waits for the preference latch', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final pendingPrefs = Completer<MobilePreferences>();
    final container = ProviderContainer(
      overrides: [
        mobilePreferencesProvider.overrideWith((ref) => pendingPrefs.future),
      ],
    );
    addTearDown(container.dispose);

    var completed = false;
    final detection = container
        .read(shouldRunFirstRunSetupProvider.future)
        .then((value) {
          completed = true;
          return value;
        });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    pendingPrefs.complete(
      MobilePreferences(await SharedPreferences.getInstance()),
    );
    expect(await detection, FirstRunSetupNeeds.none);
  });

  group('FirstRunSetupScreen smoke render', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    testWidgets('renders the three setup steps without crashing', (
      tester,
    ) async {
      // We render the screen with a non-NetworkBackend so it never tries
      // to make HTTP calls; the wizard still has to render its Stepper
      // shell and the three step headers.
      var onCompletedFired = false;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(extensions: const [SkotiqColors.dark]),
            home: FirstRunSetupScreen(
              needs: const FirstRunSetupNeeds(
                missingImageOutputPath: true,
                missingProfiles: true,
                missingCatalogs: true,
              ),
              onCompleted: () => onCompletedFired = true,
            ),
          ),
        ),
      );
      await tester.pump();

      // The Stepper renders all three step titles regardless of which
      // step is active.
      expect(find.text('Image output path'), findsOneWidget);
      expect(find.text('Catalogs'), findsOneWidget);
      expect(find.text('Equipment profile'), findsOneWidget);

      // AppBar Skip button is visible. The Stepper's "Skip and continue"
      // label on the catalogs step also contains the word, but it is not
      // rendered on the active step on first build (active step is 0),
      // so an exact match against 'Skip' is unambiguous.
      expect(find.widgetWithText(TextButton, 'Skip'), findsOneWidget);
      // Wizard hasn't completed yet.
      expect(onCompletedFired, isFalse);
    });

    testWidgets(
      'catalog failure does not discard successfully loaded profiles',
      (tester) async {
        final backend = _CatalogFailureBackend();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              backendProvider.overrideWith(
                (ref) => _TestBackendNotifier(ref, backend),
              ),
            ],
            child: MaterialApp(
              theme: ThemeData(extensions: const [SkotiqColors.dark]),
              home: FirstRunSetupScreen(
                needs: const FirstRunSetupNeeds(
                  missingImageOutputPath: false,
                  missingProfiles: false,
                  missingCatalogs: true,
                ),
                onCompleted: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Could not list catalogs'), findsOneWidget);
        await tester.tap(find.text('Skip catalogs'));
        await tester.pumpAndSettle();

        expect(find.text('Observatory'), findsOneWidget);
        expect(find.text('Finish setup'), findsOneWidget);
      },
    );

    testWidgets('rejects a host capture path that fails validation', (
      tester,
    ) async {
      final backend = _PathValidationBackend(
        validationResult: const {
          'valid': false,
          'exists': false,
          'writable': false,
          'error': 'Folder does not exist on the imaging host',
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(extensions: const [SkotiqColors.dark]),
            home: FirstRunSetupScreen(
              needs: const FirstRunSetupNeeds(
                missingImageOutputPath: true,
                missingProfiles: false,
                missingCatalogs: false,
              ),
              onCompleted: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '/missing/captures');
      await tester.tap(find.text('Save and continue'));
      await tester.pumpAndSettle();

      expect(backend.validatedPath, '/missing/captures');
      expect(backend.requiredExistingDirectory, isTrue);
      expect(backend.requiredWritableDirectory, isTrue);
      expect(backend.updatedSettings, isNull);
      expect(
        find.textContaining('Folder does not exist on the imaging host'),
        findsOneWidget,
      );
      expect(find.text('Host capture directory'), findsOneWidget);
    });

    testWidgets('persists the normalized host capture path', (tester) async {
      final backend = _PathValidationBackend(
        validationResult: const {
          'valid': true,
          'exists': true,
          'writable': true,
          'normalizedPath': '/srv/skotiq/captures',
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(extensions: const [SkotiqColors.dark]),
            home: FirstRunSetupScreen(
              needs: const FirstRunSetupNeeds(
                missingImageOutputPath: true,
                missingProfiles: false,
                missingCatalogs: true,
              ),
              onCompleted: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '/host/captures/../data');
      await tester.tap(find.text('Save and continue'));
      await tester.pumpAndSettle();

      expect(backend.validatedPath, '/host/captures/../data');
      expect(
        backend.updatedSettings?.imageOutputPath,
        '/srv/skotiq/captures',
      );
      expect(find.textContaining('Pick catalogs to install'), findsOneWidget);
    });
  });

  group('FirstRunSetupScreen step ticks', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    List<StepState> statesOf(WidgetTester tester) => tester
        .widget<Stepper>(find.byType(Stepper))
        .steps
        .map((step) => step.state)
        .toList();

    testWidgets('tapping ahead does not tick off an unconfigured step', (
      tester,
    ) async {
      final backend = _PathValidationBackend(
        validationResult: const {'valid': true},
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(extensions: const [SkotiqColors.dark]),
            home: FirstRunSetupScreen(
              needs: const FirstRunSetupNeeds(
                missingImageOutputPath: true,
                missingProfiles: true,
                missingCatalogs: true,
              ),
              onCompleted: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(statesOf(tester), [
        StepState.indexed,
        StepState.indexed,
        StepState.indexed,
      ]);

      // Jump straight to the profile step without saving a path or installing
      // a catalog. Nothing has been configured, so nothing may claim to be.
      await tester.tap(find.text('Equipment profile'));
      await tester.pumpAndSettle();

      expect(
        statesOf(tester),
        [StepState.indexed, StepState.indexed, StepState.indexed],
        reason: 'navigating past a step is not the same as completing it',
      );
      expect(backend.updatedSettings, isNull);
    });

    testWidgets('the output-path step ticks once the host accepts the path', (
      tester,
    ) async {
      final backend = _PathValidationBackend(
        validationResult: const {
          'valid': true,
          'normalizedPath': '/srv/captures',
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(extensions: const [SkotiqColors.dark]),
            home: FirstRunSetupScreen(
              needs: const FirstRunSetupNeeds(
                missingImageOutputPath: true,
                missingProfiles: true,
                missingCatalogs: true,
              ),
              onCompleted: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '/srv/captures');
      await tester.tap(find.text('Save and continue'));
      await tester.pumpAndSettle();

      expect(backend.updatedSettings?.imageOutputPath, '/srv/captures');
      expect(statesOf(tester).first, StepState.complete);
      expect(statesOf(tester)[1], StepState.indexed);
    });

    testWidgets('a profile read back from the host ticks the profile step', (
      tester,
    ) async {
      // The launch-time snapshot said "no profiles", but the host answers with
      // one — the tick follows the host, not the stale snapshot.
      final backend = _CatalogFailureBackend();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(extensions: const [SkotiqColors.dark]),
            home: FirstRunSetupScreen(
              needs: const FirstRunSetupNeeds(
                missingImageOutputPath: false,
                missingProfiles: true,
                missingCatalogs: true,
              ),
              onCompleted: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(statesOf(tester).last, StepState.complete);
    });
  });
}

class _PathValidationBackend extends NetworkBackend {
  _PathValidationBackend({required this.validationResult})
    : super(serverHost: '127.0.0.1', autoConnectWebSocket: false);

  final Map<String, dynamic> validationResult;
  String? validatedPath;
  bool? requiredExistingDirectory;
  bool? requiredWritableDirectory;
  AppSettings? updatedSettings;

  @override
  Future<Map<String, dynamic>> validateRemoteDirectory(
    String path, {
    bool mustExist = false,
    bool mustBeWritable = false,
  }) async {
    validatedPath = path;
    requiredExistingDirectory = mustExist;
    requiredWritableDirectory = mustBeWritable;
    return validationResult;
  }

  @override
  Future<AppSettings> getSettings() async => const AppSettings();

  @override
  Future<void> updateSettings(AppSettings settings) async {
    updatedSettings = settings;
  }

  @override
  Future<List<RemoteAvailableCatalog>> listAvailableCatalogs() async =>
      const [];

  @override
  Future<List<EquipmentProfile>> getProfiles() async => const [];
}

class _CatalogFailureBackend extends NetworkBackend {
  _CatalogFailureBackend()
    : super(serverHost: '127.0.0.1', autoConnectWebSocket: false);

  @override
  Future<List<RemoteAvailableCatalog>> listAvailableCatalogs() {
    throw StateError('catalog endpoint unavailable');
  }

  @override
  Future<List<EquipmentProfile>> getProfiles() async => const [
    EquipmentProfile(id: 'profile-1', name: 'Observatory'),
  ];
}

class _DetectionFailureBackend extends NetworkBackend {
  _DetectionFailureBackend()
    : super(serverHost: '127.0.0.1', autoConnectWebSocket: false);

  @override
  Future<AppSettings> getSettings() {
    throw StateError('settings endpoint unavailable');
  }

  @override
  Future<List<EquipmentProfile>> getProfiles() {
    throw StateError('profiles endpoint unavailable');
  }

  @override
  Future<RemoteCatalogStatusResponse> getCatalogStatus() {
    throw StateError('catalog status endpoint unavailable');
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
