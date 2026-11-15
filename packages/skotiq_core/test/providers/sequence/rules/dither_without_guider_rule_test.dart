// A light burst that dithers every N frames on a rig with no guider is taken
// undithered. Pre-flight says so per step before the run, instead of the run
// logging it once and the step reading as done.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/providers/sequence/rules/equipment_rules.dart';
import 'package:skotiq_core/src/settings/app_settings_state.g.dart';

class _FakeGuiderNotifier extends StateNotifier<GuiderState>
    implements GuiderStateNotifier {
  _FakeGuiderNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(ditherEnabled: true, ditherEveryFrames: 3);
}

Future<List<ValidationIssue>> _issues(
  List<SequenceNode> steps, {
  GuiderState guider = const GuiderState(),
}) async {
  final container = ProviderContainer(
    overrides: [
      guiderStateProvider.overrideWith((ref) => _FakeGuiderNotifier(guider)),
      appSettingsProvider.overrideWith(_FakeAppSettings.new),
    ],
  );
  addTearDown(container.dispose);
  await container.read(appSettingsProvider.future);
  final root = InstructionSetNode(
    name: 'Root',
    childIds: [for (final step in steps) step.id],
  );
  final sequence = Sequence.create(
    name: 'T',
    nodes: {
      root.id: root,
      for (final step in steps) step.id: step.copyWith(parentId: root.id),
    },
    rootNodeId: root.id,
  );
  return container.read(
    Provider(
      (ref) =>
          DitherWithoutGuiderRule().validate(sequence, ValidationContext(ref)),
    ),
  );
}

void main() {
  test(
    'a light burst that would dither warns when no guider is connected',
    () async {
      final burst = ExposureNode(
        name: 'L 10 × 60 s',
        count: 10,
        ditherEvery: 2,
      );
      final issues = await _issues([burst]);
      expect(issues, hasLength(1));
      expect(issues.single.severity, ValidationSeverity.warning);
      expect(issues.single.affectedNodeId, burst.id);
      expect(
        issues.single.description,
        'L 10 × 60 s dithers every 2 frames, but no guider is connected, so its '
        'frames are taken undithered.',
      );
    },
  );

  test('the global dither-every counts for a burst that sets none', () async {
    final issues = await _issues([ExposureNode(count: 10, ditherEvery: null)]);
    expect(issues.single.description, contains('every 3 frames'));
  });

  test('no warning where no dither would be asked for', () async {
    expect(
      await _issues([
        // The dither after the last frame is never taken.
        ExposureNode(count: 3, ditherEvery: 3),
        ExposureNode(count: 10, ditherEvery: 0),
        ExposureNode(count: 10, frameType: FrameType.dark),
      ]),
      isEmpty,
    );
  });

  test('a connected guider has nothing to warn about', () async {
    expect(
      await _issues(
        [ExposureNode(count: 10, ditherEvery: 2)],
        guider: const GuiderState(
          connectionState: DeviceConnectionState.connected,
        ),
      ),
      isEmpty,
    );
  });
}
