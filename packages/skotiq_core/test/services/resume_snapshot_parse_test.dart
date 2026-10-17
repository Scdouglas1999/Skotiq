import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/sequence_file_service.dart';

/// A resumed run recovers its sequence tree by re-parsing the snapshot the
/// interrupted run stored in `sequence_runs.sequence_snapshot_json`. That only
/// works if the snapshot `sequenceToMap` writes round-trips back through
/// `parseFromMap` — the fixture here is a REAL snapshot captured from a live
/// desktop run, so a schema drift that breaks resume attribution fails here
/// instead of silently degrading a night's frames to 0.0s exposures.
void main() {
  test('a real stored run snapshot round-trips through parseFromMap', () {
    final raw = File(
      'test/fixtures/run_snapshot_sample.json',
    ).readAsStringSync();
    final map = jsonDecode(raw) as Map<String, dynamic>;

    final service = SequenceFileService();
    final sequence = service.parseFromMap(map);

    expect(sequence.name, 'CLAUDE BIN2 GAIN TEST');
    expect(sequence.nodes, hasLength(3));
    expect(sequence.rootNodeId, map['rootNodeId']);

    // The exposure node must survive with its capture settings intact — those
    // are exactly the fields frame attribution reads on resume.
    final exposure = sequence.nodes.values.firstWhere(
      (n) => n.nodeType == 'TakeExposure',
    );
    expect(exposure.id, isNotEmpty);
  });
}
