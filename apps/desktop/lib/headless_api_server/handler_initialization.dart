part of '../headless_api_server.dart';

extension _HeadlessApiServerHandlerInitialization on HeadlessApiServer {
  void _initializeHandlers() {
    // job manager. Constructed BEFORE the device/imaging/
    // framing/session handlers so they can be wired to it. SessionHandlers
    // uses it for thumbnail backfill; polar Start remains a synchronous
    // admission command so native rejection reaches the caller. broadcastEvent
    // is a method on this class so we can pass the bound reference even
    // though the server hasn't bound a socket yet — the event stream
    // becomes active in start().
    _jobManager = JobManager(emitEvent: broadcastEvent);

    // session ownership manager. The digest function reuses the
    // existing `computeServerFingerprint` helper so token-digest values
    // share the same domain-separated SHA-256 prefix as everywhere else
    // we hash a credential.
    _sessionOwnership = SessionOwnershipManager(
      emitEvent: broadcastEvent,
      digestToken: computeServerFingerprint,
    );

    // Initialize handler instances. Long-running ops (autofocus, plate-
    // solve, center-on-target) receive the JobManager
    // so their handlers return `{jobId, status: queued}` immediately and
    // run the work in the background. Other handlers don't need it.
    // The correlator MUST be injected here or the whole command/event
    // correlation feature is dead code while `/api/docs` advertises it — the
    // parameter is optional and every call site guards with
    // `commandCorrelator?.`, so omitting it fails silently in the pass-making
    // direction. `_commandCorrelator` is assigned in the constructor before
    // `_initializeHandlers()` runs, so it is safe to read here.
    _deviceHandlers = DeviceHandlers(
      container,
      commandCorrelator: _commandCorrelator,
      jobManager: _jobManager,
    );
    _deviceDiscoveryHandlers = DeviceDiscoveryHandlers(container);
    _collaborationHandlers = CollaborationHandlers(
      manager: _collaborationManager,
      logger: container.read(loggingServiceProvider),
    );
    _staticFileHandlers = StaticFileHandlers(
      logger: container.read(loggingServiceProvider),
    );
    _authHandlers = AuthHandlers(
      wsTicketManager: _wsTicketManager,
      authCookieManager: _authCookieManager,
      scopeForToken: _scopeForToken,
      logger: container.read(loggingServiceProvider),
    );
    _pairingHandlers = PairingHandlers(
      pairingAttempts: _pairingAttempts,
      ensurePairingService: _ensurePairingService,
      // Why a closure: PairingHandlers does not have visibility into
      // [_pairedSessionTokens], and we deliberately do not want to leak
      // that map past the server boundary. The closure mutates it
      // through a typed, intent-named entry point so the call site is
      // unambiguous.
      recordPairedSession: (token, grant) {
        _pairedSessionTokens[token] = grant;
      },
      rateLimitClientKey: _rateLimitClientKey,
      // A completed pairing is proof the operator is legitimate, so it must
      // also lift the bearer-token failure lockout — the middleware's own
      // clear-on-success is unreachable once that limiter has tripped.
      clearAuthFailures: _tokenResolver.clearFailures,
      pairingPrintCodes: pairingPrintCodes,
      pairingMode: () => pairingMode,
      logger: container.read(loggingServiceProvider),
    );
    // Phase D — push token/preference endpoints. Reuses `_ensurePairingService`
    // so the `device_push_tokens` / `device_push_prefs` tables live in the same
    // Drift DB as the paired-device rows they reference.
    _pushHandlers = PushHandlers(
      ensurePairingService: _ensurePairingService,
      logger: container.read(loggingServiceProvider),
      // Closure, not a captured value: delivery is wired (or cleared) after
      // the handlers are built, so `/api/push/targets` must read the live one.
      // A MockRemotePushDelivery reports as `mock`, never as a cloud channel —
      // it records what it would have sent and reaches no phone.
      deliveryChannel: () => switch (_remotePushDelivery) {
        null => PushDeliveryChannel.none,
        MockRemotePushDelivery() => PushDeliveryChannel.mock,
        _ => PushDeliveryChannel.cloud,
      },
    );
    _systemHandlers = SystemHandlers(
      container: container,
      view: SystemServerView(
        // Wrap every server field in a closure so the handler always
        // reads the live value (the event-seq counter advances on
        // every broadcast, so a one-shot capture would be wrong by
        // the second request).
        fingerprint: () => _serverFingerprint,
        instanceId: () => _serverInstanceId,
        currentEventSeq: () => _eventSeq,
        eventReplayBufferSize: () => eventReplayBufferSize,
        eventReplayBufferOldestSeq: () => _eventReplayBuffer.oldestSeq,
        port: () => port,
        bindLocalOnly: () => bindLocalOnly,
        authRequired: () => _effectiveAuthTokensByValue.isNotEmpty,
        availableAuthScopes: _availableAuthScopes,
        pairingModeWire: () => pairingMode.wire,
        tailscaleHost: () => remoteAccessHints.tailscaleHost,
        relayApplianceId: () => remoteAccessHints.relayApplianceId,
      ),
      staticFileHandlers: _staticFileHandlers,
      logger: container.read(loggingServiceProvider),
    );
    _guidingHandlers = GuidingHandlers(container);
    _sequencerHandlers = SequencerHandlers(
      container,
      commandCorrelator: _commandCorrelator,
    );
    _replayDebugHandlers = ReplayDebugHandlers(container);
    _equipmentHandlers = EquipmentHandlers(container);
    // [settings sync] inject `broadcastEvent` so handleUpdateSettings
    // can fan settings.changed events out to every connected WS client.
    _profileHandlers = ProfileHandlers(container, emitEvent: broadcastEvent);
    _imagingHandlers = ImagingHandlers(
      container,
      jobManager: _jobManager,
      showApiCapturesInPreview: showApiCapturesInPreview,
    );
    _sessionHandlers = SessionHandlers(container, jobManager: _jobManager);

    // Initialize new feature parity handlers
    _targetHandlers = TargetHandlers(container);
    _sequenceManagementHandlers = SequenceManagementHandlers(container);
    _flatWizardHandlers = FlatWizardHandlers(container);
    _mosaicHandlers = MosaicHandlers(container);
    _coImagingHandlers = CoImagingHandlers(container);
    _analyticsHandlers = AnalyticsHandlers(container);
    _weatherHandlers = WeatherHandlers(container);
    _suggestionHandlers = SuggestionHandlers(container);
    _transientHandlers = TransientHandlers(container);
    _firstLightHandlers = FirstLightHandlers(container);
    _atlasHandlers = AtlasHandlers(container);
    _backupHandlers = BackupHandlers(container);
    _syncHandlers = SyncHandlers(container);
    _runtimeStateHandlers = RuntimeStateHandlers(
      container,
      retained: () {
        final oldest = _eventReplayBuffer.oldestSeq;
        if (oldest == null) return const <SkotiqEvent>[];
        return _eventReplayBuffer.eventsSince(oldest - 1) ??
            const <SkotiqEvent>[];
      },
    );
    _framingHandlers = FramingHandlers(container, jobManager: _jobManager);
    _fileSystemHandlers = FileSystemHandlers(container);
    _scienceHandlers = ScienceHandlers(container);

    _narratorHandlers = NarratorHandlers(container);

    // Initialize auxiliary device handlers
    _domeHandlers = DomeHandlers(container);
    _safetyMonitorHandlers = SafetyMonitorHandlers(container);
    _auxiliaryHandlers = AuxiliaryHandlers(container);

    // Initialize planetarium handlers
    _planetariumHandlers = PlanetariumHandlers(container);

    // Initialize intelligent scheduler and focus model handlers
    _schedulerHandlers = SchedulerHandlers(container);
    _focusModelHandlers = FocusModelHandlers(container);

    // Planner/scheduler DATA tables (goals/constraints/horizons/projects)
    // served to remote slaves so their candidate loader, editors, and Planner
    // Projects tab read host rows instead of the slave's empty local DB.
    _planningDataHandlers = PlanningDataHandlers(container);

    // Live stacking control surface (host-side EAA integration).
    _stackingHandlers = StackingHandlers(container);

    // Post-session integration / finishing control surface. JobManager-backed
    // (passed the same manager as plate-solve) so each long compute op returns
    // {jobId} immediately and runs on the host's FFI pipeline in the background.
    _postSessionHandlers = PostSessionHandlers(
      container,
      jobManager: _jobManager,
    );

    // Darkroom peer delivery. Not JobManager-backed: the manifest and the
    // acknowledgement are short reads and one journal write, and the artifact
    // download is a streamed file the client resumes itself.
    _darkroomDeliveryHandlers = DarkroomDeliveryHandlers(container);

    // DepthLock goal store. The native side owns the goals and the analysis
    // queue, so the handler is a thin translation layer over the backend role.
    _depthLockHandlers = DepthLockHandlers(container);

    // broadcast controller that fans out SkotiqEvents from
    // the backend stream to every connected SSE subscriber. Created here
    // (rather than in `start()`) so it can be passed to the handler ctor
    // and survive a stop()/start() pair without rebuilding the handler.
    _runWatchEventBroadcast = StreamController<SkotiqEvent>.broadcast();
    _runWatchHandlers = RunWatchHandlers(
      container: container,
      eventBroadcast: _runWatchEventBroadcast!.stream,
    );

    // broadcast endpoint handler (live-stacking
    // viewer for EAA / outreach). Lives independently of the run-watch
    // surface because the broadcast is public-by-default whereas
    // run-watch is paired-only.
    _broadcastHandlers = BroadcastHandlers(container: container);

    // Hub owns the producer loop + subscriber registry across
    // socket churn so we never lose the "is anyone listening?" signal
    // between client reconnects. The handler is a thin wrapper that
    // exposes the WS upgrade callback to the router.
    _liveViewStreamHub = LiveViewStreamHub(container: container);
    _liveViewStreamHandlers = LiveViewStreamHandlers(
      container: container,
      hub: _liveViewStreamHub,
    );

    // WebRTC live-view fan-out. Each session attaches to the
    // SAME hub via attachRaw with a custom sink that pushes binary
    // frames into an outbound RTCDataChannel. No re-encode, no second
    // producer loop.
    _webRtcLiveViewHandlers = WebRtcLiveViewHandlers(
      container: container,
      hub: _liveViewStreamHub,
    );

    // remote log retrieval/tail for mobile operators on
    // headless deployments (Pi/embedded). The handler is stateless
    // beyond what's in the LoggingService it reads from the container.
    _logHandlers = LogHandlers(container);

    // remote calibration library management. Stateless beyond the
    // DAOs it reads from the container; no upstream service to dispose.
    _calibrationHandlers = CalibrationHandlers(container);

    // v46 — unified Calibration Library Manager (browse / match / tag).
    // Stateless beyond the CalibrationLibraryService it reads off the
    // container.
    _calibrationLibraryHandlers = CalibrationLibraryHandlers(container);

    // catalog management. The handler dispatches long-running
    // downloads through the JobManager so the action POST returns
    // {jobId} immediately. Catalog lifecycle events are bridged onto
    // the WS event stream in start() below.
    _catalogHandlers = CatalogHandlers(
      jobManager: _jobManager,
      logger: container.read(loggingServiceProvider),
      diskSpaceService: container.read(diskSpaceServiceProvider),
    );

    // db read endpoints. Reads from existing DAOs; no service
    // dependency, so construction is trivial.
    _dbReadHandlers = DbReadHandlers(container);

    // Plugin management endpoints. Runtime state comes from PluginHost; the
    // legacy archive service is still container-backed for migration cleanup.
    _pluginHandlers = PluginHandlers(container);

    // REST surface for the JobManager that was constructed
    // earlier (before the device handlers so they could be wired).
    _jobHandlers = JobHandlers(jobManager: _jobManager);

    // REST surface for the SessionOwnershipManager.
    _sessionOwnershipHandlers = SessionOwnershipHandlers(
      manager: _sessionOwnership,
      tokenResolver: _extractBearerToken,
    );
  }
}
