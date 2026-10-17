// The authoring surface must read the same filters the capture path uses.
// Reading the equipment PROFILE and nothing else makes the builder say
// "No Filter" / "No filters in profile" while every frame of the run is
// captured, named `M42-TEST_R_0001.fits` and reported under filter "R", because
// the capture path uses the connected wheel.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/filter_source.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _StubFilterWheel extends FilterWheelStateNotifier {
  _StubFilterWheel(super.ref, FilterWheelState initial) {
    state = initial;
  }
}

Future<BuilderFilterSource> _resolve(
  WidgetTester tester, {
  required FilterWheelState wheel,
}) async {
  late BuilderFilterSource resolved;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        filterWheelStateProvider.overrideWith(
          (ref) => _StubFilterWheel(ref, wheel),
        ),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          resolved = builderFilterSource(ref);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return resolved;
}

void main() {
  testWidgets(
      'a connected wheel supplies the filters when the profile has '
      'none', (tester) async {
    final source = await _resolve(
      tester,
      wheel: const FilterWheelState(
        connectionState: DeviceConnectionState.connected,
        filterNames: ['R', 'G', 'B'],
      ),
    );

    expect(source.names, ['R', 'G', 'B']);
    expect(source.fromWheel, isTrue);
    expect(source.isEmpty, isFalse);
  });

  testWidgets('a disconnected wheel offers nothing, and says so',
      (tester) async {
    final source = await _resolve(
      tester,
      wheel: const FilterWheelState(filterNames: ['R']),
    );

    expect(source.isEmpty, isTrue);
    expect(BuilderFilterSource.emptyHint, isNot(contains('in profile')));
  });
}
