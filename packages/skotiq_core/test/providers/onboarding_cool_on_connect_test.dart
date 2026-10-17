// The wizard's cooling answer has to reach the profile it creates.
//
// Live finding: onboarding collected "Regulated cooling" plus a −10 °C
// set-point, and the profile it wrote had cool_on_connect = 0 with no way to
// say otherwise. Every connect left the sensor at ambient
// ("[CameraTemperaturePoller] Camera temp: 20.0C, power: 0%, target: -10.0C")
// until the operator found the same checkbox again in
// Equipment > Edit Profile > Camera Defaults.
//
// Cool-on-connect stays OPT-IN — a rig set up at noon must not pin the TEC at
// full power for the afternoon — but the wizard now asks, and the answer is
// what gets persisted.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;

/// The profile-activation write-through POSTs to the imaging host; with no
/// host connected the default backend throws. Same fake the sibling
/// onboarding provider test uses.
class _ProfileSettingsBackendFake implements ProfileSettingsBackend {
  @override
  Future<void> loadProfile(String id) async {}

  @override
  Future<void> saveProfile(remote_profile.EquipmentProfile profile) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  Future<OnboardingNotifier> draftWithCamera() async {
    final notifier = container.read(onboardingDraftProvider.notifier);
    await notifier.loaded;
    await notifier.setCamera(
      id: 'native:zwo:0',
      name: 'ASI294MC Pro',
      pixelSizeMicrons: 4.63,
    );
    await notifier.setProfileName('Backyard rig');
    return notifier;
  }

  test(
    'the wizard answer "cool on connect" reaches the created profile',
    () async {
      final notifier = await draftWithCamera();
      await notifier.setCameraDefaults(coolingTempC: -10, coolOnConnect: true);

      final profileId = await notifier.complete();
      final profile = await container
          .read(equipmentProfilesDaoProvider)
          .getProfileById(profileId);

      expect(profile!.defaultCoolingTemp, -10);
      expect(
        profile.coolOnConnect,
        isTrue,
        reason: 'the operator asked for regulated cooling on connect',
      );
    },
  );

  test('a set-point alone never arms the cooler', () async {
    final notifier = await draftWithCamera();
    await notifier.setCameraDefaults(coolingTempC: -10);

    final profileId = await notifier.complete();
    final profile = await container
        .read(equipmentProfilesDaoProvider)
        .getProfileById(profileId);

    expect(profile!.defaultCoolingTemp, -10);
    expect(
      profile.coolOnConnect,
      isFalse,
      reason: 'auto-cooling stays opt-in — a noon setup must not run the TEC',
    );
  });

  test('turning regulated cooling back off disarms cool-on-connect', () async {
    final notifier = await draftWithCamera();
    await notifier.setCameraDefaults(coolingTempC: -10, coolOnConnect: true);
    // The step clears the set-point when the "Regulated cooling" switch goes
    // off; the promise that went with it must not survive.
    await notifier.setCameraDefaults(clearCoolingTempC: true);

    expect(container.read(onboardingDraftProvider).coolOnConnect, isFalse);

    final profileId = await notifier.complete();
    final profile = await container
        .read(equipmentProfilesDaoProvider)
        .getProfileById(profileId);

    expect(profile!.defaultCoolingTemp, isNull);
    expect(profile.coolOnConnect, isFalse);
  });
}
