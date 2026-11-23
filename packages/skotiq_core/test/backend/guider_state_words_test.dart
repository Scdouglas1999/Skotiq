// The guider status crosses the FFI as a typed GuiderActivity. The app gives
// each state the word test_fixtures/guider_state/words.json names (the words
// the native status carried before the field was typed, and what the headless
// API still sends), and reads every word back to the same guider state.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/backend/ffi_backend.dart';

const _fixturePath = '../../test_fixtures/guider_state/words.json';

String _variant(bridge.GuiderActivity activity) => switch (activity) {
  bridge.GuiderActivity_Disconnected() => 'Disconnected',
  bridge.GuiderActivity_Connected() => 'Connected',
  bridge.GuiderActivity_Stopped() => 'Stopped',
  bridge.GuiderActivity_Calibrating() => 'Calibrating',
  bridge.GuiderActivity_Guiding() => 'Guiding',
  bridge.GuiderActivity_Looping() => 'Looping',
  bridge.GuiderActivity_Paused() => 'Paused',
  bridge.GuiderActivity_Settling() => 'Settling',
  bridge.GuiderActivity_LostLock() => 'LostLock',
  bridge.GuiderActivity_Unknown() => 'Unknown',
};

bridge.GuiderActivity _activity(String variant, String word) =>
    switch (variant) {
      'Disconnected' => const bridge.GuiderActivity.disconnected(),
      'Connected' => const bridge.GuiderActivity.connected(),
      'Stopped' => const bridge.GuiderActivity.stopped(),
      'Calibrating' => const bridge.GuiderActivity.calibrating(),
      'Guiding' => const bridge.GuiderActivity.guiding(),
      'Looping' => const bridge.GuiderActivity.looping(),
      'Paused' => const bridge.GuiderActivity.paused(),
      'Settling' => const bridge.GuiderActivity.settling(),
      'LostLock' => const bridge.GuiderActivity.lostLock(),
      'Unknown' => bridge.GuiderActivity.unknown(word),
      _ => throw StateError(
        'a native guider state the test does not know: '
        '$variant',
      ),
    };

/// What each word read as before the field was typed (the status table).
const _stateOfWord = <String, Phd2State?>{
  'Disconnected': null,
  'Connected': Phd2State.stopped,
  'Stopped': Phd2State.stopped,
  'Calibrating': Phd2State.calibrating,
  'Guiding': Phd2State.guiding,
  'Looping': Phd2State.looping,
  'Paused': Phd2State.paused,
  'Settling': Phd2State.settling,
  'LostLock': Phd2State.lostLock,
  'GuidingPaused': null,
};

void main() {
  final fixture =
      jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
  final rows = (fixture['states'] as List).cast<Map<String, dynamic>>();

  test('every native guider state has its word', () {
    final variants = <String>{};
    for (final row in rows) {
      final variant = row['variant'] as String;
      final word = row['word'] as String;
      final activity = _activity(variant, word);
      expect(_variant(activity), variant);
      expect(guiderActivityWord(activity), word, reason: variant);
      variants.add(variant);
    }
    expect(variants, hasLength(10));
  });

  test('every word reads back to the guider state it read as before', () {
    for (final row in rows) {
      final word = row['word'] as String;
      expect(_stateOfWord.containsKey(word), isTrue, reason: word);
      expect(phd2StateFromGuiderWord(word), _stateOfWord[word], reason: word);
    }
  });

  test("PHD2's own Selected word is a guider state", () {
    expect(phd2StateFromGuiderWord('Selected'), Phd2State.selected);
    expect(phd2StateFromGuiderWord(null), isNull);
  });

  test('an AppState event reads through the same word table', () {
    // Before one table, an AppState of Connected or Settling read as unknown;
    // nothing on the native side sends GuidingEvent::AppState, so no host
    // ever carried those two words in one.
    for (final row in rows) {
      final word = row['word'] as String;
      expect(
        phd2StateAfterEvent(bridge.GuidingEvent.appState(state: word)),
        _stateOfWord[word] ?? Phd2State.unknown,
        reason: word,
      );
    }
  });
}
