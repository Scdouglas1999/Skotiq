// Multi-server roaming on the mobile companion.
//
// Persists a list of previously-paired Skotiq hosts so an operator
// who manages multiple rigs (e.g. observatory + travel scope + backyard
// pier) can roam between them without re-pairing each time.
//
// Why a dedicated service (rather than just extending
// EnhancedSkotiqDiscovery): the existing discovery layer was built
// around a single "last server" slot — host/port/auth-token/fingerprint
// pairs all share one SharedPreferences key set. Adding multi-server
// support there would force every consumer to either accept a list
// signature or pick an index, breaking the QR/manual-entry seam.
// Keeping the multi-server list separate means:
//
//   1. The new `SavedServersService` is a pure data store; it does not
//      drive backend connections directly.
//   2. The screen calls `EnhancedSkotiqDiscovery.saveLastServer`
//      after connect succeeds, then `SavedServersService.upsert` to
//      mirror the same record into the roaming list. Existing callers
//      that read `loadLastServer()` (auto-reconnect on startup, LAN push
//      receiver) keep working without changes.
//   3. Migration is one-way: on first read of `SavedServersService` we
//      look at `loadLastServer()` and ensure its record exists in the
//      list. Removing a saved server only removes it from the list — the
//      "current/last" slot stays untouched until the user explicitly
//      disconnects.
//
// Auth tokens are sensitive — the desktop's PairingService issues bearer
// tokens that are equivalent to a password against the headless API.
// They are persisted exclusively in `flutter_secure_storage` (Keychain /
// EncryptedSharedPreferences), keyed by the saved-server `id`. The
// non-secret rows (display name, host, port, fingerprint, timestamps,
// notes) live in SharedPreferences as a single JSON blob so they survive
// cheap reads on cold start without touching Keychain.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One row in the persisted saved-server list.
///
/// All fields except [authToken] are non-secret and round-trip through a
/// single JSON blob in SharedPreferences. The [authToken] is held in
/// secure storage under `skotiq_saved_server_token::<id>` and is
/// loaded on-demand via [SavedServersService.tokenFor].
///
/// Equality compares every field (including [authToken]) so the screen
/// can rebuild only when something actually changed.
@immutable
class SavedServer {
  /// Stable, opaque identifier. Uniqueness is enforced by the service —
  /// the random generator below produces 128 bits of entropy, so a
  /// collision in a list of < ~1e15 entries is statistically impossible.
  final String id;

  /// Operator-editable label. Defaults to the server's discovery name
  /// (e.g. "Observatory · iMac") but the user can rename it via the
  /// long-press menu on the screen.
  final String displayName;

  /// Hostname or IP. Stored verbatim from the discovery / manual entry
  /// path; the dashboard handles `host[:port]` parsing before saving.
  final String host;

  /// Headless API port. Defaults to 8080 in the discovery seed but a
  /// user-overridden port (e.g. 8443 for TLS, 9090 for a side-by-side
  /// dev server) is honoured here.
  final int port;

  /// Bearer token minted by the desktop's `PairingService.verifyCode`.
  /// `null` when the host has auth disabled (LAN-only dev setups).
  /// In secure storage this is `null` vs missing both serialise to "no
  /// token"; consumers must treat both identically.
  final String? authToken;

  /// SHA-256 SPKI fingerprint of the server's TLS certificate (W1A) or
  /// the SHA-256 of `/api/info`'s fingerprint field on a plaintext
  /// host. `null` when neither was available at pairing time. When
  /// non-null, the LAN push receiver and TLS-pinned dialer use this
  /// to refuse a man-in-the-middle attempt — see
  /// `skotiq_remote_protocol`'s `RemotePairingClient` / the LAN
  /// push HMAC derivation. The brief calls this "pinnedFingerprint";
  /// we honour the name.
  final String? pinnedFingerprint;

  /// Wall-clock timestamp of the most recent successful `/api/info`
  /// round-trip for this entry. Updated when the screen pings the host
  /// (pull-to-refresh) and when the operator switches to this entry
  /// via [BackendNotifier.connect]. `null` before the first probe.
  final DateTime? lastConnectedAt;

  /// Optional user-supplied free-text. Surfaces in the row's expanded
  /// view + the rename dialog. Bounded to 280 characters at the screen
  /// layer so it cannot bloat the JSON blob.
  final String notes;

  /// Transport scheme the host speaks — `'http'` (plain) or `'https'`
  /// (TLS). A TLS-fronted host (the typical Tailscale remote-observatory
  /// topology) answers only on `https`; probing it over plain `http`
  /// reads as unreachable, so we persist the scheme learned at pairing
  /// time and pass it through to `testServerConnection` /
  /// `BackendNotifier.connect`. Defaults to `'http'` for entries written
  /// by pre-2.6 builds that didn't carry a scheme.
  final String scheme;

  /// The OTHER address for a dual-homed rig: [host] holds whichever address
  /// the operator paired over, this holds its tailnet counterpart, so the
  /// screen can offer one-tap Tailscale when the LAN host is unreachable and
  /// prefer the fast LAN host when both are. `null` for single-homed rigs.
  ///
  /// Both [host] and [tailscaleHost] are validated through
  /// [TailnetDetector.isAccepted] before being stored — a public address here
  /// is refused, so this can never become an exfiltration vector.
  final String? tailscaleHost;

