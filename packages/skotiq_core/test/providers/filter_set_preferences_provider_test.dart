import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

const _ownerWheel = ['L', 'R', 'G', 'B', 'Ha', 'SII', 'OIII', 'DARK'];
const _m1 = TargetSuggestion(
  targetId: 1,
  targetName: 'M1',
  catalogId: 'M1',
  raHours: 5.58,
  decDegrees: 22.01,
  objectType: 'Supernova Remnant',
  totalScore: 80,
  visibility: TargetVisibilityInfo(
    currentAltitude: 60,
    currentAzimuth: 90,
    airmass: 1.2,
    moonDistance: 90,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;
  late SettingsDao dao;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = SettingsDao(database);
  });

  tearDown(() => database.close());

  ProviderContainer containerFor(
    int profileId, {
    List<TargetSuggestion> tonight = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        tonightSuggestionsProvider.overrideWith((ref) async => tonight),
        databaseProvider.overrideWithValue(database),
        settingsDaoProvider.overrideWithValue(dao),
        activeEquipmentProfileProvider.overrideWithValue(
          EquipmentProfileModel(id: profileId, name: 'Rig $profileId'),
        ),
        smartNightExposureContextProvider.overrideWith((ref) async => null),
        effectiveFiltersProvider.overrideWithValue(_ownerWheel),
        targetFilterChoiceProvider.overrideWith(
          (ref, target) async => chooseSmartNightFilters(
            target: target,
            availableFilters: _ownerWheel,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a saved set and a target\'s choice are kept per profile and come '
      'back for the next plan', () async {
    final first = containerFor(7);
    final notifier = first.read(filterSetPreferencesProvider.notifier);
    await first.read(filterSetPreferencesProvider.future);
    await notifier.save(
      const CustomFilterSet(name: 'HaRGB', filters: ['Ha', 'R', 'G', 'B']),
    );
    final choice = chooseSmartNightFilters(
      target: _m1,
      availableFilters: _ownerWheel,
    );
    final mine = choice
        .sets(
          saved: first.read(filterSetPreferencesProvider).requireValue.custom,
        )
        .singleWhere((set) => set.isCustom);
    await notifier.choose(_m1, mine, recommended: choice.recommended);

    expect(await dao.getSetting('filter_sets.7'), isNotNull);

    final next = containerFor(7);
    final set = await next.read(targetFilterSetProvider(_m1).future);
    expect(set.key, 'custom:HaRGB');
    expect(set.filters, ['Ha', 'R', 'G', 'B']);

    final otherProfile = containerFor(8);
    expect(
      (await otherProfile.read(targetFilterSetProvider(_m1).future)).key,
      'narrowbandSho',
    );
  });

  test('a target with no choice follows the recommendation', () async {
    final container = containerFor(7);
    final set = await container.read(targetFilterSetProvider(_m1).future);
    expect(set.key, 'narrowbandSho');
    expect(set.filters, ['Ha', 'OIII', 'SII']);
  });

  test('a sequence step\'s target takes tonight\'s candidate of its name, '
      'else its library row', () async {
    await TargetsDao(database).createTarget(
      TargetsCompanion.insert(
        name: 'NGC7000',
        ra: 20.98,
        dec: 44.3,
        objectType: const Value('HII Region'),
      ),
    );
    final scoped = containerFor(7, tonight: const [_m1]);

    final m1 = await scoped.read(
      sequenceTargetSuggestionProvider((
        name: 'm1',
        raHours: 5.6,
        decDegrees: 22.0,
        libraryId: null,
      )).future,
    );
    expect(m1.objectType, 'Supernova Remnant');
    expect(m1.raHours, 5.6);

    final nebula = await scoped.read(
      sequenceTargetSuggestionProvider((
        name: 'NGC7000',
        raHours: 20.98,
        decDegrees: 44.3,
        libraryId: null,
      )).future,
    );
    expect(nebula.objectType, 'HII Region');
  });
}
