import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';

void main() {
  test('sequencer tab query maps history and legacy run aliases', () {
    expect(SequencerTab.fromQuery('history'), SequencerTab.history);
    expect(SequencerTab.fromQuery('RUNS'), SequencerTab.history);
  });

  test('unknown sequencer tab queries do not force a tab', () {
    expect(SequencerTab.fromQuery(null), isNull);
    expect(SequencerTab.fromQuery('made-up'), isNull);
  });
}