  /// The self-hosted relay's `ws(s)://host[:port]` URL when this entry is
  /// reached through a relay tunnel rather than a direct LAN / Tailscale dial.
  /// `null` for direct entries.
  ///
  /// A relay entry is identified by [isRelay] (both this and
  /// [relayApplianceId] non-empty). For a relay entry the [host] / [port]
  /// are *synthetic* loopback placeholders — the live tunnel mints a fresh
  /// ephemeral loopback port on every reconnect — so they are not used to
  /// dial; the reconnect path opens a tunnel from [relayUrl] +
  /// [relayApplianceId] and connects to 127.0.0.1 on the tunnel's port.
  final String? relayUrl;

  /// The appliance id the relay minted for the rig (printed by the headless
  /// daemon on first contact, shape `xxxx-xxxx-xxxx`). Pairs with [relayUrl]
  /// to define a relay entry. `null` for direct entries.
  final String? relayApplianceId;

  /// Whether to trust a self-signed TLS certificate on the relay
  /// (the `wss://` endpoint). Mirrors the "Trust self-signed relay TLS"
  /// toggle in the connect dialog so a relay fronted by a self-signed cert
  /// reconnects without re-prompting. Ignored for non-relay entries.
  final bool relayAllowInsecureTls;

  const SavedServer({
    required this.id,
    required this.displayName,
    required this.host,
    required this.port,
    this.authToken,
    this.pinnedFingerprint,
    this.lastConnectedAt,
    this.notes = '',
    this.scheme = 'http',
    this.tailscaleHost,
    this.relayUrl,
    this.relayApplianceId,
    this.relayAllowInsecureTls = false,
  });

  /// `true` when this entry is reached through a relay tunnel — both the
  /// relay URL and appliance id are present. The saved-servers screen
  /// routes the row tap through the relay flow (open tunnel → connect to
  /// loopback) rather than a direct dial, and shows a "Relay" badge.
  bool get isRelay =>
      relayUrl != null &&
      relayUrl!.isNotEmpty &&
      relayApplianceId != null &&
      relayApplianceId!.isNotEmpty;

  /// The reachability tier of the primary [host] — drives the LAN /
  /// Remote badge on the saved-servers screen.
  HostReachabilityTier get hostTier => TailnetDetector.classify(host);

  /// Suffix of a Tailscale MagicDNS fully-qualified name
  /// (`my-rig.tailnet-name.ts.net`). MagicDNS names are hostnames, not IP
  /// literals, so [TailnetDetector.classify] — which never resolves DNS —
  /// cannot see them as tailnet; the `.ts.net` suffix is accepted explicitly.
  /// Aliases [TailnetDetector.magicDnsSuffix] so the suffix has one home.
  static const tailscaleMagicDnsSuffix = TailnetDetector.magicDnsSuffix;

  /// `true` when [host] is a usable Tailscale endpoint: either a tailnet
  /// IP literal (`100.64.0.0/10` / `fd7a:115c::/32`) or a MagicDNS
  /// `*.ts.net` hostname. Delegates to the single shared predicate in
  /// [TailnetDetector.isTailscaleEndpoint] so the setup sheet, persistence
  /// validator, network backend, status indicator, and reconnect gate never
  /// drift apart on what counts as a tailnet endpoint.
  static bool isTailscaleEndpoint(String host) =>
      TailnetDetector.isTailscaleEndpoint(host);

  /// `true` when this rig has a distinct Tailscale host on file in
  /// addition to (or instead of) its LAN host.
  bool get hasTailscaleHost =>
      tailscaleHost != null && tailscaleHost!.isNotEmpty;

  /// `true` when the primary host is itself a Tailscale endpoint (tailnet
  /// IP literal or `*.ts.net` MagicDNS name).
  bool get isPrimaryTailscale => isTailscaleEndpoint(host);

  /// The host the operator should prefer when off-site: the explicit
  /// [tailscaleHost] when present, else the primary [host] if it is
  /// already a tailnet address, else `null` (no remote path known).
  String? get preferredRemoteHost {
    if (hasTailscaleHost) return tailscaleHost;
    if (isPrimaryTailscale) return host;
    return null;
  }

  SavedServer copyWith({
    String? displayName,
    String? host,
    int? port,
    String? authToken,
    bool clearAuthToken = false,
    String? pinnedFingerprint,
    bool clearPinnedFingerprint = false,
    DateTime? lastConnectedAt,
    bool clearLastConnectedAt = false,
    String? notes,
    String? scheme,
    String? tailscaleHost,
    bool clearTailscaleHost = false,
    String? relayUrl,
    String? relayApplianceId,
    bool clearRelay = false,
    bool? relayAllowInsecureTls,
  }) {
    return SavedServer(
      id: id,
      displayName: displayName ?? this.displayName,
      host: host ?? this.host,
      port: port ?? this.port,
      authToken: clearAuthToken ? null : (authToken ?? this.authToken),
      pinnedFingerprint: clearPinnedFingerprint
          ? null
          : (pinnedFingerprint ?? this.pinnedFingerprint),
      lastConnectedAt: clearLastConnectedAt
          ? null
          : (lastConnectedAt ?? this.lastConnectedAt),
      notes: notes ?? this.notes,
      scheme: scheme ?? this.scheme,
      tailscaleHost: clearTailscaleHost
          ? null
          : (tailscaleHost ?? this.tailscaleHost),
      relayUrl: clearRelay ? null : (relayUrl ?? this.relayUrl),
      relayApplianceId: clearRelay
          ? null
          : (relayApplianceId ?? this.relayApplianceId),
      relayAllowInsecureTls:
          relayAllowInsecureTls ?? this.relayAllowInsecureTls,
    );
  }

