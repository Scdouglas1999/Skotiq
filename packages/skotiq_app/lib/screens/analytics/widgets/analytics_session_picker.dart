import 'package:flutter/material.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../quick_capture_selection.dart';

/// The most sessions the picker lists, newest first.
const int kAnalyticsPickerSessionLimit = 60;

/// How Analytics names the session it reports on: the kit's [SessionPicker]
/// over the sessions on record, with the quick captures first when there are
/// any, and "Most recent" beside it once the operator has picked by hand.
///
/// Session and Science both choose with this, and both write the one
/// [analyticsSessionPickProvider], so a night reads the same on either tab.
class AnalyticsSessionPicker extends StatelessWidget {
  const AnalyticsSessionPicker({
    super.key,
    required this.sessions,
    required this.selectedId,
    required this.onSelected,
    this.offerQuickCaptures = false,
    this.onMostRecent,
  });

  /// The sessions on record, newest first.
  final List<ImagingSession> sessions;

  /// The session on screen, [kQuickCaptureSessionSelection], or null for none.
  final int? selectedId;

  final ValueChanged<int> onSelected;

  /// Whether to list [kQuickCaptureSessionSelection], the frames shot outside
  /// any session.
  final bool offerQuickCaptures;

  /// Goes back to the tab's own choice. Null hides the button.
  final VoidCallback? onMostRecent;

  /// What the picker lists for [sessions].
  static List<SessionPickerEntry<int>> entriesFor(
    List<ImagingSession> sessions, {
    bool offerQuickCaptures = false,
  }) =>
      [
        if (offerQuickCaptures)
          const SessionPickerEntry(
            value: kQuickCaptureSessionSelection,
            name: kQuickCaptureSessionLabel,
          ),
        for (final session in sessions.take(kAnalyticsPickerSessionLimit))
          SessionPickerEntry(
            value: session.id,
            name: session.name ?? 'Session ${session.id}',
            start: session.startTime,
            // Every capture, not the frames kept: the row's
            // `successful_exposures` ignores the grader.
            count: '${session.totalExposures} '
                '${session.totalExposures == 1 ? 'exposure' : 'exposures'}',
          ),
      ];

  @override
  Widget build(BuildContext context) {
    final picker = SessionPicker<int>(
      entries: entriesFor(sessions, offerQuickCaptures: offerQuickCaptures),
      value: selectedId,
      onChanged: onSelected,
    );
    final mostRecent = onMostRecent;
    return Row(
      children: [
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: FormRow.defaultLabelWidth +
                  FormRow.columnGap +
                  SessionPicker.maxFieldWidth,
            ),
            child: picker,
          ),
        ),
        if (mostRecent != null) ...[
          const SizedBox(width: SkotiqTokens.spaceSm),
          SkotiqButton(
            label: 'Most recent',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: mostRecent,
          ),
        ],
      ],
    );
  }
}
