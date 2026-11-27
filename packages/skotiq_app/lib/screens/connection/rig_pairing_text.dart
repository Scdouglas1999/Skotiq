import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

/// A headless host has no Remote access screen to show a code on.
bool hostHasNoScreen(DiscoveredServer host) => host.hostMode == 'headless';

/// What a failed pairing with [host] means, in the words the connect flows
/// show.
String describeRigPairingFailure(
  RigPairingFailure failure,
  DiscoveredServer host,
) {
  final name = host.displayName;
  switch (failure.kind) {
    case RigPairingFailureKind.oneTapUnavailable:
      return '$name asks for a pairing code. Type the code it shows below.';
    case RigPairingFailureKind.invalidCode:
      return "That code doesn't match the one $name shows. Check it and "
          'try again.';
    case RigPairingFailureKind.expiredCode:
      return hostHasNoScreen(host)
          ? 'That code has expired or was already used. Press Get a new '
              'code and type the one $name makes.'
          : 'That code has expired or was already used. Start pairing '
              'again on $name and type the new code.';
    case RigPairingFailureKind.rateLimited:
      return '$name paused pairing after several wrong codes. Wait a '
          'minute and try again.';
    case RigPairingFailureKind.fingerprintMismatch:
      return 'The computer at ${host.host}:${host.webPort} is not the one '
          'listed. Nothing was sent to it. Search again.';
    case RigPairingFailureKind.unreachable:
      return "Can't reach $name at ${host.host}:${host.webPort}.";
    case RigPairingFailureKind.refused:
      return '$name refused the pairing: ${failure.message}';
  }
}

/// Where a headless host put the code it made, for the person who has to go
/// and read it: "home made a code, valid until 21:05. Read it from ...".
String describeCodeWhereabouts(
  String name,
  RemotePairingStartResult made, {
  required bool askedForCode,
}) {
  final until = ClockFormat.hm(made.expiresAt.toLocal());
  final lead = askedForCode
      ? '$name asks for a code before it links a computer. It made one, '
          'valid until $until.'
      : '$name made a code, valid until $until.';
  final delivery = made.delivery;
  if (delivery == null) return '$lead Read it on $name.';
  final places = [
    if (delivery.operatorFile)
      'the file ${delivery.operatorFileName} in its Skotiq data folder (its '
          'console names that folder when Skotiq starts)',
    if (delivery.console) 'its console',
  ];
  if (places.isEmpty) {
    return '$name made a code but could not save it anywhere you can read. '
        'Start Skotiq there with --pairing-print-codes, then get a new code.';
  }
  return '$lead Read it on $name from ${places.join(', or from ')}.';
}
