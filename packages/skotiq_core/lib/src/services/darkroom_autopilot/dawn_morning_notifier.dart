/// The morning notification: the one message a dawn job sends.
///
/// It goes out through [NotificationService.notify], which is the seam that
/// fans a message out to the unified [NotificationRouter] (and from there to
/// the phone through `SystemPushTransport`, the documented sole producer of
/// mobile pushes) as well as the legacy Discord/Pushover webhooks. Enqueuing a
/// push directly here would bypass the router, which is how the existing
/// "master ready" push became unroutable and unmutable; this path does not
/// repeat that.
///
/// **The gate is reported, never worked around.** `notificationsEnabled` and
/// `notifyOnSequenceComplete` are live delivery gates on
/// [NotificationEvent.sequenceComplete], the family the end of a night's
/// processing belongs to. When either is off the job records that the operator
/// turned it off and names the flag — it does not reroute through an ungated
/// event family to make the message arrive anyway.
///
/// **The tap opens the draft.** The message carries a deep-link payload naming
/// the recipe the pass saved, so the phone's route table lands the operator in
/// the Darkroom on the draft rather than on a dashboard they then have to
/// navigate out of. A night that rendered no draft carries no payload: a link
/// to a recipe that does not exist is worse than no link.
library;

import '../../models/notification/notification_categories.dart';
import '../../providers/settings_provider.dart';
import '../notification_service.dart';
import 'dawn_job_report.dart';

/// The payload prefix the phone routes a Darkroom draft tap by. Shared with
/// the mobile route table's `darkroom_draft` arm, which is the only consumer.
const String kDarkroomDraftPayloadType = 'darkroom_draft';

/// The tap payload for [report]'s draft, or null when the night produced none.
///
/// Names the FIRST master that saved a recipe AND rendered a draft from it.
/// "First" is the order the resolver produced the masters in, which is the same
/// order the report's own headline counts them in — a multi-filter night opens
/// on the filter the report leads with, and the Darkroom's own branch list
/// carries the rest.
///
/// A recipe saved without a rendered draft is deliberately not linked: the
/// engine refused those pixels, and the recipe would open onto the same
/// refusal.
String? draftDeepLinkFor(DawnJobReport report) {
  for (final master in report.masters) {
    final recipeId = master.recipeId;
    if (recipeId != null && master.hasDraft) {
      return '$kDarkroomDraftPayloadType:$recipeId';
    }
  }
  return null;
}

/// Sends the morning message for a finished dawn job.
abstract class DawnMorningNotifier {
  /// Announce [report]. Returns what happened, including the reason nothing
  /// was sent.
  Future<DawnNotificationDecision> announce(DawnJobReport report);
}

/// The production notifier: one [NotificationService.notify] call, gated by the
/// operator's own event flags.
class NotificationServiceDawnNotifier implements DawnMorningNotifier {
  final NotificationService _notifications;
  final AppSettingsState? Function() _settings;

  const NotificationServiceDawnNotifier({
    required NotificationService notifications,
    required AppSettingsState? Function() settings,
  }) : _notifications = notifications,
       _settings = settings;

  @override
  Future<DawnNotificationDecision> announce(DawnJobReport report) async {
    final settings = _settings();
    if (settings == null) {
      return const DawnNotificationDecision(
        sent: false,
        reason:
            'The notification settings have not loaded, so no gate could be '
            'read and nothing was sent.',
      );
    }
    if (!settings.notificationsEnabled) {
      return const DawnNotificationDecision(
        sent: false,
        reason:
            'Notifications are switched off in Settings, so the morning '
            'message was not sent.',
      );
    }
    if (!settings.notifyOnSequenceComplete) {
      return const DawnNotificationDecision(
        sent: false,
        reason:
            'The "Sequence Complete" event alert is switched off, and the end '
            'of the night\'s processing belongs to that family, so the '
            'morning message was not sent.',
      );
    }

    // `sent` states what LEFT THE PROCESS, never that a send was attempted.
    // This message is the only surface that lists the night's delivery
    // problems, so a morning where the routing row was off, the phone was not
    // paired, or the debounce swallowed it must not read as one where the
    // operator was told.
    final dispatch = await _notifications.notifyDetailed(
      event: NotificationEvent.sequenceComplete,
      title: report.headline,
      message: report.body,
      // The routing row the operator sees and can retune is the Darkroom's
      // own, not `custom` shared with every scripted notification node.
      routeAs: NotificationCategory.darkroomDraftReady,
      deepLink: draftDeepLinkFor(report),
    );
    return DawnNotificationDecision(
      sent: dispatch.anyDelivered,
      reason: dispatch.describe(),
    );
  }
}
