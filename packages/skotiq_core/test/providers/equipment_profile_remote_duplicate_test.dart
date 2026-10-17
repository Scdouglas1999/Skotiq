import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;

/// Coverage for the REMOTE (slave -> host) profile duplication path in
/// [EquipmentProfilesNotifier.duplicateProfile].
///
/// `source.copyWith(id: null, name: newName, isActive: false)` cannot express
/// this: `copyWith`'s `id ?? this.id` semantics keep the SOURCE id, so the
/// outbound `saveProfile` carries it and the host UPDATES/renames the source
/// instead of creating a copy, with `isDefault` untouched. The duplicate is a
/// genuine insertion copy ([EquipmentProfileModel.toInsertionCopy]) with the id
/// CLEARED, active/default false, a new name, and every other field
/// preserved.
class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(
      const remote_profile.EquipmentProfile(id: '0', name: 'fallback'),
    );
  });

  test('remote duplicate creates a NEW host row (id absent), leaves the source '
      'untouched, and preserves every device/optics/metadata field', () async {
    // A rich source profile carrying every slot + label and a meridian-flip
    // override, active AND default, so the copy can be shown not to inherit
    // those flags.
    const source = remote_profile.EquipmentProfile(
      id: '5',
      name: 'Observatory rig',
      description: 'main scope',
      cameraId: 'ascom:camera:1',
      cameraName: 'ASI2600',
      mountId: 'ascom:mount:1',
      safetyMonitorId: 'ascom:safety:1',
      safetyMonitorName: 'CloudWatcher',
      switchId: 'ascom:switch:1',
      switchName: 'Pegasus UPB',
      coverCalibratorId: 'ascom:flat:1',
      focalLength: 530.0,
      aperture: 106.0,
      focalRatio: 5.0,
      defaultGain: 100,
      defaultOffset: 30,
      defaultBinX: 2,
      defaultBinY: 2,
      defaultCoolingTemp: -10.0,
      coolOnConnect: true,
      defaultCenteringExposure: 3.5,
      filterNames: '["L","R","G","B"]',
      meridianFlipOverrides: '{"minutesAfter":5}',
      isActive: true,
      isDefault: true,
    );

    // Mutable host-side store the fake NetworkBackend reads/writes.
    // A same-name older copy proves identity comes from the host's returned id,
    // not from the first row whose display name happens to match.
    final stored = <remote_profile.EquipmentProfile>[
      source,
      const remote_profile.EquipmentProfile(
        id: '8',
        name: 'Observatory rig (copy)',
      ),
    ];
    final saved = <remote_profile.EquipmentProfile>[];

    final backend = _MockNetworkBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.getProfiles()).thenAnswer((_) async => List.of(stored));
    when(() => backend.getActiveProfile()).thenAnswer((_) async {
      for (final p in stored) {
        if (p.isActive) return p;
      }
      return null;
    });
    when(() => backend.lastSavedProfileId).thenReturn('100');
    when(() => backend.saveProfile(any())).thenAnswer((invocation) async {
      final p =
          invocation.positionalArguments.first
              as remote_profile.EquipmentProfile;
      saved.add(p);
      // Host semantics: an absent/blank id is a CREATE — mint a fresh host id.
      if (int.tryParse(p.id) == null) {
        stored.add(p.copyWith(id: '100'));
      } else {
        // An id present is an UPDATE of that row — the case under guard.
        // Reflect it so the corruption of the source is visible.
        final idx = stored.indexWhere((e) => e.id == p.id);
        if (idx != -1) stored[idx] = p;
      }
    });

    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final newId = await container
        .read(equipmentProfilesProvider.notifier)
        .duplicateProfile(5, 'Observatory rig (copy)');

    // Exactly one outbound save, and it is genuinely a CREATE.
    expect(saved, hasLength(1));
    final outbound = saved.single;
    expect(outbound.id, isEmpty); // id genuinely absent, not the source id '5'
    expect(int.tryParse(outbound.id), isNull);
    expect(outbound.name, 'Observatory rig (copy)');
    expect(outbound.isActive, isFalse);
    expect(outbound.isDefault, isFalse);

    // Every device slot + friendly label + metadata field survived the copy.
    expect(outbound.cameraId, 'ascom:camera:1');
    expect(outbound.cameraName, 'ASI2600');
    expect(outbound.mountId, 'ascom:mount:1');
    expect(outbound.safetyMonitorId, 'ascom:safety:1');
    expect(outbound.safetyMonitorName, 'CloudWatcher');
    expect(outbound.switchId, 'ascom:switch:1');
    expect(outbound.switchName, 'Pegasus UPB');
    expect(outbound.coverCalibratorId, 'ascom:flat:1');
    expect(outbound.focalLength, 530.0);
    expect(outbound.aperture, 106.0);
    expect(outbound.focalRatio, 5.0);
    expect(outbound.defaultGain, 100);
    expect(outbound.defaultOffset, 30);
    expect(outbound.defaultBinX, 2);
    expect(outbound.defaultBinY, 2);
    expect(outbound.defaultCoolingTemp, -10.0);
    expect(outbound.coolOnConnect, isTrue);
    expect(outbound.defaultCenteringExposure, 3.5);
    expect(outbound.filterNames, '["L","R","G","B"]');
    expect(outbound.meridianFlipOverrides, '{"minutesAfter":5}');

    // The resolved return id is the NEW host row (100), not the source (5).
    expect(newId, 100);

    // The source row is completely untouched: same id, name, and active/default
    // flags. Sending the source id would overwrite it.
    final sourceAfter = stored.firstWhere((p) => p.id == '5');
    expect(sourceAfter.name, 'Observatory rig');
    expect(sourceAfter.isActive, isTrue);
    expect(sourceAfter.isDefault, isTrue);
  });
}
