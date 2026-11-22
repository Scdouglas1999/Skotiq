// What each manual "center on coordinates" leaves behind: the centering
// status every window shows and the last result the recent-solves list and
// linked windows read, for a run that centers, one that fails and one that
// throws. The Tonight action, the Mount tab's Slew & center and the
// centering dialog (Framing, the planetarium, catalog cards) each start one.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/actions/night_rig_ops.dart';
import 'package:skotiq_app/screens/night_control/panel/mount/mount_go_to.dart';
import 'package:skotiq_app/screens/night_control/panel/mount/night_mount_tab.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_app/widgets/centering_dialog.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';

import '../harness/harness.dart';
import '../screens/night_control/panel/scope_panel_test_support.dart';

enum _Outcome { centered, failed, threw, busy }

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

class _Solver extends PlateSolveService {
  _Solver(super.ref);
  @override
  Future<void> ensureSolverAvailable() async {}
}

final _progress = CenteringStatus(
  state: CenteringState.solving,
  currentIteration: 2,
  maxIterations: 5,
  currentOffsetArcsec: 40,
  message: 'Plate solving…',
  iterationHistory: const [],
);

class _ScriptedCentering extends CenteringService {
  _ScriptedCentering(super.ref, this.outcome);
  final _Outcome outcome;

  /// Another centering (a minimized dialog, say) holds the loop.
  @override
  bool get isRunning => outcome == _Outcome.busy;

  @override
  Future<CenteringResult> centerOnTarget({
    required double targetRa,
    required double targetDec,
    CenteringConfig config = const CenteringConfig(),
    void Function(CenteringStatus)? onStatusUpdate,
  }) async {
    if (outcome != _Outcome.busy) onStatusUpdate?.call(_progress);
    switch (outcome) {
      case _Outcome.busy:
        return CenteringResult.failure(
          errorMessage: 'Another centering operation is already running',
          iterations: 0,
          iterationHistory: const [],
        );
      case _Outcome.centered:
        return CenteringResult.success(
          finalOffsetArcsec: 4.5,
          iterations: 3,
          iterationHistory: const [],
        );
      case _Outcome.failed:
        return CenteringResult.failure(
          errorMessage: 'No plate solution',
          iterations: 5,
          iterationHistory: const [],
        );
      case _Outcome.threw:
        throw StateError('camera gone');
    }
  }
}

/// What a site left in the two providers once its run ended.
typedef _Left = ({CenteringState state, String? message, bool? recorded});

_Left _read(ProviderContainer c) {
  final status = c.read(centeringStatusProvider);
  final result = c.read(lastCenteringResultProvider);
  return (
    state: status.state,
    message: status.message,
    recorded: result?.success,
  );
}

List<Override> _common(_Outcome outcome) => [
      activeEquipmentProfileProvider.overrideWithValue(null),
      appSettingsProvider.overrideWith(_Settings.new),
      plateSolveServiceProvider.overrideWith(_Solver.new),
      centeringServiceProvider.overrideWith(
        (ref) => _ScriptedCentering(ref, outcome),
      ),
    ];

/// Expected per site and outcome. A missing outcome (the run threw out of
/// the site) is listed with `threw`.
const Map<String, Map<_Outcome, _Left>> expected = {
  'tonight': {
    _Outcome.busy: (state: CenteringState.idle, message: null, recorded: null),
    _Outcome.centered: (
      state: CenteringState.completed,
      message: 'Centered',
      recorded: true,
    ),
    _Outcome.failed: (
      state: CenteringState.error,
      message: 'No plate solution',
      recorded: false,
    ),
    _Outcome.threw: (
      state: CenteringState.solving,
      message: 'Plate solving…',
      recorded: null,
    ),
  },
  'mountTab': {
    _Outcome.busy: (state: CenteringState.idle, message: null, recorded: null),
    _Outcome.centered: (
      state: CenteringState.completed,
      message: 'Centered',
      recorded: true,
    ),
    _Outcome.failed: (
      state: CenteringState.error,
      message: 'No plate solution',
      recorded: false,
    ),
  },
  'dialog': {
    _Outcome.busy: (state: CenteringState.idle, message: null, recorded: null),
    _Outcome.centered: (
      state: CenteringState.completed,
      message: 'Centered',
      recorded: true,
    ),
    _Outcome.failed: (
      state: CenteringState.error,
      message: 'No plate solution',
      recorded: false,
    ),
    _Outcome.threw: (
      state: CenteringState.solving,
      message: 'Plate solving…',
      recorded: null,
    ),
  },
};

void main() {
  for (final outcome in expected['tonight']!.keys) {
    test('Tonight center, ${outcome.name}', () async {
      final c = ProviderContainer(overrides: _common(outcome));
      addTearDown(c.dispose);
      final ops = c.read(nightRigOpsProvider);
      try {
        await ops.center(
          const NightCenterTarget(raHours: 5.5, decDegrees: -5.4),
        );
      } on StateError {
        expect(outcome, _Outcome.threw);
      }
      expect(_read(c), expected['tonight']![outcome]);
    });
  }

  for (final outcome in expected['mountTab']!.keys) {
    testWidgets('Mount tab Slew & center, ${outcome.name}', (tester) async {
      final handle = await pumpPanelTab(
        tester,
        const NightMountTab(),
        overrides: [
          ...panelOverrides(),
          ..._common(outcome),
          mountCommandServiceProvider.overrideWith(RecordingMountCommands.new),
          nightGoToResolverProvider.overrideWithValue((_) async => null),
        ],
      );
      await tester.enterText(
        find.byKey(const ValueKey('nightMount.goToRa')),
        '10h00m00s',
      );
      await tester.enterText(
        find.byKey(const ValueKey('nightMount.goToDec')),
        '+20 00 00',
      );
      await tester.pump();
      final button = find.byKey(const ValueKey('nightMount.slewCenter'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(_read(handle.container), expected['mountTab']![outcome]);
    });
  }

  for (final outcome in expected['dialog']!.keys) {
    testWidgets('centering dialog, ${outcome.name}', (tester) async {
      final handle = await pumpAppScreen(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showCenteringDialog(
              context: context,
              targetRa: 22.78,
              targetDec: 58.1,
              targetName: 'NGC7380',
            ),
            child: const Text('Open centering'),
          ),
        ),
        extraOverrides: _common(outcome),
      );
      await tester.tap(find.text('Open centering'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start centering'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(_read(handle.container), expected['dialog']![outcome]);
    });
  }
}
