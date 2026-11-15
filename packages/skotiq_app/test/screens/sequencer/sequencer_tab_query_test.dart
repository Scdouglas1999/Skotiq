import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';

void main() {
  test('the run history words name no Sequencer tab; they name History', () {
    expect(SequencerTab.fromQuery('history'), isNull);
    expect(SequencerTab.fromQuery('RUNS'), isNull);
    expect(SequencerTab.namesHistory('history'), isTrue);
    expect(SequencerTab.namesHistory('RUNS'), isTrue);
    expect(SequencerTab.namesHistory('builder'), isFalse);
  });

  test('unknown sequencer tab queries do not force a tab', () {
    expect(SequencerTab.fromQuery(null), isNull);
    expect(SequencerTab.fromQuery('made-up'), isNull);
  });
}
