import 'dart:io';

/// Classification of a host's network reachability tier, used by the QR /
/// pairing trust boundary and by reachability-badge UI.
///
/// The ordering is deliberately *not* a priority list — each tier is mutually
/// exclusive for a given host. See [TailnetDetector.classify].
enum HostReachabilityTier {
  /// `127.0.0.0/8`, `::1`, or the literal `localhost`. The server itself; a
  /// phone can never reach this, so the QR generator must not embed it.
  loopback,

  /// RFC1918 (`10/8`, `172.16/12`, `192.168/16`), RFC3927 link-local
  /// (`169.254/16`), IPv6 link-local (`fe80::/10`), generic IPv6 ULA
  /// (`fc00::/7` excluding the Tailscale block), or an mDNS `.local` name.
  /// Reachable only when the phone shares the broadcast/L2 domain.
  lan,

  /// A Tailscale tailnet address: IPv4 CGNAT `100.64.0.0/10` (the default
  /// MagicDNS `100.x.y.z` range) or IPv6 `fd7a:115c::/32`. Reachable from
  /// anywhere the device is logged into the same tailnet — the whole point of
  /// this feature.
  tailscale,

  /// A syntactically valid but globally-routable / public address. Refused by
  /// the fail-closed acceptance policy — a public host in a pairing QR almost
  /// certainly means the payload was tampered with.
  public,

  /// Not a parseable host at all (empty, malformed IPv4/IPv6, junk). Always
  /// refused.
  invalid,
}

/// Fail-closed detector for Tailscale ("tailnet") and other private-reach
/// addresses.
///
/// Why this exists as its own unit: the QR validator
/// (`isLocalNetworkHost`) and the reachability UI both need to answer two
/// distinct questions — "is this host acceptable to connect to at all?"
/// (fail-closed) and "*how* is it reachable — LAN vs tailnet?" (for the badge).
/// Open-coding the CIDR math in two places drifts; one such drift already
/// silently rejected Tailscale ranges. This
/// class is the single source of truth for both questions.
///
/// Fail-closed contract: [classify] returns [HostReachabilityTier.public] or
/// [HostReachabilityTier.invalid] for anything it does not positively
/// recognise as loopback / LAN / tailnet. [isAccepted] then refuses those two
/// tiers. There is no "unknown → allow" path — an address we cannot prove is
/// private is treated as public and rejected.
class TailnetDetector {
  const TailnetDetector._();

  /// Classify [host] into exactly one [HostReachabilityTier].
  ///
  /// Accepts bare IPv4 (`100.64.0.1`), IPv6 with optional brackets and
  /// zone-id (`[fe80::1%eth0]`), and mDNS `.local` names. Anything else that
  /// is not a parseable IP literal is [HostReachabilityTier.invalid] — we do
  /// NOT perform DNS resolution here (that would block and could be steered by
  /// a hostile resolver).
  static HostReachabilityTier classify(String host) {
    if (host.isEmpty) return HostReachabilityTier.invalid;
    final lower = host.toLowerCase();

    // mDNS / Bonjour names resolve on-link only. `localhost` is handled by the
    // IPv4 loopback branch below.
    if (lower == 'localhost') return HostReachabilityTier.loopback;
    if (lower.endsWith('.local')) return HostReachabilityTier.lan;

    final candidate = _stripIpv6Wrapping(lower);

    final ipv4 = _parseIpv4(candidate);
    if (ipv4 != null) {
      return _classifyIpv4(ipv4);
    }

    final parsed = InternetAddress.tryParse(candidate);
    if (parsed != null && parsed.type == InternetAddressType.IPv6) {
      return _classifyIpv6(parsed);
    }

    // Not a literal IP and not an mDNS name — we cannot prove it is private.
    return HostReachabilityTier.invalid;
  }

  /// `true` iff [host] is on a Tailscale tailnet (IPv4 CGNAT `100.64.0.0/10`
  /// or IPv6 `fd7a:115c::/32`).
  ///
  /// Note: this is IP-literal-only by design — it does NOT recognise MagicDNS
  /// `*.ts.net` names (those would need DNS resolution to classify by address,
  /// which [classify] deliberately refuses to do). When the question is "is
  /// this a tailnet *endpoint* the operator could reach off-site, including a
  /// MagicDNS name?", use [isTailscaleEndpoint] instead.
  static bool isTailscaleHost(String host) =>
      classify(host) == HostReachabilityTier.tailscale;

  /// The MagicDNS suffix Tailscale assigns to tailnet hostnames
  /// (`<machine>.<tailnet>.ts.net`). A bare host equal to the suffix itself
  /// (`.ts.net`) is not a real endpoint and is rejected.
  static const String magicDnsSuffix = '.ts.net';

