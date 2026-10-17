// The onboarding driver step's answer has to survive the wizard.
//
// Step 2 ("Which drivers should we scan?") pre-checks Native, Alpaca and INDI;
// the user accepts, finds their camera over INDI and finishes the wizard. A
// draft `selectedDrivers` that steers only the wizard's own discovery passes
// dies with the draft, so Settings → Equipment → Connection then shows "Query
// INDI on startup" and "Query Alpaca on startup" both OFF — two screens asking
// the same question and giving opposite answers, with the one the user actually
// answered losing.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;

/// Local-mode profile activation still write-throughs to the native executor
/// store; with no backend that throws, so stand in a no-op writer.
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

  /// Minimum viable draft: the fields `complete()` needs to write a profile.
  Future<OnboardingNotifier> seedDraft(Set<DriverType> drivers) async {
    final notifier = container.read(onboardingDraftProvider.notifier);
    await notifier.loaded;
    // The draft hydrates with every non-simulator backend pre-selected, so
    // reach the requested set by toggling the difference rather than assuming
    // an empty start.
    final current = container.read(onboardingDraftProvider).selectedDrivers;
    for (final driver in {...current, ...drivers}) {
      if (current.contains(driver) != drivers.contains(driver)) {
        await notifier.toggleDriver(driver);
      }
    }
    expect(
      container.read(onboardingDraftProvider).selectedDrivers,
      drivers,
      reason: 'driver-step seeding failed; the rest of the test is meaningless',
    );
    await notifier.setCamera(id: 'indi:ccd', name: 'ASI533MC');
    await notifier.setOpticalTrain(
      focalLengthMm: 550,
      apertureMm: 125,
      pixelSizeMicrons: 3.76,
      reducerFactor: 1.0,
    );
    await notifier.setProfileName('Backyard rig');
    return notifier;
  }

  Future<({bool indi, bool alpaca})> storedFlags() async {
    final dao = container.read(settingsDaoProvider);
    return (
      indi: await dao.getSetting('indi_auto_connect') == 'true',
      alpaca: await dao.getSetting('alpaca_auto_discover') == 'true',
    );
  }

  test('the backends ticked in the wizard are queried at startup', () async {
    final notifier = await seedDraft({DriverType.native, DriverType.indi});
    await notifier.complete();

    final flags = await storedFlags();
    expect(flags.indi, isTrue, reason: 'INDI was ticked at the driver step');
    expect(flags.alpaca, isFalse, reason: 'Alpaca was not ticked');

    // And the settings surface the Connection screen reads agrees.
    container.invalidate(appSettingsProvider);
    final settings = await container.read(appSettingsProvider.future);
    expect(settings.indiAutoConnect, isTrue);
    expect(settings.alpacaAutoDiscover, isFalse);
  });

  test('unticking a backend turns its startup query back off', () async {
    // A user who inherited `true` (or ran the wizard twice) must be able to
    // take it away again — otherwise the wizard only ever adds.
    await container.read(settingsDaoProvider).setSettings({
      'indi_auto_connect': 'true',
    });

    final notifier = await seedDraft({DriverType.native, DriverType.alpaca});
    await notifier.complete();

    final flags = await storedFlags();
    expect(flags.indi, isFalse, reason: 'INDI was unticked at the driver step');
    expect(flags.alpaca, isTrue);
  });

  test('a draft with no driver answer leaves the toggles alone', () async {
    // Restored from a build before the driver step existed: there is no answer
    // to carry, and silently disabling both backends would be an answer the
    // user never gave.
    await container.read(settingsDaoProvider).setSettings({
      'indi_auto_connect': 'true',
      'alpaca_auto_discover': 'true',
    });

    final notifier = await seedDraft(const {});
    await notifier.complete();

    final flags = await storedFlags();
    expect(flags.indi, isTrue);
    expect(flags.alpaca, isTrue);
  });
}
