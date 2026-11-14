import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

import 'discovery.dart';
import 'enhanced_discovery.dart';
import 'network_uri.dart';
import 'link_version.dart';
import 'wire/routes/system_api.dart';

/// The DNS-SD service type every Skotiq host registers (GUI and headless).
const String skotiqMdnsServiceType = '_skotiq._tcp';

/// Finds imaging computers on the local network for a desktop that wants to
/// link to one.
///
/// Three sources run side by side, and a host shows up as soon as any of them
/// finds it:
///
/// * mDNS `_skotiq._tcp`. On Linux this speaks multicast DNS directly through
///   `multicast_dns`, because the `nsd` plugin the phone uses has no Linux
///   implementation (a Linux desktop found nothing over mDNS before). On
///   Windows and macOS it uses `nsd`, which goes through the system responder.
/// * The UDP probe on port 45679, for networks where multicast is filtered.
/// * `/api/info` on each candidate, which supplies the computer name, version,
///   fingerprint and pairing policy shown in the list.
class RigDiscovery {
  RigDiscovery._();

  /// Browse for [duration], emitting the full list each time it changes.
  ///
  /// The stream closes when the browse ends. Hosts are keyed by fingerprint
  /// when they report one, else by address, so a host found by both mDNS and
  /// UDP appears once.
  static Stream<List<DiscoveredServer>> browse({
    Duration duration = const Duration(seconds: 6),
    Duration infoTimeout = const Duration(seconds: 3),
  }) {
    final controller = StreamController<List<DiscoveredServer>>();
    final found = <String, DiscoveredServer>{};
    final pending = <Future<void>>[];
    final seenSeeds = <String>{};

    void publish() {
      if (controller.isClosed) return;
      final list = found.values.toList()
        ..sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );
      controller.add(List.unmodifiable(list));
    }

    void offer(DiscoveredServer seed) {
      final seedKey = '${seed.host}:${seed.webPort}';
      if (!seenSeeds.add(seedKey)) return;
      pending.add(() async {
        final enriched = await fetchInfo(seed, timeout: infoTimeout);
        // A seed /api/info never answered for is still listed: the operator
        // can see it and try, and the pairing step reports what goes wrong.
        final server = enriched ?? seed;
        final key = _identityKey(server);
        final existing = found[key];
        found[key] = existing == null ? server : _preferred(existing, server);
        publish();
      }());
    }

    Future<void> run() async {
      final sources = <Future<void>>[
        _browseMdns(duration, offer),
        _browseUdp(duration, offer),
      ];
      await Future.wait(sources);
      await Future.wait(pending);
      publish();
      await controller.close();
    }

