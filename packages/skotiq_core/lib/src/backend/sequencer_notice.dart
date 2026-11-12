import 'package:skotiq_bridge/skotiq_bridge.dart' show SequencerNotice;

import '../models/backend/event_types.dart';

/// Key of the notice in a sequencer `DecisionLogged` or `Error` event's data.
/// The host's sequencer marks a happening it carries on through and tells the
/// operator about once: the decision row raises the notification, and the
/// Warning with the same notice is the line in the run's warnings.
const String kSequencerNoticeKey = 'notice';

extension SequencerNoticeWire on SequencerNotice {
  /// The value of the event's `notice` field.
  String get wireName => switch (this) {
    SequencerNotice.autofocusContinued => 'autofocus_continued',
    SequencerNotice.rejectStreak => 'reject_streak',
    SequencerNotice.problemNoticed => 'problem_noticed',
  };
}

/// The notice named [wireName], or null for none.
SequencerNotice? sequencerNoticeFromWire(Object? wireName) {
  for (final notice in SequencerNotice.values) {
    if (notice.wireName == wireName) return notice;
  }
  return null;
}

/// The notice a sequencer decision row or Warning carries, or null when it
/// carries none.
SequencerNotice? sequencerNoticeOf(SkotiqEvent event) {
  if (event.category != EventCategory.sequencer) return null;
  return sequencerNoticeFromWire(event.data[kSequencerNoticeKey]) ??
      _noticeFromOlderHost(event);
}

/// A host from before the `notice` field marks nothing; its rows and Warnings
/// are known by the words it wrote, which are fixed for those builds.
SequencerNotice? _noticeFromOlderHost(SkotiqEvent event) {
  switch (event.eventType) {
    case 'DecisionLogged':
      if (event.data['category'] != 'system_event') return null;
      return _olderHostSummaries[event.data['summary']];
    case 'Error':
      if (event.severity != EventSeverity.warning) return null;
      final message = event.data['message'];
      if (message is! String) return null;
      for (final MapEntry(key: sentence, value: notice)
          in _olderHostWarningSentences.entries) {
        if (message.contains(sentence)) return notice;
      }
  }
  return null;
}

const Map<String, SequencerNotice> _olderHostSummaries = {
  'Autofocus failed — continuing with last-good focus':
      SequencerNotice.autofocusContinued,
  'Frames rejected in a row — the run continues': SequencerNotice.rejectStreak,
  'Problem noticed — the run continues': SequencerNotice.problemNoticed,
};

const Map<String, SequencerNotice> _olderHostWarningSentences = {
  'The run continues. To have problems like this stop the run instead, turn '
          'on Stop the run for quality problems in Settings > Sequencer.':
      SequencerNotice.problemNoticed,
  'and imaging continues on the last-good focus.':
      SequencerNotice.autofocusContinued,
  'Imaging continues, but check focus before trusting these frames.':
      SequencerNotice.autofocusContinued,
  'The run continues and every frame is kept; rejects are in the Reject '
          'folder.':
      SequencerNotice.rejectStreak,
};
