import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/services.dart';

import '../services/mobile_pairing_service.dart';

/// What the connection screen's progress card says while [activity] runs;
/// empty when nothing is being tried.
String connectActivityText(ConnectActivity? activity) => switch (activity) {
  null => '',
  ConnectDiscovering(status: null) => 'Looking for it on this Wi-Fi…',
  ConnectDiscovering(:final status?) => _discoveryStatusText(status),
  ConnectLinking(:final label) => 'Connecting to $label...',
  ConnectPairing(:final host, :final port) => 'Pairing with $host:$port...',
  ConnectViaRelay() => 'Connecting via relay...',
  ConnectViaQr() => 'Connecting via QR code...',
};

/// The discovery's progress in the phone's words: the methods it tries are
/// its business, where it is looking is the operator's.
String _discoveryStatusText(String status) {
  if (status.startsWith('Checking last server')) {
    return 'Trying the computer this phone used last…';
  }
  if (status.contains('broadcast') || status.contains('mDNS')) {
    return 'Looking for it on this Wi-Fi…';
  }
  return status;
}

/// Why the last connect did not link, as the connection screen says it.
String connectProblemText(ConnectProblem problem) => switch (problem) {
  ConnectHostProblem(:final problem) => problem.message,
  ConnectPairingFailed(:final failure, :final host) => pairingFailureText(
    failure,
    host,
  ),
  ConnectOneTapIdentity(:final failure) => failure.message,
  ConnectForgotten(:final name) =>
    'The imaging computer "$name" no longer knows this phone. Pair again.',
  ConnectNoSession(:final host, :final port, :final tokenMissing) =>
    'Could not connect to $host:$port\n\nServer may be offline, or this '
        'device is not authorized.'
        '${tokenMissing ? '\n\nThis host requires an access token or paired-device QR code.' : ''}',
  ConnectFailedWith(:final error) =>
    'Connection error: ${userFacingError(error)}',
  ConnectNothingFound() =>
    'No imaging computer answered on this Wi-Fi. Check that '
        'Skotiq is open on it and that both are on the same network, '
        'then scan its QR code or enter its address. Away from home, '
        'use Tailscale or a relay below. If it still is not found, '
        'its firewall may be blocking UDP 45679 and TCP 8080.',
  ConnectDiscoveryFailed(:final error) =>
    'Discovery failed: $error\n\nTry entering the IP address manually or '
        'scan QR code.',
  ConnectSessionLost() =>
    'Connection to server lost. Retrying automatically — '
        'or reconnect below.',
  ConnectLostStillSettling() =>
    'Connection was lost, but local sequence startup '
        'is still settling. Wait a moment, then disconnect.',
  ConnectCannotLeave(:final error) => 'Cannot leave this host yet: $error',
  ConnectUiNotReady() =>
    'Connection UI is not ready yet. Try again in a moment.',
  ConnectBadApplianceId() => 'Appliance id must look like xxxx-xxxx-xxxx.',
  ConnectBadRelayUrl(:final error) => 'Invalid relay URL: $error',
  ConnectRelayRefused(:final code, :final message) =>
    'Relay refused the connection ($code): $message',
  ConnectRelayUnreachable(:final error) => 'Could not reach the relay: $error',
  ConnectRelayFieldsMissing() => 'Enter both a relay URL and an appliance id.',
  ConnectScannerFailed(:final error) => 'QR scanner failed: $error',
  ConnectQrIdentity() =>
    'Server fingerprint does not match the QR code. Refusing to connect.',
  ConnectAddressMissing() => 'Please enter a host name or IP address',
  ConnectAddressInvalid(:final message) => message,
};
