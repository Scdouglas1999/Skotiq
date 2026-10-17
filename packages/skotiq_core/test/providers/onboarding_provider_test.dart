import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;
import 'package:skotiq_core/src/models/settings/app_settings.dart'
    as remote_settings;

/// Mock NetworkBackend so we can exercise the remote (host-authoritative)
/// branch of [OnboardingNotifier.complete] without a live headless server.
class _MockNetworkBackend extends Mock implements NetworkBackend {}

/// Backend notifier seeded with a fixed backend so `backendProvider` resolves
/// to our mock — mirrors the wiring in `equipment_remote_parity_test.dart`.
class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void swap(SkotiqBackend backend) {
    state = backend;
  }
}

class _ProfileSettingsBackendFake implements ProfileSettingsBackend {
  @override
  Future<void> loadProfile(String id) async {}

  @override
  Future<void> saveProfile(remote_profile.EquipmentProfile profile) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// End-to-end provider test for the onboarding wizard.
///
/// We override `databaseProvider` to point at an in-memory Drift
/// instance so the equipment-profile and tutorial-progress writes hit a
/// real schema (no mocks), then drive the notifier through the full
/// happy path: pick devices, set optical-train, pick capture dir, save.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(
      const remote_profile.EquipmentProfile(id: '0', name: 'fallback'),
    );
    registerFallbackValue(const remote_settings.AppSettings());
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
  });

  late SkotiqDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        profileSettingsBackendProvider.overrideWithValue(
          _ProfileSettingsBackendFake(),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test(
    'shouldRunEquipmentOnboardingProvider returns true on fresh install',
    () async {
      final shouldRun = await container.read(
        shouldRunEquipmentOnboardingProvider.future,
      );
      expect(shouldRun, isTrue);
    },
  );

  test(
    'shouldRunEquipmentOnboardingProvider returns false once a profile exists',
    () async {
      // Insert a profile through the DAO so the bootstrap gate flips false
      // — mirrors what the rest of the codebase does when a user creates a
      // profile outside the wizard.
      final dao = container.read(equipmentProfilesDaoProvider);
      await dao.createProfile(
        const EquipmentProfileModel(name: 'existing').toCompanion(),
      );

      // Invalidate so the future re-resolves against the new DB state.
      container.invalidate(shouldRunEquipmentOnboardingProvider);
      final shouldRun = await container.read(
        shouldRunEquipmentOnboardingProvider.future,
      );
      expect(shouldRun, isFalse);
    },
  );

  test(
    'equipment onboarding gate reloads when the imaging host changes',
    () async {
      final emptyHost = _MockNetworkBackend();
      final configuredHost = _MockNetworkBackend();
      when(() => emptyHost.getProfiles()).thenAnswer((_) async => const []);
      when(() => configuredHost.getProfiles()).thenAnswer(
        (_) async => const [
          remote_profile.EquipmentProfile(id: 'rig-b', name: 'Rig B'),
        ],
      );

      final hostContainer = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, emptyHost),
          ),
        ],
      );
      addTearDown(hostContainer.dispose);

      expect(
        await hostContainer.read(shouldRunEquipmentOnboardingProvider.future),
        isTrue,
      );

      final backend =
          hostContainer.read(backendProvider.notifier)
              as _SwappableBackendNotifier;
      backend.swap(configuredHost);

      expect(
        await hostContainer.read(shouldRunEquipmentOnboardingProvider.future),
        isFalse,
      );
      verify(() => emptyHost.getProfiles()).called(1);
      verify(() => configuredHost.getProfiles()).called(1);
    },
  );

  test(
    'OnboardingNotifier persists draft across reads via app_settings JSON',
    () async {
      final notifier = container.read(onboardingDraftProvider.notifier);
      await notifier.loaded;
      await notifier.setCamera(
        id: 'native:zwo:0',
        name: 'ASI294MC Pro',
        pixelSizeMicrons: 4.63,
      );
      await notifier.next();

      // Re-create the notifier from a fresh container backed by the same
      // database. The persisted JSON blob in app_settings should hydrate
      // the camera selection.
      final secondContainer = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      try {
        final loaded = secondContainer.read(onboardingDraftProvider.notifier);
        await loaded.loaded;
        final draft = secondContainer.read(onboardingDraftProvider);
        expect(draft.cameraId, 'native:zwo:0');
        expect(draft.pixelSizeMicrons, 4.63);
        expect(draft.currentStep, OnboardingStep.drivers);
      } finally {
        secondContainer.dispose();
      }
    },
  );

  test('complete() creates a profile (gain/offset/bin/cooling), persists '
      'capture dir, but does NOT yet mark the tutorial done', () async {
    final notifier = container.read(onboardingDraftProvider.notifier);
    await notifier.loaded;

    // Walk through enough of the wizard to have a valid draft.
    await notifier.toggleDriver(DriverType.native);
    await notifier.setCamera(
      id: 'native:zwo:0',
      name: 'ASI294MC Pro',
      pixelSizeMicrons: 4.63,
    );
    await notifier.setMount(id: 'ascom:EQMOD', name: 'EQ6-R');
    await notifier.setOpticalTrain(
      focalLengthMm: 1000,
      apertureMm: 80,
      pixelSizeMicrons: 4.63,
      reducerFactor: 1.0,
    );
    // Camera acquisition defaults captured at the camera-defaults step.
    await notifier.setCameraDefaults(
      gain: 120,
      offset: 30,
      binX: 2,
      binY: 2,
      coolingTempC: -10,
    );
    await notifier.setCaptureDirectory('C:/captures');
    await notifier.setProfileName('Backyard rig');

    final profileId = await notifier.complete();
    expect(profileId, isNonZero);

    // Equipment profile row exists with our values, including the camera
    // acquisition defaults threaded through from the draft.
    final dao = container.read(equipmentProfilesDaoProvider);
    final profile = await dao.getProfileById(profileId);
    expect(profile, isNotNull);
    expect(profile!.name, 'Backyard rig');
    expect(profile.cameraId, 'native:zwo:0');
    expect(profile.cameraName, 'ASI294MC Pro');
    expect(profile.mountId, 'ascom:EQMOD');
    expect(profile.focalLength, 1000);
    expect(profile.aperture, 80);
    expect(profile.defaultGain, 120);
    expect(profile.defaultOffset, 30);
    expect(profile.defaultBinX, 2);
    expect(profile.defaultBinY, 2);
    expect(profile.defaultCoolingTemp, -10);
    // Cool-on-connect is OFF by default even when a cooling set-point exists —
    // auto-cooling is opt-in so a daytime setup doesn't pin the TEC all day.
    // The set-point is still stored so enabling it later is a single toggle.
    expect(profile.coolOnConnect, isFalse);
    expect(profile.isActive, isTrue);
    expect(profile.isDefault, isTrue);

    // Default image directory persisted.
    final settingsDao = container.read(settingsDaoProvider);
    final captureDir = await settingsDao.getDefaultImageDirectory();
    expect(captureDir, 'C:/captures');

    // Tutorial progress is NOT yet completed — that waits for finishNextSteps.
    final tutorialDao = container.read(tutorialProgressDaoProvider);
    final progress = await tutorialDao.getProgress(
      OnboardingDraft.persistenceCategory,
    );
    expect(
      progress == null || (!progress.completed && !progress.dismissed),
      isTrue,
      reason: 'complete() must not retire onboarding before nextSteps',
    );

    // Draft blob is still present (not wiped until finishNextSteps).
    final draftRow = await settingsDao.getSetting(
      OnboardingDraft.draftSettingsKey,
    );
    expect(draftRow, isNotNull);
  });

  test(
    'complete() with an existing active/default profile activates the new rig '
    'without stealing the default',
    () async {
      // Seed a pre-existing profile the way a returning user would have one.
      // dao.createProfile marks the FIRST profile active + default.
      final dao = container.read(equipmentProfilesDaoProvider);
      final firstId = await dao.createProfile(
        const EquipmentProfileModel(name: 'Existing rig').toCompanion(),
      );
      final firstBefore = await dao.getProfileById(firstId);
      expect(firstBefore!.isActive, isTrue);
      expect(firstBefore.isDefault, isTrue);

      // Re-run onboarding to create a SECOND profile. dao.createProfile
      // auto-activates only the first profile, so the terminal screen must not
      // claim this one is active + ready unless activation happened.
      final notifier = container.read(onboardingDraftProvider.notifier);
      await notifier.loaded;
      await notifier.setProfileName('Second rig');
      final secondId = await notifier.complete();
      expect(secondId, isNot(firstId));

      final second = await dao.getProfileById(secondId);
      final first = await dao.getProfileById(firstId);

      // The freshly created rig is now active and the previous one is not, so
      // the "active & ready" screen is truthful.
      expect(
        second!.isActive,
        isTrue,
        reason: 'onboarding must activate the profile it just created',
      );
      expect(
        first!.isActive,
        isFalse,
        reason: 'the previously active profile must be deactivated',
      );

      // Activation must NOT silently change the default startup profile —
      // active and default stay distinct.
      expect(
        first.isDefault,
        isTrue,
        reason: 'default startup profile is distinct from active',
      );
      expect(second.isDefault, isFalse);
    },
  );

  test(
    'complete() threads telescopeName + leaves cooling null for a DSLR-style '
    'preset (no cool-on-connect)',
    () async {
      final notifier = container.read(onboardingDraftProvider.notifier);
      await notifier.loaded;

      await notifier.applyTelescopePreset(
        builtInTelescopePresets.firstWhere(
          (p) => p.id == 'tel.williamoptics.redcat51',
        ),
      );
      await notifier.applyCameraPreset(
        builtInCameraDefaultsPresets.firstWhere(
          (p) => p.id == 'cam.canon.eosra',
        ),
      );
      await notifier.setProfileName('Wide-field rig');

      final profileId = await notifier.complete();
      final dao = container.read(equipmentProfilesDaoProvider);
      final profile = await dao.getProfileById(profileId);
      expect(profile, isNotNull);
      expect(profile!.telescopeName, 'William Optics RedCat 51');
      expect(profile.focalLength, 250);
      expect(profile.aperture, 51);
      // The Canon EOS Ra preset has no regulated cooling.
      expect(profile.defaultCoolingTemp, isNull);
      expect(profile.coolOnConnect, isFalse);
      expect(profile.defaultGain, 0);
    },
  );

  test(
    'finishNextSteps marks completed, wipes the draft, and flips the gate',
    () async {
      final notifier = container.read(onboardingDraftProvider.notifier);
      await notifier.loaded;
      await notifier.setCamera(
        id: 'native:zwo:0',
        name: 'ASI294MC Pro',
        pixelSizeMicrons: 4.63,
      );
      await notifier.setProfileName('Backyard rig');
      await notifier.complete();

      // Profile exists -> the gate would already read false, so to prove
      // finishNextSteps is what flips it via tutorial_progress we assert the
      // progress + draft state directly.
      await notifier.finishNextSteps();

      final tutorialDao = container.read(tutorialProgressDaoProvider);
      final progress = await tutorialDao.getProgress(
        OnboardingDraft.persistenceCategory,
      );
      expect(progress, isNotNull);
      expect(progress!.completed, isTrue);

      final settingsDao = container.read(settingsDaoProvider);
      final draftRow = await settingsDao.getSetting(
        OnboardingDraft.draftSettingsKey,
      );
      expect(draftRow, isNull);

      container.invalidate(shouldRunEquipmentOnboardingProvider);
      final shouldRun = await container.read(
        shouldRunEquipmentOnboardingProvider.future,
      );
      expect(shouldRun, isFalse);
    },
  );

  test('finishNextSteps flips the gate to false even with no profile (tutorial '
      'completion alone)', () async {
    // A no-profile container so the gate is driven purely by tutorial_progress.
    final notifier = container.read(onboardingDraftProvider.notifier);
    await notifier.loaded;

    final before = await container.read(
      shouldRunEquipmentOnboardingProvider.future,
    );
    expect(before, isTrue);

    await notifier.finishNextSteps();

    container.invalidate(shouldRunEquipmentOnboardingProvider);
    final after = await container.read(
      shouldRunEquipmentOnboardingProvider.future,
    );
    expect(after, isFalse);
  });

  test('skip() marks tutorial dismissed and gates further launches', () async {
    final notifier = container.read(onboardingDraftProvider.notifier);
    await notifier.loaded;
    await notifier.skip();

    final tutorialDao = container.read(tutorialProgressDaoProvider);
    final progress = await tutorialDao.getProgress(
      OnboardingDraft.persistenceCategory,
    );
    expect(progress, isNotNull);
    expect(progress!.dismissed, isTrue);

    container.invalidate(shouldRunEquipmentOnboardingProvider);
    final shouldRun = await container.read(
      shouldRunEquipmentOnboardingProvider.future,
    );
    expect(shouldRun, isFalse);
  });

  test(
    'toggleDriver round-trips a driver in/out of the selection set',
    () async {
      final notifier = container.read(onboardingDraftProvider.notifier);
      await notifier.loaded;

      final initial = container.read(onboardingDraftProvider).selectedDrivers;
      final hadAscom = initial.contains(DriverType.ascom);

      await notifier.toggleDriver(DriverType.ascom);
      final afterFirst = container
          .read(onboardingDraftProvider)
          .selectedDrivers;
      expect(afterFirst.contains(DriverType.ascom), !hadAscom);

      await notifier.toggleDriver(DriverType.ascom);
      final afterSecond = container
          .read(onboardingDraftProvider)
          .selectedDrivers;
      expect(afterSecond.contains(DriverType.ascom), hadAscom);
    },
  );

  test('back/next stay within step bounds', () async {
    final notifier = container.read(onboardingDraftProvider.notifier);
    await notifier.loaded;

    // Back on welcome is a no-op
    await notifier.back();
    expect(
      container.read(onboardingDraftProvider).currentStep,
      OnboardingStep.welcome,
    );

    await notifier.next();
    expect(
      container.read(onboardingDraftProvider).currentStep,
      OnboardingStep.drivers,
    );

    await notifier.back();
    expect(
      container.read(onboardingDraftProvider).currentStep,
      OnboardingStep.welcome,
    );

    // Walk to the last step and verify next is a no-op there. The terminal
    // step is now `nextSteps` (summary is followed by the what's-next screen).
    for (var i = 0; i < OnboardingStep.values.length - 1; i++) {
      await notifier.next();
    }
    expect(
      container.read(onboardingDraftProvider).currentStep,
      OnboardingStep.nextSteps,
    );
    await notifier.next();
    expect(
      container.read(onboardingDraftProvider).currentStep,
      OnboardingStep.nextSteps,
    );
  });

  test(
    'cameraDefaults is optional; nextSteps is the non-skippable terminal',
    () {
      expect(OnboardingStep.cameraDefaults.isOptional, isTrue);
      expect(OnboardingStep.nextSteps.isOptional, isFalse);
      // Ordering contract: cameraDefaults sits between opticalTrain and
      // captureDir; nextSteps is last.
      expect(
        OnboardingStep.cameraDefaults.order,
        greaterThan(OnboardingStep.opticalTrain.order),
      );
      expect(
        OnboardingStep.cameraDefaults.order,
        lessThan(OnboardingStep.captureDir.order),
      );
      expect(OnboardingStep.nextSteps.order, OnboardingStep.values.length - 1);
      expect(
        OnboardingStep.nextSteps.order,
        greaterThan(OnboardingStep.summary.order),
      );
    },
  );

  test(
    'applyTelescopePreset / applyCameraPreset populate the draft and persist',
    () async {
      final notifier = container.read(onboardingDraftProvider.notifier);
      await notifier.loaded;

      final scope = builtInTelescopePresets.firstWhere(
        (p) => p.id == 'tel.skywatcher.esprit100ed',
      );
      await notifier.applyTelescopePreset(scope);
      final cam = builtInCameraDefaultsPresets.firstWhere(
        (p) => p.id == 'cam.zwo.asi294mc',
      );
      await notifier.applyCameraPreset(cam);

      final draft = container.read(onboardingDraftProvider);
      expect(draft.telescopePresetId, scope.id);
      expect(draft.telescopeName, 'Sky-Watcher Esprit 100ED');
      expect(draft.focalLengthMm, 550);
      expect(draft.apertureMm, 100);

      expect(draft.cameraPresetId, cam.id);
      expect(draft.pixelSizeMicrons, 4.63);
      expect(draft.defaultGain, 120);
      expect(draft.defaultOffset, 30);
      expect(draft.defaultBinX, 1);
      expect(draft.defaultBinY, 1);
      expect(draft.defaultCoolingTempC, -10);

      // Persisted: a fresh notifier over the same DB hydrates the same picks.
      final secondContainer = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      try {
        final reloaded = secondContainer.read(onboardingDraftProvider.notifier);
        await reloaded.loaded;
        final restored = secondContainer.read(onboardingDraftProvider);
        expect(restored.telescopePresetId, scope.id);
        expect(restored.cameraPresetId, cam.id);
        expect(restored.defaultGain, 120);
        expect(restored.defaultCoolingTempC, -10);
        expect(restored.focalLengthMm, 550);
      } finally {
        secondContainer.dispose();
      }
    },
  );

  test(
    'applyCameraPreset clears the cooling set-point for a DSLR preset',
    () async {
      final notifier = container.read(onboardingDraftProvider.notifier);
      await notifier.loaded;

      // Seed a cooled-CMOS preset first so cooling is non-null...
      await notifier.applyCameraPreset(
        builtInCameraDefaultsPresets.firstWhere(
          (p) => p.id == 'cam.zwo.asi294mc',
        ),
      );
      expect(container.read(onboardingDraftProvider).defaultCoolingTempC, -10);

      // ...then apply the DSLR preset, which must null the cooling set-point
      // rather than leaving the stale -10.
      await notifier.applyCameraPreset(
        builtInCameraDefaultsPresets.firstWhere(
          (p) => p.id == 'cam.canon.eosra',
        ),
      );
      expect(
        container.read(onboardingDraftProvider).defaultCoolingTempC,
        isNull,
      );
    },
  );

  test('OnboardingDraft JSON round-trip preserves the new fields', () {
    const draft = OnboardingDraft(
      currentStep: OnboardingStep.cameraDefaults,
      telescopePresetId: 'tel.askar.fra400',
      telescopeName: 'Askar FRA400',
      cameraPresetId: 'cam.zwo.asi2600mm',
      pixelSizeMicrons: 3.76,
      focalLengthMm: 400,
      apertureMm: 72,
      defaultGain: 100,
      defaultOffset: 50,
      defaultBinX: 1,
      defaultBinY: 1,
      defaultCoolingTempC: -10,
    );

    final restored = OnboardingDraft.fromJsonStringOrEmpty(
      draft.toJsonString(),
    );
    expect(restored, draft);
    expect(restored.hashCode, draft.hashCode);
    expect(restored.currentStep, OnboardingStep.cameraDefaults);
    expect(restored.telescopePresetId, 'tel.askar.fra400');
    expect(restored.telescopeName, 'Askar FRA400');
    expect(restored.cameraPresetId, 'cam.zwo.asi2600mm');
    expect(restored.defaultGain, 100);
    expect(restored.defaultOffset, 50);
    expect(restored.defaultBinX, 1);
    expect(restored.defaultBinY, 1);
    expect(restored.defaultCoolingTempC, -10);
  });

  test(
    'complete() on a NetworkBackend resolves the host-created profile id',
    () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(() => backend.saveProfile(any())).thenAnswer((_) async {});
      when(() => backend.lastSavedProfileId).thenReturn('42');
      when(() => backend.loadProfile(any())).thenAnswer((_) async {});
      when(
        () => backend.getSettings(),
      ).thenAnswer((_) async => const remote_settings.AppSettings());
      when(() => backend.updateSettings(any())).thenAnswer((_) async {});
      // A same-name row already exists. Completion must use the id returned by
      // POST /profiles, never rediscover the row by its non-unique name.
      when(() => backend.getProfiles()).thenAnswer(
        (_) async => const [
          remote_profile.EquipmentProfile(id: '7', name: 'Remote rig'),
          remote_profile.EquipmentProfile(id: '42', name: 'Remote rig'),
        ],
      );

      final remoteContainer = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      try {
        final notifier = remoteContainer.read(onboardingDraftProvider.notifier);
        await notifier.loaded;
        await notifier.setCamera(
          id: 'native:zwo:0',
          name: 'ASI294MC Pro',
          pixelSizeMicrons: 4.63,
        );
        await notifier.setProfileName('Remote rig');
        await notifier.setCaptureDirectory('/srv/skotiq/captures');

        final id = await notifier.complete();
        expect(id, 42);
        verify(() => backend.saveProfile(any())).called(1);
        verify(() => backend.loadProfile('42')).called(1);
        // `.single`: the capture directory and the driver step's backend
        // choice go up in ONE read-modify-write, so a second round trip cannot
        // race the first and drop whichever field it did not carry.
        final settings =
            verify(() => backend.updateSettings(captureAny())).captured.single
                as remote_settings.AppSettings;
        expect(settings.imageOutputPath, '/srv/skotiq/captures');
        // Driver-step defaults (everything but the simulator) reach the host's
        // startup-discovery flags instead of dying with the draft.
        expect(settings.indiAutoConnect, isTrue);
        expect(settings.alpacaAutoDiscover, isTrue);
      } finally {
        remoteContainer.dispose();
      }
    },
  );

  test(
    'complete() never continues onboarding writes on a replacement host',
    () async {
      final firstHost = _MockNetworkBackend();
      final replacementHost = _MockNetworkBackend();
      final saveProfile = Completer<void>();
      when(
        () => firstHost.saveProfile(any()),
      ).thenAnswer((_) => saveProfile.future);
      when(() => firstHost.lastSavedProfileId).thenReturn('71');
      late _SwappableBackendNotifier backendNotifier;

      final remoteContainer = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith((ref) {
            backendNotifier = _SwappableBackendNotifier(ref, firstHost);
            return backendNotifier;
          }),
        ],
      );
      addTearDown(remoteContainer.dispose);

      final notifier = remoteContainer.read(onboardingDraftProvider.notifier);
      await notifier.loaded;
      await notifier.setProfileName('Host A rig');
      await notifier.setCaptureDirectory('/host-a/captures');

      final completion = notifier.complete();
      await untilCalled(() => firstHost.saveProfile(any()));
      backendNotifier.swap(replacementHost);
      saveProfile.complete();

      await expectLater(
        completion,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('imaging host changed'),
          ),
        ),
      );
      verifyNever(() => firstHost.loadProfile(any()));
      verifyNever(() => firstHost.getSettings());
      verifyNever(() => replacementHost.saveProfile(any()));
      verifyNever(() => replacementHost.loadProfile(any()));
      verifyNever(() => replacementHost.getSettings());
      verifyNever(() => replacementHost.updateSettings(any()));
    },
  );
}
