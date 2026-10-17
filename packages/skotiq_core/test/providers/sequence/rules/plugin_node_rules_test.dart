import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/providers/sequence/rules/plugin_node_rules.dart';
import '../../../harness/in_memory_database.dart';

final _availabilityIssuesProvider =
    Provider.family<List<ValidationIssue>, Sequence>((ref, sequence) {
      return PluginNodeAvailabilityRule().validate(
        sequence,
        ValidationContext(ref),
      );
    });

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

Sequence _sequenceWith(PluginInstructionNode node) => Sequence.create(
  id: 'plugin-sequence',
  name: 'Plugin sequence',
  nodes: {node.id: node},
  rootNodeId: node.id,
);

PluginInstructionNode _node({
  String pluginId = 'com.example.notify',
  String nodeTypeId = 'notify.send',
  String configJson = '{"message":"hello"}',
  int? timeoutSecs = 600,
  bool isEnabled = true,
}) => PluginInstructionNode(
  id: 'plugin-node-1',
  name: 'Notify',
  isEnabled: isEnabled,
  pluginId: pluginId,
  nodeTypeId: nodeTypeId,
  configJson: configJson,
  timeoutSecs: timeoutSecs,
);

void main() {
  final rule = PluginNodeConfigurationRule();

  test('valid object configuration and timeout are clean', () {
    expect(rule.validate(_sequenceWith(_node())), isEmpty);
    expect(rule.validate(_sequenceWith(_node(timeoutSecs: 0))), isEmpty);
  });

  test('malformed and non-object JSON are blocking errors', () {
    for (final config in ['{bad-json', '[]', 'null', '"message"']) {
      final issues = rule.validate(_sequenceWith(_node(configJson: config)));
      expect(
        issues.any(
          (issue) =>
              issue.code == 'plugin_node_config_invalid' &&
              issue.severity == ValidationSeverity.error,
        ),
        isTrue,
        reason: 'Expected invalid config finding for $config',
      );
    }
  });

  test('missing identity and out-of-range timeout are blocking errors', () {
    final issues = rule.validate(
      _sequenceWith(_node(pluginId: ' ', nodeTypeId: '', timeoutSecs: 7201)),
    );

    expect(
      issues.map((issue) => issue.code),
      containsAll([
        'plugin_node_identity_missing',
        'plugin_node_timeout_invalid',
      ]),
    );
  });

  test('canonical validateSequence includes plugin configuration checks', () {
    final issues = validateSequence(
      _sequenceWith(_node(configJson: 'not-json')),
    );
    expect(
      issues.any((issue) => issue.code == 'plugin_node_config_invalid'),
      isTrue,
    );
  });

  group('PluginNodeAvailabilityRule', () {
    test('accepts an enabled node type loaded on the local host', () {
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          pluginNodeBlueprintsProvider.overrideWithValue([
            const PluginNodeBlueprint(
              pluginId: 'com.example.notify',
              nodeTypeId: 'notify.send',
              pluginName: 'Notify',
              name: 'Send notification',
              description: 'Sends a notification',
              category: 'Notifications',
            ),
          ]),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(_availabilityIssuesProvider(_sequenceWith(_node()))),
        isEmpty,
      );
    });

    test('blocks a missing or disabled local plugin node type', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      final issues = container.read(
        _availabilityIssuesProvider(_sequenceWith(_node())),
      );
      expect(issues, hasLength(1));
      expect(issues.single.code, 'plugin_node_unavailable');
      expect(issues.single.severity, ValidationSeverity.error);
      expect(issues.single.affectedNodeId, 'plugin-node-1');
    });

    test('ignores disabled nodes', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      expect(
        container.read(
          _availabilityIssuesProvider(_sequenceWith(_node(isEnabled: false))),
        ),
        isEmpty,
      );
    });

    test('defers availability authority to a remote imaging host', () {
      final backend = NetworkBackend(
        serverHost: '127.0.0.1',
        autoConnectWebSocket: false,
      );
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(() {
        container.dispose();
        backend.dispose();
      });

      expect(
        container.read(_availabilityIssuesProvider(_sequenceWith(_node()))),
        isEmpty,
      );
    });
  });
}
