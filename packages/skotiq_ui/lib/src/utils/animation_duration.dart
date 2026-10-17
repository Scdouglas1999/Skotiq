import 'package:flutter/widgets.dart';

/// [duration], or [Duration.zero] when the platform has asked for no
/// animation.
///
/// ## Why this exists
///
/// `MediaQueryData.disableAnimations` is an accessibility setting, not a
/// preference: a user who has turned animations off has usually done so because
/// motion makes them ill or because a screen reader's focus keeps landing on a
/// widget that is still moving. Honouring it is therefore all-or-nothing — a
/// transition that "only" runs for 120 ms is still motion on screen.
///
/// One function rather than the flag read inline at every animation site,
/// because the failure mode of the inline read is silent: the animation that
/// was added last simply does not honour the setting, and nothing about the
/// code says so. Every animated widget in the app routes its duration through
/// here, so the setting is a property of the app rather than of whichever
/// widget remembered.
///
/// ```dart
/// AnimatedContainer(
///   duration: animationDuration(context, SkotiqTokens.durationFast),
///   curve: SkotiqTokens.curveStandard,
///   ...
/// )
/// ```
///
/// A repeating animation cannot be shortened to nothing — a zero-length repeat
/// is an infinitely fast one — so a looping controller reads
/// [animationsDisabled] directly and does not start at all.
Duration animationDuration(BuildContext context, Duration duration) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;

/// Whether the platform has asked for no animation.
///
/// For the cases [animationDuration] cannot express: a repeating animation,
/// which must be refused outright rather than shortened, and a widget that
/// chooses a different (still) representation when motion is off.
bool animationsDisabled(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context);
