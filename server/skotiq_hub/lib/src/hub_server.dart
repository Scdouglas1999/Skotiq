import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'auth/account_service.dart';
import 'auth/moderation_service.dart';
import 'auth/token_service.dart';
import 'calibration/calibration_master_store.dart';
import 'calibration/shared_calibration_service.dart';
import 'collab/attribution_service.dart';
import 'collab/consent_service.dart';
import 'db/hub_database.dart';
import 'http/audit_log.dart';
import 'http/error_envelope.dart';
import 'http/rate_limiter.dart';
import 'scheduler/coimaging_service.dart';
import 'scheduler/follow_the_night.dart';
import 'scheduler/handoff_service.dart';
import 'scheduler/mosaic_broker_service.dart';
import 'tiles/fusion_service.dart';
import 'tiles/mosaic_master_store.dart';
import 'tiles/subframe_service.dart';
import 'tiles/subframe_store.dart';
import 'tiles/tile_builder.dart';
import 'tiles/tile_codec.dart';
import 'tiles/tile_store.dart';

/// Configuration for a [HubServer].
class HubConfig {
  HubConfig({
    required this.databasePath,
    required this.atlasRoot,
    required this.serverSecret,
    this.name = 'Skotiq Constellation Hub',
    this.port = 8088,
    this.bindAddress = '0.0.0.0',
    this.openSignup = true,
    this.acceptsRawSubs = false,
    this.maxContributionBytes = 64 * 1024 * 1024,
    this.maxSubframeBytes = 256 * 1024 * 1024,
    this.maxMosaicMasterBytes = 1024 * 1024 * 1024,
    this.healpixOrder = TileBuilder.atlasHealpixOrder,
    this.tilePixels = TileBuilder.tilePixels,
  });

  /// Path to the sqlite file, or `':memory:'` for tests.
  final String databasePath;

  /// Directory under which fused tile sidecars live.
  final String atlasRoot;

  /// Secret material the SHA-256 server fingerprint is derived from (and the
  /// admin bootstrap token is derived from on first run).
  final String serverSecret;

  final String name;
  final int port;
  final String bindAddress;

  /// When true, `POST /v1/accounts` is open to anyone (community hub). When
  /// false, only an admin token may create accounts (invite-only hub).
  final bool openSignup;

  /// Upload size cap for a single contribution body.
  final int maxContributionBytes;

  /// When true, the hub accepts raw FITS subframes (the
  /// `POST /v1/tiles/.../subframes` route) in addition to additive sums,
  /// advertised via `/v1/info` so a
  /// client can offer the SUBS privacy option. Default FALSE — raw subframes
  /// reveal far more than additive sums (exact pixels/pointing, re-derivable by
  /// anyone with read access), so a hub must opt in explicitly. When false the
  /// subframe routes return 405 so the client can say "this hub does not accept
  /// raw subframes".
  final bool acceptsRawSubs;

  /// Upload size cap for a single raw subframe body (larger than a sums delta).
  final int maxSubframeBytes;

  /// Upload size cap for a finished stitched mosaic output (the output canvas
  /// can exceed a single panel master, so this is larger than
  /// [maxSubframeBytes]; panel-master uploads reuse [maxSubframeBytes]).
  ///
  /// Memory constraint: DOWNLOADS of panel masters and the stitched output are
  /// streamed straight from disk (`HubServer._streamFile`), so serving a
  /// completed mosaic to N concurrent rigs does NOT hold N full copies resident.
  /// The remaining resident cost is the UPLOAD path, which buffers up to this cap
  /// in memory before flushing to disk; on a RAM-constrained appliance (e.g. a
  /// Raspberry Pi) set this no higher than the box can hold one copy of plus
  /// headroom for concurrent uploads.
  final int maxMosaicMasterBytes;

  final int healpixOrder;
  final int tilePixels;
}

/// The Constellation hub: a self-hostable, multi-tenant Dart shelf service that
/// fuses additive sky-atlas tile contributions from many imagers. Mirrors the
/// conventions of `apps/desktop/lib/headless_api_server.dart` — bearer-token
/// middleware with scopes, a structured error envelope, per-identity rate
/// limiting, and an append-only audit log — over the `/v1` REST surface.
class HubServer {
  HubServer(this.config)
    : _db = HubDatabase.open(config.databasePath),
      _store = TileStore(config.atlasRoot),
      _subframeStore = SubframeStore(config.atlasRoot),
      _calStore = CalibrationMasterStore(config.atlasRoot),
      _mosaicStore = MosaicMasterStore(config.atlasRoot) {
    _tokens = TokenService(_db);
    _accounts = AccountService(_db, _tokens);
    _moderation = ModerationService(_db, _tokens);
    _consent = ConsentService(_db);
    _attribution = AttributionService(_db, _accounts);
    _subframes = SubframeService(db: _db, store: _subframeStore);
    _calibration = SharedCalibrationService(
      db: _db,
      store: _calStore,
      accounts: _accounts,
    );
    _mosaicBroker = MosaicBrokerService(_db, consent: _consent);
    _fusion = FusionService(
      db: _db,
      store: _store,
      accounts: _accounts,
      attribution: _attribution,
      consent: _consent,
      expectedTilePixels: config.tilePixels,
      expectedHealpixOrder: config.healpixOrder,
    );
    _scheduler = FollowTheNightScheduler(_db);
    _handoff = HandoffService(_db);
    _coimaging = CoImagingService(
      db: _db,
      scheduler: _scheduler,
      handoff: _handoff,
      healpixOrder: config.healpixOrder,
      consent: _consent,
    );
    _audit = AuditLog(_db);
    _rateLimiter = RateLimiter();
    _loginThrottle = LoginThrottle();
    _ensureAdminBootstrap();
  }

  final HubConfig config;
  final HubDatabase _db;
  final TileStore _store;
  final SubframeStore _subframeStore;
  final CalibrationMasterStore _calStore;
  final MosaicMasterStore _mosaicStore;
  late final TokenService _tokens;
  late final AccountService _accounts;
  late final ModerationService _moderation;
  late final ConsentService _consent;
  late final AttributionService _attribution;
  late final FusionService _fusion;
  late final SubframeService _subframes;
  late final SharedCalibrationService _calibration;
  late final MosaicBrokerService _mosaicBroker;
  late final FollowTheNightScheduler _scheduler;
  late final HandoffService _handoff;
  late final CoImagingService _coimaging;
  late final AuditLog _audit;
  late final RateLimiter _rateLimiter;
  late final LoginThrottle _loginThrottle;

  HttpServer? _server;

  /// SHA-256 fingerprint of the hub identity, derived from [HubConfig.serverSecret]
  /// — the same derivation as `skotiq_remote_protocol/server_identity`.
  String get fingerprint => sha256
      .convert(utf8.encode('skotiq-remote-v1:${config.serverSecret.trim()}'))
      .toString();

  /// Exposed for tests: the in-process request handler with all middleware.
  Handler get handler => _buildHandler();

  /// Direct access to the services, for tests and embedding.
  AccountService get accounts => _accounts;
  FusionService get fusion => _fusion;
  FollowTheNightScheduler get scheduler => _scheduler;
  HandoffService get handoff => _handoff;
  CoImagingService get coimaging => _coimaging;
  TokenService get tokens => _tokens;
  ModerationService get moderation => _moderation;
  ConsentService get consent => _consent;
  AttributionService get attribution => _attribution;
  TileStore get store => _store;
  SubframeService get subframes => _subframes;
  SharedCalibrationService get calibration => _calibration;
  MosaicBrokerService get mosaicBroker => _mosaicBroker;
  MosaicMasterStore get mosaicStore => _mosaicStore;

