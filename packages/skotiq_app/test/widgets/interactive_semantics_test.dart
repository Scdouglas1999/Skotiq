// The imaging controls must not tell a screen reader they cannot be used.
//
// A tap action with no role and no enabled flag reads to AT-SPI as disabled, so
// every filter chip on the Imaging screen dumps as `panel: Ha [DISABLED]` while
// clicking it drives the wheel.

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/filter_wheel_selector.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../harness/harness.dart';

const _kFilters = ['L', 'R', 'G', 'Ha'];

class _ConnectedWheel extends FilterWheelStateNotifier {
  _ConnectedWheel(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const FilterWheelState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'simulator:filterwheel:0',
      deviceName: 'Simulated Wheel',
      currentPosition: 3,
      filterNames: _kFilters,
    );
  }
}

SemanticsData _dataFor(WidgetTester tester, Finder finder) =>
    tester.getSemantics(finder).getSemanticsData();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'filter chips announce a role, that they are live, and which '
      'filter is mounted', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      const FilterWheelSelector(),
      extraOverrides: [
        filterWheelStateProvider.overrideWith(_ConnectedWheel.new),
      ],
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 50));

    for (final filter in _kFilters) {
      final data = _dataFor(tester, find.text(filter));
      expect(
        data.hasFlag(SemanticsFlag.isButton),
        isTrue,
        reason: '$filter chip declares no role',
      );
      expect(
        data.hasFlag(SemanticsFlag.isEnabled),
        isTrue,
        reason: '$filter chip is live but announces itself as disabled',
      );
      expect(
        data.hasFlag(SemanticsFlag.isSelected),
        filter == 'Ha',
        reason: '$filter chip reports the wrong mounted state',
      );
    }
    handle.dispose();
  });

}
