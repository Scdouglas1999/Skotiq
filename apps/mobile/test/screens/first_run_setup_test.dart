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
            theme: SkotiqTheme.dark,
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
      expect(find.text('Capture folder'), findsOneWidget);
      expect(find.text('Star catalogs'), findsOneWidget);
      expect(find.text('Equipment profile'), findsOneWidget);

      expect(find.widgetWithText(SkotiqButton, 'Skip'), findsOneWidget);
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
              theme: SkotiqTheme.dark,
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

        expect(
          find.textContaining('Could not list the catalogs'),
          findsOneWidget,
        );
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
            theme: SkotiqTheme.dark,
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
      expect(find.text('Capture folder on the rig'), findsOneWidget);
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
            theme: SkotiqTheme.dark,
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
      expect(backend.updatedSettings?.imageOutputPath, '/srv/skotiq/captures');
      expect(
        find.textContaining('Plate solving needs at least one star catalog'),
        findsOneWidget,
      );
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
            theme: SkotiqTheme.dark,
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
            theme: SkotiqTheme.dark,
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
            theme: SkotiqTheme.dark,
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

  group('FirstRunSetupScreen without admin access', () {
    Future<void> pumpScreen(WidgetTester tester, SkotiqBackend backend) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
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
    }

    testWidgets('says where to set the capture folder instead of failing', (
      tester,
    ) async {
      await pumpScreen(tester, _NoAdminBackend());

      expect(
        find.textContaining(
          'Set the capture folder on the imaging computer',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Save and continue'), findsNothing);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install and continue'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'Install catalogs on the imaging computer',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Token scope'), findsNothing);
    });
  });

  group('FirstRunSetupGate', () {
    Future<MobilePreferences> pumpGate(
      WidgetTester tester, {
      required SkotiqBackend backend,
      bool completedBefore = false,
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        if (completedBefore) 'mobile.firstRunCompleted': true,
      });
      final prefs = MobilePreferences(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mobilePreferencesProvider.overrideWith((ref) async => prefs),
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(ref, backend),
            ),
          ],
          child: FirstRunSetupGate(
            frame: (home) => MaterialApp(theme: SkotiqTheme.dark, home: home),
            child: const MaterialApp(home: Text('the shell')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return prefs;
    }

    testWidgets('a new phone on an unconfigured rig sees setup once', (
      tester,
    ) async {
      final prefs = await pumpGate(tester, backend: _SetupBackend());

      expect(find.text('Set up your rig'), findsOneWidget);
      expect(find.text('the shell'), findsNothing);

      await tester.tap(find.widgetWithText(SkotiqButton, 'Skip'));
      await tester.pumpAndSettle();

      expect(find.text('the shell'), findsOneWidget);
      expect(prefs.firstRunCompleted, isTrue);
    });

    testWidgets('a rig that needs nothing opens the app and ends setup', (
      tester,
    ) async {
      final prefs = await pumpGate(
        tester,
        backend: _SetupBackend(
          imageOutputPath: '/srv/captures',
          profiles: const [EquipmentProfile(id: 'p', name: 'Observatory')],
          catalogInstalled: true,
        ),
      );

      expect(find.text('the shell'), findsOneWidget);
      expect(prefs.firstRunCompleted, isTrue);
    });

    testWidgets('a phone that finished setup goes straight to the app', (
      tester,
    ) async {
      final backend = _SetupBackend();
      await pumpGate(tester, backend: backend, completedBefore: true);

      expect(find.text('the shell'), findsOneWidget);
      expect(backend.checks, 0);
    });

    testWidgets('without a linked rig the app opens and setup stays due', (
      tester,
    ) async {
      final prefs = await pumpGate(tester, backend: DisconnectedBackend());

      expect(find.text('the shell'), findsOneWidget);
      expect(prefs.firstRunCompleted, isFalse);
    });
  });
}

class _SetupBackend extends NetworkBackend {
  _SetupBackend({
    this.imageOutputPath = '',
    this.profiles = const [],
    this.catalogInstalled = false,
  }) : super(serverHost: '127.0.0.1', autoConnectWebSocket: false);

  final String imageOutputPath;
  final List<EquipmentProfile> profiles;
  final bool catalogInstalled;
  int checks = 0;

  @override
  Future<AppSettings> getSettings() async {
    checks++;
    return AppSettings(imageOutputPath: imageOutputPath);
  }

  @override
  Future<List<EquipmentProfile>> getProfiles() async {
    checks++;
    return profiles;
  }

  @override
  Future<RemoteCatalogStatusResponse> getCatalogStatus() async {
    checks++;
    return RemoteCatalogStatusResponse.fromJson({
      'catalogs': [
        {'name': 'hyg', 'status': catalogInstalled ? 'installed' : 'missing'},
      ],
    });
  }

  @override
  Future<List<RemoteAvailableCatalog>> listAvailableCatalogs() async =>
      const [];
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

class _NoAdminBackend extends NetworkBackend {
  _NoAdminBackend()
    : super(serverHost: '127.0.0.1', autoConnectWebSocket: false);

  // What the transport throws for the host's scope-denial body.
  static SkotiqError get _refused => SkotiqError.fromString(
    'Access denied: Token scope is not permitted for this endpoint: this '
    'credential holds control on filesystem, and admin is required.',
  );

  @override
  Future<RemoteDirectoryListing> browseRemoteDirectories({String? path}) =>
      Future.error(_refused);

  @override
  Future<RemoteJob> downloadCatalog(String name) => Future.error(_refused);

  @override
  Future<List<RemoteAvailableCatalog>> listAvailableCatalogs() async => [
    RemoteAvailableCatalog.fromJson({
      'name': 'stars',
      'displayName': 'HYG Star Database',
      'description': 'Stars',
      'sizeBytes': 1000,
      'requiredForPlateSolve': true,
    }),
  ];

  @override
  Future<List<EquipmentProfile>> getProfiles() async => const [];
}
