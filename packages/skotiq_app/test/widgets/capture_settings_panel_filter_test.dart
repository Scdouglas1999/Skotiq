// Widget tests for CaptureSettingsPanel's filter-wheel selector (Phase G).
//
// Scope:
//   1. selecting_position_commands_wheel — when a filter wheel is connected
//      with named slots, choosing a different filter in the capture panel's
//      dropdown dispatches setFilterWheelPosition with that slot's index, so
//      the capture UI actually drives the physical wheel (not just exposure
//      metadata). This is the win's core behavior.
//   2. position_indicator_shows_current_filter — the connected wheel's current
//      slot name is surfaced ("At wheel: <name>") so the operator can see where
//      the wheel physically sits.
//   3. mismatch_warning_when_selection_differs — when the exposure filter and
//      the physical wheel position disagree, a warning banner is shown.
//   4. no_wheel_falls_back_to_static_list — with no wheel connected the
//      dropdown keeps the default label list and selecting one never commands
//      a wheel (and never errors).
//
// We override filterWheelStateProvider with a seeded notifier and
// deviceServiceProvider with a recording service that captures the dispatched
// position — a direct, non-flaky check of exactly the wiring this win owns.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/capture_settings_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';

const _kWheelId = 'simulator:filterwheel:0';
const _kFilters = ['L', 'R', 'G', 'B'];

/// A [FilterWheelStateNotifier] seeded to a connected wheel sitting on
/// [position] so the panel renders the wheel-aware selector + indicator.
class _ConnectedFilterWheelNotifier extends FilterWheelStateNotifier {
  _ConnectedFilterWheelNotifier(super.ref, int position) {
    // ignore: invalid_use_of_protected_member
    state = FilterWheelState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _kWheelId,
      deviceName: 'Simulated Wheel',
      currentPosition: position,
      filterNames: _kFilters,
    );
  }
}

/// A [DeviceService] that records filter-wheel position commands instead of
/// driving a backend, so an accepted selection is observable without timers.
class _RecordingDeviceService extends DeviceService {
  _RecordingDeviceService(super.ref, super.backend);

  final List<int> positions = [];
  Completer<void>? moveGate;
  Object? moveError;

  @override
  Future<void> setFilterWheelPosition(int position) async {
    positions.add(position);
    final gate = moveGate;
    if (gate != null) await gate.future;
    final error = moveError;
    if (error != null) throw error;
  }
}

List<Override> _overrides({required int? wheelPosition}) => [
      if (wheelPosition != null)
        filterWheelStateProvider.overrideWith(
          (ref) => _ConnectedFilterWheelNotifier(ref, wheelPosition),
        ),
      deviceServiceProvider.overrideWith((ref) {
        final backend = ref.watch(backendProvider);
        final service = _RecordingDeviceService(ref, backend);
        ref.onDispose(service.dispose);
        return service;
      }),
    ];

Future<_RecordingDeviceService> _pumpPanel(
  WidgetTester tester, {
  required int? wheelPosition,
}) async {
  final handle = await pumpAppScreen(
    tester,
    const CaptureSettingsPanel(showHeader: false),
    extraOverrides: _overrides(wheelPosition: wheelPosition),
    settle: false,
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  return handle.container.read(deviceServiceProvider)
      as _RecordingDeviceService;
}

/// Open the filter dropdown (identified by the slot label it currently shows)
/// and tap the menu entry labelled [filter], draining the resulting state
/// frames. The recording service completes synchronously.
Future<void> _selectFilter(
  WidgetTester tester, {
  required String currentLabel,
  required String filter,
}) async {
  // The Filter dropdown is the only String dropdown whose closed trigger shows
  // a filter slot label (Binning shows '1x1', Frame shows 'Light'), so scope
  // the open tap to the dropdown ancestor of that label.
  final filterDropdown = find.ancestor(
    of: find.text(currentLabel),
    matching: find.byType(SkotiqDropdown),
  );
  await tester.tap(filterDropdown);
  await tester.pumpAndSettle();
  // The open menu shows entries; tap the last match (the menu overlay copy).
  await tester.tap(find.text(filter).last);
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'selecting_position_commands_wheel: choosing G dispatches position 2',
      (tester) async {
    // Wheel currently on L (position 0); exposure filter starts unset (-> L).
    final service = await _pumpPanel(tester, wheelPosition: 0);

    await _selectFilter(tester, currentLabel: 'L', filter: 'G');

    expect(service.positions, [2],
        reason: 'Selecting the 3rd named slot (G) must command the wheel to '
            'position index 2.');
  });

  testWidgets(
      'pending wheel move keeps old metadata and disables capture controls',
      (tester) async {
    final service = await _pumpPanel(tester, wheelPosition: 0);
    service.moveGate = Completer<void>();

    await _selectFilter(tester, currentLabel: 'L', filter: 'G');

    expect(service.positions, [2]);
    expect(
      tester
          .widget<SkotiqDropdown>(
            find.ancestor(
              of: find.text('L'),
              matching: find.byType(SkotiqDropdown),
            ),
          )
          .onChanged,
      isNull,
      reason: 'The filter cannot be changed again before hardware settles.',
    );
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Capture'),
          )
          .onPressed,
      isNull,
      reason: 'Capture must remain unavailable while the selected filter is '
          'still physically moving.',
    );

    service.moveGate!.complete();
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      tester
          .widgetList<SkotiqDropdown>(find.byType(SkotiqDropdown))
          .where((dropdown) => dropdown.value == 'G'),
      hasLength(1),
      reason: 'Exposure metadata changes only after the move completes.',
    );
  });

  testWidgets('failed wheel move retains the previous exposure filter',
      (tester) async {
    final service = await _pumpPanel(tester, wheelPosition: 0);
    service.moveError = StateError('wheel jammed');

    await _selectFilter(tester, currentLabel: 'L', filter: 'G');

    expect(service.positions, [2]);
    expect(find.text('L'), findsWidgets,
        reason: 'A failed move must not tag subsequent captures as G.');
    expect(find.textContaining('Could not change the filter'), findsOneWidget);
  });

  testWidgets('position_indicator_shows_current_filter: surfaces At wheel: R',
      (tester) async {
    await _pumpPanel(tester, wheelPosition: 1);

    expect(find.text('At wheel: R'), findsOneWidget,
        reason: 'The connected wheel position name must be shown to the user.');
  });

  testWidgets(
      'mismatch_warning_when_selection_differs: warns wheel != selection',
      (tester) async {
    // Wheel sits on G (position 2) but the exposure filter defaults to the
    // first slot (L), so the selection and the physical wheel disagree.
    await _pumpPanel(tester, wheelPosition: 2);

    expect(find.text('Wheel is on G, not L'), findsOneWidget,
        reason: 'A selection that differs from the physical wheel position '
            'must surface a mismatch warning.');
  });

  testWidgets(
      'no_wheel_falls_back_to_static_list: selection never commands a wheel',
      (tester) async {
    final service = await _pumpPanel(tester, wheelPosition: null);

    // The static fallback list still drives the dropdown (e.g. Ha is present).
    expect(find.textContaining('At wheel:'), findsNothing,
        reason: 'With no wheel connected the position indicator is hidden.');

    await _selectFilter(tester, currentLabel: 'L', filter: 'Ha');

    expect(service.positions, isEmpty,
        reason: 'With no wheel connected a filter pick must not command any '
            'hardware.');
  });
}