  /// JSON shape used by [SavedServersService] for the SharedPreferences
  /// blob. The auth token is intentionally omitted — it lives in secure
  /// storage and is keyed off [id].
  Map<String, dynamic> toJsonNonSecret() => {
    'id': id,
    'displayName': displayName,
    'host': host,
    'port': port,
    if (pinnedFingerprint != null) 'pinnedFingerprint': pinnedFingerprint,
    if (lastConnectedAt != null)
      'lastConnectedAt': lastConnectedAt!.toIso8601String(),
    if (notes.isNotEmpty) 'notes': notes,
    // Persist the scheme only when it diverges from the legacy default
    // so old readers (which assume http) and the JSON blob both stay
    // compact for the common LAN case.
    if (scheme != 'http') 'scheme': scheme,
    if (tailscaleHost != null && tailscaleHost!.isNotEmpty)
      'tailscaleHost': tailscaleHost,
    // Relay fields are written only for relay entries so a direct entry's
    // blob stays byte-identical to a pre-relay build (forward/backward
    // compatible — old readers ignore unknown keys, new readers treat the
    // absence as a direct entry).
    if (relayUrl != null && relayUrl!.isNotEmpty) 'relayUrl': relayUrl,
    if (relayApplianceId != null && relayApplianceId!.isNotEmpty)
      'relayApplianceId': relayApplianceId,
    if (relayAllowInsecureTls) 'relayAllowInsecureTls': true,
  };

  /// Inverse of [toJsonNonSecret]. The auth token is *not* populated;
  /// callers that need it should hit [SavedServersService.tokenFor] to
  /// read secure storage on demand.
  static SavedServer fromJsonNonSecret(Map<String, dynamic> json) {
    final id = json['id'];
    final displayName = json['displayName'];
    final host = json['host'];
    final port = json['port'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('SavedServer: missing/empty id');
    }
    if (displayName is! String) {
      throw const FormatException('SavedServer: missing displayName');
    }
    if (host is! String || host.isEmpty) {
      throw const FormatException('SavedServer: missing/empty host');
    }
    if (port is! int || port <= 0 || port > 65535) {
      throw const FormatException('SavedServer: invalid port');
    }
    final fp = json['pinnedFingerprint'];
    final lastIso = json['lastConnectedAt'];
    final notes = json['notes'];
    // Scheme is optional; when present it MUST be http/https. A bogus value
    // is rejected rather than coerced, because coercion routes the activation
    // probe at a protocol the server cannot answer. Absent → http default.
    final rawScheme = json['scheme'];
    final String parsedScheme;
    if (rawScheme == null) {
      parsedScheme = 'http';
    } else if (rawScheme is String &&
        (rawScheme.toLowerCase() == 'http' ||
            rawScheme.toLowerCase() == 'https')) {
      parsedScheme = rawScheme.toLowerCase();
    } else {
      throw const FormatException(
        'SavedServer: scheme is not "http" or "https"',
      );
    }
    // Tailscale host is optional, but if present it must pass the same
    // fail-closed acceptance gate as the primary host — a public address
    // smuggled in here would let a tampered blob point a one-tap connect
    // at an arbitrary internet host.
    final rawTs = json['tailscaleHost'];
    String? parsedTailscaleHost;
    if (rawTs is String && rawTs.isNotEmpty) {
      if (!isTailscaleEndpoint(rawTs)) {
        throw const FormatException(
          'SavedServer: tailscaleHost is not a tailnet IP or *.ts.net name',
        );
      }
      parsedTailscaleHost = rawTs;
    }
    // Relay fields are optional and travel together. When present the URL
    // must be a ws/wss endpoint and the appliance id must match the relay
    // id shape — a malformed blob is rejected rather than silently coerced
    // (no silent fallbacks) so a hand-edited entry can't point the
    // reconnect at an arbitrary scheme/host.
    final rawRelayUrl = json['relayUrl'];
    final rawRelayId = json['relayApplianceId'];
    String? parsedRelayUrl;
    String? parsedRelayApplianceId;
    if (rawRelayUrl != null || rawRelayId != null) {
      if (rawRelayUrl is! String ||
          rawRelayUrl.isEmpty ||
          rawRelayId is! String ||
          rawRelayId.isEmpty) {
        throw const FormatException(
          'SavedServer: relayUrl and relayApplianceId must both be present',
        );
      }
      final relayUri = Uri.tryParse(rawRelayUrl);
      if (relayUri == null ||
          (relayUri.scheme != 'ws' && relayUri.scheme != 'wss')) {
        throw const FormatException(
          'SavedServer: relayUrl is not a ws:// or wss:// URL',
        );
      }
      if (!isValidApplianceId(rawRelayId)) {
        throw const FormatException(
          'SavedServer: relayApplianceId is not a valid appliance id',
        );
      }
      parsedRelayUrl = rawRelayUrl;
      parsedRelayApplianceId = rawRelayId;
    }
    final rawRelayInsecure = json['relayAllowInsecureTls'];
    final parsedRelayInsecure = rawRelayInsecure == true;
    return SavedServer(
      id: id,
      displayName: displayName,
      host: host,
      port: port,
      pinnedFingerprint: fp is String && fp.isNotEmpty ? fp : null,
      lastConnectedAt: lastIso is String && lastIso.isNotEmpty
          ? DateTime.tryParse(lastIso)
          : null,
      notes: notes is String ? notes : '',
      scheme: parsedScheme,
      tailscaleHost: parsedTailscaleHost,
      relayUrl: parsedRelayUrl,
      relayApplianceId: parsedRelayApplianceId,
      relayAllowInsecureTls: parsedRelayInsecure,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SavedServer &&
          other.id == id &&
          other.displayName == displayName &&
          other.host == host &&
          other.port == port &&
          other.authToken == authToken &&
          other.pinnedFingerprint == pinnedFingerprint &&
          other.lastConnectedAt == lastConnectedAt &&
          other.notes == notes &&
          other.scheme == scheme &&
          other.tailscaleHost == tailscaleHost &&
          other.relayUrl == relayUrl &&
          other.relayApplianceId == relayApplianceId &&
          other.relayAllowInsecureTls == relayAllowInsecureTls);

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    host,
    port,
    authToken,
    pinnedFingerprint,
    lastConnectedAt,
    notes,
    scheme,
    tailscaleHost,
    relayUrl,
    relayApplianceId,
    relayAllowInsecureTls,
  );

