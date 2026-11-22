import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test('every state word the native executor sends has its state', () {
    // The file `state_words_match_the_app` in executor/types.rs reads.
    final words =
        (jsonDecode(
                  File(
                    'test/fixtures/native_run_states.json',
                  ).readAsStringSync(),
                )
                as List)
            .cast<String>();
    expect(
      words.map(NativeRunState.parse).toList(),
      NativeRunState.values.where((s) => s != NativeRunState.unknown).toList(),
    );
  });

  test('terminal, in-flight and under-way answer as the callers need', () {
    String row(NativeRunState s) =>
        '${s.name} ${s.isTerminal} ${s.mayBeInFlight} ${s.isUnderWay}';
    expect(NativeRunState.values.map(row).toList(), [
      'idle true false false',
      'running false true true',
      'paused false true true',
      'stopping false true true',
      'cancelled true false false',
      'completed true false false',
      'failed true false false',
      'recovering false true true',
      'unknown false true false',
    ]);
    expect(NativeRunState.parse('RUNNING'), NativeRunState.running);
    expect(NativeRunState.parse('finalizing'), NativeRunState.unknown);
  });
}
