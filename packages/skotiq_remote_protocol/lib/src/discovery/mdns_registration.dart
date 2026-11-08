import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:nsd/nsd.dart';

/// mDNS / Bonjour / DNS-SD advertisement for a Skotiq headless server.
///
/// The UDP-broadcast beacon in `discovery.dart` is the legacy zero-conf channel
/// and is still emitted. mDNS is additive — it works on modern Wi-Fi APs where
/// client-to-client broadcast is blocked (most enterprise / Eero / mesh setups)
/// and on Tailscale / VPN segments where there's no broadcast domain at all.
///
/// The service is registered as `_skotiq._tcp` so the existing client-side
/// `discoverViaMdns` (which already calls `startDiscovery('_skotiq._tcp')`)
/// finds us without any extra wiring.
///
/// ### TXT record contract
///
/// The advertisement carries these keys so a mobile client can decide whether
/// to connect, which protocol to use, and which fingerprint to confirm against
/// the QR — all without an extra HTTP roundtrip:
///
/// - `version`           — server app version (e.g. `2.5.0`)
/// - `scheme`            — `http` or `https`; tells the client whether the
///                         server was started with `--tls` so the mDNS-only
///                         flow (no QR) still hits the right transport
/// - `fingerprint`       — same SHA-256 the server returns from `GET /api/info`
///                         (TLS-SPKI when TLS is active, token-derived
///                         otherwise). Lets a QR-paired client cross-check
///                         the discovered host before sending its bearer.
/// - `pairingSupported`  — `true` / `false`; gates whether the unpaired-client
///                         UX shows the "Pair this server" CTA
/// - `name`              — human-readable display name shown next to the host
///                         in the server picker. Duplicated in the Service
///                         `name` field for platforms that show it in the OS
///                         picker (iOS, macOS).
///
/// ### Failure model
///
/// `start()` is best-effort. If `nsd.register(...)` throws (no entitlement on
/// iOS, Avahi daemon not running on a stripped-down Linux box, Bonjour service
/// missing on a fresh Windows install), the registration is silently disabled
/// for this run after a warning callback to the caller's logger. The HTTP
/// server continues — UDP broadcast and manual entry remain available. This
/// matches the audit's "log a warning and continue, not fail to start" rule
/// for ancillary background services.
class MdnsServiceRegistration {
  static const String _serviceType = '_skotiq._tcp';

  /// Human-readable service name shown in OS-level pickers.
  final String name;

  /// TCP port the HTTP / WebSocket server is bound to.
  final int port;

  /// Pre-built TXT records. Keys MUST be ASCII printable, values are UTF-8
  /// encoded on the wire. See class docs for the canonical key list.
  final Map<String, String> txt;

  /// Optional warning sink. Invoked with a single-line human-readable message
  /// when registration cannot proceed. Lets the caller route the message
  /// through a structured logger without this package depending on
  /// skotiq_core.
  final void Function(String message)? onWarning;

  Registration? _registration;
  bool _started = false;

  MdnsServiceRegistration({
    required this.name,
    required this.port,
    required this.txt,
    this.onWarning,
  });

  /// `true` after [start] successfully registered the service. Stays false
  /// when registration was skipped because of a platform / permissions error.
  bool get isRegistered => _registration != null || _avahiPublisher != null;

  /// `avahi-publish-service` child on Linux, where `nsd` has no
  /// implementation. Held so [stop] can end it.
  Process? _avahiPublisher;