  /// Start listening. Returns the bound address:port for logging.
  Future<String> start() async {
    _server = await shelf_io.serve(
      _buildHandler(),
      config.bindAddress,
      config.port,
    );
    return '${_server!.address.address}:${_server!.port}';
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void dispose() {
    _db.dispose();
  }

  /// On a fresh DB, mint the first admin account from the server secret so an
  /// operator always has a way in without a chicken-and-egg signup problem. Its
  /// public key is the server fingerprint; its bootstrap token is printed by the
  /// entrypoint. Idempotent: skipped if any account already exists.
  void _ensureAdminBootstrap() {
    if (_accounts.count > 0) return;
    _accounts.signup(
      publicKey: 'admin:$fingerprint',
      displayName: 'hub-admin',
      password: config.serverSecret,
      isAdmin: true,
    );
  }

  Handler _buildHandler() {
    final router = Router();
    for (final route in _routeTable()) {
      router.add(route.method, route.path, route.handler);
    }
    final pipeline = const Pipeline()
        .addMiddleware(_requestIdMiddleware())
        .addMiddleware(_errorTrapMiddleware())
        .addMiddleware(_rateLimitMiddleware())
        // Inner-most so it observes the FINAL handler response (a returned
        // 401/403/400/422 denial included) and audits every non-2xx — see
        // [_auditDenialMiddleware]. Sits inside the rate limiter so a 429 flood
        // does not cost a token resolve per dropped request.
        .addMiddleware(_auditDenialMiddleware());
    return pipeline.addHandler(router.call);
  }

  /// The single declarative table of every route this server registers, paired
  /// with its handler. [_buildHandler] registers from it and [registeredRoutes]
  /// enumerates it, so the default-deny test exercises EXACTLY the live route
  /// set — a new protected route added here cannot ship without the
  /// unauthenticated-request gate test covering it (fail-closed by construction).
  List<({String method, String path, Handler handler})> _routeTable() {
    return <({String method, String path, Handler handler})>[
      // Public, by design (see [publicRoutes]): server info, signup, login.
      (method: 'GET', path: '/v1/info', handler: _infoHandler),
      (method: 'POST', path: '/v1/accounts', handler: _createAccountHandler),
      (method: 'POST', path: '/v1/sessions', handler: _loginHandler),

      // Self-revoke (logout): drop the caller's own token.
      (
        method: 'DELETE',
        path: '/v1/sessions/current',
        handler: _revokeCurrentSessionHandler,
      ),

      // Fine-grained token minting — the "hand a member a
      // contribute-to-mosaic-42-only token" capability. Subset-only delegation:
      // the requester must already permit every requested action.
      (method: 'POST', path: '/v1/tokens', handler: _mintTokenHandler),

      // Moderation — suspend / reinstate an abusive account.
      (
        method: 'POST',
        path: '/v1/moderation/suspend',
        handler: _suspendAccountHandler,
      ),
      (
        method: 'POST',
        path: '/v1/moderation/reinstate',
        handler: _reinstateAccountHandler,
      ),

      // Attribution — the ordered per-contributor credit list for a finished
      // collaborative artifact (the contributor-credits UI source).
      (method: 'GET', path: '/v1/attribution', handler: _attributionHandler),

      (method: 'GET', path: '/v1/tiles/<tileId>', handler: _getTileHandler),
      (
        method: 'POST',
        path: '/v1/tiles/<tileId>/contributions',
        handler: _contributeHandler,
      ),
      (
        method: 'DELETE',
        path: '/v1/contributions/<contributionId>',
        handler: _retractContributionHandler,
      ),

      // Raw subframe (opt-in) path — gated inside the handlers on
      // [HubConfig.acceptsRawSubs] (405 when off) rather than at the router so a
      // client gets the explanatory "this hub does not accept raw subframes"
      // status instead of a bare 404.
      (
        method: 'POST',
        path: '/v1/tiles/<tileId>/subframes',
        handler: _contributeSubframeHandler,
      ),
      (
        method: 'DELETE',
        path: '/v1/subframes/<contributionId>',
        handler: _deleteSubframeHandler,
      ),

      (method: 'GET', path: '/v1/targets', handler: _listTargetsHandler),
      (method: 'POST', path: '/v1/targets', handler: _ensureTargetHandler),
      (
        method: 'GET',
        path: '/v1/follow-the-night',
        handler: _followTheNightHandler,
      ),
      (
        method: 'GET',
        path: '/v1/handoff/<targetId>',
        handler: _handoffStateHandler,
      ),
      (
        method: 'POST',
        path: '/v1/handoff/<targetId>/claim',
        handler: _handoffClaimHandler,
      ),
      (
        method: 'POST',
        path: '/v1/handoff/<targetId>/release',
        handler: _handoffReleaseHandler,
      ),

      // Shared calibration libraries. Query ranked remote masters for a sensor
      // + capture tuple, publish (consent-gated), download a chosen master's
      // bytes on accept, and retract a published master.
      (
        method: 'GET',
        path: '/v1/calibration/masters',
        handler: _queryCalibrationMastersHandler,
      ),
      (
        method: 'POST',
        path: '/v1/calibration/masters',
        handler: _publishCalibrationMasterHandler,
      ),
      (
        method: 'GET',
        path: '/v1/calibration/masters/<id>/file',
        handler: _downloadCalibrationMasterHandler,
      ),
      (
        method: 'DELETE',
        path: '/v1/calibration/masters/<id>',
        handler: _deleteCalibrationMasterHandler,
      ),

      // Collaborative mosaics. Publish a panel grid as claimable work items,
      // broker per-panel claims with the hand-off baton pattern, stream panel
      // masters up + the finished mosaic down, gate central assembly until
      // every panel has landed.
      (method: 'POST', path: '/v1/mosaics', handler: _publishMosaicHandler),
      (method: 'GET', path: '/v1/mosaics', handler: _listMosaicsHandler),
      (
        method: 'GET',
        path: '/v1/mosaics/<mosaicId>',
        handler: _getMosaicHandler,
      ),
      (
        method: 'POST',
        path: '/v1/mosaics/<mosaicId>/panels/<panelIndex>/claim',
        handler: _claimMosaicPanelHandler,
      ),
      (
        method: 'POST',
        path: '/v1/mosaics/<mosaicId>/panels/<panelIndex>/release',
        handler: _releaseMosaicPanelHandler,
      ),
      (
        method: 'POST',
        path: '/v1/mosaics/<mosaicId>/panels/<panelIndex>/force-release',
        handler: _forceReleaseMosaicPanelHandler,
      ),
      (
        method: 'POST',
        path: '/v1/mosaics/<mosaicId>/panels/<panelIndex>/master',
        handler: _uploadMosaicPanelMasterHandler,
      ),
      (
        method: 'GET',
        path: '/v1/mosaics/<mosaicId>/panels/<panelIndex>/master',
        handler: _downloadMosaicPanelMasterHandler,
      ),
      (
        method: 'POST',
        path: '/v1/mosaics/<mosaicId>/output',
        handler: _uploadMosaicOutputHandler,
      ),
      (
        method: 'GET',
        path: '/v1/mosaics/<mosaicId>/output',
        handler: _downloadMosaicOutputHandler,
      ),

      // Live co-imaging sessions. N rigs JOIN the SAME target; the hub tracks
      // COMBINED integration + frame count across rigs, assigns each rig a
      // unique framing offset (dither so they don't frame identically), pushes
      // a live combined preview over an SSE events channel, and productizes the
      // longitude hand-off baton (re-using HandoffService on the session's
      // shared target).
      (
        method: 'POST',
        path: '/v1/coimaging/sessions',
        handler: _createCoImagingSessionHandler,
      ),
      (
        method: 'GET',
        path: '/v1/coimaging/sessions',
        handler: _listCoImagingSessionsHandler,
      ),
      (
        method: 'GET',
        path: '/v1/coimaging/sessions/<sessionId>',
        handler: _getCoImagingSessionHandler,
      ),
      (
        method: 'POST',
        path: '/v1/coimaging/sessions/<sessionId>/join',
        handler: _joinCoImagingSessionHandler,
      ),
      (
        method: 'POST',
        path: '/v1/coimaging/sessions/<sessionId>/leave',
        handler: _leaveCoImagingSessionHandler,
      ),
      (
        method: 'POST',
        path: '/v1/coimaging/sessions/<sessionId>/close',
        handler: _closeCoImagingSessionHandler,
      ),
      (
        method: 'POST',
        path: '/v1/coimaging/sessions/<sessionId>/contributions',
        handler: _coImagingContributionHandler,
      ),
      (
        method: 'GET',
        path: '/v1/coimaging/sessions/<sessionId>/events',
        handler: _coImagingEventsHandler,
      ),
      (
        method: 'GET',
        path: '/v1/coimaging/sessions/<sessionId>/baton',
        handler: _coImagingBatonStateHandler,
      ),
      (
        method: 'POST',
        path: '/v1/coimaging/sessions/<sessionId>/baton/claim',
        handler: _coImagingBatonClaimHandler,
      ),
      (
        method: 'POST',
        path: '/v1/coimaging/sessions/<sessionId>/baton/release',
        handler: _coImagingBatonReleaseHandler,
      ),

      (method: 'GET', path: '/v1/audit', handler: _auditHandler),
    ];
  }

  /// Every `(method, path)` this server registers, for the default-deny test to
  /// enumerate. Driven off [_routeTable] (the same source [_buildHandler] uses),
  /// so the test fails closed the moment a new protected route forgets its gate.
  List<(String, String)> get registeredRoutes =>
      _routeTable().map((r) => (r.method, r.path)).toList(growable: false);

  /// The routes intentionally reachable WITHOUT a bearer token; everything else
  /// in [registeredRoutes] must default-deny. `POST /v1/accounts` is public only
  /// while [HubConfig.openSignup] is on (the handler self-gates to admin
  /// otherwise), so the default-deny test runs with open signup.
  static const Set<(String, String)> publicRoutes = <(String, String)>{
    ('GET', '/v1/info'),
    ('POST', '/v1/accounts'),
    ('POST', '/v1/sessions'),
  };

  // --- Middleware ----------------------------------------------------------

  Middleware _requestIdMiddleware() {
    return (Handler inner) {
      return (Request request) async {
        final requestId =
            request.headers['x-request-id'] ??
            DateTime.now().microsecondsSinceEpoch.toRadixString(16);
        final response = await inner(
          request.change(context: <String, Object>{'requestId': requestId}),
        );
        return response.change(
          headers: <String, String>{'x-request-id': requestId},
        );
      };
    };
  }

  Middleware _errorTrapMiddleware() => hubErrorTrapMiddleware();

  /// Audit every non-2xx handler response so authorization denials (401/403),
  /// consent rejections (400), and contribution rejections (422) all leave a
  /// trail — the gap that previously let authz probing, repeated forbidden
  /// attempts, and un-consented upload floods bypass `/v1/audit` and the abuse
  /// auto-flag entirely (denials are RETURNED, not thrown, so the errorTrap
  /// never saw them and the success-path `_audit.record` calls never ran).
  ///
  /// Handlers self-audit their SUCCESS (2xx/201) paths; this captures only the
  /// >= 400 responses they return early, so nothing is double-logged. The acting
  /// account is resolved from the bearer (null for an anonymous probe) and the
  /// token hash — never the raw token — is recorded. The small JSON error body
  /// is buffered so its stable `error.code` enriches the entry and the response
  /// is still delivered intact.
  Middleware _auditDenialMiddleware() {
    return (Handler inner) {
      return (Request request) async {
        final response = await inner(request);
        if (response.statusCode < 400) return response;
        final body = await response.readAsString();
        String? code;
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map && decoded['error'] is Map) {
            code = (decoded['error'] as Map)['code']?.toString();
          }
        } catch (_) {
          // Non-JSON error body (none today); fall back to the bare status.
        }
        final token = _bearer(request);
        final accountId = token == null
            ? null
            : _tokens.resolve(token)?.accountId;
        _audit.record(
          method: request.method,
          path: request.requestedUri.path,
          status: response.statusCode,
          accountId: accountId,
          detail: token == null
              ? 'denied ${code ?? response.statusCode} (no token)'
              : 'denied ${code ?? response.statusCode} '
                    'token=${TokenService.hashToken(token)}',
        );
        // An authenticated denial just landed in the audit ledger: re-evaluate
        // the abuse auto-flag so a forbidden-probe (403) or content-rejection
        // (422) flood from one account stops itself — the same uniform choke
        // point the tile-fusion reject path triggers via its own `checkAbuse`.
        if (accountId != null &&
            (response.statusCode == 403 || response.statusCode == 422)) {
          _moderation.checkAbuse(accountId);
        }
        return response.change(body: body);
      };
    };
  }

  Middleware _rateLimitMiddleware() {
    return (Handler inner) {
      return (Request request) async {
        _rateLimiter.sweep();
        final identity = _rateLimitIdentity(request);
        if (!_rateLimiter.allow(identity)) {
          final retry = _rateLimiter.retryAfterSeconds(identity);
          return HubError.rateLimited('too many requests').toResponse(
            requestId: request.context['requestId'] as String?,
            headers: <String, String>{'retry-after': '$retry'},
          );
        }
        return inner(request);
      };
    };
  }

  String _rateLimitIdentity(Request request) {
    final token = _bearer(request);
    if (token != null) return 'tok:${TokenService.hashToken(token)}';
    final conn = request.context['shelf.io.connection_info'];
    if (conn is HttpConnectionInfo) {
      return 'ip:${conn.remoteAddress.address}';
    }
    return 'anon';
  }

  // --- Auth helpers --------------------------------------------------------

  String? _bearer(Request request) {
    final header = request.headers['authorization'];
    if (header == null) return null;
    const prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return null;
    final token = header.substring(prefix.length).trim();
    return token.isEmpty ? null : token;
  }

  /// Resolve and authorize a request to at least [required] scope. Returns the
  /// identity on success, or a ready-to-send error [Response] on failure.
  ///
  /// Fine-grained gate: when a route declares the [action] (and optional
  /// [resourceType]/[resourceId]) it governs, the grant's per-action allow-list,
  /// per-resource binding, and per-device binding are enforced HERE — so EVERY
  /// governed route (the tile-swarm handlers included) is subject to the same
  /// check, not only the routes that call `_denyAction` themselves. When a gate
  /// declares NO action, a narrowed / resource-bound / device-bound grant FAILS
  /// CLOSED — on READ gates as well as writes: a least-privilege token must
  /// never inherit blanket authority on an unscoped route. That is what keeps a
  /// "contribute to mosaic 42 only" token off the global co-add / handoff WRITE
  /// routes AND off the action-less READ gates (the swarm target queue, every
  /// tile, the mosaic / co-imaging lists), where a resource-bound grant could
  /// otherwise enumerate other users' and clubs' coordinates and activity. A
  /// plain whole-role token (no narrowing) is unaffected. So a narrowed token
  /// can still poll the artifacts it participates in, every read handler
  /// declares its own read [action] + resource binding, which a resource-bound
  /// grant satisfies for its OWN resource (via the `action != null` path
  /// below). [allowNarrowed] is the single deliberate exception, for
  /// self-revoke (dropping your own token is always permitted, whatever the
  /// token's narrowing).
  ({AuthIdentity? identity, Response? error}) _authorize(
    Request request,
    HubScope required, {
    CollabAction? action,
    String? resourceType,
    String? resourceId,
    bool allowNarrowed = false,
  }) {
    final token = _bearer(request);
    final requestId = request.context['requestId'] as String?;
    if (token == null) {
      return (
        identity: null,
        error: HubError.unauthorized(
          'missing bearer token',
        ).toResponse(requestId: requestId),
      );
    }
    final identity = _tokens.resolve(token);
    if (identity == null) {
      return (
        identity: null,
        error: HubError.unauthorized(
          'invalid or expired token',
        ).toResponse(requestId: requestId),
      );
    }
    if (!identity.scope.satisfies(required)) {
      return (
        identity: null,
        error: HubError.forbidden(
          'requires ${required.name} scope',
        ).toResponse(requestId: requestId),
      );
    }
    if (action != null) {
      final deny = _denyAction(
        request,
        identity,
        action,
        resourceType: resourceType,
        resourceId: resourceId,
      );
      if (deny != null) return (identity: null, error: deny);
    } else if (!allowNarrowed &&
        (identity.grant.actions != null ||
            identity.grant.isResourceBound ||
            identity.grant.deviceId != null)) {
      return (
        identity: null,
        error: HubError.forbidden(
          'this token is narrowed and does not permit this action',
        ).toResponse(requestId: requestId),
      );
    }
    return (identity: identity, error: null);
  }

  // --- Handlers ------------------------------------------------------------

  Response _infoHandler(Request request) {
    return hubJson(<String, Object?>{
      'name': config.name,
      'fingerprint': fingerprint,
      'version': '6.0.0',
      'healpixOrder': config.healpixOrder,
      'tilePixels': config.tilePixels,
      'selfHosted': true,
      'openSignup': config.openSignup,
      'acceptsRawSubs': config.acceptsRawSubs,
      // Consent contract: the client pre-validates its chosen license
      // against `supportedLicenses` before sending any bytes, and learns that
      // every share path requires an explicit consented license up front.
      'requiresConsent': true,
      'supportedLicenses': ConsentService.shareableLicenses.toList(
        growable: false,
      ),
    });
  }

  Future<Response> _createAccountHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    if (!config.openSignup) {
      final auth = _authorize(request, HubScope.admin);
      if (auth.error != null) return auth.error!;
    }
    final body = await _readJson(request);
    final publicKey = body['publicKey'];
    final displayName = body['displayName'];
    if (publicKey is! String || displayName is! String) {
      return HubError.badRequest(
        'publicKey and displayName are required strings',
      ).toResponse(requestId: requestId);
    }
    final password = body['password'];
    try {
      final result = _accounts.signup(
        publicKey: publicKey,
        displayName: displayName,
        password: password is String ? password : null,
      );
      _audit.record(
        method: 'POST',
        path: '/v1/accounts',
        status: 201,
        accountId: result.account.id,
        detail: 'signup',
      );
      return hubJson(<String, Object?>{
        'accountId': result.account.id,
        'bearerToken': result.bearerToken,
        'trust': result.account.trust,
      }, statusCode: 201);
    } on AccountConflict catch (e) {
      return HubError.conflict(
        'accountConflict',
        e.message,
      ).toResponse(requestId: requestId);
    } on ArgumentError catch (e) {
      return HubError.badRequest(
        e.message?.toString() ?? 'invalid account fields',
      ).toResponse(requestId: requestId);
    }
  }

  Future<Response> _loginHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final body = await _readJson(request);
    final publicKey = body['publicKey'];
    final password = body['password'];
    if (publicKey is! String || password is! String) {
      return HubError.badRequest(
        'publicKey and password are required strings',
      ).toResponse(requestId: requestId);
    }
    // Per-account lockout, independent of the IP/token rate limiter: stop
    // credential stuffing against one account even when the attacker rotates
    // source addresses. Keyed by the submitted public key so a key that does
    // not resolve to an account is throttled identically (no existence oracle).
    final accountKey = publicKey.trim();
    _loginThrottle.sweep();
    if (_loginThrottle.isLocked(accountKey)) {
      final retry = _loginThrottle.retryAfterSeconds(accountKey);
      _audit.record(
        method: 'POST',
        path: '/v1/sessions',
        status: 429,
        accountId: null,
        detail: 'login locked out',
      );
      return HubError.rateLimited(
        'too many failed logins for this account',
      ).toResponse(
        requestId: requestId,
        headers: <String, String>{'retry-after': '$retry'},
      );
    }
    final result = _accounts.login(publicKey: publicKey, password: password);
    if (result == null) {
      _loginThrottle.recordFailure(accountKey);
      return HubError.unauthorized(
        'invalid credentials',
      ).toResponse(requestId: requestId);
    }
    _loginThrottle.recordSuccess(accountKey);
    _audit.record(
      method: 'POST',
      path: '/v1/sessions',
      status: 200,
      accountId: result.account.id,
      detail: 'login',
    );
    return hubJson(<String, Object?>{
      'accountId': result.account.id,
      'bearerToken': result.bearerToken,
      'trust': result.account.trust,
    });
  }

  Future<Response> _getTileHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.tileRead,
      resourceType: 'tile',
      resourceId: request.params['tileId'],
    );
    if (auth.error != null) return auth.error!;
    final tileId = int.tryParse(request.params['tileId'] ?? '');
    if (tileId == null) {
      return HubError.badRequest(
        'tileId must be an integer',
      ).toResponse(requestId: requestId);
    }
    final order = _orderQuery(request);
    final finalized =
        (request.url.queryParameters['finalized'] ?? 'true') == 'true';

    final tile = _store.load(tileId, order);
    if (tile == null) {
      return HubError.notFound(
        'no contributions for tile $tileId at order $order',
      ).toResponse(requestId: requestId);
    }

    final headers = <String, String>{
      'content-type': 'application/octet-stream',
      'x-total-frames': '${tile.totalFrames}',
      'x-integration-seconds': '${tile.totalIntegrationSeconds}',
      'x-contributors': '${tile.contributors.length}',
    };
    if (finalized) {
      // The finalized raster (mean per pixel) as raw little-endian f64 — a
      // compact, dependency-free representation the client decodes alongside
      // the tile WCS in the header. (FITS packaging is a client concern.)
      final mean = tile.finalizeMean();
      return Response.ok(mean.buffer.asUint8List(), headers: headers);
    }
    // finalized=false → the merged .skt accumulator bytes themselves.
    final bytes = _store.loadBytes(tileId, order)!;
    return Response.ok(bytes, headers: headers);
  }

  Future<Response> _contributeHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.tileContribute,
      resourceType: 'tile',
      resourceId: request.params['tileId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final tileId = int.tryParse(request.params['tileId'] ?? '');
    if (tileId == null) {
      return HubError.badRequest(
        'tileId must be an integer',
      ).toResponse(requestId: requestId);
    }
    final order = _orderQuery(request);
    final q = request.url.queryParameters;
    final framesDelta = int.tryParse(q['framesDelta'] ?? '') ?? 0;
    final integrationSecondsDelta =
        double.tryParse(q['integrationSecondsDelta'] ?? '') ?? 0.0;
    final medianFwhm = double.tryParse(q['medianFwhm'] ?? '');
    final solver = q['solver'];
    final instrument = q['instrument'];

    // A contribution into the SHARED co-add must carry a parseable,
    // shareable license + recorded consent BEFORE any bytes are read/stored —
    // an un-consented frame is never persisted. 400 when the license is
    // missing/unknown/non-shareable so the client (which pre-validates against
    // `/v1/info supportedLicenses`) learns the request was malformed.
    final consent = _resolveShareConsent(
      request,
      accountId: identity.accountId,
      artifactType: 'tile',
      artifactRef: FusionService.tileArtifactRef(tileId, order),
    );
    if (consent.error != null) return consent.error!;

    final bytes = await _readBinary(request, config.maxContributionBytes);
    if (bytes == null) {
      // Nothing was stored, so the consent recorded before the byte read now
      // guards no artifact — revoke it instead of leaking a live row.
      _consent.revoke(consent.consentId);
      return HubError.payloadTooLarge(
        'contribution exceeds ${config.maxContributionBytes} bytes',
      ).toResponse(requestId: requestId);
    }

    final ContributionOutcome outcome;
    try {
      outcome = _fusion.contribute(
        accountId: identity.accountId,
        tileId: tileId,
        order: order,
        deltaBytes: bytes,
        framesDelta: framesDelta,
        integrationSecondsDelta: integrationSecondsDelta,
        medianFwhm: medianFwhm,
        instrument: instrument,
        solver: solver,
        license: consent.license,
        consentId: consent.consentId,
        anonymous: consent.anonymous,
      );
    } on ContributionRejected catch (e) {
      // A hard reject (geometry / order / channel / range gate) throws before any
      // contribution row is recorded, so the up-front consent guards bytes that
      // were never stored — revoke it before returning the 400.
      _consent.revoke(consent.consentId);
      return HubError(400, e.code, e.message).toResponse(requestId: requestId);
    }
    // Auto-suspend an account that has crossed the rejected-contribution
    // threshold (the abuse auto-flag), so a flood of bad frames stops itself.
    if (!outcome.accepted) {
      _moderation.checkAbuse(identity.accountId);
    }

    _audit.record(
      method: 'POST',
      path: '/v1/tiles/$tileId/contributions',
      status: outcome.accepted ? 200 : 200,
      accountId: identity.accountId,
      detail: outcome.accepted
          ? 'accepted trust=${outcome.trustApplied}'
          : 'rejected ${outcome.verdict.reason}',
    );

    return hubJson(<String, Object?>{
      'contributionId': outcome.contributionId,
      'accepted': outcome.accepted,
      'trustApplied': outcome.trustApplied,
      'totalFramesAfter': outcome.totalFramesAfter,
      'integrationSecondsAfter': outcome.integrationSecondsAfter,
      'contributorsAfter': outcome.contributorsAfter,
      'quality': outcome.verdict.toJson(),
    });
  }

  Future<Response> _retractContributionHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.retract,
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final contributionId = request.params['contributionId'];
    if (contributionId == null || contributionId.isEmpty) {
      return HubError.badRequest(
        'contributionId is required',
      ).toResponse(requestId: requestId);
    }
    try {
      // Admins may retract anyone's contribution; contributors only their own.
      final requesterId = identity.scope == HubScope.admin
          ? null
          : identity.accountId;
      final outcome = _fusion.retract(contributionId, requesterId: requesterId);
      _audit.record(
        method: 'DELETE',
        path: '/v1/contributions/$contributionId',
        status: 200,
        accountId: identity.accountId,
        detail: 'retracted',
      );
      return hubJson(<String, Object?>{
        'retracted': outcome.retracted,
        'totalFramesAfter': outcome.totalFramesAfter,
        'integrationSecondsAfter': outcome.integrationSecondsAfter,
        'contributorsAfter': outcome.contributorsAfter,
      });
    } on ContributionNotFound {
      return HubError.notFound(
        'no such contribution',
      ).toResponse(requestId: requestId);
    } on ContributionForbidden {
      return HubError.forbidden(
        'not your contribution',
      ).toResponse(requestId: requestId);
    } on ContributionStateError catch (e) {
      return HubError.conflict(
        'notRetractable',
        e.message,
      ).toResponse(requestId: requestId);
    }
  }

  /// `POST /v1/tiles/<tileId>/subframes?order=…` — store one raw FITS subframe.
  ///
  /// Gated on [HubConfig.acceptsRawSubs]: when the hub has not opted in, return
  /// 405 so the client surfaces "this hub does not accept raw subframes" rather
  /// than appearing to accept it. Provenance (capturedImageId, instrument,
  /// exposure) rides as query params, mirroring the sums contribution headers.
  Future<Response> _contributeSubframeHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.tileContribute,
      resourceType: 'tile',
      resourceId: request.params['tileId'],
    );
    if (auth.error != null) return auth.error!;
    if (!config.acceptsRawSubs) {
      return HubError(
        405,
        'rawSubsDisabled',
        'this hub does not accept raw subframes',
      ).toResponse(requestId: requestId);
    }
    final identity = auth.identity!;
    final tileId = int.tryParse(request.params['tileId'] ?? '');
    if (tileId == null) {
      return HubError.badRequest(
        'tileId must be an integer',
      ).toResponse(requestId: requestId);
    }
    final order = _orderQuery(request);
    final q = request.url.queryParameters;
    final capturedImageId = int.tryParse(q['capturedImageId'] ?? '');
    final exposureSeconds = double.tryParse(q['exposureSeconds'] ?? '');
    final instrument = q['instrument'];

    // The raw-subframe path is the most privacy-sensitive share (exact
    // pixels + pointing, re-derivable by any reader), so it too requires a
    // parseable shareable license + recorded consent before any bytes land. The
    // consent additionally records the explicit raw-subframe-sharing opt-in.
    final consent = _resolveShareConsent(
      request,
      accountId: identity.accountId,
      artifactType: 'subframe',
      artifactRef: FusionService.tileArtifactRef(tileId, order),
      defaultShareRawSubframes: true,
    );
    if (consent.error != null) return consent.error!;

    final bytes = await _readBinary(request, config.maxSubframeBytes);
    if (bytes == null) {
      return HubError.payloadTooLarge(
        'subframe exceeds ${config.maxSubframeBytes} bytes',
      ).toResponse(requestId: requestId);
    }
    if (bytes.isEmpty) {
      return HubError.badRequest(
        'empty subframe body',
      ).toResponse(requestId: requestId);
    }

    final receipt = _subframes.store(
      accountId: identity.accountId,
      tileId: tileId,
      order: order,
      bytes: bytes,
      capturedImageId: capturedImageId,
      instrument: instrument,
      exposureSeconds: exposureSeconds,
      license: consent.license,
      consentId: consent.consentId,
    );
    _audit.record(
      method: 'POST',
      path: '/v1/tiles/$tileId/subframes',
      status: 200,
      accountId: identity.accountId,
      detail: 'raw subframe ${receipt.storedBytes}B',
    );
    return hubJson(receipt.toJson());
  }

  /// `DELETE /v1/subframes/<contributionId>` — delete a stored raw subframe.
  /// A raw-sub deletion is a FILE-DELETE (the frame is removed), not a clean
  /// subtraction from a co-add — the client copy makes that distinction.
  Future<Response> _deleteSubframeHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.retract,
    );
    if (auth.error != null) return auth.error!;
    if (!config.acceptsRawSubs) {
      return HubError(
        405,
        'rawSubsDisabled',
        'this hub does not accept raw subframes',
      ).toResponse(requestId: requestId);
    }
    final identity = auth.identity!;
    final contributionId = request.params['contributionId'];
    if (contributionId == null || contributionId.isEmpty) {
      return HubError.badRequest(
        'contributionId is required',
      ).toResponse(requestId: requestId);
    }
    try {
      final requesterId = identity.scope == HubScope.admin
          ? null
          : identity.accountId;
      final consentId = _subframes.delete(
        contributionId,
        requesterId: requesterId,
      );
      // A deleted raw frame is no longer consented — mark its consent revoked.
      _consent.revoke(consentId);
      _audit.record(
        method: 'DELETE',
        path: '/v1/subframes/$contributionId',
        status: 200,
        accountId: identity.accountId,
        detail: 'raw subframe deleted',
      );
      return hubJson(<String, Object?>{'deleted': true});
    } on SubframeNotFound {
      return HubError.notFound(
        'no such subframe',
      ).toResponse(requestId: requestId);
    } on SubframeForbidden {
      return HubError.forbidden(
        'not your subframe',
      ).toResponse(requestId: requestId);
    }
  }

  /// `GET /v1/targets` — browse the swarm's shared targets (the entry point to
  /// join / contribute / pull). Emits the client-facing shape
  /// (`SharedTarget.fromJson`): `targetId`, `name`, `raDeg`, `decDeg`,
  /// `integrationSeconds`, `contributors` (distinct accounts on the active tile),
  /// and `activeTileId`.
  Future<Response> _listTargetsHandler(Request request) async {
    // Read action with NO resource binding: a plain read/contribute/admin token
    // browses the global queue, but a resource-bound grant (which permits no
    // action carrying no resource) is confined OUT of the swarm-wide listing.
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.targetRead,
    );
    if (auth.error != null) return auth.error!;
    final targets = _scheduler.listTargets();
    final out = <Map<String, Object?>>[];
    for (final t in targets) {
      final activeTileId = FollowTheNightScheduler.activeTileFor(
        t,
        config.healpixOrder,
      );
      out.add(<String, Object?>{
        'targetId': t.id,
        'name': t.name,
        'raDeg': t.centerRaDeg,
        'decDeg': t.centerDecDeg,
        'integrationSeconds': t.integrationSeconds,
        'contributors': _contributorsForTile(activeTileId, config.healpixOrder),
        'activeTileId': activeTileId,
      });
    }
    return hubJson(<String, Object?>{'targets': out});
  }

  /// Distinct contributor count recorded for a tile in the fused index (0 if the
  /// tile has not been folded into yet).
  int _contributorsForTile(int tileId, int order) {
    final rows = _db.db.select(
      'SELECT contributors FROM tile_index WHERE tile_id = ? AND '
      'healpix_order = ?;',
      <Object?>[tileId, order],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['contributors'] as num?)?.toInt() ?? 0;
  }

  Future<Response> _ensureTargetHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.targetEnsure,
    );
    if (auth.error != null) return auth.error!;
    final body = await _readJson(request);
    final name = body['name'];
    final ra = body['centerRaDeg'];
    final dec = body['centerDecDeg'];
    final radius = body['radiusDeg'];
    if (name is! String || ra is! num || dec is! num || radius is! num) {
      return HubError.badRequest(
        'name, centerRaDeg, centerDecDeg, radiusDeg required',
      ).toResponse(requestId: requestId);
    }
    final priority = body['priority'];
    final id = _scheduler.ensureTarget(
      name: name,
      centerRaDeg: ra.toDouble(),
      centerDecDeg: dec.toDouble(),
      radiusDeg: radius.toDouble(),
      priority: priority is num ? priority.toDouble() : 0.5,
    );
    final target = _scheduler.getTarget(id)!;
    final activeTileId = FollowTheNightScheduler.activeTileFor(
      target,
      config.healpixOrder,
    );
    return hubJson(<String, Object?>{
      'targetId': id,
      // Echo the target back in the SAME client-facing browse shape
      // `GET /v1/targets` uses (`targetId`/`raDeg`/`decDeg`/`activeTileId`) so
      // the client's `SharedTarget.fromJson` decodes it without a second fetch.
      'target': <String, Object?>{
        'targetId': id,
        'name': target.name,
        'raDeg': target.centerRaDeg,
        'decDeg': target.centerDecDeg,
        'integrationSeconds': target.integrationSeconds,
        'contributors': _contributorsForTile(activeTileId, config.healpixOrder),
        'activeTileId': activeTileId,
      },
    });
  }

  Future<Response> _followTheNightHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.handoffManage,
    );
    if (auth.error != null) return auth.error!;
    final q = request.url.queryParameters;
    final lat = double.tryParse(q['latitudeDeg'] ?? '');
    final lon = double.tryParse(q['longitudeDeg'] ?? '');
    if (lat == null || lon == null) {
      return HubError.badRequest(
        'latitudeDeg and longitudeDeg query params are required',
      ).toResponse(requestId: requestId);
    }
    final minAlt = double.tryParse(q['minAltitudeDeg'] ?? '') ?? 25.0;
    final plan = _scheduler.plan(
      latitudeDeg: lat,
      longitudeDeg: lon,
      minAltitudeDeg: minAlt,
    );
    return hubJson(<String, Object?>{
      'plan': plan.map((e) => e.toJson()).toList(),
    });
  }

  Future<Response> _handoffStateHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.handoffManage,
      resourceType: 'target',
      resourceId: request.params['targetId'],
    );
    if (auth.error != null) return auth.error!;
    final targetId = int.tryParse(request.params['targetId'] ?? '');
    if (targetId == null) {
      return HubError.badRequest(
        'targetId must be an integer',
      ).toResponse(requestId: requestId);
    }
    final target = _scheduler.getTarget(targetId);
    if (target == null) {
      return HubError.notFound(
        'no such target',
      ).toResponse(requestId: requestId);
    }
    final state = _handoff.state(targetId);
    final q = request.url.queryParameters;
    final lat = double.tryParse(q['latitudeDeg'] ?? '');
    final lon = double.tryParse(q['longitudeDeg'] ?? '');
    var altitudeOk = true;
    if (lat != null && lon != null) {
      final alt = _scheduler.altitudeForTarget(
        target: target,
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      altitudeOk = alt >= (double.tryParse(q['minAltitudeDeg'] ?? '') ?? 25.0);
    }
    return hubJson(<String, Object?>{
      'targetId': targetId,
      'activeTileId': FollowTheNightScheduler.activeTileFor(
        target,
        config.healpixOrder,
      ),
      'holder': state.holder,
      'altitudeOk': altitudeOk,
      'claimToken': null,
    });
  }

  Future<Response> _handoffClaimHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.handoffManage,
      resourceType: 'target',
      resourceId: request.params['targetId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final targetId = int.tryParse(request.params['targetId'] ?? '');
    if (targetId == null) {
      return HubError.badRequest(
        'targetId must be an integer',
      ).toResponse(requestId: requestId);
    }
    if (_scheduler.getTarget(targetId) == null) {
      return HubError.notFound(
        'no such target',
      ).toResponse(requestId: requestId);
    }
    final claim = _handoff.claim(
      targetId: targetId,
      accountId: identity.accountId,
    );
    if (claim == null) {
      return HubError.conflict(
        'handoffHeld',
        'target $targetId is currently held by another contributor',
      ).toResponse(requestId: requestId);
    }
    return hubJson(<String, Object?>{
      'claimToken': claim.claimToken,
      'expiresAt': claim.expiresAt.toIso8601String(),
    });
  }

  Future<Response> _handoffReleaseHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.handoffManage,
      resourceType: 'target',
      resourceId: request.params['targetId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final targetId = int.tryParse(request.params['targetId'] ?? '');
    if (targetId == null) {
      return HubError.badRequest(
        'targetId must be an integer',
      ).toResponse(requestId: requestId);
    }
    final released = _handoff.release(
      targetId: targetId,
      accountId: identity.accountId,
    );
    return hubJson(<String, Object?>{'released': released});
  }

  // --- Shared calibration libraries ----------------------------------------

  /// `GET /v1/calibration/masters?masterType=&camera=&gain=&offset=&binX=&binY=`
  /// — ranked remote masters matching the sensor + capture tuple. Read scope +
  /// the per-action `calibration.download` grant. The hub does the coarse
  /// sensor-keyed filter; the client re-scores + applies the full quality gate.
  Future<Response> _queryCalibrationMastersHandler(Request request) async {
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.calibrationDownload,
    );
    if (auth.error != null) return auth.error!;
    final q = request.url.queryParameters;
    final masters = _calibration.query(
      masterType: q['masterType'],
      cameraModel: q['camera'],
      gain: int.tryParse(q['gain'] ?? ''),
      offset: int.tryParse(q['offset'] ?? ''),
      binX: int.tryParse(q['binX'] ?? ''),
      binY: int.tryParse(q['binY'] ?? ''),
      // Scope shared FLATS to the requesting owner: a flat is only valid on the
      // exact physical train that produced it, and train names are not globally
      // unique, so cross-account flat reuse is never offered.
      requesterAccountId: auth.identity!.accountId,
      limit: int.tryParse(q['limit'] ?? '') ?? 50,
    );
    return hubJson(<String, Object?>{
      'masters': masters.map((m) => m.toJson()).toList(),
    });
  }

  /// Decode the `x-provenance-json` header into the raw provenance JSON string.
  ///
  /// The client transports it as `base64(utf8(json))` so a provenance whose
  /// attribution / camera model / notes carry non-Latin-1 characters (CJK,
  /// emoji, …) survives `dart:io`'s ASCII-only HTTP header validation. A legacy
  /// or hand-rolled caller that sends the JSON verbatim still works: a raw JSON
  /// object always contains `{` / `"` / `:` characters outside the base64
  /// alphabet, so [base64.decode] throws and we fall back to the literal value.
  static String? _decodeProvenanceHeader(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return utf8.decode(base64.decode(raw));
    } on FormatException {
      return raw;
    }
  }

  /// `POST /v1/calibration/masters` — publish a master (consent-gated). The
  /// calibration tuple + license ride as query params, the `Provenance` JSON as
  /// the base64-encoded `x-provenance-json` header, and the master FITS as the
  /// binary body. Contribute scope + the per-action `calibration.publish` grant.
  Future<Response> _publishCalibrationMasterHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.calibrationPublish,
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final q = request.url.queryParameters;
    final masterType = q['masterType'];
    final camera = q['camera'];
    final license = q['license'];
    if (masterType == null || camera == null || license == null) {
      return HubError.badRequest(
        'masterType, camera, and license query params are required',
      ).toResponse(requestId: requestId);
    }
    final bytes = await _readBinary(request, config.maxSubframeBytes);
    if (bytes == null) {
      return HubError.payloadTooLarge(
        'master exceeds ${config.maxSubframeBytes} bytes',
      ).toResponse(requestId: requestId);
    }
    try {
      final row = _calibration.publish(
        accountId: identity.accountId,
        masterType: masterType,
        cameraModel: camera,
        license: license,
        bytes: bytes,
        sensorWidth: int.tryParse(q['sensorWidth'] ?? '') ?? 0,
        sensorHeight: int.tryParse(q['sensorHeight'] ?? '') ?? 0,
        gain: int.tryParse(q['gain'] ?? '') ?? 0,
        offset: int.tryParse(q['offset'] ?? '') ?? 0,
        exposureSeconds: double.tryParse(q['exposureSeconds'] ?? '') ?? 0.0,
        temperatureC: double.tryParse(q['temperatureC'] ?? ''),
        binX: int.tryParse(q['binX'] ?? '') ?? 1,
        binY: int.tryParse(q['binY'] ?? '') ?? 1,
        filter: q['filter'],
        opticalTrain: q['opticalTrain'],
        frameCount: int.tryParse(q['frameCount'] ?? '') ?? 0,
        darkCurrent: double.tryParse(q['darkCurrent'] ?? ''),
        provenanceJson: _decodeProvenanceHeader(
          request.headers['x-provenance-json'],
        ),
      );
      // Consent ledger: a published master is a SHARED, downloadable artifact
      // exactly like a tile / mosaic-panel / co-imaging contribution, so — for
      // parity with those paths — record a durable `consent_records` row keyed to
      // the new master under the license the service already validated shareable.
      // This is the retract-revocable proof that the producer consented to the
      // share; a shared master carries no raw subframes, and the derivative /
      // redistribution / named-credit rights ride as optional flags. The service
      // has already rejected an un-shareable license (`unsharableLicense`, 400),
      // so a consent row is only ever recorded for an accepted master.
      _consent.record(
        accountId: identity.accountId,
        artifactType: 'calibration',
        artifactRef: row.id,
        license: row.license,
        allowDerivatives: _flag(
          request,
          'allowDerivatives',
          q,
          defaultValue: false,
        ),
        allowRedistribution: _flag(
          request,
          'allowRedistribution',
          q,
          defaultValue: false,
        ),
        attributionConsent: _flag(
          request,
          'attributionConsent',
          q,
          defaultValue: true,
        ),
      );
      _audit.record(
        method: 'POST',
        path: '/v1/calibration/masters',
        status: 201,
        accountId: identity.accountId,
        detail: 'published ${row.masterType} master ${row.id}',
      );
      return hubJson(row.toJson(), statusCode: 201);
    } on CalibrationPublishRejected catch (e) {
      // A content-integrity rejection (poison FITS bytes / spoofed geometry —
      // the FITS-parse, dimension-mismatch, and pixel-sanity codes) is a
      // poison-flood signal, so map it to 422: [_auditDenialMiddleware] audits
      // the denial and re-runs `checkAbuse`, the same uniform choke point the
      // co-imaging implausible-report 422 and the tile-fusion soft-reject use.
      // A benign malformed request (unsharable type/license, missing camera,
      // flat without an optical train, empty/undeclared geometry) stays a 400 so
      // an honest-but-wrong client never accrues against the abuse auto-suspend.
      return HubError(
        e.contentIntegrity ? 422 : 400,
        e.code,
        e.message,
      ).toResponse(requestId: requestId);
    }
  }

  /// `GET /v1/calibration/masters/<id>/file` — download a chosen master's bytes
  /// (download-on-accept). Read scope + `calibration.download`. Metadata rides
  /// in headers so the puller can verify provenance against the query result.
  Future<Response> _downloadCalibrationMasterHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.calibrationDownload,
      resourceType: 'calibration',
      resourceId: request.params['id'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final id = request.params['id'];
    if (id == null || id.isEmpty) {
      return HubError.badRequest(
        'id is required',
      ).toResponse(requestId: requestId);
    }
    final row = _calibration.get(id);
    if (row == null) {
      return HubError.notFound(
        'no such calibration master',
      ).toResponse(requestId: requestId);
    }
    // Re-enforce the cross-account flat-scoping invariant at the data-egress
    // point, not just in query(): a flat encodes dust/vignetting unique to one
    // physical optical train and is never valid across accounts. A non-owner
    // (non-admin) download of a foreign flat is refused as 404 — preferring
    // not-found over forbidden so a guessed/leaked id is not an existence oracle.
    if (row.masterType == 'flat' &&
        identity.scope != HubScope.admin &&
        row.accountId != identity.accountId) {
      return HubError.notFound(
        'no such calibration master',
      ).toResponse(requestId: requestId);
    }
    final bytes = _calibration.bytesFor(row);
    if (bytes == null) {
      return HubError.notFound(
        'calibration master file is missing',
      ).toResponse(requestId: requestId);
    }
    return Response.ok(
      bytes,
      headers: <String, String>{
        'content-type': 'application/octet-stream',
        'x-master-id': row.id,
        'x-master-type': row.masterType,
        'x-frame-count': '${row.frameCount}',
        'x-license': row.license,
        // The AUTHORITATIVE matching tuple (gain/offset/exposure/temperature/
        // binning/geometry/filter/optical train/provenance), so the puller
        // records what the hub actually stores rather than whatever metadata
        // its caller handed it. Without this a client that posts back a
        // mutated match result silently files the bytes under the wrong tuple
        // and calibrates future lights with a mismatched master. Transported as
        // base64(utf8(json)) for the same reason `x-provenance-json` is: a raw
        // JSON header value is not ASCII/header-safe once a camera model or
        // attribution name carries non-Latin-1 characters.
        'x-master-meta': base64.encode(utf8.encode(jsonEncode(row.toJson()))),
      },
    );
  }

  /// `DELETE /v1/calibration/masters/<id>` — retract a published master.
  /// Contribute scope + the `retract` grant; owners retract their own, admins
  /// anyone's.
  Future<Response> _deleteCalibrationMasterHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.retract,
      resourceType: 'calibration',
      resourceId: request.params['id'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final id = request.params['id'];
    if (id == null || id.isEmpty) {
      return HubError.badRequest(
        'id is required',
      ).toResponse(requestId: requestId);
    }
    try {
      final requesterId = identity.scope == HubScope.admin
          ? null
          : identity.accountId;
      _calibration.delete(id, requesterId: requesterId);
      // A retracted master is no longer shared — mark its consent record revoked
      // (mirrors the raw-subframe delete + mosaic force-release consent-revoke).
      _consent.revokeForArtifact('calibration', id);
      _audit.record(
        method: 'DELETE',
        path: '/v1/calibration/masters/$id',
        status: 200,
        accountId: identity.accountId,
        detail: 'retracted calibration master',
      );
      return hubJson(<String, Object?>{'deleted': true});
    } on CalibrationMasterNotFound {
      return HubError.notFound(
        'no such calibration master',
      ).toResponse(requestId: requestId);
    } on CalibrationMasterForbidden {
      return HubError.forbidden(
        'not your calibration master',
      ).toResponse(requestId: requestId);
    }
  }

  // --- Collaborative mosaics -----------------------------------------------

  /// `POST /v1/mosaics` — publish a MosaicProject's panel grid as claimable work
  /// items. Contribute scope + the per-action `mosaic.publish` grant. Body:
  /// name, rows, cols, overlapPct, positionAngleDeg, centerRaDeg/DecDeg,
  /// panels:[{panelIndex, centerRaDeg, centerDecDeg}]; owner = caller.
  Future<Response> _publishMosaicHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.mosaicPublish,
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final body = await _readJson(request);
    final name = body['name'];
    final rows = body['rows'];
    final cols = body['cols'];
    final centerRa = body['centerRaDeg'];
    final centerDec = body['centerDecDeg'];
    final panelsRaw = body['panels'];
    if (name is! String ||
        rows is! num ||
        cols is! num ||
        centerRa is! num ||
        centerDec is! num ||
        panelsRaw is! List) {
      return HubError.badRequest(
        'name, rows, cols, centerRaDeg, centerDecDeg, and panels[] are required',
      ).toResponse(requestId: requestId);
    }
    final panels = <MosaicPanelSpec>[];
    for (final entry in panelsRaw) {
      if (entry is! Map) {
        return HubError.badRequest(
          'each panel must be an object',
        ).toResponse(requestId: requestId);
      }
      final idx = entry['panelIndex'];
      final pRa = entry['centerRaDeg'];
      final pDec = entry['centerDecDeg'];
      if (idx is! num || pRa is! num || pDec is! num) {
        return HubError.badRequest(
          'each panel needs panelIndex, centerRaDeg, centerDecDeg',
        ).toResponse(requestId: requestId);
      }
      panels.add(
        MosaicPanelSpec(
          panelIndex: idx.toInt(),
          centerRaDeg: pRa.toDouble(),
          centerDecDeg: pDec.toDouble(),
        ),
      );
    }
    if (panels.isEmpty) {
      return HubError.badRequest(
        'a mosaic must publish at least one panel',
      ).toResponse(requestId: requestId);
    }
    final overlapPct = body['overlapPct'];
    final pa = body['positionAngleDeg'];
    final mosaicId = _mosaicBroker.publish(
      ownerAccountId: identity.accountId,
      name: name,
      rows: rows.toInt(),
      cols: cols.toInt(),
      centerRaDeg: centerRa.toDouble(),
      centerDecDeg: centerDec.toDouble(),
      panels: panels,
      overlapPct: overlapPct is num ? overlapPct.toDouble() : 15.0,
      positionAngleDeg: pa is num ? pa.toDouble() : 0.0,
    );
    _audit.record(
      method: 'POST',
      path: '/v1/mosaics',
      status: 201,
      accountId: identity.accountId,
      detail: 'published mosaic $mosaicId (${panels.length} panels)',
    );
    final mosaic = _mosaicBroker.getMosaic(mosaicId)!;
    // The publisher is the owner — privileged, so the response echoes the raw
    // account ids it already knows alongside the resolved display names.
    return hubJson(
      _mosaicJson(mosaic, identity: identity, privileged: true),
      statusCode: 201,
    );
  }

  /// `GET /v1/mosaics` — list open/claimable collaborative mosaics. Read scope.
  Future<Response> _listMosaicsHandler(Request request) async {
    // Unbound read action: a resource-bound grant cannot enumerate the
    // swarm-wide mosaic list (other clubs' targets + owner display names).
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.mosaicRead,
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    return hubJson(<String, Object?>{
      'mosaics': _mosaicBroker
          .listMosaics()
          // Per-mosaic privilege: the raw account ids are exposed only to the
          // owner / a participant / an admin; everyone else sees coarse state +
          // a resolved owner display name for attribution.
          .map(
            (m) => _mosaicJson(
              m,
              identity: identity,
              privileged: _isMosaicPrivileged(m, identity),
              includePanels: false,
            ),
          )
          .toList(),
    });
  }

  /// `GET /v1/mosaics/<mosaicId>` — mosaic + per-panel state. Read scope.
  Future<Response> _getMosaicHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.mosaicRead,
      resourceType: 'mosaic',
      resourceId: request.params['mosaicId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final mosaicId = request.params['mosaicId'];
    if (mosaicId == null || mosaicId.isEmpty) {
      return HubError.badRequest(
        'mosaicId is required',
      ).toResponse(requestId: requestId);
    }
    final mosaic = _mosaicBroker.getMosaic(mosaicId);
    if (mosaic == null) {
      return HubError.notFound(
        'no such mosaic',
      ).toResponse(requestId: requestId);
    }
    return hubJson(
      _mosaicJson(
        mosaic,
        identity: identity,
        privileged: _isMosaicPrivileged(mosaic, identity),
      ),
    );
  }

  /// Whether [identity] may see a mosaic's raw internal account ids: the owner,
  /// any contributing participant, or an admin (for moderation). Mirrors the
  /// per-participant scoping the blob-download handlers enforce, applied to the
  /// metadata so an arbitrary read token can no longer enumerate
  /// account -> panel -> contributor.
  bool _isMosaicPrivileged(
    CollaborativeMosaicRow mosaic,
    AuthIdentity identity,
  ) =>
      identity.scope == HubScope.admin ||
      _mosaicBroker.isParticipant(mosaic.id, identity.accountId);

  /// Build the mosaic JSON body with privacy-scoped account ids + server-resolved
  /// display-name attribution. [privileged] gates the raw account ids; display
  /// names are always resolved from the accounts table so a non-participant still
  /// gets attribution. When [includePanels] is true the per-panel state is folded
  /// in under the same scoping.
  Map<String, Object?> _mosaicJson(
    CollaborativeMosaicRow mosaic, {
    required AuthIdentity identity,
    required bool privileged,
    bool includePanels = true,
  }) {
    return <String, Object?>{
      ...mosaic.toJson(
        includeAccountId: privileged,
        ownerDisplayName: _accounts.getById(mosaic.ownerAccountId)?.displayName,
      ),
      if (includePanels)
        'panels': _mosaicBroker.panelStates(mosaic.id).map((p) {
          final acct = p.assignedAccountId;
          return p.toJson(
            includeAccountId: privileged,
            assignedDisplayName: acct == null
                ? null
                : _accounts.getById(acct)?.displayName,
          );
        }).toList(),
    };
  }

  /// `POST /v1/mosaics/<mosaicId>/panels/<panelIndex>/claim` — take the panel
  /// baton. Contribute + `mosaic.claim`. 409 `mosaicPanelHeld` when another rig
  /// holds it (mirrors handoff `handoffHeld`).
  Future<Response> _claimMosaicPanelHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.mosaicClaim,
      resourceType: 'mosaic',
      resourceId: request.params['mosaicId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final mosaicId = request.params['mosaicId'];
    final panelIndex = int.tryParse(request.params['panelIndex'] ?? '');
    if (mosaicId == null || mosaicId.isEmpty || panelIndex == null) {
      return HubError.badRequest(
        'mosaicId and integer panelIndex are required',
      ).toResponse(requestId: requestId);
    }
    final q = request.url.queryParameters;
    try {
      final claim = _mosaicBroker.claimPanel(
        mosaicId: mosaicId,
        panelIndex: panelIndex,
        accountId: identity.accountId,
        rigId: q['rigId'],
      );
      if (claim == null) {
        return HubError.conflict(
          'mosaicPanelHeld',
          'panel $panelIndex of mosaic $mosaicId is held by another rig or '
              'already uploaded',
        ).toResponse(requestId: requestId);
      }
      _audit.record(
        method: 'POST',
        path: '/v1/mosaics/$mosaicId/panels/$panelIndex/claim',
        status: 200,
        accountId: identity.accountId,
        detail: 'claimed panel',
      );
      return hubJson(claim.toJson());
    } on MosaicNotFound {
      return HubError.notFound(
        'no such mosaic',
      ).toResponse(requestId: requestId);
    } on MosaicPanelNotFound {
      return HubError.notFound(
        'no such panel',
      ).toResponse(requestId: requestId);
    }
  }

  /// `POST /v1/mosaics/<mosaicId>/panels/<panelIndex>/release` — give the baton
  /// back if held. Contribute + `mosaic.claim`.
  Future<Response> _releaseMosaicPanelHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.mosaicClaim,
      resourceType: 'mosaic',
      resourceId: request.params['mosaicId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final mosaicId = request.params['mosaicId'];
    final panelIndex = int.tryParse(request.params['panelIndex'] ?? '');
    if (mosaicId == null || mosaicId.isEmpty || panelIndex == null) {
      return HubError.badRequest(
        'mosaicId and integer panelIndex are required',
      ).toResponse(requestId: requestId);
    }
    final released = _mosaicBroker.releasePanel(
      mosaicId: mosaicId,
      panelIndex: panelIndex,
      accountId: identity.accountId,
    );
    return hubJson(<String, Object?>{'released': released});
  }

  /// `POST /v1/mosaics/<mosaicId>/panels/<panelIndex>/force-release` — owner/admin
  /// eviction of a squatting claim OR a bogus upload that poisoned a panel slot.
  /// Contribute + `mosaic.claim`; the broker additionally enforces that the
  /// caller is the mosaic OWNER (or an admin), and resets the panel to `pending`
  /// (clearing any uploaded master), re-arming the all-panels gate. 403 when the
  /// caller is neither owner nor admin; 404 when there is nothing to evict.
  Future<Response> _forceReleaseMosaicPanelHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.mosaicClaim,
      resourceType: 'mosaic',
      resourceId: request.params['mosaicId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final mosaicId = request.params['mosaicId'];
    final panelIndex = int.tryParse(request.params['panelIndex'] ?? '');
    if (mosaicId == null || mosaicId.isEmpty || panelIndex == null) {
      return HubError.badRequest(
        'mosaicId and integer panelIndex are required',
      ).toResponse(requestId: requestId);
    }
    final mosaic = _mosaicBroker.getMosaic(mosaicId);
    if (mosaic == null) {
      return HubError.notFound(
        'no such mosaic',
      ).toResponse(requestId: requestId);
    }
    final isAdmin = identity.scope == HubScope.admin;
    if (!isAdmin && mosaic.ownerAccountId != identity.accountId) {
      return HubError.forbidden(
        'only the mosaic owner or an admin may force-release a panel',
      ).toResponse(requestId: requestId);
    }
    // Capture the evicted panel's recorded share consent BEFORE the reset clears
    // the row, so an evicted master's consent can be revoked once it is gone.
    final evictedConsentId = _mosaicBroker.panelConsentId(mosaicId, panelIndex);
    final released = _mosaicBroker.forceReleasePanel(
      mosaicId: mosaicId,
      panelIndex: panelIndex,
      accountId: identity.accountId,
      isAdmin: isAdmin,
    );
    if (!released) {
      return HubError.notFound(
        'no such panel, or the panel is already free',
      ).toResponse(requestId: requestId);
    }
    // A force-released panel's master is removed from the shared mosaic, so its
    // recorded share consent no longer applies — revoke it (mirrors the raw-
    // subframe delete path).
    _consent.revoke(evictedConsentId);
    _audit.record(
      method: 'POST',
      path: '/v1/mosaics/$mosaicId/panels/$panelIndex/force-release',
      status: 200,
      accountId: identity.accountId,
      detail: 'force-released panel${isAdmin ? ' (admin)' : ' (owner)'}',
    );
    return hubJson(<String, Object?>{'released': released});
  }

  /// `POST /v1/mosaics/<mosaicId>/panels/<panelIndex>/master?rigId=…` — stream a
  /// panel master FITS up (up to [HubConfig.maxSubframeBytes]). Contribute +
  /// `mosaic.upload`, and the caller MUST currently hold the panel claim
  /// (`x-claim-token` header match OR assigned account). On the final upload —
  /// when every panel has landed — the mosaic auto-flips to `assembling`.
  Future<Response> _uploadMosaicPanelMasterHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.mosaicUpload,
      resourceType: 'mosaic',
      resourceId: request.params['mosaicId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final mosaicId = request.params['mosaicId'];
    final panelIndex = int.tryParse(request.params['panelIndex'] ?? '');
    if (mosaicId == null || mosaicId.isEmpty || panelIndex == null) {
      return HubError.badRequest(
        'mosaicId and integer panelIndex are required',
      ).toResponse(requestId: requestId);
    }
    if (_mosaicBroker.getMosaic(mosaicId) == null) {
      return HubError.notFound(
        'no such mosaic',
      ).toResponse(requestId: requestId);
    }
    // Upload gate: only the current claim holder may upload that panel's master,
    // so a non-holder can never overwrite a panel another rig is capturing.
    if (!_mosaicBroker.holdsClaim(
      mosaicId: mosaicId,
      panelIndex: panelIndex,
      accountId: identity.accountId,
      claimToken: request.headers['x-claim-token'],
    )) {
      return HubError.forbidden(
        'you do not hold the claim for panel $panelIndex',
      ).toResponse(requestId: requestId);
    }
    // Consent gate: a panel master is streamed into a SHARED, redistributable
    // mosaic that every participant later pulls, so — exactly like a tile / raw
    // subframe contribution — it requires a parseable, shareable license +
    // recorded consent BEFORE any bytes are read or stored. 400 when the license
    // is missing/unknown/non-shareable so the client (which pre-validates against
    // `/v1/info supportedLicenses`) learns the request was malformed; the recorded
    // consent id + license + named-vs-anonymous choice are persisted on the panel
    // so the finalize attribution credits under the right license/anonymity and a
    // force-release can revoke the consent.
    final consent = _resolveShareConsent(
      request,
      accountId: identity.accountId,
      artifactType: 'mosaic',
      artifactRef: mosaicId,
    );
    if (consent.error != null) return consent.error!;
    final bytes = await _readBinary(request, config.maxSubframeBytes);
    if (bytes == null) {
      // No master was stored, so the consent recorded before the byte read guards
      // nothing — revoke it rather than leaking a live `(mosaic, mosaicId)` row.
      _consent.revoke(consent.consentId);
      return HubError.payloadTooLarge(
        'panel master exceeds ${config.maxSubframeBytes} bytes',
      ).toResponse(requestId: requestId);
    }
    if (bytes.isEmpty) {
      _consent.revoke(consent.consentId);
      return HubError.badRequest(
        'empty panel master body',
      ).toResponse(requestId: requestId);
    }
    // Server-side sanity gate: the WCS/plate-solve check lives client-side in
    // CollaborativeMosaicService.uploadPanelMaster, so a rig hitting the raw
    // REST API could otherwise store arbitrary bytes as a panel master that the
    // assembler then feeds into the stitch. Reject anything that is not at least
    // a FITS file (the SIMPLE primary-header magic) up front so a single bogus
    // upload cannot permanently poison the slot with non-image garbage.
    if (!_looksLikeFits(bytes)) {
      // The non-FITS body is refused before any master is stored, so the up-front
      // consent guards nothing — revoke it before returning the 400.
      _consent.revoke(consent.consentId);
      return HubError.badRequest(
        'panel master is not a FITS file (missing SIMPLE primary header)',
      ).toResponse(requestId: requestId);
    }
    final masterId = const Uuid().v4();
    final path = _mosaicStore.savePanelMaster(
      mosaicId: mosaicId,
      panelIndex: panelIndex,
      masterId: masterId,
      bytes: bytes,
    );
    final q = request.url.queryParameters;
    final panel = _mosaicBroker.recordUpload(
      mosaicId: mosaicId,
      panelIndex: panelIndex,
      accountId: identity.accountId,
      masterId: masterId,
      path: path,
      rigId: q['rigId'],
      claimToken: request.headers['x-claim-token'],
      consentId: consent.consentId,
      license: consent.license,
      attributionConsent: !consent.anonymous,
    );
    if (panel == null) {
      // The claim was lost while the (potentially large) master streamed in — an
      // owner/admin force-release or a claim-expiry + re-claim landed during the
      // `await _readBinary` above. recordUpload refused to clobber the new panel
      // state, so the bytes we just stored are orphaned and the consent we
      // recorded up front guards nothing: delete the master and revoke the
      // consent (exactly how the tile/subframe paths self-heal on a post-read
      // failure), then 409 so the client re-claims before retrying.
      _mosaicStore.delete(path);
      _consent.revoke(consent.consentId);
      _audit.record(
        method: 'POST',
        path: '/v1/mosaics/$mosaicId/panels/$panelIndex/master',
        status: 409,
        accountId: identity.accountId,
        detail: 'panel claim lost mid-upload; master discarded',
      );
      return HubError.conflict(
        'mosaicPanelHeld',
        'the claim for panel $panelIndex of mosaic $mosaicId was released or '
            'reassigned while the master uploaded; re-claim and retry',
      ).toResponse(requestId: requestId);
    }
    // Partial-set gate: only when EVERY panel has uploaded does the mosaic move
    // to `assembling` (the owner rig then pulls + stitches). Until then it stays
    // `open` and the output download 404s.
    final allIn = _mosaicBroker.allPanelsUploaded(mosaicId);
    if (allIn) _mosaicBroker.markAssembling(mosaicId);
    _audit.record(
      method: 'POST',
      path: '/v1/mosaics/$mosaicId/panels/$panelIndex/master',
      status: 200,
      accountId: identity.accountId,
      detail: 'uploaded panel master ${bytes.length}B',
    );
    // The uploader holds the claim — a privileged participant — so its own
    // panel state echoes the account id + resolved display name back.
    return hubJson(<String, Object?>{
      ...panel.toJson(
        includeAccountId: true,
        assignedDisplayName: panel.assignedAccountId == null
            ? null
            : _accounts.getById(panel.assignedAccountId!)?.displayName,
      ),
      'allPanelsUploaded': allIn,
    });
  }

  /// Whether [bytes] begin with a FITS primary header — the `SIMPLE  = T` magic
  /// card at offset 0. A minimal, dependency-free integrity check (the hub is
  /// pure-Dart with no FITS reader): the first 80-char card must be a `SIMPLE`
  /// keyword whose logical value is `T`.
  static bool _looksLikeFits(List<int> bytes) {
    if (bytes.length < 80) return false;
    final firstCard = String.fromCharCodes(bytes.sublist(0, 80));
    if (!firstCard.startsWith('SIMPLE')) return false;
    final eq = firstCard.indexOf('=');
    if (eq < 0) return false;
    return firstCard.substring(eq + 1).trimLeft().startsWith('T');
  }

  /// `GET /v1/mosaics/<mosaicId>/panels/<panelIndex>/master` — download a panel
  /// master (the assembler pulls every panel). Read scope.
  Future<Response> _downloadMosaicPanelMasterHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.mosaicDownload,
      resourceType: 'mosaic',
      resourceId: request.params['mosaicId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final mosaicId = request.params['mosaicId'];
    final panelIndex = int.tryParse(request.params['panelIndex'] ?? '');
    if (mosaicId == null || mosaicId.isEmpty || panelIndex == null) {
      return HubError.badRequest(
        'mosaicId and integer panelIndex are required',
      ).toResponse(requestId: requestId);
    }
    final mosaic = _mosaicBroker.getMosaic(mosaicId);
    if (mosaic == null) {
      return HubError.notFound(
        'no such mosaic',
      ).toResponse(requestId: requestId);
    }
    // Per-panel scoping: a panel master is one contributor's RAW integrated FITS
    // — the most sensitive blob in the mosaic. Only admins (moderation), the
    // mosaic OWNER (the assembler, who legitimately pulls every panel to stitch),
    // or the rig that produced THIS panel (re-pulling its own data) may download
    // it. We deliberately do NOT use isParticipant here: that returns true for
    // any account assigned ANY panel, which would let a hostile contribute-scoped
    // user claim one throwaway panel and then exfiltrate every peer's raw imaging
    // data. The download is scoped to the requested panel, never all panels.
    final isOwner = mosaic.ownerAccountId == identity.accountId;
    final ownsThisPanel =
        _mosaicBroker.panelAssignedAccount(mosaicId, panelIndex) ==
        identity.accountId;
    if (identity.scope != HubScope.admin && !isOwner && !ownsThisPanel) {
      return HubError.forbidden(
        'not authorized to download this panel master',
      ).toResponse(requestId: requestId);
    }
    final path = _mosaicBroker.panelMasterPath(mosaicId, panelIndex);
    if (path == null) {
      return HubError.notFound(
        'panel $panelIndex has no uploaded master',
      ).toResponse(requestId: requestId);
    }
    final response = _streamFile(path);
    if (response == null) {
      return HubError.notFound(
        'panel master file is missing',
      ).toResponse(requestId: requestId);
    }
    return response;
  }

  /// `POST /v1/mosaics/<mosaicId>/output` — stream the finished stitched mosaic
  /// up (up to [HubConfig.maxMosaicMasterBytes]). Contribute + `mosaic.upload`,
  /// OWNER-ONLY (owner_account_id == caller). Marks the mosaic `complete`.
  Future<Response> _uploadMosaicOutputHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.mosaicUpload,
      resourceType: 'mosaic',
      resourceId: request.params['mosaicId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final mosaicId = request.params['mosaicId'];
    if (mosaicId == null || mosaicId.isEmpty) {
      return HubError.badRequest(
        'mosaicId is required',
      ).toResponse(requestId: requestId);
    }
    final mosaic = _mosaicBroker.getMosaic(mosaicId);
    if (mosaic == null) {
      return HubError.notFound(
        'no such mosaic',
      ).toResponse(requestId: requestId);
    }
    if (mosaic.ownerAccountId != identity.accountId) {
      return HubError.forbidden(
        'only the mosaic owner may upload the finished output',
      ).toResponse(requestId: requestId);
    }
    // All-panels-uploaded gate: the mosaic must be `assembling` (every panel has
    // landed and it auto-flipped on the final upload). Accepting an output while
    // panels are still pending/claimed would publish an incomplete mosaic as
    // `complete` to every participant and silently drop the contributors still
    // mid-capture — the exact integrity property this workstream gates on.
    if (mosaic.status != 'assembling') {
      return HubError(
        409,
        'mosaicNotAssembling',
        'mosaic is "${mosaic.status}", not "assembling" — the finished output '
            'is only accepted once every panel has been uploaded',
      ).toResponse(requestId: requestId);
    }
    final bytes = await _readBinary(request, config.maxMosaicMasterBytes);
    if (bytes == null) {
      return HubError.payloadTooLarge(
        'mosaic output exceeds ${config.maxMosaicMasterBytes} bytes',
      ).toResponse(requestId: requestId);
    }
    if (bytes.isEmpty) {
      return HubError.badRequest(
        'empty mosaic output body',
      ).toResponse(requestId: requestId);
    }
    final masterId = const Uuid().v4();
    final path = _mosaicStore.saveOutput(
      mosaicId: mosaicId,
      masterId: masterId,
      bytes: bytes,
    );
    // markComplete re-checks the `assembling` precondition atomically (no await
    // since the status read above), so a status that raced out from under us
    // (e.g. a concurrent completion) is a 409 rather than a silent overwrite.
    if (!_mosaicBroker.markComplete(mosaicId, outputPath: path)) {
      return HubError(
        409,
        'mosaicNotAssembling',
        'mosaic is no longer assembling — output rejected',
      ).toResponse(requestId: requestId);
    }
    // Attribution: a finished mosaic credits every rig that contributed a
    // panel. One credit per uploaded panel (frames=1) so the contributor-credits
    // UI lists each participant ordered by panels contributed.
    for (final panel in _mosaicBroker.panelStates(mosaicId)) {
      final acct = panel.assignedAccountId;
      if (panel.isUploaded && acct != null) {
        _attribution.recordAccepted(
          artifactType: 'mosaic',
          artifactRef: mosaicId,
          accountId: acct,
          frames: 1,
          license: panel.license,
          // Honour the contributor's attribution consent recorded at upload: a
          // panel shared without named-credit consent is credited anonymously.
          anonymous: !panel.attributionConsent,
        );
      }
    }
    _audit.record(
      method: 'POST',
      path: '/v1/mosaics/$mosaicId/output',
      status: 200,
      accountId: identity.accountId,
      detail: 'uploaded stitched mosaic ${bytes.length}B',
    );
    // The uploader is the owner — privileged.
    return hubJson(
      _mosaicJson(
        _mosaicBroker.getMosaic(mosaicId)!,
        identity: identity,
        privileged: true,
        includePanels: false,
      ),
    );
  }

  /// `GET /v1/mosaics/<mosaicId>/output` — download the finished mosaic. Read
  /// scope. 404 until the mosaic is `complete` (the partial-set gate).
  Future<Response> _downloadMosaicOutputHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.mosaicDownload,
      resourceType: 'mosaic',
      resourceId: request.params['mosaicId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final mosaicId = request.params['mosaicId'];
    if (mosaicId == null || mosaicId.isEmpty) {
      return HubError.badRequest(
        'mosaicId is required',
      ).toResponse(requestId: requestId);
    }
    // Owner/participant scoping (mirrors the panel-master pull): the finished
    // mosaic is served only to the owner + contributing rigs, never to an
    // unrelated account that merely holds a read token. Admins may moderate.
    if (identity.scope != HubScope.admin &&
        !_mosaicBroker.isParticipant(mosaicId, identity.accountId)) {
      return HubError.forbidden(
        'not a participant of this mosaic',
      ).toResponse(requestId: requestId);
    }
    final path = _mosaicBroker.outputPathFor(mosaicId);
    if (path == null) {
      return HubError.notFound(
        'mosaic is not complete yet',
      ).toResponse(requestId: requestId);
    }
    final response = _streamFile(path);
    if (response == null) {
      return HubError.notFound(
        'mosaic output file is missing',
      ).toResponse(requestId: requestId);
    }
    return response;
  }

  // --- Live co-imaging sessions --------------------------------------------

  /// `POST /v1/coimaging/sessions` — open a live co-imaging session on a target.
  /// Contribute + `coimaging.join`. Body: targetName, centerRaDeg, centerDecDeg,
  /// optional radiusDeg/priority/rigId. The caller is the owner + anchor
  /// participant (slot 0); the response echoes its membership token + offset.
  Future<Response> _createCoImagingSessionHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.coimagingJoin,
      resourceType: 'coimaging',
      resourceId: request.params['sessionId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final body = await _readJson(request);
    final name = body['targetName'];
    final ra = body['centerRaDeg'];
    final dec = body['centerDecDeg'];
    if (name is! String || name.trim().isEmpty || ra is! num || dec is! num) {
      return HubError.badRequest(
        'targetName, centerRaDeg, and centerDecDeg are required',
      ).toResponse(requestId: requestId);
    }
    final radius = body['radiusDeg'];
    final priority = body['priority'];
    final rigId = body['rigId'];
    final sessionId = _coimaging.createSession(
      ownerAccountId: identity.accountId,
      targetName: name,
      centerRaDeg: ra.toDouble(),
      centerDecDeg: dec.toDouble(),
      radiusDeg: radius is num ? radius.toDouble() : 1.5,
      priority: priority is num ? priority.toDouble() : 0.5,
      ownerRigId: rigId is String ? rigId : null,
    );
    _audit.record(
      method: 'POST',
      path: '/v1/coimaging/sessions',
      status: 201,
      accountId: identity.accountId,
      detail: 'opened co-imaging session $sessionId',
    );
    final session = _coimaging.getSession(sessionId)!;
    return hubJson(
      _coImagingSessionJson(
        session,
        identity: identity,
        privileged: true,
        selfRigId: rigId is String ? rigId : '',
      ),
      statusCode: 201,
    );
  }

  /// `GET /v1/coimaging/sessions` — browse active co-imaging sessions. Read scope.
  Future<Response> _listCoImagingSessionsHandler(Request request) async {
    // Unbound read action: a resource-bound grant cannot enumerate every live
    // co-imaging session (other participants' targets + activity metadata).
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.coimagingRead,
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    return hubJson(<String, Object?>{
      'sessions': _coimaging
          .listSessions()
          .map(
            (s) => _coImagingSessionJson(
              s,
              identity: identity,
              privileged: _isCoImagingPrivileged(s, identity),
              includeParticipants: false,
            ),
          )
          .toList(),
    });
  }

  /// `GET /v1/coimaging/sessions/<id>` — session + participants + baton. Read.
  Future<Response> _getCoImagingSessionHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.coimagingRead,
      resourceType: 'coimaging',
      resourceId: request.params['sessionId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final sessionId = request.params['sessionId'];
    if (sessionId == null || sessionId.isEmpty) {
      return HubError.badRequest(
        'sessionId is required',
      ).toResponse(requestId: requestId);
    }
    final session = _coimaging.getSession(sessionId);
    if (session == null) {
      return HubError.notFound(
        'no such co-imaging session',
      ).toResponse(requestId: requestId);
    }
    return hubJson(
      _coImagingSessionJson(
        session,
        identity: identity,
        privileged: _isCoImagingPrivileged(session, identity),
      ),
    );
  }

  /// `POST /v1/coimaging/sessions/<id>/join?rigId=&role=` — JOIN as a rig. The
  /// hub assigns a UNIQUE framing offset slot + a membership token. Contribute +
  /// `coimaging.join`.
  Future<Response> _joinCoImagingSessionHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.coimagingJoin,
      resourceType: 'coimaging',
      resourceId: request.params['sessionId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final sessionId = request.params['sessionId'];
    if (sessionId == null || sessionId.isEmpty) {
      return HubError.badRequest(
        'sessionId is required',
      ).toResponse(requestId: requestId);
    }
    final session = _coimaging.getSession(sessionId);
    if (session == null) {
      return HubError.notFound(
        'no such co-imaging session',
      ).toResponse(requestId: requestId);
    }
    final q = request.url.queryParameters;
    // SECURITY: never honour a client-supplied admin role. A joiner is only
    // minted role='admin' when it is the session owner (already inserted as
    // admin on create) or an admin-scoped token; everyone else is a contributor.
    // Otherwise any contribute-scoped account could spoof admin attribution in
    // the authoritative participant row.
    final mayBeAdmin =
        identity.scope == HubScope.admin ||
        identity.accountId == session.ownerAccountId;
    final role = (q['role'] == 'admin' && mayBeAdmin) ? 'admin' : 'contribute';
    try {
      final participant = _coimaging.join(
        sessionId: sessionId,
        accountId: identity.accountId,
        rigId: q['rigId'],
        role: role,
      );
      _audit.record(
        method: 'POST',
        path: '/v1/coimaging/sessions/$sessionId/join',
        status: 200,
        accountId: identity.accountId,
        detail: 'joined slot ${participant.framingOffsetIndex}',
      );
      // This is the joining rig's OWN response — privileged: echo its account id
      // + membership token + assigned offset.
      return hubJson(
        participant.toJson(
          includeAccountId: true,
          includeToken: true,
          displayName: _accounts.getById(identity.accountId)?.displayName,
        ),
      );
    } on CoImagingSessionNotFound {
      return HubError.notFound(
        'no such co-imaging session',
      ).toResponse(requestId: requestId);
    } on CoImagingSessionClosed {
      return HubError.conflict(
        'coimagingSessionClosed',
        'session $sessionId is closed',
      ).toResponse(requestId: requestId);
    }
  }

  /// `POST /v1/coimaging/sessions/<id>/leave?rigId=` — leave the session.
  Future<Response> _leaveCoImagingSessionHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.coimagingJoin,
      resourceType: 'coimaging',
      resourceId: request.params['sessionId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final sessionId = request.params['sessionId'];
    if (sessionId == null || sessionId.isEmpty) {
      return HubError.badRequest(
        'sessionId is required',
      ).toResponse(requestId: requestId);
    }
    final left = _coimaging.leave(
      sessionId: sessionId,
      accountId: identity.accountId,
      rigId: request.url.queryParameters['rigId'],
    );
    return hubJson(<String, Object?>{'left': left});
  }

  /// `POST /v1/coimaging/sessions/<id>/close` — close the session (owner/admin
  /// only) and tear down its live preview subscribers. Contribute +
  /// `coimaging.join`. Flips the session to `closed` (no further joins /
  /// contributions) and completes every open SSE stream. Returns the closed
  /// session's state.
  Future<Response> _closeCoImagingSessionHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.coimagingJoin,
      resourceType: 'coimaging',
      resourceId: request.params['sessionId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final sessionId = request.params['sessionId'];
    if (sessionId == null || sessionId.isEmpty) {
      return HubError.badRequest(
        'sessionId is required',
      ).toResponse(requestId: requestId);
    }
    final session = _coimaging.getSession(sessionId);
    if (session == null) {
      return HubError.notFound(
        'no such co-imaging session',
      ).toResponse(requestId: requestId);
    }
    // Only the owner (or an admin-scoped operator) may close the session.
    final mayClose =
        identity.scope == HubScope.admin ||
        identity.accountId == session.ownerAccountId;
    if (!mayClose) {
      return HubError.forbidden(
        'only the session owner may close it',
      ).toResponse(requestId: requestId);
    }
    // Attribution: a closed co-imaging session credits every participant by the
    // combined frames + integration they contributed (the ordered
    // contributor-credits list the UI renders).
    for (final p in _coimaging.participants(sessionId)) {
      if (p.contributedFrames > 0 || p.contributedIntegrationSeconds > 0) {
        _attribution.recordAccepted(
          artifactType: 'coimaging',
          artifactRef: sessionId,
          accountId: p.accountId,
          frames: p.contributedFrames,
          integrationSeconds: p.contributedIntegrationSeconds,
          license: p.license,
          // Honour the contributor's attribution consent recorded with its
          // combined-accounting reports: a rig that contributed without
          // named-credit consent is credited anonymously.
          anonymous: !p.attributionConsent,
        );
      }
    }
    _coimaging.closeSession(sessionId);
    _coimaging.disposeSession(sessionId);
    // A closed session accepts no further contributions, so every consent still
    // live for it is now stale: revoke the whole `(coimaging, sessionId)` set so
    // `liveConsentCount` drops to zero and a moderation / audit surface reads the
    // closed share as no-longer-consented (mirrors the calibration delete path).
    _consent.revokeForArtifact('coimaging', sessionId);
    _audit.record(
      method: 'POST',
      path: '/v1/coimaging/sessions/$sessionId/close',
      status: 200,
      accountId: identity.accountId,
      detail: 'closed co-imaging session $sessionId',
    );
    final closed = _coimaging.getSession(sessionId)!;
    return hubJson(
      _coImagingSessionJson(closed, identity: identity, privileged: true),
    );
  }

  /// `POST /v1/coimaging/sessions/<id>/contributions?framesDelta=&integrationSecondsDelta=&rigId=`
  /// — report a rig's contribution to the COMBINED accounting after it folded its
  /// sub into the shared-target tile. Contribute + `coimaging.contribute`, and
  /// the caller MUST be a participant (membership token via `x-membership-token`
  /// header OR account membership). Pushes a live combined preview to subscribers.
  Future<Response> _coImagingContributionHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.coimagingContribute,
      resourceType: 'coimaging',
      resourceId: request.params['sessionId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final sessionId = request.params['sessionId'];
    if (sessionId == null || sessionId.isEmpty) {
      return HubError.badRequest(
        'sessionId is required',
      ).toResponse(requestId: requestId);
    }
    if (_coimaging.getSession(sessionId) == null) {
      return HubError.notFound(
        'no such co-imaging session',
      ).toResponse(requestId: requestId);
    }
    final q = request.url.queryParameters;
    final rigId = q['rigId'];
    if (!_coimaging.holdsMembership(
      sessionId: sessionId,
      accountId: identity.accountId,
      rigId: rigId,
      membershipToken: request.headers['x-membership-token'],
    )) {
      return HubError.forbidden(
        'not a participant of this co-imaging session',
      ).toResponse(requestId: requestId);
    }
    // Consent: a co-imaging contribution folds this rig's sub into the SHARED
    // co-add and claims combined-depth credit, so it records the license + the
    // named-vs-anonymous choice that gate the share BEFORE the accounting lands.
    // A missing/unshareable license is a 400 (the client pre-validates against
    // `/v1/info supportedLicenses`); the recorded consent rides onto the
    // participant row so the close attribution credits under the right
    // license/anonymity.
    final consent = _resolveShareConsent(
      request,
      accountId: identity.accountId,
      artifactType: 'coimaging',
      artifactRef: sessionId,
    );
    if (consent.error != null) return consent.error!;
    final frames = int.tryParse(q['framesDelta'] ?? '') ?? 0;
    final seconds = double.tryParse(q['integrationSecondsDelta'] ?? '') ?? 0.0;
    try {
      final accounting = _coimaging.recordContribution(
        sessionId: sessionId,
        accountId: identity.accountId,
        rigId: rigId,
        framesDelta: frames,
        integrationSecondsDelta: seconds,
        consentId: consent.consentId,
        license: consent.license,
        attributionConsent: !consent.anonymous,
      );
      _audit.record(
        method: 'POST',
        path: '/v1/coimaging/sessions/$sessionId/contributions',
        status: 200,
        accountId: identity.accountId,
        detail:
            'co-imaging +$frames frames (combined '
            '${accounting.combinedFrames})',
      );
      return hubJson(accounting.toJson());
    } on CoImagingSessionClosed {
      // The share never landed, so the consent recorded up-front for it is
      // stale: revoke it rather than leaking a live row for un-stored bytes.
      _consent.revoke(consent.consentId);
      return HubError.conflict(
        'coimagingSessionClosed',
        'session $sessionId is closed',
      ).toResponse(requestId: requestId);
    } on CoImagingParticipantNotFound {
      _consent.revoke(consent.consentId);
      return HubError.forbidden(
        'not a participant of this co-imaging session',
      ).toResponse(requestId: requestId);
    } on CoImagingContributionRejected catch (e) {
      // The implausible report was refused, so its pre-recorded consent guards
      // nothing — revoke it before returning the 422. The 422 is audit-flagged
      // uniformly by [_auditDenialMiddleware] (with the acting account + token
      // hash), where it feeds the abuse auto-flag — so an implausible-report
      // flood surfaces for moderation rather than silently inflating the shared
      // depth, without a redundant self-audit here.
      _consent.revoke(consent.consentId);
      return HubError(
        422,
        'coimagingContributionRejected',
        e.reason,
      ).toResponse(requestId: requestId);
    }
  }

  /// `GET /v1/coimaging/sessions/<id>/events` — the live combined-preview channel
  /// as Server-Sent Events. Read scope + participant/admin (the same scoping the
  /// session detail uses). The hub is pure-Dart with no WebSocket dependency, so
  /// the events channel is a streamed `text/event-stream` response — identical
  /// push-to-all semantics. Emits a snapshot immediately then one frame per
  /// contribution / join.
  Future<Response> _coImagingEventsHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.coimagingRead,
      resourceType: 'coimaging',
      resourceId: request.params['sessionId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final sessionId = request.params['sessionId'];
    if (sessionId == null || sessionId.isEmpty) {
      return HubError.badRequest(
        'sessionId is required',
      ).toResponse(requestId: requestId);
    }
    final session = _coimaging.getSession(sessionId);
    if (session == null) {
      return HubError.notFound(
        'no such co-imaging session',
      ).toResponse(requestId: requestId);
    }
    if (!_isCoImagingPrivileged(session, identity)) {
      return HubError.forbidden(
        'not a participant of this co-imaging session',
      ).toResponse(requestId: requestId);
    }
    final byteStream = _coimaging
        .subscribe(sessionId)
        .map<List<int>>((e) => utf8.encode(e.toSseFrame()));
    return Response.ok(
      byteStream,
      headers: <String, String>{
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        'x-request-id': requestId ?? '',
      },
      context: <String, Object>{'shelf.io.buffer_output': false},
    );
  }

  /// `GET /v1/coimaging/sessions/<id>/baton` — the longitude-baton holder. Read.
  Future<Response> _coImagingBatonStateHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.coimagingRead,
      resourceType: 'coimaging',
      resourceId: request.params['sessionId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final sessionId = request.params['sessionId'];
    if (sessionId == null || sessionId.isEmpty) {
      return HubError.badRequest(
        'sessionId is required',
      ).toResponse(requestId: requestId);
    }
    try {
      final state = _coimaging.batonState(sessionId);
      final session = _coimaging.getSession(sessionId)!;
      final privileged = _isCoImagingPrivileged(session, identity);
      return hubJson(
        state.toJson(
          includeAccountId: privileged,
          holderDisplayName: state.holder == null
              ? null
              : _accounts.getById(state.holder!)?.displayName,
        ),
      );
    } on CoImagingSessionNotFound {
      return HubError.notFound(
        'no such co-imaging session',
      ).toResponse(requestId: requestId);
    }
  }

  /// `POST /v1/coimaging/sessions/<id>/baton/claim` — take the active-imager
  /// baton. Contribute + `coimaging.join`. 409 when another site holds it.
  Future<Response> _coImagingBatonClaimHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.coimagingJoin,
      resourceType: 'coimaging',
      resourceId: request.params['sessionId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final sessionId = request.params['sessionId'];
    if (sessionId == null || sessionId.isEmpty) {
      return HubError.badRequest(
        'sessionId is required',
      ).toResponse(requestId: requestId);
    }
    final session = _coimaging.getSession(sessionId);
    if (session == null) {
      return HubError.notFound(
        'no such co-imaging session',
      ).toResponse(requestId: requestId);
    }
    // The baton belongs to the PARTICIPATING rigs: a stranger who merely
    // resolved the session id must not seize it (DoS / consent bypass), mirroring
    // the contribution + events participant gate.
    if (!_coimaging.isParticipant(sessionId, identity.accountId)) {
      return HubError.forbidden(
        'not a participant of this co-imaging session',
      ).toResponse(requestId: requestId);
    }
    try {
      final claim = _coimaging.claimBaton(
        sessionId: sessionId,
        accountId: identity.accountId,
      );
      if (claim == null) {
        return HubError.conflict(
          'coimagingBatonHeld',
          'the baton for session $sessionId is held by another site',
        ).toResponse(requestId: requestId);
      }
      _audit.record(
        method: 'POST',
        path: '/v1/coimaging/sessions/$sessionId/baton/claim',
        status: 200,
        accountId: identity.accountId,
        detail: 'claimed co-imaging baton',
      );
      return hubJson(<String, Object?>{
        'claimToken': claim.claimToken,
        'expiresAt': claim.expiresAt.toIso8601String(),
      });
    } on CoImagingSessionNotFound {
      return HubError.notFound(
        'no such co-imaging session',
      ).toResponse(requestId: requestId);
    } on CoImagingSessionClosed {
      return HubError.conflict(
        'coimagingSessionClosed',
        'session $sessionId is closed',
      ).toResponse(requestId: requestId);
    }
  }

  /// `POST /v1/coimaging/sessions/<id>/baton/release` — hand the baton east.
  /// Contribute + `coimaging.join`.
  Future<Response> _coImagingBatonReleaseHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.contribute,
      action: CollabAction.coimagingJoin,
      resourceType: 'coimaging',
      resourceId: request.params['sessionId'],
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final sessionId = request.params['sessionId'];
    if (sessionId == null || sessionId.isEmpty) {
      return HubError.badRequest(
        'sessionId is required',
      ).toResponse(requestId: requestId);
    }
    final session = _coimaging.getSession(sessionId);
    if (session == null) {
      return HubError.notFound(
        'no such co-imaging session',
      ).toResponse(requestId: requestId);
    }
    if (!_coimaging.isParticipant(sessionId, identity.accountId)) {
      return HubError.forbidden(
        'not a participant of this co-imaging session',
      ).toResponse(requestId: requestId);
    }
    try {
      final released = _coimaging.releaseBaton(
        sessionId: sessionId,
        accountId: identity.accountId,
      );
      return hubJson(<String, Object?>{'released': released});
    } on CoImagingSessionNotFound {
      return HubError.notFound(
        'no such co-imaging session',
      ).toResponse(requestId: requestId);
    } on CoImagingSessionClosed {
      return HubError.conflict(
        'coimagingSessionClosed',
        'session $sessionId is closed',
      ).toResponse(requestId: requestId);
    }
  }

  /// Whether [identity] may see a session's raw internal account ids / tokens:
  /// the owner, any active participant, or an admin. Mirrors the mosaic privacy
  /// scoping so an arbitrary read token cannot enumerate account -> session.
  bool _isCoImagingPrivileged(
    CoImagingSessionRow session,
    AuthIdentity identity,
  ) =>
      identity.scope == HubScope.admin ||
      _coimaging.isParticipant(session.id, identity.accountId);

  /// Build the session JSON with privacy-scoped account ids + server-resolved
  /// display-name attribution, the fused active tile, the baton holder, and
  /// (optionally) per-participant state under the same scoping. [selfRigId] is
  /// the caller's own rig, whose participant row alone gets its membership token
  /// echoed (on the create-session response the owner needs its token).
  Map<String, Object?> _coImagingSessionJson(
    CoImagingSessionRow session, {
    required AuthIdentity identity,
    required bool privileged,
    bool includeParticipants = true,
    String? selfRigId,
  }) {
    final activeTileId = _coimaging.activeTileFor(session, config.healpixOrder);
    final baton = _coimaging.batonState(session.id);
    final ps = includeParticipants
        ? _coimaging.participants(session.id).map((p) {
            final isSelf =
                privileged &&
                p.accountId == identity.accountId &&
                (selfRigId == null || p.rigId == selfRigId);
            return p.toJson(
              includeAccountId: privileged,
              includeToken: isSelf,
              displayName: _accounts.getById(p.accountId)?.displayName,
            );
          }).toList()
        : null;
    return session.toJson(
      includeAccountId: privileged,
      ownerDisplayName: _accounts.getById(session.ownerAccountId)?.displayName,
      activeTileId: activeTileId,
      batonHolder: baton.holder,
      batonHolderDisplayName: baton.holder == null
          ? null
          : _accounts.getById(baton.holder!)?.displayName,
      participants: ps,
    );
  }

  // --- Tokens, moderation, attribution, consent ----------------------------

  /// `POST /v1/tokens` — mint a fine-grained scoped token. The
  /// realization of "hand a member a contribute-to-mosaic-42-only token":
  /// capability attenuation, NOT escalation. The minted token is for the
  /// caller's own account (or, for an admin, a named [accountId]) and is
  /// validated subset-only — the caller must already permit every requested
  /// action on the requested resource, so no token can mint authority beyond its
  /// own. Returns the RAW token once.
  ///
  /// Body: `{role, deviceId?, resourceType?, resourceId?, actions?:[wire,…],
  /// lifetimeSeconds?, accountId?}`. `actions` omitted ⇒ every action the role
  /// permits by default (still subset-checked against the caller's grant).
  Future<Response> _mintTokenHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    // The caller must itself hold the mint capability (a token narrowed to
    // exclude `token.mint`, or bound to a resource, cannot re-delegate). Gated
    // through `_authorize`'s action path so the narrowed-token denial does not
    // pre-empt a legitimately mint-capable narrowed token.
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.tokenMint,
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final body = await _readJson(request);

    final roleRaw = body['role'];
    final scope = roleRaw is String ? HubScope.parse(roleRaw) : null;
    if (scope == null) {
      return HubError.badRequest(
        'role is required and must be read/contribute/admin',
      ).toResponse(requestId: requestId);
    }
    // No scope escalation: the requested base role may not exceed the caller's.
    if (!identity.scope.satisfies(scope)) {
      return HubError.forbidden(
        'cannot mint a "${scope.wireName}" token from a '
        '"${identity.scope.wireName}" token (no escalation)',
      ).toResponse(requestId: requestId);
    }

    final deviceId = body['deviceId'] is String
        ? body['deviceId'] as String
        : null;
    final resourceType = body['resourceType'] is String
        ? body['resourceType'] as String
        : null;
    final resourceId = body['resourceId'] is String
        ? body['resourceId'] as String
        : null;
    if ((resourceType == null) != (resourceId == null)) {
      return HubError.badRequest(
        'resourceType and resourceId must be supplied together',
      ).toResponse(requestId: requestId);
    }

    // Resolve the requested action set. An explicit list narrows; omission means
    // every action the requested role permits by default.
    Set<CollabAction> requested;
    final rawActions = body['actions'];
    if (rawActions is List) {
      requested = <CollabAction>{};
      for (final entry in rawActions) {
        final a = CollabAction.fromWire(entry is String ? entry : null);
        if (a == null) {
          return HubError.badRequest(
            'unknown action "$entry"',
          ).toResponse(requestId: requestId);
        }
        requested.add(a);
      }
    } else {
      requested = CollabAction.values
          .where((a) => scope.satisfies(a.minimumScope))
          .toSet();
    }

    // Subset-only delegation: the caller must already permit every requested
    // action on the requested resource. Reject escalation with 403.
    for (final action in requested) {
      if (!identity.permits(
        action,
        onResourceType: resourceType,
        onResourceId: resourceId,
      )) {
        return HubError.forbidden(
          'cannot delegate ${action.wireName}: the minting token does not '
          'permit it on the requested resource (no escalation)',
        ).toResponse(requestId: requestId);
      }
    }

    // Target account: self by default; an admin may provision a token for
    // another account (e.g. an appliance key). A non-admin naming another
    // account is forbidden.
    var targetAccountId = identity.accountId;
    final bodyAccount = body['accountId'];
    if (bodyAccount is String && bodyAccount != identity.accountId) {
      if (identity.scope != HubScope.admin) {
        return HubError.forbidden(
          'only an admin may mint a token for another account',
        ).toResponse(requestId: requestId);
      }
      if (_accounts.getById(bodyAccount) == null) {
        return HubError.badRequest(
          'no such account',
        ).toResponse(requestId: requestId);
      }
      targetAccountId = bodyAccount;
    }

    final lifetimeSeconds = body['lifetimeSeconds'];
    final lifetime = lifetimeSeconds is num && lifetimeSeconds > 0
        ? Duration(seconds: lifetimeSeconds.toInt())
        : null;

    final raw = _tokens.issueScoped(
      accountId: targetAccountId,
      grant: ScopedGrant(
        scope: scope,
        deviceId: deviceId,
        // A narrowed list persists; the default-all set serializes as the bare
        // role (no `actions`) so a whole-role delegation stays compact.
        actions: rawActions is List ? requested : null,
        resourceType: resourceType,
        resourceId: resourceId,
      ),
      lifetime: lifetime,
    );
    _audit.record(
      method: 'POST',
      path: '/v1/tokens',
      status: 201,
      accountId: identity.accountId,
      detail:
          'minted ${scope.wireName} token for $targetAccountId'
          '${resourceType == null ? '' : ' on $resourceType:$resourceId'}',
    );
    return hubJson(<String, Object?>{
      'bearerToken': raw,
      'accountId': targetAccountId,
      'role': scope.wireName,
      if (deviceId != null) 'deviceId': deviceId,
      if (resourceType != null) 'resourceType': resourceType,
      if (resourceId != null) 'resourceId': resourceId,
      'actions': requested.map((a) => a.wireName).toList(growable: false),
      if (lifetime != null) 'lifetimeSeconds': lifetime.inSeconds,
    }, statusCode: 201);
  }

  /// `DELETE /v1/sessions/current` — self-revoke (logout): drop the bearer token
  /// the caller presented. Any authenticated scope may revoke its own token —
  /// including a narrowed / resource-bound / device-bound delegation, since
  /// dropping only your OWN token is always safe (hence [allowNarrowed]).
  Future<Response> _revokeCurrentSessionHandler(Request request) async {
    final auth = _authorize(request, HubScope.read, allowNarrowed: true);
    if (auth.error != null) return auth.error!;
    final revoked = _tokens.revokeTokenHash(auth.identity!.tokenHash);
    _audit.record(
      method: 'DELETE',
      path: '/v1/sessions/current',
      status: 200,
      accountId: auth.identity!.accountId,
      detail: 'self-revoked token',
    );
    return hubJson(<String, Object?>{'revoked': revoked});
  }

  /// `POST /v1/moderation/suspend` — suspend an abusive account.
  /// Admin scope + the `moderate` action. Body: `{accountId, reason?}`.
  Future<Response> _suspendAccountHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.admin,
      action: CollabAction.moderate,
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final body = await _readJson(request);
    final accountId = body['accountId'];
    if (accountId is! String || accountId.isEmpty) {
      return HubError.badRequest(
        'accountId is required',
      ).toResponse(requestId: requestId);
    }
    // An admin cannot suspend itself (would lock the operator out of the very
    // moderation surface used to undo it).
    if (accountId == identity.accountId) {
      return HubError.badRequest(
        'an admin cannot suspend its own account',
      ).toResponse(requestId: requestId);
    }
    final reason = body['reason'] is String ? body['reason'] as String : null;
    final ok = _moderation.suspend(
      targetAccountId: accountId,
      moderatorAccountId: identity.accountId,
      reason: reason,
    );
    if (!ok) {
      return HubError.notFound(
        'no such account',
      ).toResponse(requestId: requestId);
    }
    _audit.record(
      method: 'POST',
      path: '/v1/moderation/suspend',
      status: 200,
      accountId: identity.accountId,
      detail: 'suspended $accountId',
    );
    return hubJson(<String, Object?>{
      'suspended': true,
      'accountId': accountId,
    });
  }

  /// `POST /v1/moderation/reinstate` — lift a suspension. Admin + `moderate`.
  Future<Response> _reinstateAccountHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.admin,
      action: CollabAction.moderate,
    );
    if (auth.error != null) return auth.error!;
    final identity = auth.identity!;
    final body = await _readJson(request);
    final accountId = body['accountId'];
    if (accountId is! String || accountId.isEmpty) {
      return HubError.badRequest(
        'accountId is required',
      ).toResponse(requestId: requestId);
    }
    final reason = body['reason'] is String ? body['reason'] as String : null;
    final ok = _moderation.reinstate(
      targetAccountId: accountId,
      moderatorAccountId: identity.accountId,
      reason: reason,
    );
    _audit.record(
      method: 'POST',
      path: '/v1/moderation/reinstate',
      status: 200,
      accountId: identity.accountId,
      detail: ok ? 'reinstated $accountId' : 'reinstate no-op $accountId',
    );
    return hubJson(<String, Object?>{'reinstated': ok, 'accountId': accountId});
  }

  /// `GET /v1/attribution?artifactType=&artifactRef=` — the ordered
  /// per-contributor credit list for a finished collaborative artifact (the
  /// contributor-credits UI source). Read scope + the `attribution.read`
  /// action. Anonymous contributors render as "Anonymous contributor" with no
  /// raw account id.
  Future<Response> _attributionHandler(Request request) async {
    final requestId = request.context['requestId'] as String?;
    final auth = _authorize(
      request,
      HubScope.read,
      action: CollabAction.attributionRead,
    );
    if (auth.error != null) return auth.error!;
    final q = request.url.queryParameters;
    final type = q['artifactType'];
    final ref = q['artifactRef'];
    if (type == null || type.isEmpty || ref == null || ref.isEmpty) {
      return HubError.badRequest(
        'artifactType and artifactRef query params are required',
      ).toResponse(requestId: requestId);
    }
    return hubJson(<String, Object?>{
      'artifactType': type,
      'artifactRef': ref,
      'contributors': _attribution.list(artifactType: type, artifactRef: ref),
    });
  }

  /// Validate + record the consent gating a SHARE into the swarm, reading the
  /// license + per-action flags from the request (header first, query fallback)
  /// and persisting a `consent_records` row BEFORE any bytes are stored. Returns
  /// a ready-to-send 400 in `error` when the license is missing/unknown/
  /// non-shareable; otherwise the recorded `consentId`, the validated `license`
  /// wire name, and whether the contributor wants public credit (`anonymous`).
  ({Response? error, String license, String? consentId, bool anonymous})
  _resolveShareConsent(
    Request request, {
    required String accountId,
    required String artifactType,
    required String artifactRef,
    bool defaultShareRawSubframes = false,
  }) {
    final q = request.url.queryParameters;
    final license = (request.headers['license'] ?? q['license'])?.trim();
    if (!ConsentService.isShareable(license)) {
      return (
        error: HubError.badRequest(
          'a contribution into the shared co-add requires a shareable license '
          '(${ConsentService.shareableLicenses.join(', ')}); got '
          '"${license ?? ''}"',
        ).toResponse(requestId: request.context['requestId'] as String?),
        license: '',
        consentId: null,
        anonymous: false,
      );
    }
    final attributionConsent = _flag(
      request,
      'attributionConsent',
      q,
      defaultValue: true,
    );
    final consentId = _consent.record(
      accountId: accountId,
      artifactType: artifactType,
      artifactRef: artifactRef,
      license: license!,
      shareRawSubframes: _flag(
        request,
        'shareRawSubframes',
        q,
        defaultValue: defaultShareRawSubframes,
      ),
      allowDerivatives: _flag(
        request,
        'allowDerivatives',
        q,
        defaultValue: false,
      ),
      allowRedistribution: _flag(
        request,
        'allowRedistribution',
        q,
        defaultValue: false,
      ),
      attributionConsent: attributionConsent,
    );
    return (
      error: null,
      license: license,
      consentId: consentId,
      anonymous: !attributionConsent,
    );
  }

  /// Read a boolean flag from a header (preferred) or query param, defaulting to
  /// [defaultValue] when absent. `true`/`1`/`yes` are true; anything else false.
  bool _flag(
    Request request,
    String key,
    Map<String, String> query, {
    required bool defaultValue,
  }) {
    final raw = (request.headers[key] ?? query[key])?.trim().toLowerCase();
    if (raw == null || raw.isEmpty) return defaultValue;
    return raw == 'true' || raw == '1' || raw == 'yes';
  }

  /// Enforce a fine-grained [action] grant on top of the coarse scope already
  /// checked by [_authorize]. Returns a ready-to-send 403 when denied (honouring
  /// any per-device binding via the optional `x-device-id` header AND any
  /// per-resource binding via [resourceType]/[resourceId]), else null.
  ///
  /// [resourceType]/[resourceId] are the artifact the request targets, derived
  /// from the path id (e.g. `('mosaic', mosaicId)`). A token narrowed to one
  /// resource ("contribute to mosaic 42") is denied here for every other
  /// resource — that per-resource scoping is load-bearing. A coarse /
  /// whole-role / device-only token carries no resource binding and is
  /// unaffected.
  Response? _denyAction(
    Request request,
    AuthIdentity identity,
    CollabAction action, {
    String? resourceType,
    String? resourceId,
  }) {
    final fromDevice = request.headers['x-device-id'];
    if (identity.permits(
      action,
      fromDevice: fromDevice,
      onResourceType: resourceType,
      onResourceId: resourceId,
    )) {
      return null;
    }
    return HubError.forbidden(
      'token does not permit ${action.wireName}',
    ).toResponse(requestId: request.context['requestId'] as String?);
  }

  Future<Response> _auditHandler(Request request) async {
    final auth = _authorize(request, HubScope.admin);
    if (auth.error != null) return auth.error!;
    return hubJson(<String, Object?>{'entries': _audit.recent()});
  }

  // --- Body helpers --------------------------------------------------------

  Future<Map<String, Object?>> _readJson(Request request) async {
    final raw = await request.readAsString();
    if (raw.isEmpty) return <String, Object?>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('expected a JSON object');
    }
    return decoded.map(
      (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
    );
  }

  /// Build a streamed download response for an on-disk blob at [path], backed by
  /// `openRead()` so a multi-hundred-MB panel master or stitched mosaic output
  /// is never resident in hub memory. The headless/appliance target is a
  /// Raspberry Pi: buffering a full copy per concurrent puller (the mosaic
  /// output is the single largest artifact in the system) would OOM the pure-Dart
  /// hub, so the download direction streams just like the [_sendFile] upload
  /// direction. Returns null when the file is gone so the caller can 404.
  Response? _streamFile(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    final length = file.lengthSync();
    return Response.ok(
      file.openRead(),
      headers: <String, String>{
        'content-type': 'application/octet-stream',
        'content-length': '$length',
      },
    );
  }

  /// Read a binary body up to [maxBytes]; returns null if the body exceeds the
  /// cap. Streams so an oversized upload is rejected without buffering it all.
  Future<Uint8List?> _readBinary(Request request, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      builder.add(chunk);
      if (builder.length > maxBytes) return null;
    }
    return builder.toBytes();
  }

  int _orderQuery(Request request) {
    return int.tryParse(request.url.queryParameters['order'] ?? '') ??
        config.healpixOrder;
  }

  static bool _isConflictCode(String code) {
    return code == 'geometryMismatch' ||
        code == 'orderMismatch' ||
        code == 'channelMismatch' ||
        code == 'idMismatch';
  }
}

