import 'package:flutter/material.dart';
import 'package:skotiq_app/screens/analytics/history/night_views/review_view.dart';

/// A night's review the way the night page shows it: the header actions over
/// the Report (or the Workbench).
class ReviewHost extends StatelessWidget {
  const ReviewHost(
      {super.key, required this.sessionId, this.workbench = false});

  final int sessionId;
  final bool workbench;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: NightReviewActions(
                sessionId: sessionId,
                workbench: workbench,
              ),
            ),
            Expanded(
              child:
                  NightReviewView(sessionId: sessionId, workbench: workbench),
            ),
          ],
        ),
      );
}
