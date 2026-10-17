// The Imaging screen's filter wheel is the ONLY filter-position control on the
// screen, and it shipped without an `onFilterSelected` callback: picking Ha
// moved the wheel and highlighted the chip, but `exposureSettingsProvider.filter`
// stayed on whatever it was before, so every reader of that mirror (the Tonight
// session card among them) described the frame with the wrong filter.
//
// The Observatory relayout moved the strip out of the deleted bottom banner
// into the side panel's Filter wheel section; the contract did not move.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_side_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// Index of the Filter wheel section on the side-panel strip.
const int _filterSection = 5;

class _ConnectedWheel extends FilterWheelStateNotifier {
  _ConnectedWheel(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const FilterWheelState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'sim_filterwheel_1',
      deviceName: 'Simulated Filter Wheel',
      currentPosition: 1,
      filterNames: ['L', 'R', 'G', 'B', 'Ha'],
    );
  }
}

/// Accepts the move without a driver round-trip; the strip only needs the
/// command to succeed before it reports the selection.
class _AcceptingDeviceService extends DeviceService {
  _AcceptingDeviceService(super.ref, super.backend);

  int? lastPosition;

  @override
  Future<void> setFilterWheelPosition(int position) async {
    lastPosition = position;
  }
}

/// One frame, long enough for the async provider overrides to land.
const Duration _settleFrame = Duration(milliseconds: 50);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('picking a filter records it on the exposure settings',
      (tester) async {
    late _AcceptingDeviceService deviceService;
    final handle = await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => ImagingSectionBody(
          colors: context.skotiqColors,
          section: _filterSection,
        ),
      ),
      size: const Size(1400, 700),
      settle: false,
      extraOverrides: <Override>[
        filterWheelStateProvider.overrideWith(_ConnectedWheel.new),
        deviceServiceProvider.overrideWith((ref) {
          final backend = ref.watch(backendProvider);
          deviceService = _AcceptingDeviceService(ref, backend);
          ref.onDispose(deviceService.dispose);
          return deviceService;
        }),
      ],
    );
    await tester.pump(_settleFrame);

    expect(handle.container.read(exposureSettingsProvider).filter, isNull);

    await tester.tap(find.text('Ha'));
    await tester.pump();
    await tester.pump(_settleFrame);

    expect(deviceService.lastPosition, 4);
    expect(handle.container.read(exposureSettingsProvider).filter, 'Ha');
  });

  testWidgets('with no wheel attached the section says so once',
      (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => ImagingSectionBody(
          colors: context.skotiqColors,
          section: _filterSection,
        ),
      ),
      size: const Size(1400, 700),
      settle: false,
    );
    await tester.pump(_settleFrame);

    // The single empty-state pattern, not a banner and not a stack of cards.
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('No filter wheel'), findsOneWidget);
  });
}
