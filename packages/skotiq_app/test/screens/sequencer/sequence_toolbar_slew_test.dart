// The toolbar's "Slew to Target" must not fire a real, unconfirmed slew —
// during a run, or to a target below the horizon — with zero feedback: no
// dialog, no toast, no "Slewing" state, and nothing in the session log, so the
// only way to discover the mount moved is to open another screen and read the
// Equipment panel.
//
// These tests drive the real toolbar: the control must be locked while the
// executor owns the mount, and must ask before moving it when idle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_app/services/command_action_result.dart';
import 'package:skotiq_app/services/goto_altitude_check.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';
import 'canvas_bar_menu.dart';

Sequence _sequenceWithTarget() {
  final exposure = ExposureNode(
    id: 'exp',
    name: 'Lum',
    durationSecs: 15,
    count: 4,
    parentId: 'target',
  );
  final target = TargetHeaderNode(
    id: 'target',
    name: 'Target',
    targetName: 'M42-TEST',
    raHours: 12.0,
    decDegrees: -35.0,
    childIds: const ['exp'],
  );
  return Sequence.create(
    name: 'T',
    nodes: {target.id: target, exposure.id: exposure},
    rootNodeId: target.id,
  );
}

class _ConnectedMount extends MountStateNotifier {
  _ConnectedMount(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'mount-1',
      deviceName: 'Test Mount',
    );
  }
}

/// A site at +45 with a 30 degree floor: the target at Dec -35 never climbs
/// above 10 degrees there.
class _HighFloorSite extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        latitude: 45,
        longitude: 0,
        horizonProfileJson: '{"N":30,"NE":30,"E":30,"SE":30,"S":30,"SW":30,'
            '"W":30,"NW":30}',
      );
}

class _SlewRecorder extends MountCommandService {
  _SlewRecorder(super.ref);

  int sent = 0;

  @override
  Future<CommandActionResult> sendSlew(
    double ra,
    double dec, {
    bool showFeedback = true,
  }) async {
    sent++;
    return CommandActionResult.ok;
  }
}

Future<void> _pumpToolbar(
  WidgetTester tester, {
  required SequenceExecutionState executionState,
  List<Override> overrides = const [],
}) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _sequenceWithTarget();

  await pumpAppScreen(
    tester,
    Builder(
      builder: (context) => SequenceToolbar(colors: SkotiqColors.of(context)),
    ),
    size: const Size(1600, 900),
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      runRecordProvider.overrideWith(
        (ref) => RunRecordNotifier(ref, RunRecord(lifecycle: executionState)),
      ),
      ...overrides,
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('locked while the sequence is running, like its neighbors',
      (tester) async {
    await _pumpToolbar(tester, executionState: SequenceExecutionState.running);

    await openCanvasBarMenu(tester);
    const locked = 'Slew to target (locked while sequence is running)';
    expect(canvasBarAction(locked), findsOneWidget);
    expect(canvasBarAction('Slew to target'), findsNothing);
    expect(
      canvasBarActionEnabled(tester, locked),
      isFalse,
      reason: 'a mount command during a run fights the executor for the '
          'telescope',
    );
  });

  Future<(_SlewRecorder, List<GoToAltitudeQuestion>)> pumpAsking(
    WidgetTester tester, {
    List<Override> site = const [],
  }) async {
    final asked = <GoToAltitudeQuestion>[];
    late _SlewRecorder mount;
    await _pumpToolbar(
      tester,
      executionState: SequenceExecutionState.idle,
      overrides: [
        ...site,
        mountStateProvider.overrideWith(_ConnectedMount.new),
        mountCommandServiceProvider
            .overrideWith((ref) => mount = _SlewRecorder(ref)),
        goToAltitudeAskProvider.overrideWithValue((question) async {
          asked.add(question);
          return false;
        }),
      ],
    );
    await tapCanvasBarAction(tester, 'Slew to target');
    await tester.pumpAndSettle();
    return (mount, asked);
  }

  Future<void> release(WidgetTester tester) async {
    // The connected mount arms the device-contact ticker; let it go.
    ProviderScope.containerOf(tester.element(find.byType(SequenceToolbar)))
        .read(mountStateProvider.notifier)
        .setDisconnected();
    await tester.pump(const Duration(seconds: 11));
  }

  testWidgets('when idle it always asks once before moving the mount',
      (tester) async {
    final (mount, asked) = await pumpAsking(tester);

    expect(asked, hasLength(1), reason: 'a mis-press never moves the mount');
    expect(asked.single.targetName, 'M42-TEST');
    expect(asked.single.verdict?.kind ?? GoToAltitudeKind.clear,
        GoToAltitudeKind.clear);
    expect(mount.sent, 0);
    await release(tester);
  });

  testWidgets('under the floor the one question carries the warning',
      (tester) async {
    final (mount, asked) = await pumpAsking(
      tester,
      site: [appSettingsProvider.overrideWith(_HighFloorSite.new)],
    );

    expect(asked, hasLength(1));
    expect(asked.single.verdict?.kind, isNot(GoToAltitudeKind.clear));
    expect(mount.sent, 0);
    await release(tester);
  });
}
