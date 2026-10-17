// The watermark field's insert control offers `watermarkVariableCatalog`.
// `expandWatermarkTokens` passes an unknown token through LITERALLY, so any
// entry the catalog offers that `_watermarkTokens` does not answer would be
// burned verbatim into the broadcast JPEG — the operator picks it from a menu
// and gets `${filter}` in their image. This pins catalog and renderer together.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

LiveStackingNode _node(String watermark) => LiveStackingNode(
  id: 'ls-vocab',
  name: 'Live Stacking',
  mode: LiveStackingMode.broadcastOnly,
  stackMethod: LiveStackingMethod.average,
  broadcastPort: 8081,
  watermarkText: watermark,
);

void main() {
  test('every offered watermark variable actually resolves', () {
    final c = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(c.dispose);
    final svc = c.read(liveStackingBroadcastServiceProvider);

    for (final variable in watermarkVariableCatalog) {
      svc.activate(_node(variable.placeholder));
      expect(
        svc.renderWatermark(),
        isNot(equals(variable.placeholder)),
        reason:
            '${variable.placeholder} is offered by the picker but the '
            'broadcast renders it literally',
      );
      svc.deactivate();
    }
  });

  test('the sequencer catalog is NOT the watermark vocabulary', () {
    // Wiring the picker to the sequencer's expression catalog offers variables
    // most of which the watermark cannot resolve. If the two ever converge
    // legitimately, this test is what says so.
    final watermarkNames = watermarkVariableCatalog.map((v) => v.name).toSet();
    final unresolvable = interpolationCatalog
        .map((v) => v.name)
        .where((name) => !watermarkNames.contains(name))
        .toList();
    expect(unresolvable, isNotEmpty);

    final c = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(c.dispose);
    final svc = c.read(liveStackingBroadcastServiceProvider);
    // Spot-check one: a sequencer variable renders as its own literal text.
    svc.activate(_node(r'${filter}'));
    expect(svc.renderWatermark(), r'${filter}');
  });
}
