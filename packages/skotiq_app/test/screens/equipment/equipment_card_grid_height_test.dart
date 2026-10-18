import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_app/screens/equipment/widgets/device_tile_width.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../golden/surface_golden_harness.dart';
import '../../harness/harness.dart';

class _MountNotifier extends MountStateNotifier {
  _MountNotifier(super.ref, MountState initial) {
    state = initial;
  }
}

class _DomeNotifier extends DomeStateNotifier {
  _DomeNotifier(super.ref, DomeState initial) {
    state = initial;
  }
}

class _FilterWheelNotifier extends FilterWheelStateNotifier {
  _FilterWheelNotifier(super.ref) {
    setConnecting('efw', 'ZWO EFW 7x36');
    setConnected(filterNames: const ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII']);
    updatePosition(4);
  }
}

class _CameraNotifier extends CameraStateNotifier {
  _CameraNotifier(super.ref, CameraStateSnapshot initial) {
    state = initial;
  }
}

/// The device dashboard laid its fixed-width cards out in a plain `Wrap`
/// (spacing + runSpacing only, no cross-axis stretch), so every card sized to
/// its own content. Cards whose action buttons wrap to a second line then hung
/// below their row-mates: measured on a 2560 px window with nine devices
/// connected, the Mount card's bottom edge sat 36 px below its row and the Dome
/// card's 72 px below its own, producing a visibly ragged grid.
///
/// This pins the property `Wrap` cannot express: cards on the same row share a
/// height. It measures real rendered geometry rather than asserting on the widget
/// type, so a future re-layout that keeps the invariant still passes.
void main() {
  testWidgets('cards on one row share a height even when actions wrap', (
    tester,
  ) async {
    const camera = CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'cam-1',
      deviceName: 'Sim Camera',
    );
    // The mount card is the tall one: Unpark/Track/Home/Flip plus two icon
    // buttons wrap to a second action line.
    const mount = MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'mount-1',
      deviceName: 'Sim Mount',
    );
    const dome = DomeState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'dome-1',
      deviceName: 'Sim Dome',
    );

    final handle = await pumpAppScreen(
      tester,
      const _CardRow(),
      size: const Size(1400, 900),
      settle: false,
      extraOverrides: [
        cameraStateProvider.overrideWith((ref) => _CameraNotifier(ref, camera)),
        mountStateProvider.overrideWith((ref) => _MountNotifier(ref, mount)),
        domeStateProvider.overrideWith((ref) => _DomeNotifier(ref, dome)),
      ],
    );
    addTearDown(() async => handle.database.close());
    await tester.pump(const Duration(milliseconds: 300));

    final heights = tester
        .widgetList<ConnectedDeviceCard>(find.byType(ConnectedDeviceCard))
        .map((card) => tester.getSize(find.byWidget(card)).height)
        .toList();

    expect(heights.length, 3, reason: 'all three cards should render');
    for (final height in heights) {
      expect(
        height,
        moreOrLessEquals(heights.first, epsilon: 0.5),
        reason: 'row-mates must share a height; got $heights',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a filter wheel card with its filter select lays out in a grid row at '
      'the owner\'s 1308 px content width', (tester) async {
    // The select measured itself through a bare LayoutBuilder, which has no
    // intrinsic height: in this IntrinsicHeight row it asserted in debug and
    // counted as zero in release, so the row came out short of the card.
    const camera = CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'cam-1',
      deviceName: 'Sim Camera',
    );
    // The shipped fonts, so the readouts take their real widths.
    await SurfaceGoldenHarness.ensureFonts();
    final handle = await pumpAppScreen(
      tester,
      const _FilterWheelRow(),
      size: const Size(1308, 774),
      settle: false,
      extraOverrides: [
        cameraStateProvider.overrideWith((ref) => _CameraNotifier(ref, camera)),
        filterWheelStateProvider.overrideWith(_FilterWheelNotifier.new),
      ],
    );
    addTearDown(() async => handle.database.close());
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    final select = find.byType(SkotiqDropdown);
    expect(select, findsOneWidget,
        reason: 'non-vacuous: the filter wheel card carries its select');
    final card = find.ancestor(
      of: select,
      matching: find.byType(ConnectedDeviceCard),
    );
    expect(
      tester.getRect(select).bottom,
      lessThanOrEqualTo(tester.getRect(card).bottom),
      reason: 'the select sits inside its card',
    );
  });
}

/// Two tiles of the grid's width at 1308 px: (1308 - padding - gaps) / 3.
class _FilterWheelRow extends StatelessWidget {
  const _FilterWheelRow();

  static const double _tile = 380;

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(
                width: _tile,
                child: DeviceTileWidth(
                  width: _tile,
                  child: ConnectedDeviceCard(type: ConnectedDeviceType.camera),
                ),
              ),
              SizedBox(width: 16),
              SizedBox(
                width: _tile,
                child: DeviceTileWidth(
                  width: _tile,
                  child: ConnectedDeviceCard(
                    type: ConnectedDeviceType.filterWheel,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mirrors the dashboard's desktop grid: fixed-width tiles in an
/// [IntrinsicHeight] row.
class _CardRow extends StatelessWidget {
  const _CardRow();

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(
                width: 320,
                child: DeviceTileWidth(
                  width: 320,
                  child: ConnectedDeviceCard(type: ConnectedDeviceType.camera),
                ),
              ),
              SizedBox(width: 16),
              SizedBox(
                width: 320,
                child: DeviceTileWidth(
                  width: 320,
                  child: ConnectedDeviceCard(type: ConnectedDeviceType.mount),
                ),
              ),
              SizedBox(width: 16),
              SizedBox(
                width: 320,
                child: DeviceTileWidth(
                  width: 320,
                  child: ConnectedDeviceCard(type: ConnectedDeviceType.dome),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
