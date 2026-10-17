// A filter-name typo must be caught while the rig is still in the garage.
//
// FilterInWheelRule only runs when a filter wheel is CONNECTED - which is
// never true while a sequence is being built in daylight. So "Ha" vs
// "H-alpha" survived the builder and failed mid-run at 2am.
// FilterInProfileRule checks the same names against the active equipment
// profile (the same list the Change Filter dropdown binds to) whenever no
// wheel is connected.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/sequence/rules/filter_rules.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';

class _StubFilterWheelNotifier extends FilterWheelStateNotifier {
  _StubFilterWheelNotifier(super.ref, FilterWheelState initial) {
    state = initial;
  }
}

ProviderContainer _container({
  required List<String>? profileFilters,
  FilterWheelState wheel = const FilterWheelState(),
}) {
  final container = ProviderContainer(
    overrides: [
      activeEquipmentProfileProvider.overrideWithValue(
        profileFilters == null
            ? null
            : EquipmentProfileModel(
                name: 'Test Rig',
                focalLength: 600,
                aperture: 80,
                filterNames: profileFilters,
              ),
      ),
      filterWheelStateProvider.overrideWith(
        (ref) => _StubFilterWheelNotifier(ref, wheel),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

T _withRef<T>(ProviderContainer container, T Function(Ref ref) body) {
  final probe = Provider<T>((ref) => body(ref));
  return container.read(probe);
}

Sequence _sequenceWith(List<SequenceNode> nodes) {
  final root = InstructionSetNode(id: 'root', name: 'Root');
  return Sequence.create(
    id: 'seq',
    name: 'test',
    nodes: {
      for (final n in nodes) n.id: n.copyWith(parentId: root.id),
      root.id: root.copyWith(childIds: [for (final n in nodes) n.id]),
    },
    rootNodeId: root.id,
  );
}

List<ValidationIssue> _run(ProviderContainer container, Sequence sequence) =>
    _withRef(
      container,
      (ref) => FilterInProfileRule().validate(sequence, ValidationContext(ref)),
    );

void main() {
  test('a filter change naming a filter the profile lacks warns', () {
    final container = _container(profileFilters: const ['L', 'H-alpha']);
    final issues = _run(
      container,
      _sequenceWith([
        FilterChangeNode(id: 'fc', name: 'Change Filter', filterName: 'Ha'),
      ]),
    );

    expect(issues, hasLength(1));
    expect(issues.single.title, 'Filter Not in Profile');
    expect(issues.single.severity, ValidationSeverity.warning);
    expect(issues.single.affectedNodeId, 'fc');
    expect(issues.single.description, contains('H-alpha'));
  });

  test('an exposure naming a filter the profile lacks warns', () {
    final container = _container(profileFilters: const ['L', 'R', 'G', 'B']);
    final issues = _run(
      container,
      _sequenceWith([
        ExposureNode(
          id: 'ex',
          name: 'Lights',
          durationSecs: 120,
          filter: 'Lum',
        ),
      ]),
    );

    expect(issues, hasLength(1));
    expect(issues.single.affectedNodeId, 'ex');
  });

  test('a name that matches the profile (any case) is silent', () {
    final container = _container(profileFilters: const ['L', 'H-alpha']);
    final issues = _run(
      container,
      _sequenceWith([
        FilterChangeNode(
          id: 'fc',
          name: 'Change Filter',
          filterName: 'h-ALPHA',
        ),
        ExposureNode(id: 'ex', name: 'Lights', durationSecs: 120, filter: 'L'),
      ]),
    );

    expect(issues, isEmpty);
  });

  test('a profile with no filters cannot cry wolf', () {
    final container = _container(profileFilters: const []);
    final issues = _run(
      container,
      _sequenceWith([
        FilterChangeNode(id: 'fc', name: 'Change Filter', filterName: 'Ha'),
      ]),
    );

    expect(issues, isEmpty);
  });

  test('no active profile at all is silent', () {
    final container = _container(profileFilters: null);
    final issues = _run(
      container,
      _sequenceWith([
        FilterChangeNode(id: 'fc', name: 'Change Filter', filterName: 'Ha'),
      ]),
    );

    expect(issues, isEmpty);
  });

  test('a connected wheel hands the check back to FilterInWheelRule', () {
    final container = _container(
      profileFilters: const ['L', 'H-alpha'],
      wheel: const FilterWheelState(
        connectionState: DeviceConnectionState.connected,
        deviceName: 'Wheel',
        filterNames: ['L', 'Ha'],
      ),
    );
    final issues = _run(
      container,
      _sequenceWith([
        FilterChangeNode(id: 'fc', name: 'Change Filter', filterName: 'Ha'),
      ]),
    );

    // The wheel really carries "Ha"; the stale profile must not override it.
    expect(issues, isEmpty);
  });

  test('a disabled node is not warned about', () {
    final container = _container(profileFilters: const ['L']);
    final issues = _run(
      container,
      _sequenceWith([
        FilterChangeNode(
          id: 'fc',
          name: 'Change Filter',
          filterName: 'Ha',
          isEnabled: false,
        ),
      ]),
    );

    expect(issues, isEmpty);
  });
}
