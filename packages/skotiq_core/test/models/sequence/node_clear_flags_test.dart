// copyWith keeps a field on a null argument; the clear flags are how an editor
// sets a nullable field back to null without touching any other field.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

import '../../services/node_codec_goldens/node_fixtures.dart';

void main() {
  final header = fullNodes().whereType<TargetHeaderNode>().single;

  Map<String, Object?> fields(SequenceNode n) =>
      (plain(dumpNode(n)) as Map).cast<String, Object?>();

  test('each target clear flag nulls its field and keeps every other', () {
    final cases = <TargetHeaderNode Function(), TargetHeaderNode>{
      () => header.copyWith(clearStartAfter: true): TargetHeaderNode(
        id: header.id,
        name: header.name,
        isEnabled: header.isEnabled,
        comment: header.comment,
        targetName: header.targetName,
        raHours: header.raHours,
        decDegrees: header.decDegrees,
        rotation: header.rotation,
        priority: header.priority,
        minAltitude: header.minAltitude,
        maxAltitude: header.maxAltitude,
        endBefore: header.endBefore,
        mosaicPanel: header.mosaicPanel,
        integrationBudget: header.integrationBudget,
        startWhen: header.startWhen,
        endWhen: header.endWhen,
        triggerPollIntervalSecs: header.triggerPollIntervalSecs,
        brightnessTierHint: header.brightnessTierHint,
        catalogTargetId: header.catalogTargetId,
      ),
    };
    for (final MapEntry(key: build, value: expected) in cases.entries) {
      expect(fields(build()), fields(expected));
    }
    expect(header.copyWith(clearEndBefore: true).endBefore, isNull);
    expect(header.copyWith(clearEndBefore: true).startAfter, header.startAfter);
    final noBudget = header.copyWith(clearIntegrationBudget: true);
    expect(noBudget.integrationBudget, isNull);
    expect(noBudget.catalogTargetId, header.catalogTargetId);
    expect(fields(header.copyWith()), fields(header));
  });

  test('the other editors clear through their flags', () {
    final nodes = fullNodes();
    final conditional = nodes.whereType<ConditionalNode>().single;
    expect(conditional.safetyMonitorId, isNotNull);
    expect(
      conditional.copyWith(clearSafetyMonitorId: true).safetyMonitorId,
      isNull,
    );
    final science = nodes.whereType<SciencePhotometryNode>().single;
    final noGain = science.copyWith(clearGain: true);
    expect([noGain.gain, noGain.offset], [null, science.offset]);
    final stack = nodes.whereType<LiveStackingNode>().single;
    final public = stack.copyWith(clearAuthToken: true);
    expect(
      [public.authToken, public.watermarkText],
      [null, stack.watermarkText],
    );
  });
}
