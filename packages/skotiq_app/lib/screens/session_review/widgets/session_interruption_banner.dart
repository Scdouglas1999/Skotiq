import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// States a post-session pass that a PROCESS EXIT cut off.
///
/// Sibling of [DarkroomPassBanner], and here for the same reason. That banner
/// covers a pass that reached an ending: `failed` or `cancelled` on its own
/// `darkroom_jobs` row. A pass the machine died inside reaches no ending at
/// all — the row is simply still `running` when the process stops existing —
/// so the open-time recovery is what discovers it, hours later, in
/// `beforeOpen`. What that recovery wrote went to the session's notes and a
/// `warning` Night Narrator event, and this screen renders neither: the
/// operator opened the night, saw the masters and the score, and had nothing
/// telling them the drafting, the night report and the delivery had been cut
/// off mid-run.
///
/// [notice] is the detector's own sentences, carried unchanged through
/// `SessionReviewState.interruptedPassNotice`. Nothing is added here — a
/// banner that re-worded them could only make this screen and the morning feed
/// disagree about one night.
class SessionInterruptionBanner extends StatelessWidget {
  const SessionInterruptionBanner({super.key, required this.notice});

  /// What the recovery said, or null when this session was not interrupted.
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final sentence = notice?.trim();
    if (sentence == null || sentence.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
      child: SkotiqBanner(
        key: const ValueKey('session_review_interruption_banner'),
        title: 'This session was interrupted',
        message: sentence,
        tone: BannerTone.warning,
      ),
    );
  }
}
