import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

class _StubFilterWheel extends FilterWheelStateNotifier {
  _StubFilterWheel(super.ref, FilterWheelState initial) {
    state = initial;
  }
}

List<String> _filters({
  required FilterWheelState wheel,
  List<String>? profileFilters,
}) {
  final container = ProviderContainer(
    overrides: [
      activeEquipmentProfileProvider.overrideWithValue(
        profileFilters == null
            ? null
            : EquipmentProfileModel(name: 'Rig', filterNames: profileFilters),
      ),
      filterWheelStateProvider.overrideWith(
        (ref) => _StubFilterWheel(ref, wheel),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container.read(effectiveFiltersProvider);
}

void main() {
  group('effectiveFiltersProvider', () {
    test('a connected wheel\'s slots win over the profile', () {
      expect(
        _filters(
          wheel: const FilterWheelState(
            connectionState: DeviceConnectionState.connected,
            filterNames: ['L', 'R', 'G', 'B', 'Ha'],
          ),
          profileFilters: const ['L', 'R', 'G'],
        ),
        ['L', 'R', 'G', 'B', 'Ha'],
      );
    });

    test('a connected wheel serves a rig whose profile names none', () {
      expect(
        _filters(
          wheel: const FilterWheelState(
            connectionState: DeviceConnectionState.connected,
            filterNames: ['R', 'G', 'B'],
          ),
        ),
        ['R', 'G', 'B'],
      );
    });

    test('without a connected wheel the profile is the list', () {
      expect(
        _filters(
          wheel: const FilterWheelState(filterNames: ['Stale']),
          profileFilters: const ['Ha', 'OIII'],
        ),
        ['Ha', 'OIII'],
      );
    });

    test('nothing to pick without a wheel or profile filters', () {
      expect(_filters(wheel: const FilterWheelState()), isEmpty);
    });
  });

  group('resolveEffectiveFilterNames', () {
    test('prefers profile names when wheel reports generic slots', () {
      expect(
        resolveEffectiveFilterNames(
          wheelNames: const ['Filter 1', 'Filter 2', 'Filter 3', 'Filter 4'],
          profileNames: const ['L', 'R', 'G', 'B'],
        ),
        equals(['L', 'R', 'G', 'B']),
      );
    });

    test('keeps wheel names when both sides are generic', () {
      const wheel = ['Filter 1', 'Filter 2'];
      expect(
        resolveEffectiveFilterNames(
          wheelNames: wheel,
          profileNames: const ['Filter 1', 'Filter 2'],
        ),
        equals(wheel),
      );
    });

    test('keeps real wheel names when driver reports band labels', () {
      const wheel = ['Ha', 'OIII', 'SII'];
      expect(
        resolveEffectiveFilterNames(
          wheelNames: wheel,
          profileNames: const ['L', 'R', 'G', 'B'],
        ),
        equals(wheel),
      );
    });

    test('pads profile names when wheel has more slots', () {
      expect(
        resolveEffectiveFilterNames(
          wheelNames: const ['Filter 1', 'Filter 2', 'Filter 3'],
          profileNames: const ['L', 'R'],
        ),
        equals(['L', 'R', 'Filter 3']),
      );
    });
  });

  group('isGenericFilterSlotName', () {
    test('matches common driver slot labels', () {
      expect(isGenericFilterSlotName('Filter 1'), isTrue);
      expect(isGenericFilterSlotName('filter2'), isTrue);
      expect(isGenericFilterSlotName('Ha'), isFalse);
      expect(isGenericFilterSlotName('L'), isFalse);
    });
  });
}
