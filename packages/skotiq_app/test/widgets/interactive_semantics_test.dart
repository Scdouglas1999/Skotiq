// The imaging controls must not tell a screen reader they cannot be used.
//
// A tap action with no role and no enabled flag reads to AT-SPI as disabled, so
// every filter chip and the Frame Type / Binning dropdowns on the Imaging screen
// dump as `panel: Ha [DISABLED]` / `button: Light [DISABLED]` while clicking
// them drives the wheel. These pin both surfaces.

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/capture_settings_panel.dart';
import 'package:skotiq_app/widgets/filter_wheel_selector.dart';
import 'package:skotiq_core/skotiq_core.dart';

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

  testWidgets(
      'the capture panel exposes no tappable control without a role '
      'and an enabled state', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      const CaptureSettingsPanel(showHeader: false),
      extraOverrides: [
        filterWheelStateProvider.overrideWith(_ConnectedWheel.new),
      ],
      settle: false,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    final failures = <String>[];
    void visit(SemanticsNode node) {
      // A node merged into its parent is dropped from the platform update and
      // its flags and actions are carried by the ancestor it merged into, so it
      // is not what a screen reader walks. `SkotiqDropdown` merges on
      // purpose — it publishes the button role above Material's own annotation,
      // which Material clears as soon as the control carries a hint — and
      // judging its inner node alone would fail the control over a node no
      // assistive technology can reach.
      if (node.isMergedIntoParent) return;
      final data = node.getSemanticsData();
      final hasRole = data.hasFlag(SemanticsFlag.isButton) ||
          data.hasFlag(SemanticsFlag.hasCheckedState) ||
          data.hasFlag(SemanticsFlag.hasToggledState) ||
          data.hasFlag(SemanticsFlag.isSlider) ||
          data.hasFlag(SemanticsFlag.isTextField);
      if (data.hasAction(SemanticsAction.tap)) {
        if (!hasRole) failures.add('"${data.label}" is tappable with no role');
        if (!data.hasFlag(SemanticsFlag.hasEnabledState)) {
          failures.add('"${data.label}" has no enabled state');
        }
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    expect(failures, isEmpty, reason: failures.join('; '));
    handle.dispose();
  });
}
