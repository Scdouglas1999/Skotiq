/// The ONE rule for "are these two notifications the same statement?".
///
/// ## Why this is shared rather than reimplemented per surface
///
/// One happening reaches the operator from several producers whose copy differs
/// only cosmetically — a failed connect of the built-in guider is rendered both
/// by the Dart connect path via `ErrorService.log` and by the backend's error
/// event via `errorNotificationBridgeProvider`, one of them with a trailing
/// full stop. Not every surface goes through [NotificationRouter]: in-app
/// toasts are published directly through `UiNotificationNotifier.showError`.
/// So the rule lives here, and every surface that asks "have I already said
/// this?" calls it.
library;

final RegExp _whitespaceRun = RegExp(r'\s+');
final RegExp _trailingCosmetics = RegExp(r'[\s.,;:!…]+$');

/// Cosmetic-insensitive form of a rendered string, used ONLY as a
/// de-duplication key — never as the copy that is shown.
///
/// Trailing sentence punctuation, case and internal whitespace runs are
/// differences between PRODUCERS of one statement, never differences the
/// operator can act on.
///
/// `?` is deliberately NOT stripped: a question and a statement are different
/// notifications ("Park the mount" is a report; "Park the mount?" is a prompt).
String normalizeNotificationSignature(String value) => value
    .trim()
    .replaceAll(_whitespaceRun, ' ')
    .replaceAll(_trailingCosmetics, '')
    .toLowerCase();

/// The signature of one rendered notification: what the operator SEES, keyed
/// cosmetically-insensitively. [discriminator] separates notifications that
/// share words but not meaning — the severity/level, or a transport kind.
String notificationContentSignature({
  required String discriminator,
  required String title,
  required String body,
}) =>
    '$discriminator|${normalizeNotificationSignature(title)}'
    '|${normalizeNotificationSignature(body)}';
