// The phone app is launched as a client of an imaging host, whether it is
// linked, not linked yet, or resting on its demo rig. A phone owns none of the
// host's features: it has no executor to configure, no rig to set up, and no
// capture folder on its own disk.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/providers/sequence/rules/settings_rules.dart';
import 'package:skotiq_core/src/settings/app_settings_state.g.dart';

class _PinnedBackend extends BackendNotifier {
  _PinnedBackend(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _FixedSettings extends AppSettingsNotifier {
  _FixedSettings(this._initial);
  final AppSettingsState _initial;
  @override
  Future<AppSettingsState> build() async => _initial;
}

SkotiqBackend _backendFor(HostPlace place) => switch (place) {
  HostPlace.none => DisconnectedBackend(),
  HostPlace.demo => DemoBackend(latitudeDeg: 40, longitudeDeg: -75),
  _ => throw ArgumentError(place),
};

ProviderContainer _phone(
  HostPlace place, {
  LaunchRole role = LaunchRole.mobile,
  List<Override> overrides = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      launchRoleProvider.overrideWithValue(role),
      backendProvider.overrideWith(
        (ref) => _PinnedBackend(ref, _backendFor(place)),
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

T _withRef<T>(ProviderContainer container, T Function(Ref ref) body) =>
    container.read(Provider<T>((ref) => body(ref)));

Sequence _oneExposure() {
  final root = InstructionSetNode(name: 'Root');
  final exposure = ExposureNode().copyWith(parentId: root.id);
  return Sequence.create(
    name: 'T',
    nodes: {
      root.id: root.copyWith(childIds: [exposure.id]),
      exposure.id: exposure,
    },
    rootNodeId: root.id,
  );
}

void main() {
  for (final place in [HostPlace.none, HostPlace.demo]) {
    group('a phone with ${place.name} for a host', () {
      test('is a client and owns no host features', () {
        final container = _phone(place);
        expect(container.read(isRemoteClientProvider), isTrue);
      });

      test('has no executor to send the run config to', () async {
        final container = _phone(place);
        await expectLater(
          container.read(runConfigSyncProvider).beginRun(onSendFailure: (_) {}),
          throwsA(isA<StateError>()),
        );
      });

      test('does not check a capture folder on its own disk', () async {
        final container = _phone(
          place,
          overrides: [
            appSettingsProvider.overrideWith(
              () => _FixedSettings(
                const AppSettingsState(
                  imageOutputPath: '/no/such/folder/on/this/phone',
                ),
              ),
            ),
          ],
        );
        await container.read(appSettingsProvider.future);
        final issues = _withRef(
          container,
          (ref) => ImageOutputPathRule().validate(
            _oneExposure(),
            ValidationContext(ref),
          ),
        );
        expect(issues, isEmpty);
      });
    });
  }

  test('the demo rig does not offer to set up a rig', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = _phone(
      HostPlace.demo,
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    expect(
      await container.read(shouldRunEquipmentOnboardingProvider.future),
      isFalse,
    );
  });

  test('a host window with the same backends still owns its features', () {
    final container = _phone(HostPlace.none, role: LaunchRole.hostGui);
    expect(container.read(isRemoteClientProvider), isFalse);
  });
}
