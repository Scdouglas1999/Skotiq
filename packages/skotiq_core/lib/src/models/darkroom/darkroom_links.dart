/// Where Darkroom notifications take the operator.
///
/// A notification carries a `type[:arg]` payload; the phone and the desktop
/// toast both turn it into an app route with [darkroomRouteForPayload], so a
/// tap lands on the same screen on either.
library;

/// A target's page in the Darkroom; the argument is the target name.
const String kDarkroomTargetPayloadType = 'darkroom_target';

/// A target's framing check; the argument is the target name.
const String kDarkroomFramingPayloadType = 'darkroom_framing';

/// The Darkroom's Activity tab.
const String kDarkroomActivityPayloadType = 'darkroom_activity';

/// The Darkroom route for one target.
String darkroomTargetRoute(String target) =>
    '/darkroom?tab=targets&target=${Uri.encodeQueryComponent(target)}';

/// The Darkroom route for a target's framing check.
String darkroomFramingRoute(String target) =>
    '${darkroomTargetRoute(target)}&view=framing';

/// The Darkroom's Activity tab.
const String darkroomActivityRoute = '/darkroom?tab=activity';

/// The payload that opens [target].
String darkroomTargetPayload(String target) =>
    '$kDarkroomTargetPayloadType:$target';

/// The payload that opens [target]'s framing check.
String darkroomFramingPayload(String target) =>
    '$kDarkroomFramingPayloadType:$target';

/// The route a Darkroom payload opens, or null when [payload] is not one.
String? darkroomRouteForPayload(String payload) {
  final split = payload.indexOf(':');
  final type = split < 0 ? payload : payload.substring(0, split);
  final arg = split < 0 ? null : payload.substring(split + 1);
  final named = arg != null && arg.isNotEmpty;
  switch (type) {
    case kDarkroomTargetPayloadType:
      return named ? darkroomTargetRoute(arg) : darkroomActivityRoute;
    case kDarkroomFramingPayloadType:
      return named ? darkroomFramingRoute(arg) : darkroomActivityRoute;
    case kDarkroomActivityPayloadType:
      return darkroomActivityRoute;
  }
  return null;
}