  @override
  String toString() =>
      'SavedServer($id, $displayName, $scheme://$host:$port, '
      'tailscale=${tailscaleHost ?? '-'}, '
      'relay=${isRelay ? '$relayApplianceId@$relayUrl' : '-'}, '
      'pinned=${pinnedFingerprint != null}, '
      'lastConnected=$lastConnectedAt)';
}

/// Storage keys + helpers used by [SavedServersService]. Exposed for
/// tests so a SharedPreferences mock can preload state under the same
/// keys the production service reads.
class SavedServersStorageKeys {
  SavedServersStorageKeys._();

  /// SharedPreferences key for the JSON-encoded list of non-secret fields.
  /// Still v1: every field added since is optional and omitted at its default,
  /// so an older blob deserialises cleanly under the same key.
  static const list = 'skotiq.saved_servers.v1';

  /// One-shot migration latch. Set after we've folded the legacy
  /// "last server" record into the list so we don't re-import on every
  /// startup.
  static const migrated = 'skotiq.saved_servers.migrated.v1';

  /// Secure-storage key prefix for per-row bearer tokens. The full key
  /// is `<tokenKeyPrefix><id>`.
  static const tokenKeyPrefix = 'skotiq_saved_server_token::';
}

/// Persists and mutates the multi-server roaming list.
///
/// The service is *not* a Notifier; the screen treats the on-disk state
/// as the source of truth and re-loads after every mutation. This keeps
/// the contract simple and matches how
/// `EnhancedSkotiqDiscovery.saveLastServer` is used elsewhere.
///
/// All methods are `Future`-returning; the few that have to hit secure
/// storage are documented per-method.
class SavedServersService {
  /// Secure storage handle used for bearer tokens. Defaults to the same
  /// Keychain/EncryptedSharedPreferences-backed instance the rest of
  /// the mobile app uses; injectable for tests.
  final FlutterSecureStorage _secureStorage;

  /// SharedPreferences resolver. Tests inject `SharedPreferences.setMockInitialValues`
  /// before constructing the service.
  final Future<SharedPreferences> Function() _prefsLoader;

  /// Optional RNG hook for tests (deterministic ids). Defaults to
  /// `Random.secure()` in production — 128 bits of entropy per id is
  /// more than enough.
  final Random _random;

  /// Tail of the in-process mutation queue.
  ///
  /// Every list mutation is a read/modify/write of one SharedPreferences
  /// blob. Without serialization, two otherwise-correct operations can both
  /// read the same snapshot and the later write silently erases the earlier
  /// change (for example, a reachability refresh racing a rename). Keep the
  /// whole operation in one queue, including secure-storage work, so callers
  /// can safely issue mutations concurrently.
  Future<void> _mutationTail = Future<void>.value();

  /// Shares the one-shot legacy migration between concurrent first reads.
  Future<void>? _migrationFuture;

  SavedServersService({
    FlutterSecureStorage? secureStorage,
    Future<SharedPreferences> Function()? prefsLoader,
    Random? random,
  }) : _secureStorage = secureStorage ?? _defaultSecureStorage,
       _prefsLoader = prefsLoader ?? SharedPreferences.getInstance,
       _random = random ?? Random.secure();

  static const FlutterSecureStorage _defaultSecureStorage =
      FlutterSecureStorage(
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      );

