import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_executor/sequence_serializer.dart';

class _StubFilterWheel extends FilterWheelStateNotifier {
  _StubFilterWheel(super.ref, FilterWheelState initial) {
    state = initial;
  }
}

// A profile made on the phone has no slot names; the wheel reports them.
void main() {
  test('a profile without slot names uses the wheel\'s, and does not warn', () {
    final warnings = <String>[];
    final serializer = Provider(
      (ref) => SequenceSerializer(ref: ref, warn: warnings.add),
    );
    final container = ProviderContainer(
      overrides: [
        activeEquipmentProfileProvider.overrideWithValue(
          EquipmentProfileModel(name: 'Backyard Pi'),
        ),
        filterWheelStateProvider.overrideWith(
          (ref) => _StubFilterWheel(
            ref,
            const FilterWheelState(
              connectionState: DeviceConnectionState.connected,
              filterNames: ['L', 'R', 'G', 'B'],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final exposure = ExposureNode(
      name: 'Red',
      durationSecs: 120,
      count: 2,
      filter: 'R',
    );
    final root = InstructionSetNode(name: 'Root');
    final sequence = Sequence.create(
      name: 'Wheel names',
      rootNodeId: root.id,
      nodes: {
        exposure.id: exposure.copyWith(parentId: root.id),
        root.id: root.copyWith(childIds: [exposure.id]),
      },
    );

    final json = container.read(serializer).sequenceToJson(sequence);
    expect(json, contains('"filter_index":1'));
    expect(warnings.where((w) => w.contains('filter')), isEmpty);
    expect(jsonDecode(json), isA<Map>());
  });
}
