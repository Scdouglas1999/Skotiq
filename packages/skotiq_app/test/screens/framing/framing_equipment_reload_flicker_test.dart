// Regression test: the Framing sidebar's Equipment card must keep showing the
// equipment it has already resolved while its provider re-runs.
//
// Observed on the running desktop build: on arrival at Framing the Equipment
// section rendered nothing but a CircularProgressIndicator, and it was still
// spinning minutes later — while the FOV / Resolution / Sensor rows directly
// below it were populated the whole time. Sampling the card region ten times
// over ~30 s found a bare spinner in eight of them and the resolved
// "My First Rig / Simulated Camera / 530mm f/5.0" in two.
//
// Both halves are fed by the SAME framingFOVProvider. The rows below read
// `equipmentAsync.valueOrNull` and keep the retained value; the card used
// `.when(...)` whose `skipLoadingOnReload` defaults to FALSE, so it threw the
// resolved value away and painted a spinner every time the provider re-ran.
// And framingFOVProvider watches cameraStateProvider, so ordinary camera
// telemetry (cooler power, sensor temperature, exposure progress) re-runs its
// async getCameraStatus round-trip continuously.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_sidebar.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

const _resolved = FramingEquipmentResult(
  status: EquipmentStatus.ready,
  profileName: 'My First Rig',
  equipment: FramingEquipment(
    cameraName: 'Simulated Camera',
    sensorWidthMm: 23.5,
    sensorHeightMm: 15.7,
    pixelSizeMicrons: 3.76,
    pixelsX: 6248,
    pixelsY: 4176,
    telescopeName: 'My First Rig',
    focalLengthMm: 530,
    apertureMm: 106,
  ),
);

/// Stands in for framingFOVProvider: resolves once, then re-runs on demand the
/// way camera telemetry churn makes the real provider re-run.
class _EquipmentSource
    extends StateNotifier<AsyncValue<FramingEquipmentResult>> {
  _EquipmentSource() : super(const AsyncValue.loading());

  void resolve() => state = const AsyncValue.data(_resolved);

  /// Exactly what Riverpod does to a FutureProvider whose WATCHED DEPENDENCY
  /// changed: AsyncLoading that retains the previous value, flagged as a
  /// reload (`isRefresh: false`) rather than a user-triggered refresh. That
  /// distinction is the whole defect — `when` skips loading on a refresh by
  /// default but NOT on a reload, and camera telemetry churn produces reloads.
  void reload() => state = const AsyncValue<FramingEquipmentResult>.loading()
      .copyWithPrevious(const AsyncValue.data(_resolved), isRefresh: false);
}

final _sourceProvider =
    StateNotifierProvider<_EquipmentSource, AsyncValue<FramingEquipmentResult>>(
  (ref) => _EquipmentSource(),
);

class _Host extends ConsumerWidget {
  const _Host();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      child: FramingEquipmentSection(
        colors: SkotiqColors.dark,
        equipmentAsync: ref.watch(_sourceProvider),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'equipment_card_survives_a_provider_reload: a re-run does not blank the '
      'resolved rig back to a spinner', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const _Host(),
      size: const Size(320, 900),
      settle: false,
    );
    await tester.pump();

    // First load: a spinner is honest, there is nothing to show yet.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    handle.container.read(_sourceProvider.notifier).resolve();
    await tester.pump();
    expect(find.text('My First Rig'), findsOneWidget);
    expect(find.text('Simulated Camera'), findsOneWidget);

    // Camera telemetry ticks -> the provider re-runs its getCameraStatus call.
    handle.container.read(_sourceProvider.notifier).reload();
    await tester.pump();

    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'The equipment is already known; replacing it with a spinner on '
          'every telemetry tick is what made the card look permanently stuck.',
    );
    expect(find.text('Simulated Camera'), findsOneWidget,
        reason: 'The resolved rig must stay on screen across a reload, the way '
            'the FOV rows below it already do.');
    expect(find.text('My First Rig'), findsOneWidget,
        reason: 'The status badge must not blank out either.');
  });

  testWidgets(
      'equipment_badge_names_a_genuine_first_load: the loading badge is no '
      'longer an invisible SizedBox', (tester) async {
    await pumpAppScreen(
      tester,
      const _Host(),
      size: const Size(320, 900),
      settle: false,
    );
    await tester.pump();

    expect(find.text('Loading…'), findsOneWidget,
        reason: 'With nothing resolved yet the badge must say so — an empty '
            'SizedBox made a stuck first load indistinguishable from a state '
            'that simply has no badge.');
  });
}