    controller.onListen = () => unawaited(run());
    return controller.stream;
  }

  /// `GET /api/info` on [seed] and merge what it says. Null when the host did
  /// not answer with a Skotiq info document.
  static Future<DiscoveredServer?> fetchInfo(
    DiscoveredServer seed, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final response = await http
          .get(
            buildSkotiqServerUri(
              scheme: seed.scheme,
              host: seed.host,
              port: seed.webPort,
              pathAndQuery: SystemApi.info.route.path,
            ),
            headers: {LinkVersion.header: skotiqRelease},
          )
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['fingerprint'] is! String && decoded['version'] is! String) {
        return null;
      }
      return EnhancedSkotiqDiscovery.mergeServerInfo(seed, decoded);
    } catch (e) {
      developer.log(
        '/api/info failed for ${seed.host}:${seed.webPort}: $e',
        name: 'RigDiscovery',
        level: 500,
      );
      return null;
    }
  }

  /// The manual-address path: ask [host]:[port] who it is. Null when nothing
  /// that looks like Skotiq answered.
  static Future<DiscoveredServer?> probeAddress(
    String host,
    int port, {
    String scheme = 'http',
    Duration timeout = const Duration(seconds: 5),
  }) {
    return fetchInfo(
      DiscoveredServer(host: host, webPort: port, name: host, scheme: scheme),
      timeout: timeout,
    );
  }

  static String _identityKey(DiscoveredServer server) {
    final fingerprint = server.fingerprint;
    if (fingerprint != null && fingerprint.isNotEmpty) {
      return 'fp:${fingerprint.toLowerCase()}:${server.webPort}';
    }
    return 'addr:${server.host}:${server.webPort}';
  }

  /// Two sightings of one host: keep the one with an IPv4 address and the
  /// richer identity.
  static DiscoveredServer _preferred(DiscoveredServer a, DiscoveredServer b) {
    bool isV4(DiscoveredServer s) =>
        InternetAddress.tryParse(s.host)?.type == InternetAddressType.IPv4;
    final base = isV4(a) || !isV4(b) ? a : b;
    final other = identical(base, a) ? b : a;
    return base.copyWith(
      hostName: base.hostName ?? other.hostName,
      platform: base.platform ?? other.platform,
      hostMode: base.hostMode ?? other.hostMode,
    );
  }

  static Future<void> _browseUdp(
    Duration duration,
    void Function(DiscoveredServer) offer,
  ) async {
    try {
      final timeout = duration < const Duration(seconds: 3)
          ? duration
          : const Duration(seconds: 3);
      final servers = await SkotiqDiscovery.discoverServers(timeout: timeout);
      servers.forEach(offer);
    } catch (e) {
      developer.log('UDP browse failed: $e', name: 'RigDiscovery', level: 900);
    }
  }

  static Future<void> _browseMdns(
    Duration duration,
    void Function(DiscoveredServer) offer,
  ) async {
    if (Platform.isLinux) {
      await browseMulticastDns(duration: duration, onFound: offer);
      return;
    }
    try {
      final servers = await EnhancedSkotiqDiscovery.discoverViaMdns(
        timeout: duration,
      );
      servers.forEach(offer);
    } catch (e) {
      developer.log('nsd browse failed: $e', name: 'RigDiscovery', level: 900);
    }
  }

  /// Browse `_skotiq._tcp.local` with a plain multicast DNS client.
  ///
  /// Public for tests and for platforms without a system responder plugin.
  /// [clientFactory] lets a test substitute the client.
  static Future<void> browseMulticastDns({
    required Duration duration,
    required void Function(DiscoveredServer) onFound,
    MDnsClient Function()? clientFactory,
  }) async {
    final client = (clientFactory ?? MDnsClient.new)();
    try {
      // A query that cannot be sent (no route on this interface) is reported
      // on the socket's stream, not thrown by lookup().
      await client.start(
        onError: (Object e) => developer.log(
          'mDNS socket error: $e',
          name: 'RigDiscovery',
          level: 900,
        ),
      );
    } catch (e) {
      developer.log(
        'mDNS client could not start: $e',
        name: 'RigDiscovery',
        level: 900,
      );
      return;
    }
    final resolutions = <Future<void>>[];
    try {
      final seen = <String>{};
      // A single query is easy to lose while the group membership is still
      // settling (seen on the first browse after start), so ask in rounds.
      final deadline = DateTime.now().add(duration);
      while (true) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) break;
        final round = remaining < const Duration(seconds: 2)
            ? remaining
            : const Duration(seconds: 2);
        await for (final ptr
            in client
                .lookup<PtrResourceRecord>(
                  ResourceRecordQuery.serverPointer(
                    '$skotiqMdnsServiceType.local',
                  ),
                  timeout: round,
                )
                .handleError((Object e) {
                  developer.log('mDNS PTR lookup: $e', name: 'RigDiscovery');
                })) {
          if (!seen.add(ptr.domainName)) continue;
          resolutions.add(_resolveInstance(client, ptr.domainName, onFound));
        }
      }
      await Future.wait(resolutions);
    } catch (e) {
      developer.log('mDNS browse failed: $e', name: 'RigDiscovery', level: 900);
    } finally {
      client.stop();
    }
  }

  static Future<void> _resolveInstance(
    MDnsClient client,
    String instance,
    void Function(DiscoveredServer) onFound,
  ) async {
    const step = Duration(seconds: 2);
    try {
      final txt = <String, String>{};
      await for (final record in client.lookup<TxtResourceRecord>(
        ResourceRecordQuery.text(instance),
        timeout: step,
      )) {
        txt.addAll(parseTxtRecord(record.text));
        break;
      }
      await for (final srv in client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(instance),
        timeout: step,
      )) {
        final target = srv.target;
        final computer = mdnsTargetComputerName(target);
        final addresses = <InternetAddress>[];
        await for (final ip in client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(target),
          timeout: const Duration(milliseconds: 1200),
        )) {
          addresses.add(ip.address);
        }
        final address = await pickReachableAddress(addresses);
        if (address != null) {
          final scheme = (txt['scheme'] ?? 'http').toLowerCase();
          onFound(
            DiscoveredServer(
              host: address.address,
              webPort: srv.port,
              name: txt['name'] ?? instance.split('.').first,
              version: txt['version'],
              scheme: scheme == 'https' ? 'https' : 'http',
              fingerprint: _nonEmpty(txt['fingerprint']),
              pairingSupported: txt['pairingSupported'] == 'true',
              hostName: txt['hostName'] ?? computer,
              hostMode: txt['hostMode'],
            ),
          );
        }
        break;
      }
    } catch (e) {
      developer.log(
        'mDNS resolve of $instance failed: $e',
        name: 'RigDiscovery',
        level: 500,
      );
    }
  }

  /// A host with several interfaces (Docker bridges, a VPN, a second NIC)
  /// answers with an A record for each. Prefer one on a subnet this computer
  /// shares, then any private address, then the first.
  static Future<InternetAddress?> pickReachableAddress(
    List<InternetAddress> candidates, {
    Future<List<InternetAddress>> Function()? localAddresses,
  }) async {
    if (candidates.isEmpty) return null;
    final locals = await (localAddresses ?? _localIpv4)();
    bool sameSubnet(InternetAddress a) {
      final raw = a.rawAddress;
      return locals.any((l) {
        final lr = l.rawAddress;
        return lr.length == 4 &&
            raw.length == 4 &&
            lr[0] == raw[0] &&
            lr[1] == raw[1] &&
            lr[2] == raw[2];
      });
    }

    for (final a in candidates) {
      if (sameSubnet(a)) return a;
    }
    for (final a in candidates) {
      final raw = a.rawAddress;
      if (raw.length == 4 &&
          (raw[0] == 10 ||
              (raw[0] == 192 && raw[1] == 168) ||
              (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31))) {
        return a;
      }
    }
    return candidates.first;
  }

  static Future<List<InternetAddress>> _localIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      return [
        for (final i in interfaces)
          // Container and VPN bridges share a subnet with nothing on the LAN.
          if (!i.name.startsWith('docker') &&
              !i.name.startsWith('veth') &&
              !i.name.startsWith('br-'))
            ...i.addresses,
      ];
    } on SocketException catch (e) {
      developer.log(
        'listing local interfaces failed, no subnet preference: $e',
        name: 'RigDiscovery',
        level: 900,
      );
      return const [];
    }
  }

  static String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  /// `multicast_dns` hands a TXT record's strings joined by newlines.
  static Map<String, String> parseTxtRecord(String text) {
    final out = <String, String>{};
    for (final line in const LineSplitter().convert(text)) {
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      out[line.substring(0, eq)] = line.substring(eq + 1);
    }
    return out;
  }

  /// `DESKTOP-MMAJGAK.local` → `DESKTOP-MMAJGAK`. Null for an empty target.
  static String? mdnsTargetComputerName(String target) {
    var name = target.trim();
    if (name.endsWith('.')) name = name.substring(0, name.length - 1);
    if (name.toLowerCase().endsWith('.local')) {
      name = name.substring(0, name.length - '.local'.length);
    }
    return name.isEmpty ? null : name;
  }
}
