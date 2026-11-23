// A paused run whose step is still finishing reads as pausing on the shell
// bar and the phone's playback bar, so the operator waits before touching
// the rig.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/widgets/run_status/sequence_status_visuals.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  final l10n = SkotiqLocalizations(const Locale('en'));
  String label(SequenceExecutionState state, bool? pausedIdle) =>
      SequenceStatusVisuals.of(
        state,
        SkotiqColors.dark,
        l10n,
        pausedIdle: pausedIdle,
      ).label;

  test('a paused run reads as pausing until its step has finished', () {
    expect(
      label(SequenceExecutionState.paused, false),
      'Pausing: step finishing',
    );
    expect(label(SequenceExecutionState.paused, true), 'Paused');
    expect(label(SequenceExecutionState.paused, null), 'Paused');
    expect(
      label(SequenceExecutionState.running, false),
      label(SequenceExecutionState.running, null),
    );
  });
}