/// The production error-trap middleware, extracted to top level so its
/// redaction contract is unit-testable without standing up the full server +
/// DB. [HubServer] installs this verbatim ([HubServer._errorTrapMiddleware]).
///
/// Maps a [TileCodecException] to its 400/409 envelope and a [FormatException]
/// to a 400, but converts any OTHER thrown error into a generic 500
/// (`internal error`) that NEVER echoes the underlying exception text or stack
/// to the caller (those routinely embed absolute filesystem paths, SQL
/// fragments, and type internals). The full detail is logged server-side keyed
/// to the requestId so an operator can still correlate.
Middleware hubErrorTrapMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      final requestId = request.context['requestId'] as String?;
      try {
        return await inner(request);
      } on TileCodecException catch (e) {
        final status = HubServer._isConflictCode(e.code) ? 409 : 400;
        return HubError(
          status,
          e.code,
          e.message,
        ).toResponse(requestId: requestId);
      } on FormatException catch (e) {
        return HubError.badRequest(
          'malformed JSON: ${e.message}',
        ).toResponse(requestId: requestId);
      } catch (e, stack) {
        stderr.writeln(
          '[hub] unhandled error (requestId=${requestId ?? '-'}): $e\n$stack',
        );
        return HubError.internal(
          'internal error',
        ).toResponse(requestId: requestId);
      }
    };
  };
}