  /// `true` iff [host] is a Tailscale *endpoint* the device can reach over the
  /// tailnet: either a tailnet IP literal (`100.64.0.0/10` / `fd7a:115c::/32`,
  /// per [isTailscaleHost]) OR a MagicDNS `*.ts.net` hostname.
  ///
  /// This is the single source of truth for "treat this connection as remote /
  /// tailnet-tier" across the backend (timeout selection), the network status
  /// indicator, the mobile reconnect-on-cellular gate, and the saved-server
  /// list. Open-coding the `.ts.net` suffix check separately from the IP-literal
  /// check is the exact drift this method exists to prevent: a MagicDNS session
  /// must get the relaxed remote timeouts and the "via Tailscale" badge, not be
  /// silently treated as LAN.
  ///
  /// Unlike [classify]/[isTailscaleHost] this performs no DNS resolution — it
  /// matches the MagicDNS suffix lexically, which is safe (a hostile resolver
  /// cannot forge the suffix) and non-blocking.
  static bool isTailscaleEndpoint(String host) {
    final lower = host.trim().toLowerCase();
    if (lower.isEmpty) return false;
    if (lower.endsWith(magicDnsSuffix) &&
        lower.length > magicDnsSuffix.length) {
      return true;
    }
    return isTailscaleHost(host);
  }

  /// Fail-closed acceptance for the QR / pairing trust boundary and for the
  /// `ts net` (tailnet) reachability path.
  ///
  /// Accepts loopback, LAN, and tailnet hosts. Refuses public and invalid
  /// hosts. This is the canonical predicate `isLocalNetworkHost` delegates to.
  static bool isAccepted(String host) {
    switch (classify(host)) {
      case HostReachabilityTier.loopback:
      case HostReachabilityTier.lan:
      case HostReachabilityTier.tailscale:
        return true;
      case HostReachabilityTier.public:
      case HostReachabilityTier.invalid:
        return false;
    }
  }

  /// `true` iff [address] (a resolved interface address) is a Tailscale
  /// tailnet address. Used by the desktop local-IP enumerator to surface the
  /// `100.x` interface as a distinct advertised host.
  static bool isTailscaleInterfaceAddress(InternetAddress address) {
    if (address.type == InternetAddressType.IPv4) {
      final parts = _parseIpv4(address.address);
      if (parts == null) return false;
      return _classifyIpv4(parts) == HostReachabilityTier.tailscale;
    }
    if (address.type == InternetAddressType.IPv6) {
      return _classifyIpv6(address) == HostReachabilityTier.tailscale;
    }
    return false;
  }

  static String _stripIpv6Wrapping(String value) {
    var candidate = value;
    if (candidate.startsWith('[') && candidate.endsWith(']')) {
      candidate = candidate.substring(1, candidate.length - 1);
    }
    final zoneIdx = candidate.indexOf('%');
    if (zoneIdx >= 0) {
      candidate = candidate.substring(0, zoneIdx);
    }
    return candidate;
  }

  static HostReachabilityTier _classifyIpv4(List<int> octets) {
    final a = octets[0];
    final b = octets[1];

    // 127.0.0.0/8 loopback.
    if (a == 127) return HostReachabilityTier.loopback;

    // 100.64.0.0/10 — RFC 6598 CGNAT, the default Tailscale MagicDNS range.
    // The /10 boundary is exact: the first 10 bits must match
    // `01100100 01xxxxxx`, i.e. `a == 100` AND `b` in [64, 127]. Widening to
    // `a == 100` alone would leak the 16M public IPs in 100.0.0.0/8 that sit
    // below the CGNAT block.
    if (a == 100 && b >= 64 && b <= 127) {
      return HostReachabilityTier.tailscale;
    }

    // RFC1918 private ranges.
    if (a == 10) return HostReachabilityTier.lan; // 10.0.0.0/8
    if (a == 172 && b >= 16 && b <= 31) {
      return HostReachabilityTier.lan; // 172.16.0.0/12
    }
    if (a == 192 && b == 168) return HostReachabilityTier.lan; // 192.168.0.0/16

    // 169.254.0.0/16 link-local.
    if (a == 169 && b == 254) return HostReachabilityTier.lan;

    return HostReachabilityTier.public;
  }

  static HostReachabilityTier _classifyIpv6(InternetAddress parsed) {
    if (parsed.isLoopback) return HostReachabilityTier.loopback;
    final raw = parsed.rawAddress;
    if (raw.length < 16) return HostReachabilityTier.invalid;

    // Tailscale issues each tailnet a /48 inside fd7a:115c::/32. We classify
    // that as tailnet (not generic LAN ULA) so the reachability UI can label
    // it "via Tailscale". The /32 prefix is fd 7a 11 5c.
    if (raw[0] == 0xFD && raw[1] == 0x7A && raw[2] == 0x11 && raw[3] == 0x5C) {
      return HostReachabilityTier.tailscale;
    }

    // fe80::/10 link-local — first byte 0xFE, top two bits of second byte 10.
    if (raw[0] == 0xFE && (raw[1] & 0xC0) == 0x80) {
      return HostReachabilityTier.lan;
    }

    // fc00::/7 generic Unique Local Addresses (RFC 4193): first byte 0xFC or
    // 0xFD. (The Tailscale /32 above is a subset of fd00::/8 but matched
    // first so it lands in the tailnet tier.)
    if (raw[0] == 0xFC || raw[0] == 0xFD) {
      return HostReachabilityTier.lan;
    }

    return HostReachabilityTier.public;
  }

  static List<int>? _parseIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return null;
    final out = <int>[];
    for (final part in parts) {
      if (part.isEmpty) return null;
      final n = int.tryParse(part);
      if (n == null || n < 0 || n > 255) return null;
      out.add(n);
    }
    return out;
  }
}
