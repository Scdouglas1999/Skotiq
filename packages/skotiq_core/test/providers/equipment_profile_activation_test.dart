import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;

/// Coverage for the single, remote-aware profile-activation authority
/// ([EquipmentProfilesNotifier]).
///
/// Local activation must write through the notifier into the native
/// ProfileSettings backend as well as SQLite: a SQLite-only write leaves the
/// Rust executor resolving the previous profile while the UI reports the new
/// one. Remote (slave) mode defers to the host's load endpoint and must never
/// perform that slave-local native write.
class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// A DAO whose SQLite active-flag COMMIT (`setActiveProfile`) always fails,
/// leaving every other operation intact. Used to prove the strict transactional
/// activation's native-restore compensation. Profiles are created through a
/// separate plain DAO on the same db so setup is unaffected.
class _ThrowingCommitDao extends EquipmentProfilesDao {
  _ThrowingCommitDao(super.db);

  @override
  Future<void> setActiveProfile(int profileId) async {
    throw Exception('sqlite commit failed');
  }
}

/// No-op logger so the strict path's ERROR logs never reach the native logging
/// bridge (unavailable in a pure Dart unit test).
class _SilentLogger extends LoggingService {
  @override
  void debug(String message, {String? source, Map<String, Object?>? fields}) {}
  @override
  void info(String message, {String? source, Map<String, Object?>? fields}) {}
  @override
  void warning(
    String message, {
    String? source,
    Map<String, Object?>? fields,
  }) {}
  @override
  void error(String message, {String? source, Map<String, Object?>? fields}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
    registerFallbackValue(
      const remote_profile.EquipmentProfile(id: '0', name: 'fallback'),
    );
  });

  late SkotiqDatabase db;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  for (final entry in ['profile editor', 'optics service']) {
    for (final active in [true, false]) {
      test(
        'optics edits through $entry sync only active profiles (active=$active)',
        () async {
          final backend = _MockFfiBackend();
          when(
            () => backend.eventStream,
          ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
          when(() => backend.saveProfile(any())).thenAnswer((_) async {});
          when(() => backend.loadProfile(any())).thenAnswer((_) async {});
          final container = ProviderContainer(
            overrides: [
              databaseProvider.overrideWithValue(db),
              backendProvider.overrideWith(
                (ref) => _FixedBackendNotifier(ref, backend),
              ),
            ],
          );
          addTearDown(container.dispose);
          final dao = container.read(equipmentProfilesDaoProvider);
          if (!active) {
            await dao.createProfile(
              const EquipmentProfileModel(name: 'Current').toCompanion(),
            );
          }
          final id = await dao.createProfile(
            const EquipmentProfileModel(name: 'Imaging').toCompanion(),
          );
          await container.read(equipmentProfilesProvider.future);
          if (entry == 'profile editor') {
            final row = await dao.getProfileById(id);
            await container
                .read(equipmentProfilesProvider.notifier)
                .updateProfile(
                  EquipmentProfileModel.fromDatabase(
                    row!,
                  ).copyWith(focalLength: 1000),
                );
          } else {
            await container
                .read(profileServiceProvider)
                .updateProfileOptics(id, focalLength: 1000);
          }
          expect((await dao.getProfileById(id))!.focalLength, 1000);
          if (active) {
            final saved =
                verify(() => backend.saveProfile(captureAny())).captured.single
                    as remote_profile.EquipmentProfile;
            expect(saved.focalLength, 1000);
            verify(() => backend.loadProfile(id.toString())).called(1);
          } else {
            verifyNever(() => backend.saveProfile(any()));
            verifyNever(() => backend.loadProfile(any()));
            expect((await dao.getActiveProfile())!.id, isNot(id));
          }
        },
      );
    }
  }

  test('local setActiveProfile write-throughs the new active row to the native '
      'backend (save + load) before SQLite flips', () async {
    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.saveProfile(any())).thenAnswer((_) async {});
    when(() => backend.loadProfile(any())).thenAnswer((_) async {});

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final dao = container.read(equipmentProfilesDaoProvider);
    final aId = await dao.createProfile(
      const EquipmentProfileModel(name: 'A').toCompanion(),
    );
    final bId = await dao.createProfile(
      const EquipmentProfileModel(name: 'B').toCompanion(),
    );

    // Precondition: A is active (first profile auto-activates), B is not.
    expect((await dao.getProfileById(aId))!.isActive, isTrue);
    expect((await dao.getProfileById(bId))!.isActive, isFalse);

    await container
        .read(equipmentProfilesProvider.notifier)
        .setActiveProfile(bId);

    // SQLite flipped: B active, A inactive, default (A) untouched.
    expect((await dao.getProfileById(bId))!.isActive, isTrue);
    expect((await dao.getProfileById(aId))!.isActive, isFalse);
    expect((await dao.getProfileById(aId))!.isDefault, isTrue);

    // Native executor store received the new active row: save THEN load,
    // once each, both carrying B's id.
    final ordered = verifyInOrder([
      () => backend.saveProfile(captureAny()),
      () => backend.loadProfile(captureAny()),
    ]);
    final savedProfile =
        ordered[0].captured.single as remote_profile.EquipmentProfile;
    expect(savedProfile.id, bId.toString());
    expect(ordered[1].captured.single, bId.toString());
  });

  test('remote setActiveProfile calls the host load endpoint once and never '
      'touches local SQLite or the native backend', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.loadProfile(any())).thenAnswer((_) async {});

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(equipmentProfilesProvider.notifier)
        .setActiveProfile(7);

    // Host owns activation via its load endpoint, exactly once.
    verify(() => backend.loadProfile('7')).called(1);

    // No slave-local native write-through: the ProfileSettings mirror
    // (saveProfile) must NEVER fire on a NetworkBackend.
    verifyNever(() => backend.saveProfile(any()));

    // Local SQLite is untouched on the slave (no rows created/activated).
    final dao = container.read(equipmentProfilesDaoProvider);
    expect(await dao.getActiveProfile(), isNull);
    expect(await dao.getAllProfiles(), isEmpty);
  });

  test('local setDefaultProfile(makeActive:true) syncs native state; '
      'makeActive:false changes only the default and does not', () async {
    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.saveProfile(any())).thenAnswer((_) async {});
    when(() => backend.loadProfile(any())).thenAnswer((_) async {});

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final dao = container.read(equipmentProfilesDaoProvider);
    final aId = await dao.createProfile(
      const EquipmentProfileModel(name: 'A').toCompanion(),
    );
    final bId = await dao.createProfile(
      const EquipmentProfileModel(name: 'B').toCompanion(),
    );
    final notifier = container.read(equipmentProfilesProvider.notifier);

    // makeActive:true -> B becomes default AND active; native mirror fires.
    await notifier.setDefaultProfile(bId, makeActive: true);
    expect((await dao.getProfileById(bId))!.isActive, isTrue);
    expect((await dao.getProfileById(bId))!.isDefault, isTrue);

    final ordered = verifyInOrder([
      () => backend.saveProfile(captureAny()),
      () => backend.loadProfile(captureAny()),
    ]);
    expect(
      (ordered[0].captured.single as remote_profile.EquipmentProfile).id,
      bId.toString(),
    );
    expect(ordered[1].captured.single, bId.toString());

    // Let the notifier rebuild before the next mutation — in real usage a
    // frame elapses between taps, so reading a provider through the notifier's
    // ref right after invalidateSelf() (still "outdated") never happens.
    await container.read(equipmentProfilesProvider.future);
    clearInteractions(backend);

    // makeActive:false -> A becomes the default only; the active profile
    // stays B; NO native mirror (default != active).
    await notifier.setDefaultProfile(aId, makeActive: false);
    expect((await dao.getProfileById(aId))!.isDefault, isTrue);
    expect((await dao.getProfileById(aId))!.isActive, isFalse);
    expect((await dao.getProfileById(bId))!.isActive, isTrue);

    verifyNever(() => backend.saveProfile(any()));
    verifyNever(() => backend.loadProfile(any()));
  });

  test(
    'ordinary interactive activation is transactional on native failure',
    () async {
      final backend = _MockFfiBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(
        () => backend.saveProfile(any()),
      ).thenThrow(Exception('native store unavailable'));
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          loggingServiceProvider.overrideWithValue(_SilentLogger()),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);
      final dao = container.read(equipmentProfilesDaoProvider);
      final aId = await dao.createProfile(
        const EquipmentProfileModel(name: 'A').toCompanion(),
      );
      final bId = await dao.createProfile(
        const EquipmentProfileModel(name: 'B').toCompanion(),
      );

      await expectLater(
        container
            .read(equipmentProfilesProvider.notifier)
            .setActiveProfile(bId),
        throwsA(isA<Exception>()),
      );

      expect((await dao.getProfileById(aId))!.isActive, isTrue);
      expect((await dao.getProfileById(bId))!.isActive, isFalse);
    },
  );

  test('default+active selection is transactional on native failure', () async {
    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(
      () => backend.saveProfile(any()),
    ).thenThrow(Exception('native store unavailable'));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        loggingServiceProvider.overrideWithValue(_SilentLogger()),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    final dao = container.read(equipmentProfilesDaoProvider);
    final aId = await dao.createProfile(
      const EquipmentProfileModel(name: 'A').toCompanion(),
    );
    final bId = await dao.createProfile(
      const EquipmentProfileModel(name: 'B').toCompanion(),
    );

    await expectLater(
      container
          .read(equipmentProfilesProvider.notifier)
          .setDefaultProfile(bId, makeActive: true),
      throwsA(isA<Exception>()),
    );

    expect((await dao.getProfileById(aId))!.isActive, isTrue);
    expect((await dao.getProfileById(aId))!.isDefault, isTrue);
    expect((await dao.getProfileById(bId))!.isActive, isFalse);
    expect((await dao.getProfileById(bId))!.isDefault, isFalse);
  });

  // Strict transactional activation (startup path).
  //
  // The invariant: SQLite must NEVER claim a profile active unless the native
  // executor store accepted it first, and a native/commit failure must never be
  // silently reported as success.

  ProviderContainer strictContainer(
    SkotiqBackend backend, {
    EquipmentProfilesDao? daoOverride,
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        loggingServiceProvider.overrideWithValue(_SilentLogger()),
        if (daoOverride != null)
          equipmentProfilesDaoProvider.overrideWithValue(daoOverride),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  _MockFfiBackend healthyFfi() {
    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.saveProfile(any())).thenAnswer((_) async {});
    when(() => backend.loadProfile(any())).thenAnswer((_) async {});
    return backend;
  }

  test('strict: native SAVE failure leaves the previous DB active/default '
      'unchanged and never loads', () async {
    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(
      () => backend.saveProfile(any()),
    ).thenThrow(Exception('native store offline'));
    when(() => backend.loadProfile(any())).thenAnswer((_) async {});

    final container = strictContainer(backend);
    final dao = container.read(equipmentProfilesDaoProvider);
    final aId = await dao.createProfile(
      const EquipmentProfileModel(name: 'A').toCompanion(),
    );
    final bId = await dao.createProfile(
      const EquipmentProfileModel(name: 'B').toCompanion(),
    );

    await expectLater(
      container
          .read(equipmentProfilesProvider.notifier)
          .setActiveProfileStrict(bId),
      throwsA(isA<Exception>()),
    );

    // SQLite untouched: A still active AND default, B still inactive.
    expect((await dao.getProfileById(aId))!.isActive, isTrue);
    expect((await dao.getProfileById(aId))!.isDefault, isTrue);
    expect((await dao.getProfileById(bId))!.isActive, isFalse);
    // load was never reached — save failed first.
    verifyNever(() => backend.loadProfile(any()));
  });

  test('strict: native LOAD failure leaves the previous DB active/default '
      'unchanged', () async {
    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.saveProfile(any())).thenAnswer((_) async {});
    when(
      () => backend.loadProfile(any()),
    ).thenThrow(Exception('native load failed'));

    final container = strictContainer(backend);
    final dao = container.read(equipmentProfilesDaoProvider);
    final aId = await dao.createProfile(
      const EquipmentProfileModel(name: 'A').toCompanion(),
    );
    final bId = await dao.createProfile(
      const EquipmentProfileModel(name: 'B').toCompanion(),
    );

    await expectLater(
      container
          .read(equipmentProfilesProvider.notifier)
          .setActiveProfileStrict(bId),
      throwsA(isA<Exception>()),
    );

    expect((await dao.getProfileById(aId))!.isActive, isTrue);
    expect((await dao.getProfileById(aId))!.isDefault, isTrue);
    expect((await dao.getProfileById(bId))!.isActive, isFalse);
  });

  test('strict: an invalid target errors with ZERO native writes and no DB '
      'change', () async {
    final backend = healthyFfi();
    final container = strictContainer(backend);
    final dao = container.read(equipmentProfilesDaoProvider);
    final aId = await dao.createProfile(
      const EquipmentProfileModel(name: 'A').toCompanion(),
    );

    // No profile 999 exists — strict mode treats a missing target as an error,
    // not a successful no-op.
    await expectLater(
      container
          .read(equipmentProfilesProvider.notifier)
          .setActiveProfileStrict(999),
      throwsA(isA<StateError>()),
    );

    // Nothing was written to the native store (so a caller connects nothing)...
    verifyNever(() => backend.saveProfile(any()));
    verifyNever(() => backend.loadProfile(any()));
    // ...and A is still the active/default profile.
    expect((await dao.getProfileById(aId))!.isActive, isTrue);
    expect((await dao.getProfileById(aId))!.isDefault, isTrue);
  });

  test('strict: a successful activation makes native AND DB target active, '
      'native FIRST (save then load)', () async {
    final backend = healthyFfi();
    final container = strictContainer(backend);
    final dao = container.read(equipmentProfilesDaoProvider);
    final aId = await dao.createProfile(
      const EquipmentProfileModel(name: 'A').toCompanion(),
    );
    final bId = await dao.createProfile(
      const EquipmentProfileModel(name: 'B').toCompanion(),
    );

    await container
        .read(equipmentProfilesProvider.notifier)
        .setActiveProfileStrict(bId);

    // Native received the target first, save THEN load, carrying B's id.
    final ordered = verifyInOrder([
      () => backend.saveProfile(captureAny()),
      () => backend.loadProfile(captureAny()),
    ]);
    expect(
      (ordered[0].captured.single as remote_profile.EquipmentProfile).id,
      bId.toString(),
    );
    expect(ordered[1].captured.single, bId.toString());

    // DB committed after native: B active, A inactive, A still default.
    expect((await dao.getProfileById(bId))!.isActive, isTrue);
    expect((await dao.getProfileById(aId))!.isActive, isFalse);
    expect((await dao.getProfileById(aId))!.isDefault, isTrue);
  });

  test('strict: a DB commit failure restores native to the previous active '
      'and rethrows the commit error (not a divergence)', () async {
    // Profiles are created through a plain DAO so first-profile activation is
    // not blocked by the throwing commit override.
    final setupDao = EquipmentProfilesDao(db);
    final aId = await setupDao.createProfile(
      const EquipmentProfileModel(name: 'A').toCompanion(),
    );
    final bId = await setupDao.createProfile(
      const EquipmentProfileModel(name: 'B').toCompanion(),
    );

    final backend = healthyFfi();
    final container = strictContainer(
      backend,
      daoOverride: _ThrowingCommitDao(db),
    );

    await expectLater(
      container
          .read(equipmentProfilesProvider.notifier)
          .setActiveProfileStrict(bId),
      // The ORIGINAL commit error, not a divergence — the restore succeeded.
      throwsA(
        allOf(isA<Exception>(), isNot(isA<ProfileActivationDivergenceError>())),
      ),
    );

    // Native store was driven to the target (B) and then restored to the
    // previous active (A).
    verify(() => backend.loadProfile(bId.toString())).called(1);
    verify(() => backend.loadProfile(aId.toString())).called(1);

    // SQLite untouched: A is still the committed active/default profile.
    expect((await setupDao.getProfileById(aId))!.isActive, isTrue);
    expect((await setupDao.getProfileById(aId))!.isDefault, isTrue);
    expect((await setupDao.getProfileById(bId))!.isActive, isFalse);
  });

  test('strict: a DB commit failure whose native restore ALSO fails surfaces a '
      'composite divergence error', () async {
    final setupDao = EquipmentProfilesDao(db);
    final aId = await setupDao.createProfile(
      const EquipmentProfileModel(name: 'A').toCompanion(),
    );
    final bId = await setupDao.createProfile(
      const EquipmentProfileModel(name: 'B').toCompanion(),
    );

    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.saveProfile(any())).thenAnswer((_) async {});
    // Target load (B) succeeds; the restore load (A) fails.
    when(() => backend.loadProfile(any())).thenAnswer((_) async {});
    when(
      () => backend.loadProfile(aId.toString()),
    ).thenThrow(Exception('native restore load failed'));

    final container = strictContainer(
      backend,
      daoOverride: _ThrowingCommitDao(db),
    );

    await expectLater(
      container
          .read(equipmentProfilesProvider.notifier)
          .setActiveProfileStrict(bId),
      throwsA(isA<ProfileActivationDivergenceError>()),
    );

    // SQLite still unchanged (the commit never landed).
    expect((await setupDao.getProfileById(aId))!.isActive, isTrue);
    expect((await setupDao.getProfileById(bId))!.isActive, isFalse);
  });
}
