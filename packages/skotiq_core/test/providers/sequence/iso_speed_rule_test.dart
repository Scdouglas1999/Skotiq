import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/device_capabilities.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/capability_provider.dart';
import 'package:skotiq_core/src/providers/sequence/rules/preflight_rules.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/settings/app_settings_state.g.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => AppSettingsState();
}

Sequence _sequenceWith(List<SequenceNode> children) {
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{root.id: root};
  final ids = <String>[];
  for (final child in children) {
    final placed = child.copyWith(parentId: root.id);
    nodes[placed.id] = placed;
    ids.add(placed.id);
  }
  nodes[root.id] = root.copyWith(childIds: ids);
  return Sequence.create(name: 'T', nodes: nodes, rootNodeId: root.id);
}

List<String> _titles(ExposureSensitivity sensitivity, List<int?> gains) {
  final container = ProviderContainer(
    overrides: [
      cameraSensitivityProvider.overrideWithValue(sensitivity),
      appSettingsProvider.overrideWith(_Settings.new),
    ],
  );
  addTearDown(container.dispose);
  final probe = Provider(
    (ref) => IsoSpeedRule().validate(
      _sequenceWith([for (final g in gains) ExposureNode(gain: g)]),
      ValidationContext(ref),
    ),
  );
  return [for (final issue in container.read(probe)) issue.title];
}

void main() {
  final dslr = IsoSensitivity(const [100, 200, 400, 800, 1600]);

  test('an ISO-list position from an older sequence is flagged', () {
    expect(_titles(dslr, [3]), ['ISO Not Set']);
  });

  test('an ISO between two speeds is noted, an offered one is not', () {
    expect(_titles(dslr, [850, 800, null]), ['ISO Rounded']);
  });

  test('a gain camera is not checked', () {
    expect(_titles(const GainSensitivity(), [3, 850]), isEmpty);
  });
}