  /// Load the full list. Always sorted with the most-recently-connected
  /// entry first, then alphabetically by [SavedServer.displayName] for
  /// rows that have never been connected.
  ///
  /// Side effect: on the first call after install, folds the legacy
  /// `loadLastServer()` record into the list (migration). The
  /// migration is gated by [SavedServersStorageKeys.migrated] so it
  /// runs exactly once.
  Future<List<SavedServer>> loadAll() async {
    final prefs = await _prefsLoader();
    await (_migrationFuture ??= _migrateLegacyIfNeeded(prefs));
    final raw = prefs.getString(SavedServersStorageKeys.list);
    if (raw == null || raw.isEmpty) return const [];
    List<dynamic> decoded;
    try {
      final any = jsonDecode(raw);
      if (any is! List) {
        developer.log(
          'saved_servers: list blob was not a JSON array; resetting',
          name: 'SavedServersService',
          level: 1000,
        );
        await prefs.remove(SavedServersStorageKeys.list);
        return const [];
      }
      decoded = any;
    } on FormatException catch (e, st) {
      developer.log(
        'saved_servers: list blob is not valid JSON, resetting: $e',
        name: 'SavedServersService',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      await prefs.remove(SavedServersStorageKeys.list);
      return const [];
    }
    final result = <SavedServer>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      try {
        final server = SavedServer.fromJsonNonSecret(
          entry.cast<String, dynamic>(),
        );
        result.add(server);
      } on FormatException catch (e, st) {
        // Skip the bad row but keep the rest — a single corrupted entry
        // shouldn't make the whole list unusable. Surface the failure
        // (no silent fallbacks) via a structured log line so
        // the operator sees something is up.
        developer.log(
          'saved_servers: skipping malformed row: $e',
          name: 'SavedServersService',
          level: 1000,
          error: e,
          stackTrace: st,
        );
      }
    }
    _sortMostRecentFirst(result);
    return result;
  }

