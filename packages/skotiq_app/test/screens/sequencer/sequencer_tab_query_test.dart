import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';

void main() {
  test('sequencer tab query maps history and legacy run aliases', () {
    expect(sequencerTabFromQuery('history'), SequencerTab.history);
    expect(sequencerTabFromQuery('RUNS'), SequencerTab.history);
  });

  test('unknown sequencer tab queries do not force a tab', () {
    expect(sequencerTabFromQuery(null), isNull);
    expect(sequencerTabFromQuery('made-up'), isNull);
  });
}