  /// Register the service with the local DNS-SD responder.
  ///
  /// Idempotent — repeated calls are a no-op. Logs and swallows
  /// platform-level errors (see class docs).
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final encodedTxt = <String, Uint8List?>{};
    for (final entry in txt.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) continue;
      // Why: the TXT-record spec (RFC 6763 §6.4) requires printable ASCII for
      // keys and forbids `=`. Drop anything that violates these so we never
      // hand the platform a payload it will reject as illegalArgument.
      if (key.contains('=') || _hasNonPrintableAscii(key)) {
        _emitWarning(
          'mDNS: dropping invalid TXT key "${entry.key}" (must be printable ASCII, no `=`)',
        );
        continue;
      }
      encodedTxt[key] = Uint8List.fromList(utf8.encode(entry.value));
    }

    if (Platform.isLinux) {
      await _startAvahi();
      return;
    }

    final service = Service(
      name: name,
      type: _serviceType,
      port: port,
      txt: encodedTxt.isEmpty ? null : encodedTxt,
    );

    try {
      _registration = await register(service);
      developer.log(
        'Registered mDNS service "$name" on port $port',
        name: 'MdnsServiceRegistration',
        level: 800,
      );
    } on NsdError catch (e, stackTrace) {
      // Why distinguished: NsdError carries an ErrorCause we can include in
      // the operator-facing warning so they know whether to install Bonjour /
      // enable Avahi (operationNotSupported, securityIssue) versus retry
      // (alreadyActive). We don't rethrow because mDNS is additive — UDP
      // broadcast and manual entry are still available.
      _emitWarning(
        'mDNS registration failed (${e.cause.name}): ${e.message} — '
        'falling back to UDP broadcast / manual entry. mDNS will be retried '
        'on next server restart.',
      );
      developer.log(
        'NsdError during register: $e\n$stackTrace',
        name: 'MdnsServiceRegistration',
        level: 1000,
      );
      _registration = null;
    } catch (e, stackTrace) {
      _emitWarning(
        'mDNS registration failed with unexpected error: $e — '
        'falling back to UDP broadcast / manual entry.',
      );
      developer.log(
        'Unexpected exception during register: $e\n$stackTrace',
        name: 'MdnsServiceRegistration',
        level: 1000,
      );
      _registration = null;
    }
  }

  /// Unregister the service. Safe to call even when [start] failed or was
  /// never called.
  Future<void> stop() async {
    final publisher = _avahiPublisher;
    _avahiPublisher = null;
    if (publisher != null) {
      // Closing stdin ends the wrapper shell, which ends the publisher.
      try {
        await publisher.stdin.close();
      } catch (e) {
        // The publisher may already have exited; kill() below still runs.
        developer.log(
          'closing the avahi publisher stdin failed: $e',
          name: 'MdnsRegistration',
          level: 500,
        );
      }
      publisher.kill();
      _started = false;
      return;
    }
    final reg = _registration;
    _registration = null;
    if (reg == null) {
      _started = false;
      return;
    }
    try {
      await unregister(reg);
      developer.log(
        'Unregistered mDNS service',
        name: 'MdnsServiceRegistration',
        level: 800,
      );
    } on NsdError catch (e, stackTrace) {
      // Why: shutdown path. The operator already issued SIGINT / closed the
      // GUI; surfacing an unregister failure to the exit code would mask the
      // intended outcome. Log loudly so a leak-pattern bug is still visible.
      developer.log(
        'NsdError during unregister: $e\n$stackTrace',
        name: 'MdnsServiceRegistration',
        level: 1000,
      );
    } catch (e, stackTrace) {
      developer.log(
        'Unexpected exception during unregister: $e\n$stackTrace',
        name: 'MdnsServiceRegistration',
        level: 1000,
      );
    } finally {
      _started = false;
    }
  }

  /// Linux: advertise through avahi-daemon with `avahi-publish-service`.
  ///
  /// The `nsd` plugin has no Linux implementation, so a Linux host was never
  /// visible over mDNS: every registration failed with MissingPluginException.
  /// Avahi runs on nearly every Linux desktop; when it or its tools are
  /// missing this logs once and the UDP beacon remains.
  ///
  /// The publisher runs under a shell that exits when its stdin closes, which
  /// happens when this process exits for any reason, so a crashed host never
  /// leaves an orphan advertising an address nobody answers on.
  Future<void> _startAvahi() async {
    final args = <String>[
      name,
      _serviceType,
      '$port',
      for (final entry in txt.entries)
        if (entry.key.isNotEmpty &&
            !entry.key.contains('=') &&
            !_hasNonPrintableAscii(entry.key))
          '${entry.key}=${entry.value}',
    ];
    final quoted = args.map(_shellQuote).join(' ');
    try {
      final process = await Process.start('/bin/sh', [
        '-c',
        'command -v avahi-publish-service >/dev/null 2>&1 || exit 127; '
            'avahi-publish-service $quoted >/dev/null 2>&1 & child=\$!; '
            'cat >/dev/null; kill \$child 2>/dev/null',
      ]);
      // Give a missing tool or a dead daemon a moment to show itself.
      final early = await process.exitCode
          .timeout(const Duration(milliseconds: 400), onTimeout: () => -1);
      if (early != -1) {
        _emitWarning(
          early == 127
              ? 'mDNS: avahi-publish-service is not installed, so this host '
                    'is advertised by UDP broadcast only.'
              : 'mDNS: avahi-publish-service exited ($early); this host is '
                    'advertised by UDP broadcast only.',
        );
        return;
      }
      _avahiPublisher = process;
      developer.log(
        'Advertising "$name" on port $port through avahi',
        name: 'MdnsServiceRegistration',
        level: 800,
      );
    } catch (e) {
      _emitWarning('mDNS: could not start avahi-publish-service: $e');
    }
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  void _emitWarning(String message) {
    final sink = onWarning;
    if (sink != null) {
      sink(message);
    } else {
      developer.log(message, name: 'MdnsServiceRegistration', level: 900);
    }
  }

  static bool _hasNonPrintableAscii(String value) {
    for (final code in value.codeUnits) {
      if (code < 0x20 || code > 0x7E) return true;
    }
    return false;
  }
}