  /// Returns the entry with the given [id], or `null` if no such row
  /// exists. Reads through [loadAll] so migration runs the same way.
  Future<SavedServer?> findById(String id) async {
    final all = await loadAll();
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Read the bearer token for [id] from secure storage. Returns `null`
  /// when no token is bound to that id (auth-disabled hosts, or an entry
  /// whose token [removeById] has cleared). Callers must not cache the
  /// result — the secure storage is the source of truth.
  Future<String?> tokenFor(String id) async {
    if (id.isEmpty) return null;
    return _secureStorage.read(
      key: '${SavedServersStorageKeys.tokenKeyPrefix}$id',
    );
  }

  /// Add a brand-new server. Generates a fresh [SavedServer.id]. The
  /// caller passes [token] separately so the token never enters the
  /// JSON blob — it goes straight to secure storage. Returns the
  /// stored row (including the generated id).
  Future<SavedServer> add({
    required String displayName,
    required String host,
    required int port,
    String? authToken,
    String? pinnedFingerprint,
    DateTime? lastConnectedAt,
    String notes = '',
    String scheme = 'http',
    String? tailscaleHost,
    String? relayUrl,
    String? relayApplianceId,
    bool relayAllowInsecureTls = false,
  }) => _serializeMutation(
    () => _addUnqueued(
      displayName: displayName,
      host: host,
      port: port,
      authToken: authToken,
      pinnedFingerprint: pinnedFingerprint,
      lastConnectedAt: lastConnectedAt,
      notes: notes,
      scheme: scheme,
      tailscaleHost: tailscaleHost,
      relayUrl: relayUrl,
      relayApplianceId: relayApplianceId,
      relayAllowInsecureTls: relayAllowInsecureTls,
    ),
  );

  Future<SavedServer> _addUnqueued({
    required String displayName,
    required String host,
    required int port,
    String? authToken,
    String? pinnedFingerprint,
    DateTime? lastConnectedAt,
    String notes = '',
    String scheme = 'http',
    String? tailscaleHost,
    String? relayUrl,
    String? relayApplianceId,
    bool relayAllowInsecureTls = false,
  }) async {
    final id = _generateId();
    final entry = SavedServer(
      id: id,
      displayName: displayName.trim().isEmpty ? '$host:$port' : displayName,
      host: host,
      port: port,
      authToken: authToken,
      pinnedFingerprint: pinnedFingerprint,
      lastConnectedAt: lastConnectedAt,
      notes: notes,
      scheme: scheme,
      tailscaleHost: tailscaleHost,
      relayUrl: relayUrl,
      relayApplianceId: relayApplianceId,
      relayAllowInsecureTls: relayAllowInsecureTls,
    );
    await _writeRow(entry, authToken: authToken);
    return entry;
  }

  /// Insert-or-update an entry. Match strategy:
  ///   1. If [id] is provided AND a row with that id exists, update it.
  ///   2. Otherwise, look for an existing row with the same
  ///      `host:port` pair and update that.
  ///   3. Otherwise, allocate a new id and insert.
  ///
  /// The caller passes [authToken] explicitly: a non-null value
  /// overwrites the stored token, a `null` value leaves the existing
  /// token alone (use [removeToken] to clear a token without removing
  /// the row).
  Future<SavedServer> upsert({
    String? id,
    required String displayName,
    required String host,
    required int port,
    String? authToken,
    String? pinnedFingerprint,
    DateTime? lastConnectedAt,
    String? notes,
    String? scheme,
    String? tailscaleHost,
  }) => _serializeMutation(
    () => _upsertUnqueued(
      id: id,
      displayName: displayName,
      host: host,
      port: port,
      authToken: authToken,
      pinnedFingerprint: pinnedFingerprint,
      lastConnectedAt: lastConnectedAt,
      notes: notes,
      scheme: scheme,
      tailscaleHost: tailscaleHost,
    ),
  );

  Future<SavedServer> _upsertUnqueued({
    String? id,
    required String displayName,
    required String host,
    required int port,
    String? authToken,
    String? pinnedFingerprint,
    DateTime? lastConnectedAt,
    String? notes,
    String? scheme,
    String? tailscaleHost,
  }) async {
    final all = await loadAll();
    SavedServer? existing;
    if (id != null) {
      for (final s in all) {
        if (s.id == id) {
          existing = s;
          break;
        }
      }
    }
    if (existing == null) {
      for (final s in all) {
        if (s.host == host && s.port == port) {
          existing = s;
          break;
        }
      }
    }
    if (existing == null) {
      return _addUnqueued(
        displayName: displayName,
        host: host,
        port: port,
        authToken: authToken,
        pinnedFingerprint: pinnedFingerprint,
        lastConnectedAt: lastConnectedAt,
        notes: notes ?? '',
        scheme: scheme ?? 'http',
        tailscaleHost: tailscaleHost,
      );
    }
    final updated = existing.copyWith(
      displayName: displayName.trim().isEmpty ? null : displayName,
      host: host,
      port: port,
      authToken: authToken,
      pinnedFingerprint: pinnedFingerprint,
      lastConnectedAt: lastConnectedAt,
      notes: notes,
      scheme: scheme,
      tailscaleHost: tailscaleHost,
    );
    await _writeRow(updated, authToken: authToken);
    return updated;
  }

  /// Insert-or-update a relay entry, keyed on the (relay URL, appliance id)
  /// pair rather than host:port — a relay entry's loopback host:port is
  /// synthetic and changes on every reconnect, so the host:port match in
  /// [upsert] would spawn a duplicate row each session.
  ///
  /// Match strategy:
  ///   1. An existing relay row with the same [relayUrl] + [relayApplianceId]
  ///      is updated in place (keeps its id, notes, display name unless a
  ///      non-empty [displayName] is supplied).
  ///   2. Otherwise a new relay row is inserted.
  ///
  /// [authToken] follows the same rule as [upsert]: non-null overwrites the
  /// stored bearer; null leaves the existing token untouched. The token
  /// stays out of the JSON blob and lives in secure storage keyed by id.
  Future<SavedServer> upsertRelay({
    required String displayName,
    required String relayUrl,
    required String relayApplianceId,
    bool relayAllowInsecureTls = false,
    String? authToken,
    String? pinnedFingerprint,
    DateTime? lastConnectedAt,
    String? notes,
  }) => _serializeMutation(
    () => _upsertRelayUnqueued(
      displayName: displayName,
      relayUrl: relayUrl,
      relayApplianceId: relayApplianceId,
      relayAllowInsecureTls: relayAllowInsecureTls,
      authToken: authToken,
      pinnedFingerprint: pinnedFingerprint,
      lastConnectedAt: lastConnectedAt,
      notes: notes,
    ),
  );

  Future<SavedServer> _upsertRelayUnqueued({
    required String displayName,
    required String relayUrl,
    required String relayApplianceId,
    bool relayAllowInsecureTls = false,
    String? authToken,
    String? pinnedFingerprint,
    DateTime? lastConnectedAt,
    String? notes,
  }) async {
    final all = await loadAll();
    SavedServer? existing;
    for (final s in all) {
      if (s.isRelay &&
          s.relayUrl == relayUrl &&
          s.relayApplianceId == relayApplianceId) {
        existing = s;
        break;
      }
    }
    if (existing == null) {
      return _addUnqueued(
        displayName: displayName,
        // A relay entry never dials these directly; persist a loopback
        // placeholder so the (required) host/port fields round-trip and the
        // secondary line renders something stable.
        host: '127.0.0.1',
        port: 1, // Valid (1..65535) placeholder; unused for relay dials.
        authToken: authToken,
        pinnedFingerprint: pinnedFingerprint,
        lastConnectedAt: lastConnectedAt,
        notes: notes ?? '',
        relayUrl: relayUrl,
        relayApplianceId: relayApplianceId,
        relayAllowInsecureTls: relayAllowInsecureTls,
      );
    }
    final updated = existing.copyWith(
      displayName: displayName.trim().isEmpty ? null : displayName,
      authToken: authToken,
      pinnedFingerprint: pinnedFingerprint,
      lastConnectedAt: lastConnectedAt,
      notes: notes,
      relayUrl: relayUrl,
      relayApplianceId: relayApplianceId,
      relayAllowInsecureTls: relayAllowInsecureTls,
    );
    await _writeRow(updated, authToken: authToken);
    return updated;
  }

  /// Rename a saved server. Throws [StateError] when no row matches —
  /// the screen guards against this by reading from [loadAll] just
  /// before showing the rename dialog.
  Future<SavedServer> rename(String id, String displayName) =>
      _serializeMutation(() => _renameUnqueued(id, displayName));

  Future<SavedServer> _renameUnqueued(String id, String displayName) async {
    final all = await loadAll();
    for (var i = 0; i < all.length; i++) {
      if (all[i].id == id) {
        final updated = all[i].copyWith(displayName: displayName);
        await _persistList(_replaceAt(all, i, updated));
        return updated;
      }
    }
    throw StateError('SavedServersService.rename: no row with id $id');
  }

  /// Update the free-text notes for [id]. Same lookup semantics as
  /// [rename].
  Future<SavedServer> setNotes(String id, String notes) =>
      _serializeMutation(() => _setNotesUnqueued(id, notes));

  Future<SavedServer> _setNotesUnqueued(String id, String notes) async {
    final all = await loadAll();
    for (var i = 0; i < all.length; i++) {
      if (all[i].id == id) {
        final updated = all[i].copyWith(notes: notes);
        await _persistList(_replaceAt(all, i, updated));
        return updated;
      }
    }
    throw StateError('SavedServersService.setNotes: no row with id $id');
  }

  /// Stamp `lastConnectedAt` to `DateTime.now()` for [id]. Called by
  /// the screen after a successful `/api/info` ping or after the user
  /// taps a row and the backend connect completes.
  Future<void> touchLastConnected(String id) =>
      _serializeMutation(() => _touchLastConnectedUnqueued(id));

  Future<void> _touchLastConnectedUnqueued(String id) async {
    final all = await loadAll();
    for (var i = 0; i < all.length; i++) {
      if (all[i].id == id) {
        final updated = all[i].copyWith(lastConnectedAt: DateTime.now());
        await _persistList(_replaceAt(all, i, updated));
        return;
      }
    }
    // No-op if the row was removed underneath us — touching a deleted
    // entry shouldn't resurrect it.
  }

  /// Delete a row + its bearer token from secure storage. Idempotent.
  Future<void> removeById(String id) =>
      _serializeMutation(() => _removeByIdUnqueued(id));

  Future<void> _removeByIdUnqueued(String id) async {
    final all = await loadAll();
    final next = all.where((s) => s.id != id).toList(growable: false);
    if (next.length == all.length) return;
    await _persistList(next);
    await _secureStorage.delete(
      key: '${SavedServersStorageKeys.tokenKeyPrefix}$id',
    );
  }

  /// Drop the bearer token for [id] without removing the row. Useful
  /// when the operator wants to force a re-pair (e.g. they suspect the
  /// token was leaked) but keep the host/port/notes pinned.
  Future<void> removeToken(String id) =>
      _serializeMutation(() => _removeTokenUnqueued(id));

  Future<void> _removeTokenUnqueued(String id) async {
    await _secureStorage.delete(
      key: '${SavedServersStorageKeys.tokenKeyPrefix}$id',
    );
    final all = await loadAll();
    for (var i = 0; i < all.length; i++) {
      if (all[i].id == id) {
        final updated = all[i].copyWith(clearAuthToken: true);
        await _persistList(_replaceAt(all, i, updated));
        return;
      }
    }
  }

  /// Convenience for the screen's "open server" flow: returns a
  /// [DiscoveredServer] suitable for `BackendNotifier.connect` /
  /// `EnhancedSkotiqDiscovery.saveLastServer`. The auth token is
  /// loaded from secure storage on demand.
  Future<DiscoveredServer?> toDiscoveredServer(String id) async {
    final row = await findById(id);
    if (row == null) return null;
    final token = await tokenFor(id);
    return DiscoveredServer(
      name: row.displayName,
      host: row.host,
      webPort: row.port,
      // signalingPort (deprecated WebRTC) and version are left at their model
      // defaults — they are synthetic for a saved row and the real values
      // arrive via /api/info enrichment on connect.
      mode: 'headless',
      scheme: row.scheme,
      authToken: token,
      pairingSupported: true,
      authRequired: token != null,
      fingerprint: row.pinnedFingerprint,
    );
  }

  /// Set or clear the alternate Tailscale host for [id]. Passing an empty
  /// / null [tailscaleHost] clears it. A non-empty value is validated
  /// through [TailnetDetector.isAccepted] (fail-closed) before being
  /// stored — a public address is refused with an [ArgumentError] so the
  /// caller surfaces the rejection rather than persisting a bad host.
  /// Same lookup semantics as [rename] (throws [StateError] when no row
  /// matches).
  Future<SavedServer> setTailscaleHost(String id, String? tailscaleHost) =>
      _serializeMutation(() => _setTailscaleHostUnqueued(id, tailscaleHost));

  Future<SavedServer> _setTailscaleHostUnqueued(
    String id,
    String? tailscaleHost,
  ) async {
    final trimmed = tailscaleHost?.trim();
    final clearing = trimmed == null || trimmed.isEmpty;
    if (!clearing && !SavedServer.isTailscaleEndpoint(trimmed)) {
      throw ArgumentError.value(
        tailscaleHost,
        'tailscaleHost',
        'must be a tailnet IP (100.x / fd7a:115c::) or *.ts.net MagicDNS name',
      );
    }
    final all = await loadAll();
    for (var i = 0; i < all.length; i++) {
      if (all[i].id == id) {
        final updated = clearing
            ? all[i].copyWith(clearTailscaleHost: true)
            : all[i].copyWith(tailscaleHost: trimmed);
        await _persistList(_replaceAt(all, i, updated));
        return updated;
      }
    }
    throw StateError(
      'SavedServersService.setTailscaleHost: no row with id $id',
    );
  }

  // Internals

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _writeRow(
    SavedServer entry, {
    required String? authToken,
  }) async {
    final all = await loadAll();
    final next = <SavedServer>[];
    var replaced = false;
    for (final existing in all) {
      if (existing.id == entry.id) {
        next.add(entry);
        replaced = true;
      } else {
        next.add(existing);
      }
    }
    if (!replaced) {
      next.add(entry);
    }
    await _persistList(next);
    if (authToken != null) {
      await _secureStorage.write(
        key: '${SavedServersStorageKeys.tokenKeyPrefix}${entry.id}',
        value: authToken,
      );
    }
  }

  Future<void> _persistList(List<SavedServer> rows) async {
    final prefs = await _prefsLoader();
    final payload = jsonEncode(
      rows.map((r) => r.toJsonNonSecret()).toList(growable: false),
    );
    await prefs.setString(SavedServersStorageKeys.list, payload);
  }

  String _generateId() {
    final bytes = List<int>.generate(
      16,
      (_) => _random.nextInt(256),
      growable: false,
    );
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static List<SavedServer> _replaceAt(
    List<SavedServer> source,
    int index,
    SavedServer updated,
  ) {
    final next = List<SavedServer>.of(source, growable: false);
    next[index] = updated;
    return next;
  }

  static void _sortMostRecentFirst(List<SavedServer> rows) {
    rows.sort((a, b) {
      // Recent connections float to the top; never-connected rows fall
      // back to alphabetical so the order is stable on a fresh install.
      final av = a.lastConnectedAt;
      final bv = b.lastConnectedAt;
      if (av != null && bv != null) {
        return bv.compareTo(av);
      }
      if (av != null) return -1;
      if (bv != null) return 1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
  }

  /// migration: read the legacy single-server record (if any)
  /// and append it to the list as entry zero. Idempotent — gated by
  /// `migrated_v1` so an empty list across app restarts doesn't keep
  /// re-importing.
  Future<void> _migrateLegacyIfNeeded(SharedPreferences prefs) async {
    if (prefs.getBool(SavedServersStorageKeys.migrated) == true) return;
    DiscoveredServer? legacy;
    try {
      legacy = await EnhancedSkotiqDiscovery.loadLastServer();
    } catch (e, st) {
      // Don't block the rest of the app over a one-shot migration: log
      // and mark migrated so we don't keep retrying. The user can still
      // re-pair manually.
      developer.log(
        'saved_servers: legacy import failed: $e',
        name: 'SavedServersService',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      await prefs.setBool(SavedServersStorageKeys.migrated, true);
      return;
    }
    if (legacy == null) {
      await prefs.setBool(SavedServersStorageKeys.migrated, true);
      return;
    }
    // Read whatever may already be there (e.g. an upgrade path where
    // the list was seeded by a prior version) so we don't clobber it.
    final existingRaw = prefs.getString(SavedServersStorageKeys.list);
    final existingList = <SavedServer>[];
    if (existingRaw != null && existingRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(existingRaw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map) {
              try {
                existingList.add(
                  SavedServer.fromJsonNonSecret(entry.cast<String, dynamic>()),
                );
              } on FormatException catch (_) {
                // Drop malformed rows quietly during migration — the
                // loadAll path above re-logs them on the next read.
              }
            }
          }
        }
      } on FormatException catch (_) {
        // Bad JSON — treat as empty.
      }
    }
    // If the legacy host/port is already represented, skip the import.
    final alreadyPresent = existingList.any(
      (s) => s.host == legacy!.host && s.port == legacy.webPort,
    );
    if (alreadyPresent) {
      await prefs.setBool(SavedServersStorageKeys.migrated, true);
      return;
    }
    final id = _generateId();
    final imported = SavedServer(
      id: id,
      displayName: (legacy.name.isNotEmpty)
          ? legacy.name
          : '${legacy.host}:${legacy.webPort}',
      host: legacy.host,
      port: legacy.webPort,
      authToken: legacy.authToken,
      pinnedFingerprint: legacy.fingerprint,
      // We don't know when the legacy entry was last connected, but
      // the very fact that it was the "last server" implies it was
      // most recently used — stamp `now` so it sorts to the top.
      lastConnectedAt: DateTime.now(),
      notes: '',
      // Carry the transport scheme the legacy record was paired over so a
      // TLS-fronted tailnet host doesn't get probed over plain http after
      // the migration.
      scheme: legacy.scheme,
    );
    existingList.add(imported);
    final encoded = jsonEncode(
      existingList.map((r) => r.toJsonNonSecret()).toList(growable: false),
    );
    await prefs.setString(SavedServersStorageKeys.list, encoded);
    if (imported.authToken != null && imported.authToken!.isNotEmpty) {
      await _secureStorage.write(
        key: '${SavedServersStorageKeys.tokenKeyPrefix}$id',
        value: imported.authToken,
      );
    }
    await prefs.setBool(SavedServersStorageKeys.migrated, true);
    developer.log(
      'saved_servers: imported legacy server ${imported.host}:${imported.port} '
      'as $id',
      name: 'SavedServersService',
    );
  }
}

/// Provider used by [SavedServersScreen]. Holds a single
/// [SavedServersService] instance per app session — the service is
/// stateless beyond what's persisted, so a single instance is safe to
/// share across widgets.
final savedServersServiceProvider = Provider<SavedServersService>((ref) {
  return SavedServersService();
});

/// Signature of the relay-reconnect bridge — see [relayReconnectProvider].
typedef RelayReconnectFn = Future<void> Function(SavedServer server);

/// Bridge for reconnecting a saved *relay* server from the saved-servers
/// screen.
///
/// The relay tunnel (`RelayTunnelClient`) is owned by the always-mounted
/// mobile connection shell so it outlives the dashboard-launched
/// `SavedServersScreen`. The screen can't reach that state directly, so the
/// shell registers a relay-connect closure here on first frame; the screen
/// reads it to dial a saved relay row. `null` until the shell is mounted
/// (e.g. a widget test that pumps the screen in isolation) — in that case the
/// relay row tap surfaces a "not available" message rather than crashing.
final relayReconnectProvider = StateProvider<RelayReconnectFn?>((ref) => null);
