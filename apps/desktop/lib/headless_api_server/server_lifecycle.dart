part of '../headless_api_server.dart';

extension _HeadlessApiServerLifecycle on HeadlessApiServer {
  Future<void> _startServer() async {
    final router = Router();

    // Route table — per-domain declarative lists live under
    // `headless_api/routes/`. Each handler class has a sibling
    // `routes/<name>_routes.dart` exporting a top-level
    // `build<Name>Routes(handler)`. The order below MIRRORS the
    // legacy inline-`router.<verb>(...)` block exactly; shelf_router
    // matches by registration order so any reordering across domain
    // boundaries (e.g. moving `/api/sessions/*` (analytics) before
    // `/api/sessions/<sessionId>/images` (sessions)) would change
    // first-hit semantics. See `routes/headless_route.dart` for the
    // typed primitives.
    final allRoutes = <HeadlessRoute>[
      ...buildSystemRoutes(_systemHandlers),
      ...buildPairingRoutes(_pairingHandlers),
      // Phase D — authenticated cellular-push token + preference routes.
      ...buildPushRoutes(_pushHandlers),
      ...buildAuthRoutes(_authHandlers),
      ...buildCollaborationRoutes(_collaborationHandlers),
      ...buildDeviceDiscoveryRoutes(_deviceDiscoveryHandlers),
      ...buildDeviceRoutes(_deviceHandlers),
      ...buildGuidingRoutes(_guidingHandlers),
      ...buildImagingRoutes(_imagingHandlers),
      ...buildSequencerRoutes(_sequencerHandlers),
      ...buildReplayDebugRoutes(_replayDebugHandlers),
      ...buildEquipmentRoutes(_equipmentHandlers),
      ...buildProfileRoutes(_profileHandlers),
      ...buildSessionRoutes(_sessionHandlers),
      ...buildTargetRoutes(_targetHandlers),
      ...buildSequenceManagementRoutes(_sequenceManagementHandlers),
      ...buildFlatWizardRoutes(_flatWizardHandlers),
      ...buildMosaicRoutes(_mosaicHandlers),
      ...buildCoImagingRoutes(_coImagingHandlers),
      ...buildAnalyticsRoutes(_analyticsHandlers),
      ...buildWeatherRoutes(_weatherHandlers),
      ...buildFileSystemRoutes(_fileSystemHandlers),
      ...buildScienceRoutes(_scienceHandlers),
      ...buildSuggestionRoutes(_suggestionHandlers),
      ...buildTransientRoutes(_transientHandlers),
      ...buildFirstLightRoutes(_firstLightHandlers),
      ...buildAtlasRoutes(_atlasHandlers),
      ...buildBackupRoutes(_backupHandlers),
      ...buildSyncRoutes(_syncHandlers),
      ...buildRuntimeStateRoutes(_runtimeStateHandlers),
      ...buildFramingRoutes(_framingHandlers),
      ...buildPlanetariumRoutes(_planetariumHandlers),
      ...buildDomeRoutes(_domeHandlers),
      ...buildNarratorRoutes(_narratorHandlers),
      ...buildSafetyMonitorRoutes(_safetyMonitorHandlers),
      ...buildAuxiliaryRoutes(_auxiliaryHandlers),
      ...buildSchedulerRoutes(_schedulerHandlers),
      ...buildPlanningDataRoutes(_planningDataHandlers),
      ...buildFocusModelRoutes(_focusModelHandlers),
      ...buildStackingRoutes(_stackingHandlers),
      ...buildPostSessionRoutes(_postSessionHandlers),
      ...buildDarkroomDeliveryRoutes(_darkroomDeliveryHandlers),
      ...buildDepthLockRoutes(_depthLockHandlers),
      ...buildJobRoutes(_jobHandlers),
      ...buildSessionOwnershipRoutes(_sessionOwnershipHandlers),
    ];

    // OTA handlers are provisioned after the HTTP server starts in both GUI
    // and headless bootstraps. Register dynamic routes now so a later
    // setUpdateController() immediately activates the advertised surface.
    allRoutes.addAll(buildUpdateRoutes(() => _updateHandlers));

    // Continue appending the remaining per-domain route lists. These
    // come AFTER the OTA block above so the relative declaration order
    // of OTA routes vs. log / calibration / catalog routes is preserved
    // exactly — shelf_router matches on registration order.
    allRoutes
      ..addAll(buildRunWatchRoutes(_runWatchHandlers))
      ..addAll(buildBroadcastRoutes(_broadcastHandlers))
      ..addAll(buildLogRoutes(_logHandlers))
      ..addAll(buildCalibrationRoutes(_calibrationHandlers))
      ..addAll(buildCalibrationLibraryRoutes(_calibrationLibraryHandlers))
      ..addAll(buildCatalogRoutes(_catalogHandlers))
      ..addAll(buildDbReadRoutes(_dbReadHandlers))
      ..addAll(buildPluginRoutes(_pluginHandlers))
      // WebRTC live-view signalling. Must register before
      // the static-file catch-all so `/api/webrtc/live-view/*` is not
      // shadowed by the SPA fallback.
      ..addAll(buildWebRtcLiveViewRoutes(_webRtcLiveViewHandlers))
      ..addAll(buildStaticFileRoutes(_staticFileHandlers));

    // WebSocket-upgrade endpoints. Why these are NOT in
    // [buildWebSocketRoutes] as method-tear-offs:
    //
    // 1. `shelf_web_socket`'s `webSocketHandler` strips the original
    //    Request, so we capture it in an outer closure so the
    //    replay handler can read `?since=` and `?instance=` query
    //    parameters off the upgrade URL.
    // 2. we also lift the auth identity (digest of the bearer
    //    token that authenticated the upgrade) off the request context
    //    that `_authMiddleware` stashed there. Passing it down means
    //    the collaboration `viewerId` is always the authenticated
    //    principal, regardless of what the client puts in the
    //    `collaboration.join` payload.
    //
    // [buildWebSocketRoutes] accepts the pre-built Handler closures so
    // the route table stays purely declarative; the closure body itself
    // has to live here because it accesses private server state.
    Handler eventsHandler() {
      return (Request request) {
        final query = request.url.queryParameters;
        final authIdentity = _authIdentityFrom(request);
        return webSocketHandler((socket, _) {
          _handleWebSocketWithQuery(socket, query, authIdentity);
        }).call(request);
      };
    }

    // push-based live-view streaming. Distinct from the main
    // event WS because (a) it carries binary JPEG frames, not JSON
    // events, and (b) the message protocol is a per-socket
    // subscribe/unsubscribe model rather than the always-on event
    // broadcast.
    Handler liveViewHandler() {
      return (Request request) {
        return webSocketHandler((socket, _) {
          _liveViewStreamHandlers.handleSocket(socket);
        }).call(request);
      };
    }

    allRoutes.addAll(
      buildWebSocketRoutes(
        eventsHandler: eventsHandler(),
        liveViewHandler: liveViewHandler(),
      ),
    );

    // Single dispatch point — `registerRoutes` walks the list once and
    // calls the right `router.<verb>(...)` for each entry. See
    // `routes/headless_route.dart` for the typed-list design rationale.
    registerRoutes(router, allRoutes);

    final handler = Pipeline()
        .addMiddleware(_requestTrackingMiddleware())
        // Why placement: error translation must wrap downstream so
        // BadRequestError thrown anywhere lower becomes a structured 400.
        // It must be _outside_ auth/CORS so 4xx auth responses keep their
        // intended status (errorTranslationMiddleware only intercepts
        // exceptions, not non-2xx responses).
        .addMiddleware(
          errorTranslationMiddleware(
            logError: _logError,
            requestIdFor: _requestIdFrom,
            shouldBypass: (request) {
              final path = '/${request.url.path}';
              // also bypass /ws/live-view so shelf does not try to
              // wrap the WS upgrade response into a JSON error envelope.
              return path == '/api/ws' ||
                  path == '/events' ||
                  path == '/ws/live-view';
            },
          ),
        )
        .addMiddleware(_corsMiddleware())
        // The declared-Content-Length ceiling (header-only, no body read)
        // stays ahead of auth so an over-large declared upload is still
        // rejected with 413 without credentials; the chunked-body buffering is
        // deferred to _chunkedBodyLimitMiddleware below, AFTER auth, so an
        // unauthenticated client cannot force the server to buffer a body up to
        // the per-path cap before its token is checked.
        .addMiddleware(_contentLengthLimitMiddleware())
        .addMiddleware(_apiVersionMiddleware())
        .addMiddleware(_pairedTokenHydrationGate())
        .addMiddleware(_authMiddleware())
        .addMiddleware(_chunkedBodyLimitMiddleware())
        .addMiddleware(_rateLimitMiddleware())
        .addMiddleware(_highRiskAuditMiddleware())
        // ownership gate runs AFTER auth so we only check ownership
        // for requests that already presented a valid token. Placed
        // before the router so the 409 short-circuits the handler.
        .addMiddleware(_sessionOwnershipMiddleware())
        .addHandler(router.call);

    // Paired session tokens load from the pairing database, whose file only
    // opens on the first query. Start that before binding and hold requests
    // behind it: a request that arrived first used to be judged against an
    // empty map, answered 403 "Invalid authentication token", and a remote
    // client takes that answer as final and asks its operator to re-pair.
    // Hydration swallows its own errors, so a broken database still lets the
    // server come up and print its connect URL.
    final hydration = _hydratePairedSessionTokens();
    _pairedTokenHydration = hydration;

    final bindAddress = bindLocalOnly
        ? InternetAddress.loopbackIPv4
        : InternetAddress.anyIPv4;
    // when a TLS SecurityContext is supplied, bind HTTPS instead of
    // HTTP. shelf_io.serve transparently upgrades the WebSocket layer to
    // WSS for us because the underlying HttpServer is secure.
    _server = await shelf_io.serve(
      handler,
      bindAddress,
      port,
      securityContext: tlsContext,
    );
    final scheme = tlsContext != null ? 'https' : 'http';
    _logInfo(
      'Headless API server running on $scheme://${_server!.address.host}:${_server!.port}',
    );
    if (tlsContext != null) {
      _logInfo(
        '[TLS] Transport encryption is ENABLED. Bearer tokens and pairing codes are protected on the wire.',
      );
    }
    if (_effectiveAuthTokensByValue.isNotEmpty) {
      _logInfo(
        '[AUTH] Authentication is ENABLED. All requests require Bearer token.',
      );
    } else if (allowUnauthenticated) {
      // The operator explicitly opted into the legacy fully-open behaviour.
      // Surface it loudly so an accidental `--allow-unauthenticated` in a
      // production unit is impossible to miss in the logs.
      _logWarning(
        '[AUTH] UNAUTHENTICATED ACCESS IS ENABLED via --allow-unauthenticated '
        '(SKOTIQ_ALLOW_UNAUTHENTICATED). EVERY endpoint is served WITHOUT a '
        'token. Only use this on a fully trusted LAN or for local development.',
      );
      if (!bindLocalOnly) {
        _logWarning(
          '[AUTH] The open server is also bound to the LAN. Any device on the '
          'network can control this rig. This is unsafe for normal use.',
        );
      }
    } else {
      // FAIL CLOSED (default): no tokens configured, no opt-in. Privileged
      // endpoints reject with 401 until the appliance is paired or a token is
      // set; only the pairing/discovery/dashboard bootstrap surface is open.
      _logInfo(
        '[AUTH] No tokens configured. Server is FAIL CLOSED: only the pairing '
        'and dashboard bootstrap endpoints are reachable. Pair a device (or set '
        'SKOTIQ_AUTH_TOKEN / --auth-token) to unlock control. To deliberately '
        'serve everything unauthenticated on a trusted LAN, pass '
        '--allow-unauthenticated (SKOTIQ_ALLOW_UNAUTHENTICATED=1).',
      );
    }

    // Finish hydrating `_pairedSessionTokens` (started before the bind) and
    // register a revocation listener so revokeDevice() / token expiry / the
    // periodic sweep all evict the in-memory entry synchronously without a
    // server restart.
    await hydration;
    _pairedTokenHydration = null;
    // Best-effort: learn our own tailnet address so /api/info can hand it to a
    // remote client (no more reading the MagicDNS name off the appliance log).
    await _discoverTailscaleHostBestEffort();
    _installRevocationListener();
    _scheduleTokenSweep();

    // periodically evict expired pending commands so a hung driver
    // (or a sequence aborted before a completion event fires) doesn't keep
    // the correlator table growing forever.
    _commandCorrelatorSweepTimer?.cancel();
    _commandCorrelatorSweepTimer = Timer.periodic(const Duration(minutes: 5), (
      _,
    ) {
      try {
        _commandCorrelator.evictExpired();
      } catch (e) {
        _logWarning('CommandCorrelator sweep failed: $e');
      }
    });

    // purge terminated jobs older than the manager's
    // retention window. 5-minute cadence keeps the worst-case age at
    // `retention + 5min` which is well within the documented 24h budget.
    _jobSweepTimer?.cancel();
    _jobSweepTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      try {
        _jobManager.evictExpired();
      } catch (e) {
        _logWarning('JobManager sweep failed: $e');
      }
    });

    // Arm the unattended collaborative-mosaic driver so an owner appliance
    // auto-assembles (and a participant auto-downloads) the finished mosaic
    // with nobody watching. Reuses the same hub-credentialed
    // [CollaborativeMosaicService] the headless mosaic endpoints drive; a
    // no-hub config simply makes each refresh a quiet auth no-op until the
    // operator signs in.
    _collabMosaicPoller?.stop();
    final collabSettings = container.read(settingsDaoProvider);
    _collabMosaicPoller = CollaborativeMosaicPoller(
      service: container.read(collaborativeMosaicServiceProvider),
      projectsDao: container.read(mosaicProjectsDaoProvider),
      panelsDao: container.read(mosaicPanelsDaoProvider),
      logger: container.read(loggingServiceProvider),
      // Auto-upload an unattended rig's integrated panels only under the
      // operator's recorded unattended-upload consent (license + attribution +
      // auto opt-in); absence keeps uploads manual.
      uploadConsentResolver: () => resolveMosaicUploadConsent(collabSettings),
    )..start();

    // The Darkroom delivery retry sweep is deliberately NOT armed here. It
    // belongs to delivery, not to remote access: this start only runs when the
    // operator has switched the embedded server on, which is off on a fresh
    // install, so arming it here left a desktop GUI with no periodic sweep at
    // all while a stopped dawn pass promised the operator that "the retry sweep
    // resumes them". `resumeDarkroomWork` in the desktop bootstrap arms it in
    // every mode that owns the journal — including this daemon, which runs that
    // seam too — and `start()` is idempotent, so there is one timer either way.

    // Subscribe to backend events and broadcast to WebSocket clients
    _subscribeToBackendEvents();
    _subscribeToSequenceCatalogUpdates();
    _subscribeToHostMutationEvents();
    // Start publishing runtime channels; a headless host has no GUI to do it.
    container.read(hostRuntimeMirrorProvider);
    _subscribeToCatalogManagerEvents();
    _collaborationSubscription = _collaborationManager.stream.listen(
      _broadcastCollaborationState,
    );

    // start the LAN UDP push broadcaster (when wired). We start it
    // only when the server is non-loopback — loopback-only deployments
    // have no LAN to fan out on, so the bind would just waste sockets.
    final broadcaster = _lanPushBroadcaster;
    if (broadcaster != null && !bindLocalOnly && !broadcaster.isStarted) {
      try {
        await broadcaster.start();
        _logInfo(
          '[push] LAN push broadcaster started '
          '(port=${broadcaster.port}, interfaces=${broadcaster.activeSinkCount})',
        );
      } catch (e, st) {
        // Bind failure is not fatal — UDP push is a supplement to the WS
        // fan-out. Surface a warning so the operator knows phones won't
        // wake on critical alerts when the WS is broken.
        _logWarning(
          '[push] LAN push broadcaster failed to start: $e\n$st — '
          'critical alerts will only reach phones via the WebSocket.',
        );
      }
    } else if (broadcaster != null && bindLocalOnly) {
      _logInfo(
        '[push] LAN push broadcaster supplied but server is loopback-only; '
        'broadcaster will not start.',
      );
    }
  }

  /// Load all active, unexpired pairing tokens from Drift into the in-memory
  /// `_pairedSessionTokens` map. Without this, every server restart evicts
  /// every HTTP-paired client (audit F-3 in 01-connection-auth.md). The
  /// paired-device row stores the canonical grant spec, so an admin or
  /// fine-grained pairing keeps exactly the same authority after a restart.
  /// Legacy v3 rows are migrated to the historical `control` default.
  Future<void> _hydratePairedSessionTokens() async {
    // The service is either injected via the constructor (tests / GUI
    // in-memory pairing DB) or lazily constructed here via
    // [_ensurePairingService]. Lazy construction is safe inside `start()`:
    // `PairingDatabase()` wraps a `LazyDatabase`, so no file is opened until
    // the first query below — and that query runs inside the try/catch, so
    // a widget-test binding without path_provider just logs the hydration
    // failure instead of crashing startup.
    //
    // Why not skip when no service exists: a host restart that skips
    // hydration leaves every previously paired client permanently rejected
    // as "invalid token" until some pairing endpoint happens to run — which
    // a thin client never calls. The restart then looks like the clients
    // broke. Always hydrating on start makes persisted pairings survive.
    final service = _ensurePairingService();
    try {
      final rows = await service.tokenManager.getActiveUnexpiredPairedDevices();
      var restored = 0;
      var rejected = 0;
      for (final row in rows) {
        final grant = HeadlessAuthGrant.parseSpec(row.authGrantSpec);
        if (grant == null) {
          // Never guess when a persisted authorization record is corrupt. A
          // skipped bearer forces re-pairing and cannot accidentally escalate
          // to admin or broad control authority.
          rejected++;
          _logWarning(
            '[AUTH] Refusing paired session for device=${row.deviceId}: '
            'stored grant spec is malformed',
          );
          continue;
        }
        _pairedSessionTokens[row.sessionToken] = grant;
        restored++;
      }
      _logInfo(
        '[AUTH] Restored $restored paired session '
        'token${restored == 1 ? '' : 's'} from disk',
        fields: {'restored': restored, 'rejectedMalformed': rejected},
      );
    } catch (e, st) {
      // Never fall back silently to an empty map. A restart that quietly
      // loses every paired client looks like the phones broke; logging the
      // hydration failure tells the operator they may need to re-pair.
      _logError(
        '[AUTH] Failed to hydrate paired session tokens from disk: $e\n$st',
      );
    }
  }

  /// Register the [TokenManager] revocation listener so revocations from
  /// any code path (`TokenManager.revokeDevice`, the periodic sweep, the
  /// expiry path in `verifySessionToken`) propagate to the in-memory map.
  ///
  /// Skipped when no PairingService has been injected; the lazy-construct
  /// path inside [_handlePairingVerify] re-registers the listener via
  /// [_ensurePairingService] once a service exists. See
  /// [_hydratePairedSessionTokens] for the symmetric reasoning.
  void _installRevocationListener() {
    final service = _pairingService;
    if (service == null) return;
    service.tokenManager.setRevocationListener(_evictPairedSessionToken);
  }

  /// Remove a paired-session token from the in-memory map. Idempotent: if
  /// the token is unknown (already evicted, or never present) the call is a
  /// no-op so concurrent sweep + verify paths cannot fight.
  void _evictPairedSessionToken(String sessionToken) {
    final grant = _pairedSessionTokens.remove(sessionToken);
    if (grant != null) {
      _logInfo(
        '[AUTH] Evicted paired session token (${HeadlessApiServer._redactBearer(sessionToken)}) '
        'from in-memory map (scope=${grant.toSpec()})',
      );
    }
  }

  /// Periodic sweep that calls into `TokenManager.purgeExpiredAndRevokedSessions`.
  /// Why 60 s: revocation propagation is bounded by this interval. The
  /// `_evictPairedSessionToken` callback runs synchronously on direct revoke
  /// paths, but the sweep also catches tokens that hit `expires_at` between
  /// requests — no client attempts to use them, so the verify path never runs
  /// the listener for them.
  void _scheduleTokenSweep() {
    _tokenSweepTimer?.cancel();
    _tokenSweepTimer = Timer.periodic(tokenSweepInterval, (_) {
      if (_tokenSweepFuture != null) return;
      final sweep = _runTokenSweep();
      _tokenSweepFuture = sweep;
      unawaited(
        sweep.whenComplete(() {
          if (identical(_tokenSweepFuture, sweep)) {
            _tokenSweepFuture = null;
          }
        }),
      );
    });
  }

  Future<void> _runTokenSweep() async {
    final service = _pairingService;
    if (service == null) return;
    try {
      final result = await service.tokenManager
          .purgeExpiredAndRevokedSessions();
      if (!result.isEmpty) {
        _logInfo(
          '[AUTH] Token sweep purged ${result.expiredTokens.length} expired '
          'and ${result.revokedTokens.length} revoked session '
          'token${result.revokedTokens.length == 1 ? '' : 's'}',
        );
      }
    } catch (e, st) {
      _logWarning('[AUTH] Token sweep failed: $e\n$st');
    }
  }

  void _subscribeToSequenceCatalogUpdates() {
    _catalogUpdateSubscription?.cancel();
    _catalogUpdateSubscription = container
        .read(sequenceCatalogUpdateBusProvider)
        .stream
        .listen((update) {
          broadcastEvent(update.toSkotiqEvent());
        });
  }

  void _subscribeToHostMutationEvents() {
    final hub = container.read(hostMutationEventHubProvider);
    hub.wsBroadcast = (event) {
      final stamped = broadcastEvent(event);
      final ctrl = _runWatchEventBroadcast;
      if (ctrl != null && !ctrl.isClosed) {
        try {
          // The STAMPED copy, so the run-watch feed carries the same server
          // `seq` and instance id the WebSocket path does — the pair its feed
          // de-dup keys on. Raw only when stamping declined (a non-event
          // payload), which carries no seq to key on regardless.
          ctrl.add(stamped ?? event);
        } catch (e) {
          _logWarning('[run-watch] host-mutation SSE fan-out failed: $e');
        }
      }
    };
  }

  void _unsubscribeFromHostMutationEvents() {
    container.read(hostMutationEventHubProvider).wsBroadcast = null;
  }

  /// bridge [CatalogManager.events] onto the WS event stream so
  /// clients see structured catalog lifecycle messages
  /// (`CatalogDownloadStarted`, `CatalogDownloadProgress`,
  /// `CatalogVerified`, ...) in the `catalog` category. The fan-out
  /// happens inside the manager's stream listener so this works even
  /// when the catalog op was initiated from the local GUI rather than
  /// the REST API.
  void _subscribeToCatalogManagerEvents() {
    _catalogEventSubscription?.cancel();
    _catalogEventSubscription = CatalogManager.instance.events.listen(
      (event) {
        final severity = switch (event.eventType) {
          'CatalogDownloadFailed' => EventSeverity.error,
          'CatalogVerified' =>
            (event.data['ok'] == true)
                ? EventSeverity.info
                : EventSeverity.warning,
          _ => EventSeverity.info,
        };
        broadcastEvent(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: severity,
            category: EventCategory.catalog,
            eventType: event.eventType,
            data: Map<String, dynamic>.from(event.data),
          ),
        );
      },
      onError: (Object e, _) {
        _logWarning('[catalog] event stream error: $e');
      },
    );
  }

  /// Scan local interfaces for a Tailscale CGNAT address (100.64.0.0/10 IPv4 or
  /// fd7a:115c::/32 IPv6) and cache it as the rig's tailnet host. Best-effort:
  /// any failure leaves the hint null and `/api/info` simply omits it.
  Future<void> _discoverTailscaleHostBestEffort() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.any,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final bytes = addr.rawAddress;
          final isTs4 =
              addr.type == InternetAddressType.IPv4 &&
              bytes.length == 4 &&
              bytes[0] == 100 &&
              bytes[1] >= 64 &&
              bytes[1] <= 127; // 100.64.0.0/10
          final isTs6 =
              addr.type == InternetAddressType.IPv6 &&
              bytes.length == 16 &&
              bytes[0] == 0xfd &&
              bytes[1] == 0x7a &&
              bytes[2] == 0x11 &&
              bytes[3] == 0x5c; // fd7a:115c::/32
          if (isTs4 || isTs6) {
            _tailscaleHost = addr.address;
            _logInfo('[remote] tailnet address detected: ${addr.address}');
            return;
          }
        }
      }
    } catch (e) {
      _logWarning('[remote] tailnet address scan failed: $e');
    }
  }

  void _subscribeToBackendEvents() {
    try {
      final backend = container.read(backendProvider);
      _eventSubscription = backend.eventStream.listen((event) {
        final stamped = broadcastEvent(event);
        // Host-side live-stacking auto-feed: every frame the host writes to
        // disk is offered to the stacker, which ignores it unless stacking is
        // armed. This is what lets a running sequence stack live with no client
        // in the loop. Fire-and-forget; the coordinator serializes internally.
        if (event.eventType == 'ImageSaved') {
          final path = event.data['file_path'];
          if (path is String && path.isNotEmpty) {
            _stackingHandlers.onImageSaved(path);
          }
        }
        // re-broadcast onto the SSE fan-out controller. Two
        // separate sinks (WS clients + SSE clients) read from the same
        // upstream so a phone subscribing via SSE sees the same events
        // as the desktop dashboard's WebSocket.
        final ctrl = _runWatchEventBroadcast;
        if (ctrl != null && !ctrl.isClosed) {
          try {
            // The STAMPED copy: the run-watch SSE/snapshot feed then carries
            // the same server `seq` and instance id as the WebSocket path, so
            // its de-dup can key on the pair that actually distinguishes a
            // burst of same-millisecond siblings. Raw only when stamping
            // declined, which has no seq to key on regardless.
            ctrl.add(stamped ?? event);
          } catch (e) {
            // A failure inside the SSE fan-out must never crash the
            // upstream event subscription that the WS path depends on.
            _logWarning('[run-watch] SSE fan-out add failed: $e');
          }
        }
        _dispatchPluginNodeIfRequested(event);
      });
    } catch (e) {
      _logError('[API] Failed to subscribe to backend events: $e');
    }
  }

  void _dispatchPluginNodeIfRequested(SkotiqEvent event) {
    if (!dispatchPluginNodes ||
        event.category != EventCategory.sequencer ||
        event.eventType != 'PluginNodeRequested') {
      return;
    }

    final backend = container.read(backendProvider);
    if (!backend.dispatchPluginNodesLocally) {
      _logInfo(
        '[plugin-node] Remote backend event ignored; host-side dispatcher '
        'owns plugin node execution',
      );
      return;
    }

    final nodeId = event.data['node_id'] as String? ?? '';
    final pluginId = event.data['plugin_id'] as String? ?? '';
    final nodeTypeId = event.data['node_type_id'] as String? ?? '';
    final configJson = event.data['config_json'] as String? ?? '';
    final displayName = event.data['display_name'] as String?;
    final rawTimeout = event.data['timeout_secs'];
    final timeoutSecs = rawTimeout is num ? rawTimeout.toInt() : 600;

    if (nodeId.isEmpty) {
      _logWarning(
        '[plugin-node] PluginNodeRequested event missing node_id '
        '(plugin=$pluginId, node_type=$nodeTypeId)',
      );
      return;
    }

    final coordinator = container.read(pluginNodeDispatchCoordinatorProvider);
    if (!coordinator.claim(nodeId)) {
      _logInfo(
        '[plugin-node] PluginNodeRequested ignored; another local listener '
        'claimed node_id=$nodeId',
      );
      return;
    }

    final dispatcher = container.read(pluginNodeDispatcherProvider);
    unawaited(() async {
      late PluginNodeDispatchResult result;
      try {
        result = await dispatcher(
          PluginNodeDispatchRequest(
            nodeId: nodeId,
            pluginId: pluginId,
            nodeTypeId: nodeTypeId,
            configJson: configJson,
            displayName: displayName,
            timeoutSecs: timeoutSecs,
          ),
        );
      } catch (e, st) {
        _logError(
          '[plugin-node] Dispatcher threw for $pluginId/$nodeTypeId '
          '(node_id=$nodeId): $e\n$st',
        );
        result = PluginNodeDispatchResult(
          success: false,
          message: 'dispatcher threw: $e',
        );
      }

      try {
        await backend.sequencerPluginNodeFinished(
          nodeId: nodeId,
          success: result.success,
          message: result.message,
          structuredDetailJson: result.structuredDetailJson,
        );
      } catch (e, st) {
        _logError(
          '[plugin-node] Failed to deliver verdict for $pluginId/$nodeTypeId '
          '(node_id=$nodeId): $e\n$st',
        );
      } finally {
        coordinator.release(nodeId);
      }
    }());
  }

  Future<void> _stopServer() async {
    _unsubscribeFromHostMutationEvents();
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _catalogUpdateSubscription?.cancel();
    _catalogUpdateSubscription = null;
    // drop the bridge from CatalogManager.events to the WS
    // broadcaster so the manager's controller can finish flushing on
    // disposal without us still listening.
    await _catalogEventSubscription?.cancel();
    _catalogEventSubscription = null;
    await _collaborationSubscription?.cancel();
    _collaborationSubscription = null;
    await _pushNotificationSubscription?.cancel();
    _pushNotificationSubscription = null;
    // tear down the LAN UDP broadcaster + remote delivery hooks.
    // Ownership note: the broadcaster's lifecycle is shared with the
    // server it was passed to. Calling stop() here is the right thing
    // because we constructed/owned its sockets via [start]; the caller
    // that supplied it expects this teardown when the server stops.
    final lanBroadcaster = _lanPushBroadcaster;
    _lanPushBroadcaster = null;
    if (lanBroadcaster != null) {
      await lanBroadcaster.stop();
    }
    final remote = _remotePushDelivery;
    _remotePushDelivery = null;
    if (remote != null) {
      await remote.dispose();
    }
    _webSocketHeartbeatTimer?.cancel();
    _webSocketHeartbeatTimer = null;
    // stop the periodic token sweep before tearing down the DB, and
    // clear the revocation listener so it does not retain a reference to
    // `this` past disposal.
    _tokenSweepTimer?.cancel();
    _tokenSweepTimer = null;
    // A slow Drift purge must finish before the caller tears down the pairing
    // database. The single-flight gate also prevents minute ticks from piling
    // up concurrent writes when storage is degraded.
    final tokenSweep = _tokenSweepFuture;
    if (tokenSweep != null) await tokenSweep;
    _tokenSweepFuture = null;
    // stop the correlator eviction sweep.
    _commandCorrelatorSweepTimer?.cancel();
    _commandCorrelatorSweepTimer = null;
    _commandCorrelator.clear();
    _eventReplayBuffer.clear();
    // stop job sweep + drain the manager. Any in-flight
    // work observes the cancellation flag and exits its next poll.
    _jobSweepTimer?.cancel();
    _jobSweepTimer = null;
    // stop the unattended collaborative-mosaic driver. In-flight stitches own
    // their own cleanup; only the scheduling stops.
    _collabMosaicPoller?.stop();
    _collabMosaicPoller = null;
    // The Darkroom delivery retry sweep is deliberately NOT stopped here. It is
    // armed by `resumeDarkroomWork`, not by this start, and switching remote
    // access off is not a decision to stop delivering the night's files. It is
    // closed with the provider container when the process ends.
    await _jobManager.dispose();
    // tear down ownership state and broadcast controller.
    await _sessionOwnership.dispose();
    final pairingForListener = _pairingService;
    if (pairingForListener != null) {
      pairingForListener.tokenManager.setRevocationListener(null);
    }
    // closing the broadcast controller signals all attached
    // SSE clients to disconnect cleanly. The handler's onCancel cleans
    // up its own per-client timer + subscription.
    final ctrl = _runWatchEventBroadcast;
    _runWatchEventBroadcast = null;
    if (ctrl != null && !ctrl.isClosed) {
      await ctrl.close();
    }
    // tear down WebRTC sessions BEFORE the hub so any pending
    // datachannel send during the hub's final detach iteration does
    // not race with libwebrtc's close path.
    await _webRtcLiveViewHandlers.dispose();
    // tear down the live-view hub before the HTTP server so any
    // in-flight producer tick observes the disposal flag and stops
    // touching the backend.
    await _liveViewStreamHub.dispose();
    await _server?.close(force: true);
    _server = null;
    for (final socket in List.of(_sockets)) {
      await socket.sink.close();
    }
    _socketViewerIds.clear();
    _socketAuthIdentities.clear();
    _socketLastSeenAt.clear();
    _sockets.clear();
    _publishConnectedClientCount();
    _collaborationManager.dispose();
    // Why close the pairing DB: PairingService owns a Drift connection.
    // Leaving it open across server restarts leaks file handles in tests.
    // Best-effort: if the underlying LazyDatabase never opened (e.g. startup
    // hydration failed before the file could be resolved), close() rethrows
    // the open error — nothing is actually open to close, so swallow it.
    final pairing = _pairingService;
    if (pairing != null) {
      try {
        await pairing.close();
      } catch (e, st) {
        _logWarning(
          '[AUTH] Pairing database close failed during stop: $e\n$st',
        );
      }
      _pairingService = null;
    }
  }
}
