/// The ONE rule for "are these two notifications the same statement?".
///
/// ## Why this is shared rather than reimplemented per surface
///
/// One happening can reach the operator from more than one producer whose copy
/// differs only cosmetically (a trailing full stop, case, spacing). The router
/// de-duplicates what it sends and the toast overlay collapses what it shows,
/// so the rule lives here and every surface that asks "have I already said
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
