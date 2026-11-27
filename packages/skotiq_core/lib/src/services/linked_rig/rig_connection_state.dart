import 'package:flutter/foundation.dart' show immutable;
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import 'rig_pairing_service.dart';

/// What the connect flow is doing while [RigConnectState.busy].
sealed class ConnectActivity {
  const ConnectActivity();
}

/// Looking for an imaging computer; [status] is the discovery's own report.
final class ConnectDiscovering extends ConnectActivity {
  const ConnectDiscovering([this.status]);

  /// Null before discovery has reported anything.
  final String? status;
}

/// Opening a link to [label] (a computer's name or an address).
final class ConnectLinking extends ConnectActivity {
  const ConnectLinking(this.label);
  final String label;
}

/// Sending the pairing code to [host]:[port].
final class ConnectPairing extends ConnectActivity {
  const ConnectPairing(this.host, this.port);
  final String host;
  final int port;
}

/// Opening the tunnel through a relay.
final class ConnectViaRelay extends ConnectActivity {
  const ConnectViaRelay();
}

/// Linking to the computer a scanned QR code names.
final class ConnectViaQr extends ConnectActivity {
  const ConnectViaQr();
}

/// Why the last connect did not link, in terms the connection screen words.
sealed class ConnectProblem {
  const ConnectProblem();
}

/// The host answered `/api/info` with a reason this device cannot link to it.
/// [mismatchedHost] is set when it runs another release, so the screen can
/// offer to update one side.
final class ConnectHostProblem extends ConnectProblem {
  const ConnectHostProblem(this.problem, {this.mismatchedHost});
  final LinkProblem problem;
  final DiscoveredServer? mismatchedHost;
}

/// Pairing with [host] failed.
final class ConnectPairingFailed extends ConnectProblem {
  const ConnectPairingFailed(this.failure, this.host);
  final RigPairingFailure failure;
  final DiscoveredServer host;
}

/// One-tap pairing reached a host whose identity is not the one trusted.
final class ConnectOneTapIdentity extends ConnectProblem {
  const ConnectOneTapIdentity(this.failure);
  final RigPairingFailure failure;
}

/// The host refused this phone's token: its pairings were reset.
final class ConnectForgotten extends ConnectProblem {
  const ConnectForgotten(this.name);
  final String name;
}

/// The host did not take this phone's session.
final class ConnectNoSession extends ConnectProblem {
  const ConnectNoSession(this.host, this.port, {required this.tokenMissing});
  final String host;
  final int port;

  /// The host asks for a token and this phone had none.
  final bool tokenMissing;
}

/// The connect ended on an exception.
final class ConnectFailedWith extends ConnectProblem {
  const ConnectFailedWith(this.error);
  final Object error;
}

/// No imaging computer answered the search.
final class ConnectNothingFound extends ConnectProblem {
  const ConnectNothingFound();
}

/// The search itself failed.
final class ConnectDiscoveryFailed extends ConnectProblem {
  const ConnectDiscoveryFailed(this.error);
  final Object error;
}

/// The session's link stayed down past the grace period.
final class ConnectSessionLost extends ConnectProblem {
  const ConnectSessionLost();
}

/// The session was lost but the backend could not be detached yet.
final class ConnectLostStillSettling extends ConnectProblem {
  const ConnectLostStillSettling();
}

/// "Look around" could not leave the current host.
final class ConnectCannotLeave extends ConnectProblem {
  const ConnectCannotLeave(this.error);
  final Object error;
}

/// The connection screen's dialogs had no navigator yet.
final class ConnectUiNotReady extends ConnectProblem {
  const ConnectUiNotReady();
}

/// The relay appliance id is not `xxxx-xxxx-xxxx`.
final class ConnectBadApplianceId extends ConnectProblem {
  const ConnectBadApplianceId();
}

/// The relay URL did not parse.
final class ConnectBadRelayUrl extends ConnectProblem {
  const ConnectBadRelayUrl(this.error);
  final Object error;
}

/// The relay answered and refused the tunnel.
final class ConnectRelayRefused extends ConnectProblem {
  const ConnectRelayRefused(this.code, this.message);
  final String code;
  final String message;
}

/// The relay did not answer.
final class ConnectRelayUnreachable extends ConnectProblem {
  const ConnectRelayUnreachable(this.error);
  final Object error;
}

/// The relay dialog was left with an empty field.
final class ConnectRelayFieldsMissing extends ConnectProblem {
  const ConnectRelayFieldsMissing();
}

/// The QR scanner could not run.
final class ConnectScannerFailed extends ConnectProblem {
  const ConnectScannerFailed(this.error);
  final Object error;
}

/// The host answering is not the one the QR code names.
final class ConnectQrIdentity extends ConnectProblem {
  const ConnectQrIdentity();
}

/// The address field was empty.
final class ConnectAddressMissing extends ConnectProblem {
  const ConnectAddressMissing();
}

/// The typed address did not parse; [message] says why.
final class ConnectAddressInvalid extends ConnectProblem {
  const ConnectAddressInvalid(this.message);
  final String message;
}

/// What the phone's connection screen shows.
@immutable
class RigConnectState {
  const RigConnectState({
    this.connected,
    this.busy = false,
    this.activity,
    this.problem,
    this.unpairedHost,
    this.skipped = false,
    this.manualEntryOpen = false,
    this.stale = false,
  });

  /// The rig this phone is linked to; null while not linked.
  final DiscoveredServer? connected;

  /// A search or connect is running; the screen shows [activity].
  final bool busy;

  /// What is being tried; null when nothing is.
  final ConnectActivity? activity;

  /// Why the last attempt did not link; null when nothing went wrong.
  final ConnectProblem? problem;

  /// The computer the last connect found but did not pair with because the
  /// pairing dialog was closed; the screen offers it again.
  final DiscoveredServer? unpairedHost;

  /// The operator chose to look around without a rig.
  final bool skipped;

  /// The address form is open: the operator is typing.
  final bool manualEntryOpen;

  /// The link is down and the backend is trying to restore it.
  final bool stale;

  /// The host the last connect reached but cannot link to because it runs
  /// another release.
  DiscoveredServer? get mismatchedHost => switch (problem) {
    ConnectHostProblem(:final mismatchedHost) => mismatchedHost,
    _ => null,
  };

  RigConnectState copyWith({
    DiscoveredServer? Function()? connected,
    bool? busy,
    ConnectActivity? Function()? activity,
    ConnectProblem? Function()? problem,
    DiscoveredServer? Function()? unpairedHost,
    bool? skipped,
    bool? manualEntryOpen,
    bool? stale,
  }) => RigConnectState(
    connected: connected == null ? this.connected : connected(),
    busy: busy ?? this.busy,
    activity: activity == null ? this.activity : activity(),
    problem: problem == null ? this.problem : problem(),
    unpairedHost: unpairedHost == null ? this.unpairedHost : unpairedHost(),
    skipped: skipped ?? this.skipped,
    manualEntryOpen: manualEntryOpen ?? this.manualEntryOpen,
    stale: stale ?? this.stale,
  );
}
