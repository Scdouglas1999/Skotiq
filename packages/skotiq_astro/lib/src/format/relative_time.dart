/// How long ago something happened, as text.
library;

/// How much room the text may take.
enum RelativeTimeStyle {
  /// `5m ago`, `3h ago`, `2d ago`, `4mo ago`, `1y ago`.
  compact,

  /// `5 minutes ago`, `1 hour ago`, `2 days ago`, `4 months ago`.
  words,
}

abstract final class RelativeTime {
  /// How long before [now] (default: the device clock) [then] was.
  ///
  /// Anything under a minute, and a [then] in the future (clock skew), reads
  /// `just now`: a count of seconds is stale by the time it is read, and a
  /// negative age is never true.
  static String ago(
    DateTime then, {
    DateTime? now,
    RelativeTimeStyle style = RelativeTimeStyle.compact,
  }) => agoFor((now ?? DateTime.now()).difference(then), style: style);

  /// [ago] for an age already measured.
  static String agoFor(
    Duration age, {
    RelativeTimeStyle style = RelativeTimeStyle.compact,
  }) {
    if (age.inSeconds < 60) return 'just now';
    final (count, short, long) = _largestUnit(age);
    return switch (style) {
      RelativeTimeStyle.compact => '$count$short ago',
      RelativeTimeStyle.words => '$count $long${count == 1 ? '' : 's'} ago',
    };
  }

  /// An age without the "ago": `45s`, `5m`, `3h`, `2d`. A negative age reads
  /// `0s`.
  static String age(Duration age) {
    if (age.isNegative || age.inSeconds < 1) return '0s';
    if (age.inSeconds < 60) return '${age.inSeconds}s';
    final (count, short, _) = _largestUnit(age);
    return '$count$short';
  }

  static (int, String, String) _largestUnit(Duration age) {
    if (age.inMinutes < 60) return (age.inMinutes, 'm', 'minute');
    if (age.inHours < 24) return (age.inHours, 'h', 'hour');
    if (age.inDays < 30) return (age.inDays, 'd', 'day');
    if (age.inDays < 365) return (age.inDays ~/ 30, 'mo', 'month');
    return (age.inDays ~/ 365, 'y', 'year');
  }
}
