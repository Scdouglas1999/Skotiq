part of '../headless_api_server.dart';

extension _HeadlessApiServerHandlerInitialization on HeadlessApiServer {
  /// Builds every handler class once. A handler class is registered by adding
  /// it to the returned list; its routes come from its own `routes`, and their
  /// match order from `apiRouteGroups`.
  List<RouteSource> _initializeHandlers() {
    final logger = container.read(loggingServiceProvider);

    // Long-running operations (autofocus, plate solve, centering, backfills)
    // return `{jobId}` at once and run under the job manager.
    _jobManager = JobManager(emitEvent: broadcastEvent);

    _sessionOwnership = SessionOwnershipManager(
      emitEvent: broadcastEvent,
      digestToken: computeServerFingerprint,
    );

    final staticFiles = StaticFileHandlers(logger: logger);

    _equipmentHandlers = EquipmentHandlers(container);
    _stackingHandlers = StackingHandlers(container);

    // Created here rather than in start() so the handler keeps its stream
    // across a stop()/start() pair.
    _runWatchEventBroadcast = StreamController<SkotiqEvent>.broadcast();

    // The hub owns the producer loop and the subscriber registry across socket
    // churn. The WebSocket handler and each WebRTC session attach to the same
    // hub, so there is one producer loop and no second encode.
    _liveViewStreamHub = LiveViewStreamHub(container: container);
    _liveViewStreamHandlers = LiveViewStreamHandlers(
      container: container,
      hub: _liveViewStreamHub,
    );
    _webRtcLiveViewHandlers = WebRtcLiveViewHandlers(
      container: container,
      hub: _liveViewStreamHub,
    );

    return [
      SystemHandlers(
        container: container,
        // Closures, so each request reads the live value: the event sequence
        // advances on every broadcast.
        view: SystemServerView(
          fingerprint: () => _serverFingerprint,
          instanceId: () => _serverInstanceId,
          currentEventSeq: () => _eventSeq,
          eventReplayBufferSize: () => eventReplayBufferSize,
          eventReplayBufferOldestSeq: () => _eventReplayBuffer.oldestSeq,
          port: () => port,
          bindLocalOnly: () => bindLocalOnly,
          authRequired: () => isAuthRequired,
          availableAuthScopes: _availableAuthScopes,
          pairingModeWire: () => pairingMode.wire,
          tailscaleHost: () => remoteAccessHints.tailscaleHost,
          relayApplianceId: () => remoteAccessHints.relayApplianceId,
          hostMode: hostMode,
          hostName: hostComputerName(),
        ),
        staticFileHandlers: staticFiles,
        logger: logger,
      ),
      PairingHandlers(
        pairingAttempts: _pairingAttempts,
        ensurePairingService: _ensurePairingService,
        recordPairedSession: (token, grant) {
          _pairedSessionTokens[token] = grant;
        },
        rateLimitClientKey: _rateLimitClientKey,
        // A completed pairing is proof the operator is legitimate, so it also
        // lifts the bearer-token failure lockout; the middleware's own
        // clear-on-success is unreachable once that limiter has tripped.
        clearAuthFailures: _tokenResolver.clearFailures,
        pairingPrintCodes: pairingPrintCodes,
        pairingMode: () => pairingMode,
        logger: logger,
      ),
      // Shares the pairing service so the push token and preference tables
      // live in the same database as the paired-device rows they reference.
      PushHandlers(
        ensurePairingService: _ensurePairingService,
        logger: logger,
        // A closure: delivery is wired or cleared after the handlers are
        // built. A mock records what it would have sent and reaches no phone,
        // so it never reports as a cloud channel.
        deliveryChannel: () => switch (_remotePushDelivery) {
          null => PushDeliveryChannel.none,
          MockRemotePushDelivery() => PushDeliveryChannel.mock,
          _ => PushDeliveryChannel.cloud,
        },
      ),
      AuthHandlers(
        wsTicketManager: _wsTicketManager,
        authCookieManager: _authCookieManager,
        scopeForToken: _scopeForToken,
        logger: logger,
      ),
      CollaborationHandlers(manager: _collaborationManager, logger: logger),
      DeviceDiscoveryHandlers(container),
      // The correlator is optional on the handlers and every use is guarded
      // with `?.`, so leaving it out here would switch command/event
      // correlation off without an error.
      DeviceHandlers(
        container,
        commandCorrelator: _commandCorrelator,
        jobManager: _jobManager,
      ),
      GuidingHandlers(container),
      ImagingHandlers(
        container,
        jobManager: _jobManager,
        showApiCapturesInPreview: showApiCapturesInPreview,
      ),
      SequencerHandlers(container, commandCorrelator: _commandCorrelator),
      ReplayDebugHandlers(container),
      _equipmentHandlers,
      ProfileHandlers(container, emitEvent: broadcastEvent),
      SessionHandlers(container, jobManager: _jobManager),
      TargetHandlers(container),
      SequenceManagementHandlers(container),
      FlatWizardHandlers(container),
      MosaicHandlers(container),
      CoImagingHandlers(container),
      AnalyticsHandlers(container),
      WeatherHandlers(container),
      FileSystemHandlers(container),
      ScienceHandlers(container),
      SuggestionHandlers(container),
      TransientHandlers(container),
      FirstLightHandlers(container),
      AtlasHandlers(container),
      BackupHandlers(container),
      SyncHandlers(container),
      RuntimeStateHandlers(container, nightEvents: _nightEventLog),
      FramingHandlers(container, jobManager: _jobManager),
      PlanetariumHandlers(container),
      DomeHandlers(container),
      NarratorHandlers(container),
      SafetyMonitorHandlers(container),
      AuxiliaryHandlers(container),
      SchedulerHandlers(container),
      PlanningDataHandlers(container),
      FocusModelHandlers(container),
      _stackingHandlers,
      PostSessionHandlers(container, jobManager: _jobManager),
      DarkroomDeliveryHandlers(container),
      DepthLockHandlers(container),
      JobHandlers(jobManager: _jobManager),
      SessionOwnershipHandlers(
        manager: _sessionOwnership,
        tokenResolver: _extractBearerToken,
      ),
      // The update stack is provisioned after the server starts; the routes
      // answer 503 until then.
      UpdateRoutes(() => _updateHandlers),
      RunWatchHandlers(
        container: container,
        eventBroadcast: _runWatchEventBroadcast!.stream,
      ),
      BroadcastHandlers(container: container),
      LogHandlers(container),
      CalibrationHandlers(container),
      CalibrationLibraryHandlers(container),
      CatalogHandlers(
        jobManager: _jobManager,
        logger: logger,
        diskSpaceService: container.read(diskSpaceServiceProvider),
      ),
      DbReadHandlers(container),
      PluginHandlers(container),
      _webRtcLiveViewHandlers,
      staticFiles,
      _WebSocketRoutes(this),
    ];
  }
}

/// The WebSocket upgrade routes. They close over the server because the
/// upgrade reads the query string and the authenticated identity off the
/// request, which `webSocketHandler` does not pass on.
class _WebSocketRoutes implements RouteSource {
  _WebSocketRoutes(this._server);

  final HeadlessApiServer _server;

  @override
  Map<ApiEndpoint, Function> get routes => {
    WebSocketApi.events: _events,
    WebSocketApi.eventsLegacyPath: _events,
    WebSocketApi.liveView: _liveView,
  };

  FutureOr<Response> _events(Request request) {
    final query = request.url.queryParameters;
    // The collaboration viewer id is the authenticated principal, whatever the
    // client puts in its `collaboration.join` payload.
    final authIdentity = _server._authIdentityFrom(request);
    final adminAccess = ctx.requestHasAdminAccess(request);
    return webSocketHandler((socket, _) {
      _server._handleWebSocketWithQuery(
        socket,
        query,
        authIdentity,
        adminAccess: adminAccess,
      );
    }).call(request);
  }

  FutureOr<Response> _liveView(Request request) {
    return webSocketHandler((socket, _) {
      _server._liveViewStreamHandlers.handleSocket(socket);
    }).call(request);
  }
}
