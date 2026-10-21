/**
 * Skotiq Web Dashboard - Main Application
 *
 * Manages all dashboard panels: devices, camera, mount, sequencer, guiding, event log.
 * Connects to the headless API via REST polling and WebSocket events.
 */

(function () {
  'use strict';

  /** Read a CSS custom property from :root (keeps canvas/SVG in sync with dashboard.css). */
  function themeColor(varName) {
    return getComputedStyle(document.documentElement).getPropertyValue(varName).trim();
  }

  // =========================================================================
  // State
  // =========================================================================

  const state = {
    connectedDevices: [],
    allDevices: [],
    serverInfo: null,
    cameraDeviceId: '',
    mountDeviceId: '',
    focuserDeviceId: '',
    filterWheelDeviceId: '',
    rotatorDeviceId: '',
    lastImage: null,
    lastImagePreviewUrl: null,
    lastImageRawU16: null,
    rawLoadStatus: 'idle', // idle | loading | ready | failed
    rawLoadGeneration: 0,
    imagePreviewLoading: false,
    mountStatus: null,
    cameraStatus: null,
    sequencerStatus: null,
    guidingStatus: null,
    focuserStatus: null,
    filterWheelStatus: null,
    filterWheelPositions: null,
    filterWheelPositionsDeviceId: null,
    filterWheelPositionsLoading: false,
    rotatorStatus: null,
    readoutModes: [],
    selectedReadoutMode: null,
    lastAutofocusResult: null,
    lastImagePositionAngle: null,
    guideHistory: { ra: [], dec: [] },
    maxGuidePoints: 100,
    logEntries: [],
    maxLogEntries: 500,
    pollInterval: null,
    pingInterval: null,
    wsFallbackPollInterval: null,
    lastWsMessageAt: 0,
    // Link health — see renderLinkState(). Set only by a failed reachability
    // probe; an HTTP error means the server answered and is not unreachable.
    serverUnreachable: false,
    panelLastUpdate: {
      devices: 0, mount: 0, camera: 0, sequencer: 0, guiding: 0,
      focuser: 0, 'filter-wheel': 0, rotator: 0,
    },
    // When each panel's data source last refused. Compared against
    // `panelLastUpdate` — a failure newer than the last good answer is what
    // makes a panel stale while the server itself is plainly still there.
    panelLastFailure: {
      devices: 0, mount: 0, camera: 0, sequencer: 0, guiding: 0,
      focuser: 0, 'filter-wheel': 0, rotator: 0,
    },
    staleCheckInterval: null,
    debugMode: false,
    pendingImageFetchTimer: null,
    pendingExposureExpectedBy: 0,
    activePhoneTab: 'panel-devices',
    dpadActiveButton: null,
    dpadActiveAxis: null,
    pressedKeys: new Set(),
    connectRetryCount: 0,
    targetSearchDebounce: null,
    targetSearchAbort: null,
    // Ops-panel state, namespaced under `ops` so it stays distinct from the
    // wizard state below.
    ops: {
      sequences: [],
      selectedSequenceId: '',
      checkpoints: [],
      weather: null,
      safety: null,
      domeDeviceId: '',
      domeStatus: null,
      profiles: [],
      activeProfile: null,
      sessionSummary: null,
      catalogResults: [],
      catalogSearchDebounce: null,
      currentTargetId: null,
      sequenceStartedAt: 0,
    },

    // Wizard state. Each wizard tracks its current step index. The HTML carries `data-step`
    // attributes on .wizard-step + .wizard-dot so step changes are reflected
    // in CSS without rebuilding the DOM.
    wizardStep: {
      'polar-align-modal': 0,
      'flat-wizard-modal': 0,
      'mosaic-modal': 0,
      'framing-modal': 0,
    },
    // Step counts per wizard (matches the .wizard-dot dots in index.html).
    wizardStepCount: {
      'polar-align-modal': 3,
      'flat-wizard-modal': 3,
      'mosaic-modal': 4,
      'framing-modal': 3,
    },
    // Polar alignment live state mirrored from polarAlignment-category WS
    // events. Drives the Mount panel readout + the modal step-3 progress.
    polarAlignment: {
      phase: 'idle',
      totalErrorArcmin: null,
      statusMessage: '',
    },
    // Flat wizard state across the modal session.
    flatWizard: {
      // {name -> bool} from the filter wheel; toggled by chip clicks.
      selectedFilters: {},
      // Calibration results from /api/flat-wizard/calibrate-multi.
      calibrations: [],
      running: false,
    },
    // Framing assistant: chosen target + rotation, plus the FOV (degrees)
    // pulled from /api/planetarium/fov-config so the preview rectangle has
    // the right aspect.
    framing: {
      target: null,  // {id?, name, ra, dec}
      rotation: 0,
      fovWidthDegrees: null,
      fovHeightDegrees: null,
      searchDebounce: null,
    },
    // Mosaic planner: last generated panel layout for the preview step.
    mosaic: {
      panels: null,
      cols: 2,
      rows: 2,
    },
    // Last plate-solve result so the Mount panel can show RA/Dec/scale/PA.
    lastPlateSolve: null,
  };

  // Stale indicators, per-panel enablement, and phone tab routing all need a
  // mapping from panel id to the controlling device-type. Define it once.
  const PANEL_DEVICE_TYPES = {
    'panel-camera': 'camera',
    'panel-mount': 'mount',
    'panel-focuser': 'focuser',
    'panel-filter-wheel': 'filterWheel',
    'panel-rotator': 'rotator',
    // The dome panel needs a connected dome device to be useful.
    'ops-dome-panel': 'dome',
  };

  // Phone tabs: which panels are accessible via the bottom tab bar on phones.
  const PHONE_PANELS = ['panel-devices', 'panel-mount', 'panel-camera',
                        'panel-sequencer', 'panel-log'];

  // Phone-tab grouping: device control panels piggy-back on existing tabs so
  // the bottom nav stays at five slots. Filter wheel, focuser, and rotator
  // live in the Devices tab (next to discovery); camera, mount, and sequencer
  // keep their own dedicated tabs. The ops panels join the same tabs — the
  // Sequencer tab carries sequence-load + checkpoint, the Devices tab carries
  // weather/safety + dome + profile/analytics underneath the device list.
  const PHONE_TAB_EXTRA_PANELS = {
    'panel-devices': [
      'panel-filter-wheel', 'panel-focuser', 'panel-rotator',
      'panel-planetarium', 'panel-settings',
      'ops-weather-panel', 'ops-dome-panel', 'ops-profile-panel',
    ],
    'panel-sequencer': [
      'ops-seq-load-panel', 'ops-checkpoint-panel', 'ops-target-panel',
    ],
  };

  // The server heartbeat cadence is 30 s. Allow one complete interval plus
  // jitter before declaring a quiet socket stale: a threshold under the
  // heartbeat interval drops a healthy connection into REST fallback several
  // times a minute and cancels large raw-preview downloads mid-flight.
  const WS_FALLBACK_THRESHOLD_MS = 45000;
  // Every panel that keeps its own freshness clock. The stale line, the
  // re-ask below, and the Run panel's right to assert a state all read this
  // one list.
  //
  // `sequences` and `analytics` joined it late: both panels assert numbers
  // that outlive their source (Current target, the session frame count) and
  // both were invisible to the clock, so across a SIGTERM they sat unmarked
  // beside seven siblings that all carried a "Stale: 1m 0s since last update"
  // line.
  //
  // `weather` and `dome` joined for the same reason and matter more. Measured
  // 74 s after a SIGTERM, with the header already reading "No contact" and
  // five siblings carrying "Stale: 1m 14s since last update", the Weather &
  // Safety panel still read "SAFE / Safe to image yes / Alert level clear /
  // Conditions are within limits / Temperature 8.5 °C" — an affirmative
  // safety verdict about a rig nobody could reach. `weather` is one key for
  // both routes because one fetch gets both and one panel shows both: if
  // either of /api/weather/current and /api/safety/status refuses, the
  // panel's verdict is unconfirmed.
  const PANEL_KEYS = ['devices', 'mount', 'camera', 'sequencer', 'guiding',
                      'focuser', 'filter-wheel', 'rotator',
                      'sequences', 'analytics', 'weather', 'dome'];
  // How often a panel whose route is failing is re-asked. Matches the WS
  // fallback poll's cadence: the same load, already accepted, and only while
  // something is actually failing.
  const PANEL_REFRESH_RETRY_MS = 5000;
  let lastPanelRefreshRetryAt = 0;
  // Image-fetch fallback if no exposure_complete event arrives.
  const IMAGE_FALLBACK_GRACE_MS = 30000;
  // Cap on base64-decoded image size for display.
  const MAX_IMAGE_BYTES = 2 * 1024 * 1024;

  // =========================================================================
  // Initialization
  // =========================================================================

  document.addEventListener('DOMContentLoaded', init);

  function init() {
    // Everything that ages data subscribes to the one clock, here, once: the
    // header's verdict, the Run panel's right to assert a state, and every
    // panel's stale line. See repaintDataState().
    subscribeToDataClock(renderLinkState);
    subscribeToDataClock(renderRunDataState);
    subscribeToDataClock(renderOpsWeatherDataState);
    subscribeToDataClock(renderOpsDomeDataState);
    for (const panelKey of PANEL_KEYS) {
      subscribeToDataClock((view) => renderStaleIndicator(panelKey, view));
    }

    // Honour ?debug=1 in the URL to allow manual server URL entry. The page
    // CSP restricts the dashboard to its own origin; manual URL entry is a
    // power-user escape hatch and is hidden by default.
    state.debugMode = new URLSearchParams(window.location.search).get('debug') === '1';
    if (state.debugMode) {
      const urlInput = document.getElementById('server-url');
      urlInput.hidden = false;
      const label = document.getElementById('server-url-label');
      if (label) label.classList.remove('sr-only');
    }

    // Tokens never live in localStorage. The "remember" path goes through an
    // HttpOnly `skotiq_session` cookie that JS cannot read; the unchecked
    // path keeps the bearer in sessionStorage so it dies when the tab closes. The remember-checkbox
    // flag itself is benign metadata and stays in localStorage so the UI
    // state persists across reloads.
    const servedFromServer =
      window.location.protocol === 'http:' || window.location.protocol === 'https:';
    // The initial server URL comes from window.location.origin only.
    // Debug mode allows overriding via localStorage; production cannot.
    let savedUrl = defaultServerUrl();
    if (state.debugMode) {
      const stored = normalizeServerUrl(localStorage.getItem('skotiq_url'));
      if (stored) savedUrl = stored;
    }
    const shouldAutoConnect = servedFromServer || (state.debugMode && !!savedUrl);
    const rememberToken = localStorage.getItem('skotiq_remember_token') === 'true';
    const savedToken = readStoredToken();
    const savedDeviceName = localStorage.getItem('skotiq_device_name') || defaultDeviceName();
    const savedDeviceId = localStorage.getItem('skotiq_device_id') || generateDeviceId();
    // One-shot scrub of token bytes an older install may have left in
    // localStorage. Nothing writes there; stale bytes left behind would hand
    // a JS-readable bearer to any script that runs on the page.
    localStorage.removeItem('skotiq_token');

    document.getElementById('server-url').value = savedUrl;
    document.getElementById('auth-token').value = savedToken;
    document.getElementById('device-name').value = savedDeviceName;
    // Default OFF for remember-token. The bearer is sessionStorage-only
    // unless the user opts in.
    document.getElementById('remember-token').checked = rememberToken;
    localStorage.setItem('skotiq_device_id', savedDeviceId);

    // Connect / pair buttons
    document.getElementById('btn-connect').addEventListener('click', () => handleConnect());
    document.getElementById('btn-pair').addEventListener('click', openPairModal);
    document.getElementById('btn-apply-token').addEventListener('click', () => handleConnect());
    document.getElementById('remember-token').addEventListener('change', handleRememberTokenChanged);

    // Pairing modal
    document.getElementById('btn-pair-cancel').addEventListener('click', closePairModal);
    document.getElementById('btn-pair-submit').addEventListener('click', handlePairSubmit);
    document.getElementById('pair-modal-code').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') handlePairSubmit();
      if (e.key === 'Escape') closePairModal();
    });

    // Camera controls
    document.getElementById('btn-expose').addEventListener('click', handleExpose);
    document.getElementById('btn-abort-expose').addEventListener('click', handleAbortExpose);
    document.getElementById('btn-camera-apply-gain').addEventListener('click', handleCameraApplyGain);
    document.getElementById('btn-camera-apply-offset').addEventListener('click', handleCameraApplyOffset);
    document.getElementById('btn-camera-apply-readout').addEventListener('click', handleCameraApplyReadout);
    document.getElementById('btn-camera-cooler-on').addEventListener('click', () => handleCameraCooler(true));
    document.getElementById('btn-camera-cooler-off').addEventListener('click', () => handleCameraCooler(false));
    document.getElementById('btn-camera-apply-cooling').addEventListener('click', handleCameraApplyCooling);
    document.getElementById('btn-camera-subframe-full').addEventListener('click', handleCameraSubframeFull);
    document.getElementById('camera-binning').addEventListener('change', handleCameraBinningChange);
    // Live readout of the temperature slider so the operator sees the
    // setpoint before pressing Set.
    document.getElementById('camera-target-temp').addEventListener('input', updateCoolerSliderReadout);

    // Mount controls — press-and-hold d-pad.
    setupDpad();
    document.getElementById('btn-mount-stop').addEventListener('click', handleMountStop);
    document.getElementById('btn-mount-park').addEventListener('click', handleMountPark);
    document.getElementById('btn-mount-unpark').addEventListener('click', handleMountUnpark);
    document.getElementById('btn-mount-tracking').addEventListener('click', handleMountToggleTracking);

    // Mount goto / object slew
    document.getElementById('btn-mount-goto').addEventListener('click', handleMountGoto);
    document.getElementById('btn-mount-goto-abort').addEventListener('click', handleMountGotoAbort);
    document.getElementById('mount-goto-name').addEventListener('input', handleTargetSearchInput);
    document.getElementById('mount-goto-name').addEventListener('focus', handleTargetSearchInput);
    document.getElementById('mount-goto-name').addEventListener('blur', () => {
      // Why a small delay before hiding: click on a suggestion fires after
      // the input's blur; hiding immediately would cancel the click.
      setTimeout(hideTargetSuggestions, 150);
    });
    document.getElementById('mount-goto-name').addEventListener('keydown', handleTargetSearchKeyDown);

    // Filter wheel — wired up in setupFilterWheelPanel after device discovery.

    // Focuser controls
    document.getElementById('btn-focuser-move').addEventListener('click', handleFocuserMoveTo);
    document.getElementById('btn-focuser-halt').addEventListener('click', handleFocuserHalt);
    document.getElementById('btn-focuser-autofocus').addEventListener('click', handleFocuserRunAutofocus);
    document.getElementById('btn-focuser-autofocus-cancel').addEventListener('click', handleFocuserCancelAutofocus);
    for (const btn of document.querySelectorAll('.focuser-jog-grid button')) {
      btn.addEventListener('click', () => {
        const delta = parseInt(btn.dataset.delta, 10);
        if (!isNaN(delta)) handleFocuserMoveRelative(delta);
      });
    }

    // Rotator controls
    document.getElementById('btn-rotator-move').addEventListener('click', handleRotatorMoveTo);
    document.getElementById('btn-rotator-halt').addEventListener('click', handleRotatorHalt);
    document.getElementById('btn-rotator-sync-image').addEventListener('click', handleRotatorSyncImage);

    // Sequencer controls
    document.getElementById('btn-seq-start').addEventListener('click', handleSeqStart);
    document.getElementById('btn-seq-stop').addEventListener('click', handleSeqStop);
    document.getElementById('btn-seq-pause').addEventListener('click', handleSeqPause);
    document.getElementById('btn-seq-resume').addEventListener('click', handleSeqResume);
    // Run controls start disabled-by-state; the first status poll enables
    // whichever actions the executor/guider state actually admits.
    updateSequencerButtons('idle');
    updateGuidingButtons('disconnected');

    // Auth reveal chip — re-expands the pairing/token bar after it
    // auto-collapses on successful authentication.
    const btnAuthReveal = document.getElementById('btn-auth-reveal');
    if (btnAuthReveal) {
      btnAuthReveal.addEventListener('click', () => {
        const bar = document.getElementById('auth-bar');
        setAuthBarVisible(bar ? bar.classList.contains('hidden') : true);
      });
    }

    // Guiding controls
    document.getElementById('btn-guide-start').addEventListener('click', handleGuideStart);
    document.getElementById('btn-guide-stop').addEventListener('click', handleGuideStop);
    const btnGuideConnect = document.getElementById('btn-guide-connect');
    if (btnGuideConnect) btnGuideConnect.addEventListener('click', handleGuideConnect);
    const btnGuideDither = document.getElementById('btn-guide-dither');
    if (btnGuideDither) btnGuideDither.addEventListener('click', handleGuideDither);
    const btnGuidePause = document.getElementById('btn-guide-pause');
    if (btnGuidePause) btnGuidePause.addEventListener('click', handleGuidePauseToggle);

    // Theme toggle + persisted panel collapse.
    // Run before the rest of the panel wireup so a restored-collapsed panel
    // never flashes its body open on load.
    setupTheme();
    setupPanelPrefs();

    setupCapabilityNav();
    setupPlanetariumPanel();
    setupSettingsPanel();

    // Log controls
    document.getElementById('btn-clear-log').addEventListener('click', clearLog);

    // Phone tabs
    for (const tab of document.querySelectorAll('.phone-tab')) {
      tab.addEventListener('click', () => activatePhoneTab(tab.dataset.target));
    }

    // Ops panels. Their wireup lives in one function so it reads as a group.
    setupOpsPanels();

    // ===== Wizard launchers + modals =====
    setupWizardModals();
    document.getElementById('btn-plate-solve').addEventListener('click', () => handlePlateSolve(false));
    document.getElementById('btn-plate-solve-sync').addEventListener('click', () => handlePlateSolve(true));
    document.getElementById('btn-open-polar-align').addEventListener('click', () => openWizardModal('polar-align-modal'));
    document.getElementById('btn-stop-polar-align').addEventListener('click', handleStopPolarAlignment);
    document.getElementById('btn-polar-align-start').addEventListener('click', handleStartPolarAlignment);
    document.getElementById('btn-polar-align-close').addEventListener('click', () => closeWizardModal('polar-align-modal'));
    document.getElementById('pa-mode').addEventListener('change', updatePolarAlignmentFieldsForMode);

    document.getElementById('btn-open-flat-wizard').addEventListener('click', openFlatWizard);
    document.getElementById('btn-flat-wizard-close').addEventListener('click', () => closeWizardModal('flat-wizard-modal'));
    document.getElementById('btn-flat-wizard-calibrate').addEventListener('click', handleFlatWizardCalibrate);
    document.getElementById('btn-flat-wizard-build').addEventListener('click', handleFlatWizardBuild);

    document.getElementById('btn-open-mosaic').addEventListener('click', openMosaicWizard);
    document.getElementById('btn-mosaic-close').addEventListener('click', () => closeWizardModal('mosaic-modal'));
    document.getElementById('btn-mosaic-use-mount').addEventListener('click', handleMosaicUseMountPosition);
    document.getElementById('btn-mosaic-preview').addEventListener('click', handleMosaicPreview);
    document.getElementById('btn-mosaic-build').addEventListener('click', handleMosaicBuild);

    document.getElementById('btn-open-framing').addEventListener('click', openFramingWizard);
    document.getElementById('btn-framing-close').addEventListener('click', () => closeWizardModal('framing-modal'));
    document.getElementById('btn-framing-slew').addEventListener('click', handleFramingSlew);
    document.getElementById('btn-framing-center').addEventListener('click', handleFramingCenter);
    document.getElementById('btn-framing-rotate').addEventListener('click', handleFramingRotate);
    document.getElementById('btn-framing-save').addEventListener('click', handleFramingSave);
    document.getElementById('framing-search').addEventListener('input', handleFramingSearchInput);
    document.getElementById('framing-search').addEventListener('blur', () => {
      // Same race-condition guard as the mount-goto autocomplete — click on a
      // suggestion fires after blur, so delay the hide.
      setTimeout(hideFramingSuggestions, 150);
    });
    document.getElementById('framing-rotation').addEventListener('input', handleFramingRotationChange);


    // Guide graph canvas
    setupGuideCanvas();
    // Render initial slider readout so the user doesn't see an empty span
    // before any input event fires.
    updateCoolerSliderReadout();
    setConnectionStatus('disconnected');

    // Phone layout — apply on load and on resize.
    applyResponsiveLayout();
    window.addEventListener('resize', applyResponsiveLayout);

    // Default: every action button disabled until we connect & enumerate
    // devices.
    refreshPanelEnablement();

    // SPA surfaces: hash routing + gallery + logs + login overlay.
    // setupHashRouting() is idempotent and survives a
    // reload because the URL is the source of truth; the gallery and
    // logs surfaces are set up unconditionally because they react to
    // the route hash too (e.g. "logs" auto-subscribes on first visit).
    setupGalleryPanel();
    setupLogsPanel();
    setupHashRouting();
    setupLoginOverlay();

    // Auto-connect on load when served from the same origin. The login
    // overlay decides whether to gate it: shouldAutoConnect is a hint, not a
    // command — the overlay hides itself and dispatches the connect once
    // credentials are present (token, cookie session, or no-auth host).
    if (shouldAutoConnect) {
      bootstrapAuthFlow();
    }
  }

  // =========================================================================
  // Connection
  // =========================================================================

  /// What a failed connect means, in words the operator can act on.
  ///
  /// The raw error message is the server's own refusal body — a rejected
  /// bearer pastes `{"error":"Access denied","message":"Invalid authentication
  /// token"}` — and a JSON fragment is a diagnostic, not an instruction. Each
  /// branch below names the one thing to do next, and the `kind` is what lets
  /// the sign-in overlay tell a wrong credential from a server that is simply
  /// not answering.
  /// The refusal a scope-denied answer carries, as a sentence.
  ///
  /// Every clause comes off the wire — the resource the endpoint guards, the
  /// level it demands, and the level this credential holds on it (from
  /// `HeadlessAuthPolicy.scopeDenialBody`). Nothing here guesses at a level the
  /// server did not state: an answer carrying no `tokenLevel` gets a sentence
  /// that omits it rather than one that assumes `none`.
  function describeScopeRefusal(e, what) {
    const d = (e && e.detail) || {};
    const resource = d.resource || 'this feature';
    const held = d.tokenLevel === 'none'
      ? 'This browser’s credential has no access to ' + resource + '.'
      : d.tokenLevel
        ? 'This browser’s credential has ' + d.tokenLevel + ' access to ' +
          resource + '.'
        : '';
    return what + ' needs ' + (d.requiredLevel || 'more') + ' access to ' +
      resource + '. ' + (held ? held + ' ' : '') +
      'Pair this browser again asking for ' + resource + ':' +
      (d.requiredLevel || 'control') + ' to use it.';
  }

  function describeConnectFailure(e) {
    const status = e && e.status;
    // A scope refusal and a rejected credential are different events with
    // different fixes, and collapsing them into one "rejected" sentence sent
    // an operator holding a perfectly valid read-only token to the Remote
    // Access screen to check a token that was never the problem. Re-pairing
    // with the same spec reproduces a scope refusal exactly; only asking for
    // more scope clears it, so the copy has to say which one happened.
    if (e && e.kind === 'scope_denied') {
      return {
        kind: 'insufficient_scope',
        message: 'This browser is signed in, and the dashboard needs more ' +
          'than it holds. ' + describeScopeRefusal(e, 'The dashboard'),
      };
    }
    if (status === 401) {
      return {
        kind: 'rejected',
        message: 'The desktop did not accept this credential. Check the token ' +
          'against the desktop’s Remote Access screen, or pair this browser ' +
          'instead.',
      };
    }
    if (status === 403) {
      // A 403 that named no capability is the middleware's unknown-bearer
      // answer, which is a credential problem after all.
      return {
        kind: 'rejected',
        message: 'The desktop rejected this token. Check it against the ' +
          'desktop’s Remote Access screen, or pair this browser instead.',
      };
    }
    if (e && (e.kind === 'unreachable' || e.kind === 'timeout')) {
      return {
        kind: 'unreachable',
        message: 'No answer from the Skotiq server. Check that it is ' +
          'running and that this address is right.',
      };
    }
    if (e && e.kind === 'rate_limited') {
      return {
        kind: 'rate_limited',
        message: 'The server is rate-limiting this session — wait ' +
          (e.retryAfterSecs || 1) + 's and try again.',
      };
    }
    if (e && e.kind === 'unusable_answer') {
      return {
        kind: 'unusable_answer',
        message: 'The server answered without sending anything this page can ' +
          'read: ' + e.message,
      };
    }
    return {
      kind: 'failed',
      message: 'Could not sign in: ' + (e && e.message ? e.message : 'unknown'),
    };
  }

  /**
   * Run the initial REST handshake with bounded exponential backoff.
   * Three attempts at 250 ms, 1 s, 4 s. WebSocket has its own reconnect logic
   * and is not retried here.
   *
   * Returns `{ok: true}` once an AUTHENTICATED request has succeeded, and
   * `{ok: false, kind, message}` otherwise. The outcome is load-bearing: the
   * sign-in overlay used to dismiss itself before this function had run, so a
   * rejected bearer left an operator on a permanently "Disconnected" dashboard
   * with `#login-status` frozen at "Signing in..." and the only account of the
   * failure in a toast that expired after three seconds.
   */
  async function handleConnect() {
    const url = normalizeServerUrl(document.getElementById('server-url').value);
    const token = document.getElementById('auth-token').value.trim();
    const rememberToken = document.getElementById('remember-token').checked;
    const deviceId = localStorage.getItem('skotiq_device_id') || generateDeviceId();

    if (!url) {
      const message = 'Enter a valid http:// or https:// server URL';
      showToast(message, 'error');
      return { ok: false, kind: 'bad_url', message };
    }
    if (!isSameOriginServerUrl(url)) {
      setConnectionStatus('disconnected');
      updateConnectProgress(0, 0);
      showToast(crossOriginServerMessage(url), 'error');
      addLogEntry('error', crossOriginServerMessage(url));
      return {
        ok: false, kind: 'cross_origin', message: crossOriginServerMessage(url),
      };
    }

    document.getElementById('server-url').value = url;

    // Persist connection preferences; the bearer goes to sessionStorage
    // only — long-form persistence is the HttpOnly cookie path below.
    // Production mode (no debug flag) refuses to remember anything that
    // would override the same-origin URL.
    if (state.debugMode) {
      localStorage.setItem('skotiq_url', url);
    } else {
      localStorage.removeItem('skotiq_url');
    }
    localStorage.setItem('skotiq_device_id', deviceId);
    writeStoredToken(token, rememberToken);

    api.configure(url, token, deviceId);
    api.setConnectionState(false);
    // A different credential may hold more than the last one did, so the
    // refusals recorded against the old one must not keep its controls
    // disabled.
    clearControlRefusals();

    // If a session cookie is still alive from a previous visit, asking the
    // server for the CSRF token is what tells JS "you
    // are already authenticated, no bearer needed." We do this BEFORE the
    // /api/status round-trip below so the same fetch can ride the cookie.
    // Only meaningful when no bearer was pasted (a fresh paste of a
    // token means the user explicitly wants the bearer path right now).
    if (!token) {
      try {
        const resumed = await api.tryResumeCookieSession();
        if (resumed) {
          addLogEntry('system', 'Resumed previous remembered session via HttpOnly cookie.');
        }
      } catch (_) {
        // tryResumeCookieSession swallows known no-session errors; any
        // unexpected exception is logged through the normal connect path
        // below when the first authenticated request fails.
      }
    }

    stopPolling();
    api.disconnectWebSocket();
    api.removeAllListeners();
    setConnectionStatus('connecting');

    // 3-attempt exponential backoff. Pre-attempt sleeps: 250 ms, 1 s, 4 s.
    // The total delay budget is ~5 s, which matches the
    // user's mental model of "give it a moment" without making a healthy
    // server feel slow.
    const delays = [250, 1000, 4000];
    let lastError = null;
    for (let attempt = 0; attempt < delays.length; attempt++) {
      await sleep(delays[attempt]);
      state.connectRetryCount = attempt;
      updateConnectProgress(attempt + 1, delays.length);
      try {
        const info = await api.testConnection();
        state.serverInfo = info;

        // Show the pairing/token bar only when the server wants auth AND we
        // do not already hold a credential. Before this, `authRequired` alone
        // kept the full Device/Pair/Token/Apply bar permanently expanded on
        // every paired browser — ~40% of a phone viewport spent on controls
        // the operator needed exactly once.
        setAuthBarVisible(
          info.authRequired && !token && !api.hasSessionCookie,
        );

        // A cookie session counts as authentication: tryResumeCookieSession
        // above may have populated api.hasSessionCookie even with no
        // typed-in bearer.
        if (info.authRequired && !token && !api.hasSessionCookie) {
          setConnectionStatus('disconnected');
          updateConnectProgress(0, 0);
          const message = info.pairingSupported
            ? 'Click Pair to set up this browser, or paste a bearer token and click Apply.'
            : 'Server requires a bearer token. Paste one and click Apply.';
          showToast(message, 'error');
          return { ok: false, kind: 'needs_credential', message };
        }

        // The first authenticated request is the real connection gate.
        // /api/info is public and only confirms reachability.
        await api.getStatus();
        setConnectionStatus('connected');
        updateConnectProgress(0, 0);
        api.setConnectionState(true);
        // Authenticated and connected — collapse the pairing bar down to the
        // compact "Auth" chip so panel content gets the viewport back.
        setAuthBarVisible(false);

        // If the user wants to be remembered AND we have a bearer in hand
        // AND we are not already on the cookie path, exchange
        // the bearer for an HttpOnly cookie so the next page load doesn't
        // need the bearer at all. Why after /api/status: we only commit to
        // a cookie once we've verified the bearer actually works against the
        // server's auth middleware.
        if (rememberToken && token && !api.hasSessionCookie) {
          try {
            await api.beginCookieSession();
            // Scrub the visible token input so a casual screen-share or
            // browser-back doesn't expose it after upgrade.
            document.getElementById('auth-token').value = '';
            sessionStorage.removeItem('skotiq_token');
            addLogEntry('system', 'Upgraded session to HttpOnly cookie (remember-me).');
          } catch (e) {
            // Surface the failure: falling back to the bearer path silently
            // would let the user think they were "remembered" when the next
            // page load will ask for the token again.
            addLogEntry('error', 'Cookie upgrade failed: ' + (e && e.message ? e.message : String(e)));
            showToast('Remember-me upgrade failed: ' + (e && e.message ? e.message : 'unknown'), 'error');
          }
        }

        addLogEntry('system', 'Connected to ' + info.name + ' v' + info.version);

        // Wire up event listeners *before* opening the socket so we never
        // miss the open/error/event signals fired during connect.
        setupEventListeners();
        // connectWebSocket is async (it requests a single-use ticket first).
        api.connectWebSocket().catch((err) => {
          addLogEntry('error', 'WebSocket connect failed: ' + err.message);
        });

        await fetchAllStatus();
        startPolling();
        return { ok: true };
      } catch (e) {
        lastError = e;
        // Why log every attempt: opaque "Connection failed" with no retry trail
        // made transient flaps look like permanent failures.
        addLogEntry('error',
          'Connect attempt ' + (attempt + 1) + '/' + delays.length + ': ' + e.message);
        // A credential the server has refused will be refused again by the two
        // remaining attempts, and each retry re-prints the same refusal into
        // the operator's log. Stop and report it.
        if (e && (e.status === 401 || e.status === 403)) break;
      }
    }

    setConnectionStatus('disconnected');
    updateConnectProgress(0, 0);
    api.setConnectionState(false);
    const failure = describeConnectFailure(lastError);
    showToast(failure.message, 'error');
    return { ok: false, kind: failure.kind, message: failure.message };
  }

  function updateConnectProgress(attempt, total) {
    const el = document.getElementById('connect-progress');
    if (!el) return;
    if (attempt > 0 && total > 0) {
      el.textContent = '(attempt ' + attempt + '/' + total + ')';
    } else {
      el.textContent = '';
    }
  }

  // =========================================================================
  // Pairing
  // =========================================================================

  function openPairModal() {
    const url = normalizeServerUrl(document.getElementById('server-url').value);
    if (!url) {
      showToast('Enter a valid server URL first', 'error');
      return;
    }
    document.getElementById('server-url').value = url;
    const modal = document.getElementById('pair-modal');
    modal.removeAttribute('hidden');
    modal.classList.add('visible');
    setPairModalStatus('Requesting a pairing code...', '');

    // Configure API for unauthenticated calls during the pairing handshake.
    const deviceId = localStorage.getItem('skotiq_device_id') || generateDeviceId();
    api.configure(url, '', deviceId);

    // Kick off pairing/start on open so the operator immediately sees a code
    // on the desktop console.
    api.pairingStart()
      .then((result) => {
        const exp = wireNumber(result && result.expiresInSeconds);
        setPairModalStatus(
          'Code printed to the Skotiq desktop console.' + (exp != null
            ? ' Expires in ~' + Math.max(1, Math.round(exp / 60)) + ' min.'
            : ' Expiry not reported.'),
          'success',
        );
      })
      .catch((e) => {
        setPairModalStatus('Failed to start pairing: ' + e.message, 'error');
      });

    const codeInput = document.getElementById('pair-modal-code');
    codeInput.value = '';
    setTimeout(() => codeInput.focus(), 50);
  }

  function closePairModal() {
    const modal = document.getElementById('pair-modal');
    modal.classList.remove('visible');
    modal.setAttribute('hidden', '');
    setPairModalStatus('', '');
  }

  function setPairModalStatus(message, type) {
    const el = document.getElementById('pair-modal-status');
    if (!el) return;
    el.textContent = message;
    el.className = 'modal-status' + (type ? ' ' + type : '');
  }

  async function handlePairSubmit() {
    const url = normalizeServerUrl(document.getElementById('server-url').value);
    const code = document.getElementById('pair-modal-code').value.trim();
    const deviceName = document.getElementById('device-name').value.trim() || defaultDeviceName();
    const deviceId = localStorage.getItem('skotiq_device_id') || generateDeviceId();

    if (!url) {
      setPairModalStatus('Server URL is empty.', 'error');
      return;
    }
    if (!/^[A-Za-z0-9-]{6,32}$/.test(code)) {
      setPairModalStatus('Enter the pairing code shown on the desktop console.', 'error');
      return;
    }

    localStorage.setItem('skotiq_device_id', deviceId);
    localStorage.setItem('skotiq_device_name', deviceName);
    api.configure(url, '', deviceId);

    setPairModalStatus('Verifying...', '');
    try {
      const result = await api.pairWithCode(code, deviceName, deviceId);
      const token = result && result.token ? String(result.token) : '';
      if (!token) {
        throw new Error('Pairing completed without a token');
      }
      document.getElementById('auth-token').value = token;
      writeStoredToken(token, document.getElementById('remember-token').checked);
      setPairModalStatus('Paired. Connecting...', 'success');
      closePairModal();
      showToast('Pairing complete', 'success');
      // "Pairing complete" is about the code, not about the session. If the
      // connect that follows is refused, the sign-in form comes back saying
      // so rather than leaving a success toast over a dead dashboard.
      const outcome = await handleConnect();
      if (isCredentialFailure(outcome)) reportLoginFailure(outcome);
    } catch (e) {
      // Map the server's error codes to actionable text.
      let msg = e.message || 'Pairing failed';
      if (msg.includes('invalid_pairing_code')) {
        msg = 'Pairing code is not recognised. Check the code on the desktop console.';
      } else if (msg.includes('pairing_code_expired')) {
        msg = 'Pairing code expired. Click Pair again to request a new one.';
      } else if (msg.includes('pairing_code_already_used')) {
        msg = 'That code has already been claimed. Click Pair to start over.';
      } else if (e.kind === 'rate_limited' || msg.includes('429') ||
                 msg.includes('temporarily locked')) {
        msg = 'Too many failed attempts. Wait a moment before trying again.';
      }
      setPairModalStatus(msg, 'error');
      addLogEntry('error', describeApiError(e, 'Pairing'));
    }
  }

  function generateDeviceId() {
    if (window.crypto && typeof window.crypto.randomUUID === 'function') {
      return window.crypto.randomUUID();
    }
    // Why Math.random fallback is acceptable here: the device ID is a non-
    // secret correlation handle (used to match pairing requests with the
    // resulting token row), not a credential or signing key. Old browsers
    // without crypto.randomUUID still get a probabilistically unique value.
    return 'browser-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
  }

  function readStoredToken() {
    // sessionStorage only. The "remember" path never stashes the bearer in
    // JS-readable storage; it lives in an HttpOnly cookie on the server side
    // and is never legible to JS.
    return sessionStorage.getItem('skotiq_token') || '';
  }

  function writeStoredToken(token, rememberToken) {
    // Remember the user's UI choice only. The actual "stay logged in
    // across tabs/restart" semantics now come from the HttpOnly cookie
    // set by POST /api/auth/cookie — see beginCookieSession() in api.js.
    localStorage.setItem('skotiq_remember_token', rememberToken ? 'true' : 'false');
    if (token) {
      sessionStorage.setItem('skotiq_token', token);
    } else {
      sessionStorage.removeItem('skotiq_token');
    }
    // Guard against any older code path that may have left a bearer in
    // localStorage. Clearing on every write makes the migration idempotent.
    localStorage.removeItem('skotiq_token');
  }

  function handleRememberTokenChanged() {
    const token = document.getElementById('auth-token').value.trim();
    const rememberToken = document.getElementById('remember-token').checked;
    writeStoredToken(token, rememberToken);
    // If the user just unticked Remember while a cookie session is live,
    // immediately revoke it so we don't keep an HttpOnly cookie around
    // that contradicts their stated preference. The fire-and-forget
    // promise is fine — failures only mean the cookie persists until its
    // natural expiry, which is no worse than the prior session.
    if (!rememberToken && api.hasSessionCookie) {
      api.endCookieSession().catch(() => {});
    }
  }

  function defaultDeviceName() {
    const host = window.location.hostname || 'browser';
    return 'Browser on ' + host;
  }

  function defaultServerUrl() {
    if (window.location.protocol === 'http:' || window.location.protocol === 'https:') {
      return window.location.origin;
    }
    return 'http://127.0.0.1:8080';
  }

  function normalizeServerUrl(value) {
    const raw = String(value || '').trim();
    if (!raw) return '';
    try {
      const url = new URL(raw);
      if (url.protocol !== 'http:' && url.protocol !== 'https:') return '';
      if (!url.hostname) return '';
      url.pathname = url.pathname.replace(/\/+$/, '');
      url.search = '';
      url.hash = '';
      return url.toString().replace(/\/$/, '');
    } catch (_) {
      return '';
    }
  }

  // This page's CSP is `connect-src 'self' ws: wss:` — deliberately narrow: a
  // wildcard would let a page served from the dashboard origin relay
  // credentials to any host on the network. The consequence is that the
  // dashboard can only ever reach the origin that served it, so a Server URL
  // pointing anywhere else is unreachable by construction. Detect that here:
  // otherwise the fetch dies inside the 3-attempt backoff and the operator
  // gets ~6s of silence followed by a 4s "Connection failed: Failed to fetch"
  // toast that names neither the cause nor the remedy.
  function isSameOriginServerUrl(url) {
    try {
      return new URL(url, window.location.href).origin === window.location.origin;
    } catch (_) {
      return false;
    }
  }

  function crossOriginServerMessage(url) {
    return 'This dashboard can only talk to the server that served it (' +
      window.location.origin + '). Open ' + url + '/dashboard directly to ' +
      'control that server.';
  }

  function setConnectionStatus(status) {
    const dot = document.getElementById('status-dot');
    const text = document.getElementById('status-text');
    dot.className = 'status-dot';
    if (status === 'connected') {
      dot.classList.add('connected');
      text.textContent = 'Connected';
    } else if (status === 'connecting') {
      dot.classList.add('connecting');
      text.textContent = 'Connecting...';
    } else {
      text.textContent = 'Disconnected';
    }
    refreshPanelEnablement();
  }

  /**
   * Per-panel enable based on the connected-devices payload. Buttons
   * inside a panel are only clickable when (a) the dashboard is connected to
   * the server *and* (b) a device of the panel's type is connected.
   *
   * The clear-log button is exempt because it operates on local state.
   */
  function refreshPanelEnablement() {
    const connected = api.isConnected;
    for (const [panelId, deviceType] of Object.entries(PANEL_DEVICE_TYPES)) {
      const panel = document.getElementById(panelId);
      if (!panel) continue;
      const hasDevice = connected && state.connectedDevices.some(
        (d) => d.deviceType === deviceType,
      );
      setPanelEnabled(panel, deviceType, hasDevice);
    }

    // Sequencer/guiding/devices panels: enable iff connected. They don't
    // require a specific device of their own.
    // Same treatment for the ops panels that don't bind to a specific device
    // type (everything except the dome panel).
    const connectOnlyPanels = [
      'panel-sequencer', 'panel-guiding',
      'ops-seq-load-panel', 'ops-target-panel', 'ops-weather-panel',
      'ops-checkpoint-panel', 'ops-profile-panel',
    ];
    for (const id of connectOnlyPanels) {
      const panel = document.getElementById(id);
      if (panel) setPanelEnabled(panel, null, connected);
    }

    // Top-level connect button is always usable.
    document.getElementById('btn-connect').disabled = false;
    document.getElementById('btn-clear-log').disabled = false;
    document.getElementById('btn-pair').disabled = false;
    document.getElementById('btn-apply-token').disabled = false;
  }

  function setPanelEnabled(panelEl, deviceType, enabled) {
    if (!panelEl) return;
    panelEl.setAttribute('aria-disabled', enabled ? 'false' : 'true');
    const tooltip = enabled ? '' : (deviceType
      ? humanDeviceType(deviceType) + ' not connected'
      : 'Connect to the server first');
    const buttons = panelEl.querySelectorAll('button');
    for (const btn of buttons) {
      // The d-pad emergency Stop stays usable whenever connected, even if
      // no mount is currently reported. Better a no-op than a runaway slew
      // that can't be cancelled.
      if (btn.id === 'btn-mount-stop') {
        btn.disabled = !api.isConnected;
        continue;
      }
      // The collapse caret is a pure layout affordance, not a device command.
      // Gating it on the device meant an operator who owns no focuser /
      // rotator / dome could never fold those panels away — exactly the
      // panels they most want gone from a dashboard this dense.
      if (btn.classList.contains('panel-collapse-btn')) continue;
      btn.disabled = !enabled;
      if (tooltip) btn.title = tooltip; else btn.removeAttribute('title');
    }
    const inputs = panelEl.querySelectorAll('input, select');
    for (const input of inputs) {
      input.disabled = !enabled;
    }
  }

  function humanDeviceType(t) {
    switch (t) {
      case 'camera': return 'Camera';
      case 'mount': return 'Mount';
      case 'focuser': return 'Focuser';
      case 'filterWheel': return 'Filter wheel';
      // Keep tooltip wording in sync with the panel title.
      case 'dome': return 'Dome';
      default: return t;
    }
  }

  // =========================================================================
  // Theme toggle (light/dark, localStorage)
  // =========================================================================

  // Persist key + the two header <meta theme-color> values so the browser
  // chrome (notch / address bar) matches the active theme.
  const THEME_STORAGE_KEY = 'skotiq_theme';
  const THEME_META_COLOR = { dark: '#0A0C0F', light: '#F4F6F8' };

  function resolveInitialTheme() {
    const stored = localStorage.getItem(THEME_STORAGE_KEY);
    if (stored === 'light' || stored === 'dark') return stored;
    // First load with no stored choice: honour the OS preference, defaulting
    // to dark (the dashboard's native palette) when the query is unsupported.
    if (window.matchMedia &&
        window.matchMedia('(prefers-color-scheme: light)').matches) {
      return 'light';
    }
    return 'dark';
  }

  function applyTheme(theme) {
    const isLight = theme === 'light';
    // Dark is the default :root palette, so we only set the attribute for
    // light — keeps the DOM clean and the default fast-path untouched.
    if (isLight) {
      document.documentElement.setAttribute('data-theme', 'light');
    } else {
      document.documentElement.removeAttribute('data-theme');
    }
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', THEME_META_COLOR[isLight ? 'light' : 'dark']);

    const btn = document.getElementById('btn-theme-toggle');
    if (btn) {
      // Glyph shows the *current* theme; the label/aria announce the action.
      const glyph = btn.querySelector('.theme-toggle-glyph');
      if (glyph) glyph.innerHTML = isLight ? '&#9728;' : '&#9788;'; // ☀ / ☾
      btn.setAttribute('aria-pressed', isLight ? 'true' : 'false');
      btn.setAttribute('aria-label',
        isLight ? 'Switch to dark theme' : 'Switch to light theme');
    }
  }

  function setupTheme() {
    let theme = resolveInitialTheme();
    applyTheme(theme);
    const btn = document.getElementById('btn-theme-toggle');
    if (btn) {
      btn.addEventListener('click', () => {
        theme = theme === 'light' ? 'dark' : 'light';
        localStorage.setItem(THEME_STORAGE_KEY, theme);
        applyTheme(theme);
        // Canvas/SVG widgets (guide graph, planetarium) read CSS vars at draw
        // time via themeColor(); repaint so they pick up the new palette.
        repaintThemedCanvases();
      });
    }
  }

  // Repaint the few canvas surfaces that cache CSS-variable colours so a theme
  // flip is reflected without waiting for the next data tick.
  function repaintThemedCanvases() {
    try { if (typeof drawGuideGraph === 'function') drawGuideGraph(); } catch (_) {}
  }

  // =========================================================================
  // Persisted panel prefs (collapse state)
  // =========================================================================

  // Persist which panels the operator collapsed so an overnight layout survives
  // a reload. Stored as a JSON array of panel ids under this key. We persist the
  // *collapsed* set (typically small) rather than the full layout because the
  // panel order is fixed in markup; "which panels are open/closed" is the
  // load-bearing pref for an 8-hour tool.
  const PANEL_PREFS_KEY = 'skotiq_panel_collapsed';

  function loadCollapsedPanels() {
    try {
      const raw = localStorage.getItem(PANEL_PREFS_KEY);
      if (!raw) return new Set();
      const parsed = JSON.parse(raw);
      return new Set(Array.isArray(parsed) ? parsed.filter((x) => typeof x === 'string') : []);
    } catch (_) {
      // Corrupt value — drop it rather than wedging init.
      return new Set();
    }
  }

  function saveCollapsedPanels(set) {
    try {
      localStorage.setItem(PANEL_PREFS_KEY, JSON.stringify(Array.from(set)));
    } catch (_) {
      // localStorage can throw (private mode / quota); collapse still works
      // for the session, it just won't persist.
    }
  }

  function setupPanelPrefs() {
    const collapsed = loadCollapsedPanels();

    for (const panel of document.querySelectorAll('.panel')) {
      const header = panel.querySelector('.panel-header');
      if (!header) continue;

      const title = (panel.querySelector('.panel-title') || {}).textContent || panel.id;
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'panel-collapse-btn';
      btn.innerHTML = '&#9662;'; // ▾ — CSS rotates it to ▸ when collapsed.
      btn.setAttribute('aria-label', 'Collapse ' + title.trim() + ' panel');
      btn.setAttribute('aria-expanded', 'true');
      // The caret is the right-most header affordance so it never crowds the
      // existing panel action buttons.
      header.appendChild(btn);

      const apply = (isCollapsed, persist) => {
        panel.classList.toggle('is-collapsed', isCollapsed);
        btn.setAttribute('aria-expanded', isCollapsed ? 'false' : 'true');
        if (isCollapsed) collapsed.add(panel.id); else collapsed.delete(panel.id);
        if (persist) saveCollapsedPanels(collapsed);
      };

      // Restore persisted state (no re-persist — nothing changed yet).
      if (collapsed.has(panel.id)) apply(true, false);

      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        apply(!panel.classList.contains('is-collapsed'), true);
      });
    }
  }

  function setupEventListeners() {
    api.on('ws:connected', () => {
      state.lastWsMessageAt = Date.now();
      addLogEntry('system', 'WebSocket connected');
      // The sequence list is fetched once per connect rather than on every
      // status poll: it changes infrequently, and refetching it on every WS
      // heartbeat would hammer the DB for nothing.
      fetchOpsSequences();
    });

    api.on('ws:disconnected', () => {
      addLogEntry('system', 'WebSocket disconnected, reconnecting...');
      // A closed socket is the first hint the server may be gone. Probe now
      // rather than waiting for the next 2 s watchdog tick to notice.
      probeServerReachable();
    });

    api.on('ws:activity', () => {
      state.lastWsMessageAt = Date.now();
    });

    api.on('event', (data) => {
      state.lastWsMessageAt = Date.now();
      handleServerEvent(data);
    });
  }

  // =========================================================================
  // Polling — WebSocket-driven by default, REST fallback only when stale.
  // There is deliberately no unconditional poll loop.
  // =========================================================================

  function startPolling() {
    stopPolling();

    // Initial refresh so panels populate immediately on connect — WS events
    // arrive only when something changes.
    fetchAllStatus();

    state.pingInterval = setInterval(() => api.sendPing(), SERVER_HEARTBEAT_MS);

    // Why a slow watchdog instead of a 3 s poll: WS pushes carry the panel
    // state. We only re-fetch when the socket has been silent for
    // WS_FALLBACK_THRESHOLD_MS — i.e., the socket is dead or the server
    // dropped events. The watchdog also drives the stale-data indicator.
    state.staleCheckInterval = setInterval(checkStaleness, 2000);
  }

  function stopPolling() {
    if (state.pollInterval) {
      clearInterval(state.pollInterval);
      state.pollInterval = null;
    }
    if (state.pingInterval) {
      clearInterval(state.pingInterval);
      state.pingInterval = null;
    }
    if (state.wsFallbackPollInterval) {
      clearInterval(state.wsFallbackPollInterval);
      state.wsFallbackPollInterval = null;
    }
    if (state.staleCheckInterval) {
      clearInterval(state.staleCheckInterval);
      state.staleCheckInterval = null;
    }
    cancelSequencerRefresh();
  }

  // =========================================================================
  // Link health
  //
  // `api.isConnected` is set once at connect and never cleared, so a dead
  // backend left the header on a green "Connected" and the sequencer badge on
  // "running" indefinitely — measured at 65 s after SIGKILL with no change.
  // The block below is the dashboard's answer to "is what I am looking at
  // real": one reachability probe, one banner, one status flip.
  // =========================================================================

  // Cadence of the reachability probe. Well inside the read budget (60/s) and
  // cheap: /api/info is a static answer.
  const REACHABILITY_PROBE_MS = 5000;
  // The dashboard's own proof-of-life clock. An idle server pushes no events,
  // so on a quiet night the ping/pong below is the ONLY thing that stamps
  // contact — every staleness decision is counted in beats of this clock, not
  // in wall-clock seconds picked independently of it.
  const SERVER_HEARTBEAT_MS = 30000;
  // One missed beat is a question, not a verdict: the watchdog answers it by
  // probing the server directly (see checkStaleness).
  const HEARTBEAT_GRACE_MS = SERVER_HEARTBEAT_MS + REACHABILITY_PROBE_MS;
  // Two missed beats with nothing to show for them is the verdict. Below one
  // full beat the dashboard cannot tell "quiet" from "gone": at 12000 ms a
  // measured 200 s soak against a healthy, idle server spent 26 of 40 samples
  // on "No contact" while every request in flight was being answered.
  const MISSED_HEARTBEATS_BEFORE_STALE = 2;
  const SERVER_CONTACT_STALE_MS =
    SERVER_HEARTBEAT_MS * MISSED_HEARTBEATS_BEFORE_STALE + REACHABILITY_PROBE_MS;

  let lastReachabilityProbeAt = 0;
  let reachabilityProbeInFlight = false;

  /// Ask the server whether it is there. Records the outcome on `state` and
  /// repaints; never throws.
  async function probeServerReachable() {
    if (reachabilityProbeInFlight) return;
    if (!api.baseUrl) return;
    reachabilityProbeInFlight = true;
    lastReachabilityProbeAt = Date.now();
    try {
      await api.getInfo();
      state.serverUnreachable = false;
    } catch (e) {
      // Only a transport failure proves absence. A 401/500/429 is the server
      // answering, which means it is alive and something else is wrong.
      state.serverUnreachable = Boolean(
        e && (e.kind === 'unreachable' || e.kind === 'timeout'),
      );
    } finally {
      reachabilityProbeInFlight = false;
      repaintDataState();
    }
  }

  /// Most recent proof the server exists: any completed HTTP exchange (the API
  /// client stamps every one, whatever the status) or any WebSocket frame.
  function lastServerContactAt() {
    return Math.max(api.lastContactAt || 0, state.lastWsMessageAt || 0);
  }

  /// True when the dashboard cannot vouch for what it is showing.
  function isServerContactStale(now) {
    const last = lastServerContactAt();
    // A probe that failed with nothing succeeding since it started is
    // decisive — no need to wait out the staleness window.
    if (state.serverUnreachable && last <= lastReachabilityProbeAt) return true;
    if (last === 0) return false;
    return now - last > SERVER_CONTACT_STALE_MS;
  }

  /// True when one panel's own data can no longer be vouched for, on exactly
  /// the shape of rule the header uses: the last attempt to refresh it failed
  /// and nothing has succeeded since. That is decisive, so it needs no window —
  /// and it is silent on the quiet-but-healthy night, where nothing has changed
  /// and nothing has failed.
  ///
  /// The panel that has never been asked for is not stale; it has no data to be
  /// stale, and the renderer says so in its own words.
  function isPanelDataStale(panelKey) {
    const failedAt = state.panelLastFailure[panelKey] || 0;
    return failedAt > (state.panelLastUpdate[panelKey] || 0);
  }

  function formatAgeSeconds(ms) {
    const s = Math.round(ms / 1000);
    if (s < 60) return s + 's';
    const m = Math.floor(s / 60);
    if (m < 60) return m + 'm ' + (s % 60) + 's';
    return Math.floor(m / 60) + 'h ' + (m % 60) + 'm';
  }

  // =========================================================================
  // The page's data clock
  //
  // Everything that ages data reads it here, on one tick, from one `now`.
  //
  // Before this there were two clocks and they disagreed. The header counted
  // from the last completed exchange with the server; each panel counted from
  // its own last successful refresh, behind a `wsHealthy` gate that hid the
  // count entirely whenever the event socket was alive. So a single failing
  // route — /api/sequencer/status answering 500 while the daemon stayed up and
  // the socket stayed busy — left the Run panel painting a frozen run as live:
  // measured at "running / Exposure L / 3% / Frame 2 of 20" under a green
  // "Connected" header for 45 s while the rig was at 13.75% and frame 11, with
  // no banner and the stale badge that would have said so suppressed.
  //
  // One clock, one verdict, and the panels subscribe to it.
  // =========================================================================

  const dataClockSubscribers = [];

  /// Register a renderer that must repaint whenever the page re-judges how old
  /// its data is. Called once each, at init.
  function subscribeToDataClock(render) {
    dataClockSubscribers.push(render);
  }

  /// Sample the clock once and hand the same verdict to every subscriber.
  function repaintDataState() {
    const now = Date.now();
    const contactAt = lastServerContactAt();
    const view = {
      now,
      contactStale: isServerContactStale(now),
      contactAgeMs: contactAt > 0 ? now - contactAt : null,
      /// How old this panel's data is, or null when none has ever arrived.
      panelAgeMs(panelKey) {
        const at = state.panelLastUpdate[panelKey] || 0;
        return at > 0 ? now - at : null;
      },
      /// A panel is stale when the link is gone — nothing is arriving for
      /// anything — or when its own route is failing while the server answers
      /// everything else.
      panelStale(panelKey) {
        return this.contactStale || isPanelDataStale(panelKey);
      },
    };
    for (const render of dataClockSubscribers) render(view);
  }

  /// Repaint the banner + header status from the current link state. The
  /// header must never read "Connected" while the view says stale.
  function renderLinkState(view) {
    const banner = document.getElementById('link-banner');
    const text = document.getElementById('status-text');
    const dot = document.getElementById('status-dot');
    const waiting = api.rateLimitRemainingSecs;
    const stale = view.contactStale;

    if (!stale) {
      if (banner) {
        if (waiting > 0) {
          banner.classList.remove('hidden');
          banner.textContent =
            'Server is rate-limiting this session — polling paused for ' +
            waiting + 's.';
        } else {
          banner.classList.add('hidden');
          banner.textContent = '';
        }
      }
      // Restore the header only if the connect path still believes it holds a
      // session; setConnectionStatus owns the connected/connecting wording.
      if (api.isConnected && text && text.textContent === 'No contact') {
        setConnectionStatus('connected');
      }
      return;
    }

    const age = view.contactAgeMs;
    if (text) text.textContent = 'No contact';
    if (dot) dot.className = 'status-dot error';
    if (banner) {
      banner.classList.remove('hidden');
      banner.textContent =
        (state.serverUnreachable
          ? 'Cannot reach the Skotiq server.'
          : 'No answer from the Skotiq server.') +
        (age == null
          ? ' Nothing has been received yet.'
          : ' Last contact ' + formatAgeSeconds(age) +
            ' ago. Every value below is from then and may be wrong.');
    }
  }

  /// True while the Run panel is painted with the unknown overlay, so the
  /// recovery edge can be told from a run of healthy ticks. Staleness is a
  /// state of the data, not a mark burned into the badge: without this the
  /// badge that went "unknown" on one missed exchange stayed "unknown" for the
  /// rest of the session, over every subsequent healthy poll.
  let runUnknownAsserted = false;

  /// Whether the Run panel and its ops mirror may go on asserting what the
  /// last sequencer status said. The clock's own rule, callable between ticks
  /// — the two renderers below fire on their own events, and a repaint from
  /// the cached status is how a cleared panel came straight back.
  function runDataIsStale() {
    return isServerContactStale(Date.now()) || isPanelDataStale('sequencer');
  }

  /// Stop asserting the run, on every surface that quotes it.
  ///
  /// The Run panel and the Sequences panel read the same `state.sequencerStatus`
  /// and render different field sets from it, so they have to fall silent
  /// together: clearing only the Run panel left "Current node: Autofocus (HFR
  /// Degradation) / Progress 5%" sitting in the Sequences panel two columns
  /// away, repainted from the cache by whichever sibling fetch answered next.
  function paintRunUnknown() {
    // The sequencer badge is the single most misleading survivor of a dead
    // backend: a green "running" for a rig that may have been off for an hour.
    const seqStatus = document.getElementById('seq-status');
    if (seqStatus) renderBadge(seqStatus, 'unknown', 'badge-error');
    // The percentage is the same assertion in another shape, and it outlived
    // the badge: measured after a SIGKILL at wire progress 0.250, the badge
    // went "unknown" and the banner said every value might be wrong while
    // "25%" stayed on screen, the bar stayed 94.75px wide and the bar's
    // aria-valuenow kept announcing 25 for the next 47 s. A figure whose
    // source is gone is not a smaller truth than a state whose source is gone.
    markProgressUnknown(
      'seq-progress-bar', 'seq-progress-bar-container', 'seq-progress-text');
    markProgressUnknown(
      'ops-seq-progress-bar', 'ops-seq-progress-bar-container',
      'ops-seq-progress-text');
    // The ETA is extrapolated from that same percentage, so it cannot outlive
    // it: "finishes in 12m" computed from a rig nobody can reach is the
    // furthest-reaching claim on the page.
    const opsSeqEta = document.getElementById('ops-seq-eta');
    if (opsSeqEta) opsSeqEta.textContent = '--';
    // The node, the target and the message are the last claims about a run
    // whose source has stopped answering; they read as live text with nothing
    // around them to say otherwise. `ops-seq-current-target` was the one this
    // list forgot: measured across a SIGTERM it went on naming the run for
    // 68 s beside a Run panel that had already gone to "--" and a banner
    // saying every value below might be wrong.
    for (const id of ['seq-node', 'ops-seq-current-node',
      'ops-seq-current-target']) {
      const el = document.getElementById(id);
      if (el) el.textContent = '--';
    }
    const seqMessage = document.getElementById('seq-message');
    if (seqMessage) seqMessage.textContent = '';
  }

  /// The Run panel's own honesty. It subscribes to the same clock the header
  /// does, and it stops asserting for either reason the clock can give: the
  /// server is gone, or the server is there and THIS panel's route is failing.
  function renderRunDataState(view) {
    if (!view.panelStale('sequencer')) {
      if (runUnknownAsserted) {
        runUnknownAsserted = false;
        // Hand the panel back to the renderer that owns it, so it says what
        // the last data says — the real state if a status has arrived,
        // "connecting" if none ever has.
        renderSequencerPanel();
      }
      return;
    }
    runUnknownAsserted = true;
    paintRunUnknown();
  }

  function checkStaleness() {
    const now = Date.now();
    // How long the socket has been quiet, or null when it never opened at
    // all. Null rather than a sentinel: this value is interpolated into an
    // operator-visible log line below, and `Infinity` reached it verbatim as
    // "WebSocket silent for Infinitys". A socket with no first message has no
    // elapsed silence to report, so it gets words instead of arithmetic.
    const wsSilentMs = state.lastWsMessageAt > 0
      ? now - state.lastWsMessageAt
      : null;

    // Reachability: ask the server directly rather than inferring health from
    // a silence. Two ways to earn the question — the socket is down, or the
    // socket claims to be up but a whole heartbeat has passed with nothing on
    // it (a black-holed connection looks open to the browser). Either way the
    // answer, not the clock, is what decides the banner.
    const contactAge = now - lastServerContactAt();
    if (api.isConnected &&
        (!api.isWsConnected || contactAge > HEARTBEAT_GRACE_MS) &&
        now - lastReachabilityProbeAt > REACHABILITY_PROBE_MS) {
      probeServerReachable();
    }
    repaintDataState();

    // A panel whose route is failing is re-asked, on the same principle as the
    // reachability probe above: the page answers "is this still true" by
    // asking, not by waiting for something else to happen. Without this a
    // single refused refresh on an otherwise idle rig would leave that panel
    // reading "unknown" until the next event, which could be the whole night.
    if (api.isConnected && !isServerContactStale(now) &&
        now - lastPanelRefreshRetryAt > PANEL_REFRESH_RETRY_MS &&
        PANEL_KEYS.some(isPanelDataStale)) {
      lastPanelRefreshRetryAt = now;
      fetchAllStatus();
      // The sequence list is deliberately not part of fetchAllStatus — it is
      // fetched once per connect because it changes rarely. Without this the
      // Sequences panel would be the one panel whose stale line could never
      // clear itself.
      if (isPanelDataStale('sequences')) fetchOpsSequences();
    }

    // Fallback polling: when the socket never opened, or when it has been
    // silent past the threshold.
    if (api.isConnected &&
        (wsSilentMs === null || wsSilentMs > WS_FALLBACK_THRESHOLD_MS)) {
      if (!state.wsFallbackPollInterval) {
        addLogEntry('system', wsSilentMs === null
          ? 'WebSocket never connected — falling back to REST polling'
          : 'WebSocket silent for ' + Math.round(wsSilentMs / 1000) +
            's — falling back to REST polling');
        state.wsFallbackPollInterval = setInterval(fetchAllStatus, 5000);
        // Immediate one-shot so the user doesn't wait 5s for the next tick.
        fetchAllStatus();
      }
    } else if (state.wsFallbackPollInterval) {
      // WS came back. Drop the polling loop.
      clearInterval(state.wsFallbackPollInterval);
      state.wsFallbackPollInterval = null;
      addLogEntry('system', 'WebSocket recovered — REST fallback disabled');
    }

  }

  /// Paint one panel's stale line from the shared verdict.
  ///
  /// The `wsHealthy` early-return that used to live here is gone: it hid the
  /// line whenever the event socket was alive, which is exactly the state a
  /// single failing REST route leaves the page in.
  function renderStaleIndicator(panelKey, view) {
    const el = document.getElementById('stale-' + panelKey);
    if (!el) return;
    const ageMs = view.panelAgeMs(panelKey);
    const routeFailing = isPanelDataStale(panelKey);
    // A panel that never had data and never asked for any has nothing to
    // report: a disconnected focuser is not stale, it is absent, and the
    // panel's own body says so.
    const hasSomethingToReport = ageMs != null || routeFailing;
    if (!api.isConnected || !view.panelStale(panelKey) || !hasSomethingToReport) {
      el.classList.remove('visible');
      el.textContent = '';
      return;
    }
    el.classList.add('visible');
    el.textContent = ageMs == null
      ? 'No data has reached this panel yet'
      : 'Stale: ' + formatAgeSeconds(ageMs) + ' since last update';
  }

  function markPanelFresh(panelKey) {
    state.panelLastUpdate[panelKey] = Date.now();
  }

  /// This panel's data source refused. Recorded so the page can say the panel
  /// is stale while the server is plainly there answering everything else —
  /// the failure used to reach nothing but a log line.
  function markPanelUnconfirmed(panelKey) {
    state.panelLastFailure[panelKey] = Date.now();
  }

  /// True when a request never reached the rig's state at all because this
  /// session is over its request budget — the client declining to send inside
  /// a known retry window, or the server answering 429.
  function isCadenceRefusal(e) {
    return Boolean(e) && e.kind === 'rate_limited';
  }

  /// How a BACKGROUND refresh reports its own failure.
  ///
  /// A cadence refusal is not a failure of the panel's data source. The
  /// request never got as far as asking, so nothing the panel shows became
  /// wrong — it is exactly as old as its last successful read, and the next
  /// refresh in the cadence carries the update. Treating one as a panel
  /// failure was what blanked live panels to UNKNOWN mid-run and, through
  /// isPanelDataStale(), re-armed checkStaleness()'s failing-panel retry into
  /// a second fan-out against the same exhausted budget.
  ///
  /// It is not an operator-facing error either: 274 red ERROR lines in one
  /// 75 s run told the operator nothing they could act on and buried the
  /// events that could. The throttle itself is still stated — once, on the
  /// link banner ("Server is rate-limiting this session — polling paused for
  /// Ns."), repainted by the data clock for as long as it lasts — so this is
  /// a duplicate, dropped to the developer channel.
  ///
  /// A refusal on something the OPERATOR pressed is a different fact: that
  /// request was asked for and did not happen. Those paths keep their toast
  /// and their log line and do not come through here.
  function reportRefreshFailure(panelKey, e, what) {
    if (isCadenceRefusal(e)) {
      console.debug('[skotiq] ' + describeApiError(e, what));
      return;
    }
    if (panelKey) markPanelUnconfirmed(panelKey);
    addLogEntry('error', describeApiError(e, what));
  }

  // =========================================================================
  // Data fetching
  // =========================================================================

  /// One place that turns a REST failure into something an operator can act
  /// on. A rate-limit refusal is a cadence fact, not a stack trace, and its
  /// JSON body must never reach the log panel; an unreachable server is
  /// already stated by the link banner.
  function describeApiError(e, what) {
    if (e && e.kind === 'rate_limited') {
      return what + ' skipped: server is rate-limiting this session (retry in ' +
        (e.retryAfterSecs || 1) + 's)';
    }
    if (e && (e.kind === 'unreachable' || e.kind === 'timeout')) {
      return what + ' failed: no answer from the server';
    }
    // A refusal the server explained. Its own words, not its JSON: the log
    // panel used to carry the whole 403 body, which reads as a product fault
    // rather than as the scope decision it is.
    if (e && e.kind === 'scope_denied') {
      return what + ' refused: ' + describeScopeRefusal(e, what);
    }
    // The server answered and the answer carried nothing this page can read.
    // Named as its own outcome because it is not a dead server and not a
    // refusal the server explained — it is a success code over silence, and
    // the panel that asked is now showing a cache nobody has confirmed.
    if (e && e.kind === 'unusable_answer') {
      return what + ' failed: the server answered without sending the data — ' +
        e.message;
    }
    return what + ' failed: ' + (e && e.message ? e.message : String(e));
  }

  /// The list a wire answer names, or a typed refusal when it names none.
  ///
  /// A panel may only render a positive empty state — "No devices connected",
  /// "No captured images yet." — when the server SAID empty, which on this API
  /// means an answer carrying `field: []`. An answer with no such field said
  /// nothing about the inventory at all, and `payload.field || []` turned that
  /// silence into a stated fact: measured against the release bundle, a
  /// content-free 200 on /api/devices/connected described a rig with four
  /// connected devices as having none, with nothing anywhere on the page
  /// saying the read had failed.
  ///
  /// The refusal is the same `unusable_answer` the API client raises for an
  /// empty body, so every caller's existing catch — the stale line, the log
  /// entry, the failure text on the panel — is the surface it lands on.
  function requireWireList(payload, field, what) {
    const list = payload && typeof payload === 'object'
      ? payload[field] : undefined;
    if (Array.isArray(list)) return list;
    throw new SkotiqApiError(
      'unusable_answer',
      what + ': the answer carries no "' + field + '" list',
      { field },
    );
  }

  async function fetchAllStatus() {
    // Honour the server's own retry window instead of firing a dozen requests
    // into a bucket we know is empty: each would be refused, and each refusal
    // used to print the limiter's JSON body into the operator's log.
    if (api.rateLimitRemainingSecs > 0) {
      repaintDataState();
      return;
    }
    // Device IDs are prerequisites for every equipment-status request.
    // Running discovery in the same Promise.all caused a cold dashboard to
    // skip camera/mount/filter-wheel status whenever those tasks won the race
    // against fetchDevices(). With a healthy WebSocket there may then be no
    // event to trigger a later REST refresh, leaving gain/offset at zero and
    // the last-image panel blank indefinitely.
    await fetchDevices();
    await Promise.all([
      fetchSequencerStatus(),
      fetchGuidingStatus(),
      fetchMountStatusIfConnected(),
      fetchCameraStatusIfConnected(),
      fetchFocuserStatusIfConnected(),
      fetchFilterWheelStatusIfConnected(),
      fetchRotatorStatusIfConnected(),
      // Each ops fetch swallows its own errors via addLogEntry so a failed
      // ops panel doesn't drag the whole dashboard offline.
      fetchOpsWeatherAndSafety(),
      fetchOpsDomeStatusIfConnected(),
      fetchOpsCheckpoints(),
      fetchOpsProfiles(),
      fetchOpsAnalyticsSummary(),
      refreshPlanetariumPanel(),
      refreshSettingsPanel(),
    ]);
    // Hydrate the preview for browsers opened after a capture. Subsequent
    // frames remain event-driven.
    await fetchLastImage();
  }

  async function fetchDevices() {
    try {
      const result = await api.getConnectedDevices();
      state.connectedDevices = requireWireList(
        result, 'devices', 'Connected devices');
      const previousFilterWheelId = state.filterWheelDeviceId;

      // Rebuild the selection from the authoritative inventory. Keeping an
      // old id when a device temporarily disappears (notably while startup
      // auto-connect is still settling hardware) made the dashboard query
      // status routes for disconnected devices and flood the server log with
      // avoidable 500s.
      state.cameraDeviceId = null;
      state.mountDeviceId = null;
      state.focuserDeviceId = null;
      state.filterWheelDeviceId = null;
      state.rotatorDeviceId = null;
      state.ops.domeDeviceId = null;

      // connected-devices may carry discoveryErrors. Surface them once per
      // call in the log so a driver failure is never silent.
      if (result.discoveryErrors && typeof result.discoveryErrors === 'object') {
        for (const [dt, err] of Object.entries(result.discoveryErrors)) {
          addLogEntry('error', 'Discovery error (' + dt + '): ' + err);
        }
      }

      renderDevicesPanel();
      markPanelFresh('devices');

      // Auto-select device IDs from connected devices.
      for (const dev of state.connectedDevices) {
        switch (dev.deviceType) {
          case 'camera': state.cameraDeviceId = dev.id; break;
          case 'mount': state.mountDeviceId = dev.id; break;
          case 'focuser': state.focuserDeviceId = dev.id; break;
          case 'filterWheel': state.filterWheelDeviceId = dev.id; break;
          case 'rotator': state.rotatorDeviceId = dev.id; break;
          // The dome device id lives in the ops namespace.
          case 'dome': state.ops.domeDeviceId = dev.id; break;
        }
      }
      if (state.filterWheelDeviceId !== previousFilterWheelId) {
        state.filterWheelPositions = null;
        state.filterWheelPositionsDeviceId = null;
      }
      refreshPanelEnablement();
      // Load auxiliary data that we only know how to fetch once a device is
      // connected: camera readout modes, filter wheel positions+offsets.
      // These are best-effort — handlers log on failure rather than blocking
      // the panel render.
      maybeLoadCameraReadoutModes();
      maybeLoadFilterWheelPositions();
    } catch (e) {
      // Recorded, not only logged: the panel's stale line is drawn from this.
      reportRefreshFailure('devices', e, 'Devices fetch');
    }
  }

  // =========================================================================
  // The sequencer refresh, coalesced
  //
  // A sequencer event says "something moved"; it does not carry the panel's
  // full state, so three GETs — status, checkpoints, analytics — go out to
  // fetch it. Firing that trio once per event was the whole storm: the
  // executor emits Progress/InstructionProgress several times a second, and a
  // measured 75 s sim run put 274 red ERROR lines in the operator's Event Log,
  // every one of them this page's own request coming back 429 (147 refusals
  // across five routes server-side in a 45 s run). The refusals then marked
  // four panels stale, which re-armed the failing-panel retry in
  // checkStaleness() and asked for everything again.
  //
  // So the burst is COALESCED. The first event of a quiet period refreshes
  // immediately; every event that lands while a refresh is already scheduled
  // folds into it; and two refreshes are never closer together than
  // SEQUENCER_REFRESH_MIN_INTERVAL_MS. The trailing refresh always runs, so
  // the panels end a burst on the LAST event's state, not the first.
  //
  // The interval is the cadence the server's own budget is sized for: the
  // per-token read bucket (route_metadata/rate_limiting.dart) allows 60 GETs
  // a second precisely so "a phone dashboard [can] poll status, devices,
  // sequencer state, etc. at ~1 Hz across a dozen endpoints". Three GETs per
  // second is that, with room to spare for every other panel on the page.
  const SEQUENCER_REFRESH_MIN_INTERVAL_MS = 1000;
  let sequencerRefreshTimer = null;
  let sequencerRefreshLastAt = 0;

  function scheduleSequencerRefresh() {
    if (sequencerRefreshTimer !== null) return;
    const sinceLast = Date.now() - sequencerRefreshLastAt;
    const wait = Math.max(0, SEQUENCER_REFRESH_MIN_INTERVAL_MS - sinceLast);
    sequencerRefreshTimer = setTimeout(runSequencerRefresh, wait);
  }

  function runSequencerRefresh() {
    sequencerRefreshTimer = null;
    sequencerRefreshLastAt = Date.now();
    fetchSequencerStatus();
    fetchOpsCheckpoints();
    fetchOpsAnalyticsSummary();
  }

  function cancelSequencerRefresh() {
    if (sequencerRefreshTimer === null) return;
    clearTimeout(sequencerRefreshTimer);
    sequencerRefreshTimer = null;
  }

  async function fetchSequencerStatus() {
    try {
      const status = await api.sequencerGetStatus();
      state.sequencerStatus = status;
      // A 200 that carries no state has not refreshed anything this panel
      // asserts, so it counts as a refusal for the clock's purposes — the
      // same treatment a malformed reply already gets, and the same re-ask
      // cadence. Without this the panel wore no stale line while claiming a
      // state and a percentage nobody sent.
      if (sequencerStateOf(status) == null) {
        markPanelUnconfirmed('sequencer');
      } else {
        markPanelFresh('sequencer');
      }
      renderSequencerPanel();
    } catch (e) {
      reportRefreshFailure('sequencer', e, 'Sequencer fetch');
    }
  }

  async function fetchGuidingStatus() {
    try {
      const status = await api.phd2GetStatus();
      state.guidingStatus = status;
      renderGuidingPanel();
      markPanelFresh('guiding');
    } catch (e) {
      reportRefreshFailure('guiding', e, 'Guiding fetch');
    }
  }

  async function fetchMountStatusIfConnected() {
    if (!state.mountDeviceId) return;
    try {
      const status = await api.getMountStatus(state.mountDeviceId);
      state.mountStatus = status;
      renderMountPanel();
      markPanelFresh('mount');
    } catch (e) {
      reportRefreshFailure('mount', e, 'Mount status fetch');
    }
  }

  async function fetchCameraStatusIfConnected() {
    if (!state.cameraDeviceId) return;
    try {
      const status = await api.getCameraStatus(state.cameraDeviceId);
      state.cameraStatus = status;
      renderCameraStatusInfo();
      // Mirror the live gain/offset from the camera into the inputs so the
      // operator sees what the device currently reports (don't overwrite
      // while the input is focused, otherwise typing fights the poll).
      syncCameraInputsFromStatus(status);
      markPanelFresh('camera');
    } catch (e) {
      reportRefreshFailure('camera', e, 'Camera status fetch');
    }
  }

  async function fetchFocuserStatusIfConnected() {
    if (!state.focuserDeviceId) return;
    try {
      const status = await api.focuserGetStatus(state.focuserDeviceId);
      state.focuserStatus = status;
      renderFocuserPanel();
      markPanelFresh('focuser');
    } catch (e) {
      reportRefreshFailure('focuser', e, 'Focuser status fetch');
    }
  }

  async function fetchFilterWheelStatusIfConnected() {
    if (!state.filterWheelDeviceId) return;
    try {
      // Why both calls: the status payload (/api/equipment/filter-wheel/status)
      // gives current-position + moving; the positions payload gives the slot
      // list w/ offsets. The latter only needs refreshing on connect/rename
      // events, but reusing it here keeps WS-driven refresh predictable.
      const status = await api.getFilterWheelStatus(state.filterWheelDeviceId);
      state.filterWheelStatus = status;
      renderFilterWheelPanel();
      markPanelFresh('filter-wheel');
    } catch (e) {
      reportRefreshFailure('filter-wheel', e, 'Filter wheel status fetch');
    }
  }

  async function fetchRotatorStatusIfConnected() {
    if (!state.rotatorDeviceId) return;
    try {
      const status = await api.rotatorGetStatus(state.rotatorDeviceId);
      state.rotatorStatus = status;
      renderRotatorPanel();
      markPanelFresh('rotator');
    } catch (e) {
      reportRefreshFailure('rotator', e, 'Rotator status fetch');
    }
  }

  async function maybeLoadCameraReadoutModes() {
    if (!state.cameraDeviceId) return;
    if (state.readoutModes && state.readoutModes.length > 0) return;
    try {
      const result = await api.cameraGetReadoutModes(state.cameraDeviceId);
      state.readoutModes = (result && result.readoutModes) || [];
      renderReadoutModeOptions();
    } catch (e) {
      addLogEntry('error', describeApiError(e, 'Readout modes load'));
    }
  }

  async function maybeLoadFilterWheelPositions() {
    if (!state.filterWheelDeviceId) return;
    if (state.filterWheelPositionsLoading) return;
    if (state.filterWheelPositionsDeviceId === state.filterWheelDeviceId
        && state.filterWheelPositions) return;
    const requestedDeviceId = state.filterWheelDeviceId;
    state.filterWheelPositionsLoading = true;
    try {
      const result = await api.filterWheelGetPositions(requestedDeviceId);
      // Ignore a late response from a wheel that disconnected/reconnected
      // while the request was in flight.
      if (state.filterWheelDeviceId !== requestedDeviceId) return;
      state.filterWheelPositions = result;
      state.filterWheelPositionsDeviceId = requestedDeviceId;
      renderFilterWheelPanel();
    } catch (e) {
      addLogEntry('error', describeApiError(e, 'Filter wheel positions load'));
    } finally {
      state.filterWheelPositionsLoading = false;
    }
  }

  // =========================================================================
  // Server events (WebSocket)
  // =========================================================================

  function handleServerEvent(data) {
    const category = data.category || data.event_category || 'system';
    const message = data.message || data.description || messageFromPayload(data);

    addLogEntry(category, message);

    // Drive panel state from WS events first; only fall back to REST when an
    // event is too coarse to update the panel.
    if (category === 'camera' || category === 'imaging') {
      const eventType = data.eventType || data.event || '';
      // For temperature/cooling updates we still need a REST round-trip
      // because the WS event only carries the delta, not the full snapshot.
      if (eventType === 'TemperatureChanged' || eventType === 'ExposureProgress'
          || eventType === 'ExposureStarted' || eventType === 'ExposureStartedWithFrame') {
        fetchCameraStatusIfConnected();
      }
      // Image fetch is *only* driven by completion events; a duration-based
      // timer would fire against exposures that never completed.
      if (isExposureCompleteEvent(eventType)) {
        cancelPendingImageFetch();
        fetchLastImage();
      }
      // Capture plate-solve PA from imaging events so the rotator panel can
      // sync to the image. Many plate-solve events publish 'positionAngle'
      // (or 'pa') in their payload; we accept both.
      const imgPayload = data.data || data;
      const pa = imgPayload && (imgPayload.positionAngle ?? imgPayload.pa
        ?? imgPayload.position_angle);
      if (typeof pa === 'number' && isFinite(pa)) {
        state.lastImagePositionAngle = Number(pa);
        renderRotatorPanel();
      }
      markPanelFresh('camera');
    } else if (category === 'mount') {
      fetchMountStatusIfConnected();
    } else if (category === 'focuser') {
      const eventType = data.eventType || data.event || '';
      fetchFocuserStatusIfConnected();
      if (eventType === 'AutofocusComplete' || eventType === 'autofocus_complete') {
        // Capture the result payload so the panel can show "last autofocus"
        // even after the device returns to idle.
        state.lastAutofocusResult = data.data || data.result || data;
        renderFocuserPanel();
      }
    } else if (category === 'filterWheel' || category === 'filter_wheel') {
      fetchFilterWheelStatusIfConnected();
    } else if (category === 'rotator') {
      fetchRotatorStatusIfConnected();
    } else if (category === 'sequencer') {
      // Checkpoint state and analytics change in lock step with the sequencer,
      // so all three refresh together — but COALESCED, never once per event.
      // See scheduleSequencerRefresh().
      scheduleSequencerRefresh();
    } else if (category === 'dome') {
      fetchOpsDomeStatusIfConnected();
    } else if (category === 'safety' || category === 'safetyMonitor'
        || category === 'weather') {
      fetchOpsWeatherAndSafety();
    } else if (category === 'profile' || category === 'profiles') {
      fetchOpsProfiles();
    } else if (category === 'guiding' || category === 'phd2') {
      const eventType = data.eventType || data.event || '';
      // The canonical field names for guide-step coordinates are raPx /
      // decPx. The server emitter publishes these alongside legacy names;
      // accept either so the dashboard works across server versions.
      const payload = data.data || data;
      const guide = extractGuideStep(payload);
      if (guide) {
        addGuideDataPoint(guide.raPx, guide.decPx);
      }
      // Full status snapshots need a REST round-trip because the WS event
      // doesn't carry the rolling RMS or app state.
      if (eventType === 'GuidingStarted' || eventType === 'GuidingStopped'
          || eventType === 'Settled' || eventType === 'Settling'
          || eventType === 'AppState' || eventType === 'Connected'
          || eventType === 'Disconnected') {
        fetchGuidingStatus();
      }
      markPanelFresh('guiding');
    } else if (category === 'equipment') {
      // Only lifecycle events change inventory. PropertyChanged and healthy
      // heartbeat events can arrive several times per second; refetching the
      // complete inventory on each one also reloaded filter-wheel metadata,
      // producing request storms when a stale wheel was failing.
      const eventType = data.eventType || data.event || '';
      const payload = data.data || data;
      const heartbeatDisconnected = eventType === 'HeartbeatStatusChanged'
        && String(payload.status || '').toLowerCase() === 'disconnected';
      if (eventType === 'Connecting' || eventType === 'Connected'
          || eventType === 'Disconnected' || eventType === 'DeviceDiscovered'
          || eventType === 'DeviceLost' || heartbeatDisconnected) {
        fetchDevices();
      }
    } else if (category === 'polarAlignment' || category === 'polar_alignment') {
      // Polar alignment progress feed. Three event types come through the
      // polarAlignment category:
      //   PolarAlignment          — drift/error update (azArcmin, altArcmin, totalArcmin)
      //   PolarAlignmentStatus    — phase + statusMessage
      //   PolarAlignmentImage     — solver image preview (ignored here; the
      //                             dashboard renders the regular last image)
      handlePolarAlignmentEvent(data);
    }
  }

  function isExposureCompleteEvent(eventType) {
    if (!eventType) return false;
    return eventType === 'exposure_complete' || eventType === 'ExposureComplete'
        || eventType === 'image_ready' || eventType === 'ImageReady'
        || eventType === 'ExposureCompleted' || eventType === 'ExposureCompletedWithFrame';
  }

  function extractGuideStep(payload) {
    if (!payload || typeof payload !== 'object') return null;
    // Canonical: raPx, decPx.
    if (payload.raPx !== undefined && payload.decPx !== undefined) {
      return { raPx: Number(payload.raPx), decPx: Number(payload.decPx) };
    }
    // Backend currently emits RADistanceRaw/DECDistanceRaw inside the event
    // `data` payload. Accept both so we work whether the backend has been
    // updated yet or not.
    if (payload.RADistanceRaw !== undefined && payload.DECDistanceRaw !== undefined) {
      return {
        raPx: Number(payload.RADistanceRaw),
        decPx: Number(payload.DECDistanceRaw),
      };
    }
    // Legacy camelCase names. Keep accepting for backward compatibility.
    if (payload.raDistance !== undefined && payload.decDistance !== undefined) {
      return {
        raPx: Number(payload.raDistance),
        decPx: Number(payload.decDistance),
      };
    }
    return null;
  }

  function messageFromPayload(data) {
    const t = data.eventType || data.event || data.type;
    if (t) return String(t);
    return JSON.stringify(data);
  }

  // =========================================================================
  // Camera Controls
  // =========================================================================

  async function handleExpose() {
    if (!state.cameraDeviceId) {
      showToast('No camera connected', 'error');
      return;
    }

    const exposureTime = parseFloat(document.getElementById('exposure-time').value);
    const gain = parseInt(document.getElementById('camera-gain').value, 10);
    const binning = parseInt(document.getElementById('camera-binning').value, 10);

    if (isNaN(exposureTime) || exposureTime <= 0) {
      showToast('Invalid exposure time', 'error');
      return;
    }

    // Pull the offset from the camera-offset input so each expose carries
    // the latest dashboard intent rather than relying on a separate
    // /api/camera/offset call (which still works, but a single round-trip
    // is friendlier on slow links).
    const offsetRaw = document.getElementById('camera-offset');
    const offset = offsetRaw ? parseInt(offsetRaw.value, 10) : NaN;
    let subframe;
    try {
      subframe = readSubframeFromInputs();
    } catch (e) {
      showToast(e.message, 'error');
      return;
    }

    try {
      await api.cameraExpose(state.cameraDeviceId, exposureTime, {
        gain: isNaN(gain) ? undefined : gain,
        offset: isNaN(offset) ? undefined : offset,
        binX: binning || 1,
        binY: binning || 1,
        x: subframe ? subframe.x : undefined,
        y: subframe ? subframe.y : undefined,
        width: subframe ? subframe.width : undefined,
        height: subframe ? subframe.height : undefined,
      });
      addLogEntry('camera', 'Exposure started: ' + exposureTime + 's' +
        (subframe ? ' (subframe ' + subframe.width + 'x' + subframe.height +
          ' @ ' + subframe.x + ',' + subframe.y + ')' : ''));
      showToast('Exposure started');

      // The image fetch is event-driven. Arm a single fallback timer for
      // (exposureTime + IMAGE_FALLBACK_GRACE_MS) so a missing
      // exposure_complete event doesn't strand the operator with no preview.
      scheduleImageFetchFallback(exposureTime);
    } catch (e) {
      showToast('Expose failed: ' + e.message, 'error');
      addLogEntry('error', describeApiError(e, 'Expose'));
    }
  }

  function scheduleImageFetchFallback(exposureTime) {
    cancelPendingImageFetch();
    const waitMs = (exposureTime * 1000) + IMAGE_FALLBACK_GRACE_MS;
    state.pendingExposureExpectedBy = Date.now() + waitMs;
    state.pendingImageFetchTimer = setTimeout(() => {
      state.pendingImageFetchTimer = null;
      // One-shot fallback only — if the WS event arrives between scheduling
      // and now, handleServerEvent already cancelled the timer.
      addLogEntry('system',
        'No exposure_complete event after ' + Math.round(waitMs / 1000) +
        's; fetching last image as fallback');
      fetchLastImage();
    }, waitMs);
  }

  function cancelPendingImageFetch() {
    if (state.pendingImageFetchTimer) {
      clearTimeout(state.pendingImageFetchTimer);
      state.pendingImageFetchTimer = null;
    }
    state.pendingExposureExpectedBy = 0;
    cancelRawBackgroundFetch();
  }

  async function handleAbortExpose() {
    if (!state.cameraDeviceId) return;
    try {
      // The endpoint answers 200 whether or not an exposure was running and
      // reports which via `wasRunning` (shared stop/abort no-op contract).
      // Saying "Exposure aborted" unconditionally told the operator the
      // camera had been stopped when nothing had been running at all.
      const res = await api.cameraAbort(state.cameraDeviceId);
      cancelPendingImageFetch();
      if (res && res.wasRunning === false) {
        addLogEntry('camera', 'Abort ignored: no exposure was in progress');
        showToast('No exposure was in progress');
      } else {
        addLogEntry('camera', 'Exposure aborted');
        showToast('Exposure aborted');
      }
    } catch (e) {
      showToast('Abort failed: ' + e.message, 'error');
    }
  }

  function cancelRawBackgroundFetch() {
    state.rawLoadGeneration += 1;
    state.lastImageRawU16 = null;
    if (state.rawLoadStatus !== 'idle') {
      state.rawLoadStatus = 'idle';
      updatePreviewBadge();
    }
  }

  function setImagePreviewLoading(loading) {
    state.imagePreviewLoading = !!loading;
    const container = document.getElementById('image-preview');
    if (container) {
      container.classList.toggle('is-loading', state.imagePreviewLoading);
    }
    updatePreviewBadge();
  }

  /**
   * Overlay badge on the camera preview (matches mobile _RawPreviewBadge).
   */
  function updatePreviewBadge() {
    const badge = document.getElementById('preview-badge');
    if (!badge) return;
    const labelEl = badge.querySelector('.preview-badge-label');
    const spinner = badge.querySelector('.spinner');

    badge.classList.remove(
      'preview-badge--loading',
      'preview-badge--ready',
      'preview-badge--failed',
    );
    badge.hidden = true;

    if (state.imagePreviewLoading) {
      badge.hidden = false;
      badge.classList.add('preview-badge--loading');
      if (labelEl) labelEl.textContent = 'Loading preview…';
      if (spinner) spinner.hidden = false;
      return;
    }

    if (!state.lastImage) return;

    if (state.rawLoadStatus === 'loading') {
      badge.hidden = false;
      badge.classList.add('preview-badge--loading');
      if (labelEl) labelEl.textContent = 'Loading HQ…';
      if (spinner) spinner.hidden = false;
    } else if (state.rawLoadStatus === 'ready') {
      badge.hidden = false;
      badge.classList.add('preview-badge--ready');
      if (labelEl) labelEl.textContent = 'HQ ready';
      if (spinner) spinner.hidden = true;
    } else if (state.rawLoadStatus === 'failed') {
      badge.hidden = false;
      badge.classList.add('preview-badge--failed');
      if (labelEl) labelEl.textContent = 'Preview only';
      if (spinner) spinner.hidden = true;
    }
  }

  function rawStatLabel() {
    if (state.rawLoadStatus === 'ready') return 'HQ ready';
    if (state.rawLoadStatus === 'loading') return 'Loading HQ…';
    if (state.rawLoadStatus === 'failed') return 'Preview only';
    return '--';
  }

  function rawStatClass() {
    if (state.rawLoadStatus === 'ready') return 'raw-ready';
    if (state.rawLoadStatus === 'loading') return 'raw-loading';
    if (state.rawLoadStatus === 'failed') return 'raw-failed';
    return '';
  }

  async function fetchRawInBackground(captureGeneration) {
    if (!state.cameraDeviceId) return;
    state.rawLoadStatus = 'loading';
    updatePreviewBadge();
    await renderImagePreview();
    try {
      const raw = await api.getLastRawImageData(state.cameraDeviceId);
      if (captureGeneration !== state.rawLoadGeneration) return;
      const img = state.lastImage;
      if (!img) return;
      const expected = img.width * img.height;
      if (raw.length !== expected) {
        state.rawLoadStatus = 'failed';
        addLogEntry(
          'camera',
          'Raw size mismatch (' + raw.length + ' vs ' + expected + ' pixels)',
        );
      } else {
        state.lastImageRawU16 = raw;
        state.rawLoadStatus = 'ready';
      }
    } catch (e) {
      if (captureGeneration !== state.rawLoadGeneration) return;
      state.rawLoadStatus = 'failed';
      addLogEntry('camera', 'Raw preview unavailable: ' + e.message);
    }
    updatePreviewBadge();
    await renderImagePreview();
  }

  async function fetchLastImage() {
    if (!state.cameraDeviceId) return;
    cancelRawBackgroundFetch();
    // A fresh look at the live buffer earns a fresh look at the library: this
    // is the one place the fallback's cached row (or its read failure) goes
    // stale, which is what keeps a re-render from issuing requests.
    previewFallback.status = 'unread';
    const captureGeneration = state.rawLoadGeneration;
    setImagePreviewLoading(true);
    try {
      const result = await api.cameraGetLastImageJpeg(state.cameraDeviceId, {
        maxWidth: 1024,
        quality: 85,
      });
      if (result && result.blob && result.meta) {
        if (state.lastImagePreviewUrl) {
          URL.revokeObjectURL(state.lastImagePreviewUrl);
        }
        state.lastImage = result.meta;
        state.lastImagePreviewUrl = URL.createObjectURL(result.blob);
        await renderImagePreview();
        void fetchRawInBackground(captureGeneration);
        return;
      }
      state.lastImage = null;
      if (state.lastImagePreviewUrl) {
        URL.revokeObjectURL(state.lastImagePreviewUrl);
        state.lastImagePreviewUrl = null;
      }
      await renderImagePreview();
    } catch (e) {
      addLogEntry('error', 'Failed to fetch last image: ' + e.message);
    } finally {
      setImagePreviewLoading(false);
    }
  }

  // =========================================================================
  // Mount Controls — press-and-hold d-pad
  // =========================================================================

  function setupDpad() {
    const dpad = document.getElementById('mount-dpad');
    if (!dpad) return;

    const buttons = dpad.querySelectorAll('button.dpad-btn');
    for (const btn of buttons) {
      btn.addEventListener('pointerdown', onDpadPointerDown);
      btn.addEventListener('pointerup', onDpadPointerStop);
      btn.addEventListener('pointerleave', onDpadPointerStop);
      btn.addEventListener('pointercancel', onDpadPointerStop);
      // Why prevent click: pointerdown already starts the slew. Letting the
      // browser fire a synthetic click on touch devices would re-issue a
      // mountMoveAxis(...rate) with no matching stop, leaving the mount
      // slewing with nothing to cancel it.
      btn.addEventListener('click', (e) => e.preventDefault());
      // Stop touch from scrolling the page when the user holds a button.
      btn.addEventListener('touchstart', (e) => e.preventDefault(), { passive: false });
    }

    // Keyboard arrow keys move the axis while the d-pad container has focus.
    // Explicit focus (tabindex on the container) is required so arrow keys
    // don't hijack page-wide scrolling.
    dpad.addEventListener('keydown', onDpadKeyDown);
    dpad.addEventListener('keyup', onDpadKeyUp);
    dpad.addEventListener('focus', () => dpad.classList.add('dpad-keyboard-active'));
    dpad.addEventListener('blur', () => {
      dpad.classList.remove('dpad-keyboard-active');
      // Safety: releasing focus must release any held axis.
      stopAllDpadMotion();
      state.pressedKeys.clear();
    });
  }

  function onDpadPointerDown(e) {
    const btn = e.currentTarget;
    const axis = parseInt(btn.dataset.axis, 10);
    const direction = parseInt(btn.dataset.direction, 10);
    if (isNaN(axis) || isNaN(direction)) return;
    // Pointer capture ensures the matching pointerup fires on this element
    // even if the finger / cursor drifts off it.
    try { btn.setPointerCapture(e.pointerId); } catch (_) { /* not supported */ }
    state.dpadActiveButton = btn;
    state.dpadActiveAxis = axis;
    btn.classList.add('active');
    handleMountMoveStart(axis, direction);
  }

  function onDpadPointerStop(e) {
    const btn = e.currentTarget;
    btn.classList.remove('active');
    if (state.dpadActiveButton === btn) {
      const axis = state.dpadActiveAxis;
      state.dpadActiveButton = null;
      state.dpadActiveAxis = null;
      if (axis !== null && axis !== undefined) {
        handleMountMoveStop(axis);
      }
    }
  }

  function onDpadKeyDown(e) {
    const map = {
      'ArrowUp':    { axis: 1, direction:  1, btn: 'btn-mount-n' },
      'ArrowDown':  { axis: 1, direction: -1, btn: 'btn-mount-s' },
      'ArrowLeft':  { axis: 0, direction: -1, btn: 'btn-mount-w' },
      'ArrowRight': { axis: 0, direction:  1, btn: 'btn-mount-e' },
    };
    const m = map[e.key];
    if (!m) return;
    e.preventDefault();
    if (state.pressedKeys.has(e.key)) return; // ignore key-repeat
    state.pressedKeys.add(e.key);
    const btn = document.getElementById(m.btn);
    if (btn) btn.classList.add('active');
    handleMountMoveStart(m.axis, m.direction);
  }

  function onDpadKeyUp(e) {
    const map = {
      'ArrowUp':    { axis: 1, btn: 'btn-mount-n' },
      'ArrowDown':  { axis: 1, btn: 'btn-mount-s' },
      'ArrowLeft':  { axis: 0, btn: 'btn-mount-w' },
      'ArrowRight': { axis: 0, btn: 'btn-mount-e' },
    };
    const m = map[e.key];
    if (!m) return;
    e.preventDefault();
    state.pressedKeys.delete(e.key);
    const btn = document.getElementById(m.btn);
    if (btn) btn.classList.remove('active');
    handleMountMoveStop(m.axis);
  }

  function stopAllDpadMotion() {
    if (!state.mountDeviceId) return;
    api.mountMoveAxis(state.mountDeviceId, 0, 0).catch(() => {});
    api.mountMoveAxis(state.mountDeviceId, 1, 0).catch(() => {});
  }

  async function handleMountMoveStart(axis, direction) {
    if (!state.mountDeviceId) {
      showToast('No mount connected', 'error');
      return;
    }
    const speedSelect = document.getElementById('slew-speed');
    const rate = parseFloat(speedSelect.value) * direction;
    try {
      await api.mountMoveAxis(state.mountDeviceId, axis, rate);
    } catch (e) {
      showToast('Mount move failed: ' + e.message, 'error');
    }
  }

  async function handleMountMoveStop(axis) {
    if (!state.mountDeviceId) return;
    try {
      await api.mountMoveAxis(state.mountDeviceId, axis, 0);
    } catch (e) {
      showToast('Mount stop failed: ' + e.message, 'error');
    }
  }

  async function handleMountStop() {
    if (!state.mountDeviceId) return;
    try {
      // Stop both axes then issue a hard abort. Order matters: abort can
      // interrupt MoveAxis on drivers that queue the requests.
      await api.mountMoveAxis(state.mountDeviceId, 0, 0);
      await api.mountMoveAxis(state.mountDeviceId, 1, 0);
      await api.mountAbort(state.mountDeviceId);
      addLogEntry('mount', 'Mount stopped');
    } catch (e) {
      showToast('Mount stop failed: ' + e.message, 'error');
    }
  }

  async function handleMountPark() {
    if (!state.mountDeviceId) return;
    try {
      await api.mountPark(state.mountDeviceId);
      addLogEntry('mount', 'Parking mount');
      showToast('Parking mount');
    } catch (e) {
      showToast('Park failed: ' + e.message, 'error');
    }
  }

  async function handleMountUnpark() {
    if (!state.mountDeviceId) return;
    try {
      await api.mountUnpark(state.mountDeviceId);
      addLogEntry('mount', 'Unparking mount');
      showToast('Mount unparked');
    } catch (e) {
      showToast('Unpark failed: ' + e.message, 'error');
    }
  }

  async function handleMountToggleTracking() {
    if (!state.mountDeviceId) return;
    const isTracking = state.mountStatus && state.mountStatus.isTracking;
    try {
      await api.mountSetTracking(state.mountDeviceId, !isTracking);
      addLogEntry('mount', 'Tracking ' + (isTracking ? 'disabled' : 'enabled'));
    } catch (e) {
      showToast('Tracking toggle failed: ' + e.message, 'error');
    }
  }

  // =========================================================================
  // Sequencer Controls
  // =========================================================================

  /// Controls this credential has been refused, keyed by button id, holding
  /// the sentence the refusal produced.
  ///
  /// A read-only session renders the same control cluster a control-scope one
  /// does, so before this every press posted a request the rig had already
  /// refused once, the failure went out as a toast that faded, and the button
  /// stayed live. A control this credential cannot use is disabled and carries
  /// its reason, which is a thing the operator can still read a minute later.
  const refusedControls = new Map();

  /// Forget every recorded refusal, and take the reason off the controls that
  /// carried it. Called when the credential changes.
  function clearControlRefusals() {
    for (const id of refusedControls.keys()) {
      const el = document.getElementById(id);
      if (el) {
        el.title = '';
        el.removeAttribute('aria-disabled');
      }
    }
    refusedControls.clear();
  }

  /// Record a refusal on the control that caused it, and say it out loud once.
  ///
  /// The Event Log gets the line as well as the toast: a toast is gone in
  /// seconds, and "I pressed Pause and nothing happened" needs a record that
  /// outlives it.
  function noteControlRefused(buttonId, e, what) {
    const sentence = describeScopeRefusal(e, what);
    refusedControls.set(buttonId, sentence);
    const el = document.getElementById(buttonId);
    if (el) {
      el.disabled = true;
      el.title = sentence;
      el.setAttribute('aria-disabled', 'true');
    }
    showToast(sentence, 'error');
    addLogEntry('error', what + ' refused: ' + sentence);
  }

  /// Report a failed sequencer command. A scope refusal is named on its
  /// control; everything else keeps the toast it always had.
  function reportSeqFailure(buttonId, e, what) {
    if (e && e.kind === 'scope_denied') {
      noteControlRefused(buttonId, e, what);
      return;
    }
    showToast(what + ' failed: ' + describeApiError(e, what), 'error');
  }

  /// The refusal body a not-running pause/resume carries, parsed, or null.
  ///
  /// `_post` throws the 409 as an http_error whose `detail.body` is the raw
  /// response text; the not-running case is
  /// `{ "error": "sequencer_not_running", "wasRunning": false, "message": … }`.
  /// Read as an object so the caller can act on the verdict rather than paste
  /// the JSON into a red toast.
  function seqErrorBody(e) {
    const raw = e && e.detail ? e.detail.body : null;
    if (raw && typeof raw === 'object') return raw;
    if (typeof raw === 'string') {
      try { return JSON.parse(raw); } catch (_) { return null; }
    }
    return null;
  }

  /// Run a sequencer command that is a no-op when nothing is in flight.
  ///
  /// "Nothing was running" is not a failure. Stop reports it off a 200
  /// (`wasRunning: false`); pause and resume report it off a 409
  /// (`sequencer_not_running`, carrying the same `wasRunning: false` verdict).
  /// Both are the operator pressing a control that had nothing to act on, so
  /// both read as one informational line — never the refusal's raw JSON body in
  /// a red toast, which is what routing this 409 through `reportSeqFailure` did.
  /// Every other failure keeps the toast `reportSeqFailure` gives it.
  async function runSeqNoop(fn, buttonId, verb, doneMessage) {
    try {
      const res = await fn();
      if (res && res.wasRunning === false) {
        addLogEntry('sequencer', verb + ' ignored: no sequence was running');
        showToast('No sequence was running');
      } else {
        addLogEntry('sequencer', doneMessage);
      }
    } catch (e) {
      const body = seqErrorBody(e);
      if (e && e.status === 409 && body &&
          (body.error === 'sequencer_not_running' ||
           body.wasRunning === false)) {
        addLogEntry('sequencer', verb + ' ignored: no sequence was running');
        showToast(
          typeof body.message === 'string' && body.message
            ? body.message
            : 'No sequence was running',
        );
        return;
      }
      reportSeqFailure(buttonId, e, verb);
    }
  }

  async function handleSeqStart() {
    try {
      await api.sequencerStart();
      addLogEntry('sequencer', 'Sequence started');
      showToast('Sequence started');
    } catch (e) {
      reportSeqFailure('btn-seq-start', e, 'Start');
    }
  }

  async function handleSeqStop() {
    // See the camera-abort note: 200 does not mean a run was stopped.
    await runSeqNoop(
      () => api.sequencerStop(), 'btn-seq-stop', 'Stop', 'Sequence stopped',
    );
  }

  async function handleSeqPause() {
    await runSeqNoop(
      () => api.sequencerPause(), 'btn-seq-pause', 'Pause', 'Sequence paused',
    );
  }

  async function handleSeqResume() {
    await runSeqNoop(
      () => api.sequencerResume(), 'btn-seq-resume', 'Resume',
      'Sequence resumed',
    );
  }

  // =========================================================================
  // Guiding Controls
  // =========================================================================

  async function handleGuideStart() {
    try {
      await api.phd2StartGuiding();
      addLogEntry('guiding', 'Guiding started');
      showToast('Guiding started');
    } catch (e) {
      showToast('Guide start failed: ' + e.message, 'error');
    }
  }

  async function handleGuideStop() {
    try {
      await api.phd2StopGuiding();
      addLogEntry('guiding', 'Guiding stopped');
    } catch (e) {
      showToast('Guide stop failed: ' + e.message, 'error');
    }
  }

  async function handleGuideConnect() {
    try {
      await api.phd2Connect('localhost', 4400);
      addLogEntry('guiding', 'PHD2 connect requested');
      showToast('Connecting to PHD2');
      await refreshGuidingStatus();
    } catch (e) {
      showToast('PHD2 connect failed: ' + e.message, 'error');
    }
  }

  async function handleGuideDither() {
    const amount = parseFloat(
      (document.getElementById('guide-dither-amount') || {}).value,
    );
    try {
      await api.phd2Dither(isFinite(amount) ? amount : 5.0);
      addLogEntry('guiding', 'Dither requested');
      showToast('Dither sent');
    } catch (e) {
      showToast('Dither failed: ' + e.message, 'error');
    }
  }

  async function handleGuidePauseToggle() {
    const g = state.guidingStatus;
    const paused = g && (g.paused === true || String(g.state || '').toLowerCase() === 'paused');
    try {
      await api.phd2SetPaused(!paused);
      addLogEntry('guiding', paused ? 'Guiding resumed (PHD2)' : 'Guiding paused (PHD2)');
      showToast(paused ? 'PHD2 resumed' : 'PHD2 paused');
      await refreshGuidingStatus();
    } catch (e) {
      showToast('PHD2 pause toggle failed: ' + e.message, 'error');
    }
  }

  async function refreshGuidingStatus() {
    try {
      const status = await api.phd2GetStatus();
      state.guidingStatus = status;
      renderGuidingPanel();
      markPanelFresh('guiding');
    } catch (_) { /* panel stays stale */ }
  }

  // =========================================================================
  // Camera Extended Controls
  // =========================================================================

  // Mirror the live camera status into the gain/offset inputs so the user
  // sees what the device currently reports — but only when the input is
  // not focused (otherwise we'd fight the operator's typing).
  function syncCameraInputsFromStatus(status) {
    if (!status) return;
    const gainInput = document.getElementById('camera-gain');
    const offsetInput = document.getElementById('camera-offset');
    if (gainInput && document.activeElement !== gainInput && status.gain != null) {
      gainInput.value = String(status.gain);
    }
    if (offsetInput && document.activeElement !== offsetInput && status.offset != null) {
      offsetInput.value = String(status.offset);
    }
    // Cooling slider readout: show the live setpoint, not the stale UI
    // value, when the operator isn't actively dragging the slider.
    const slider = document.getElementById('camera-target-temp');
    if (slider && document.activeElement !== slider && status.targetTemp != null) {
      slider.value = String(status.targetTemp);
      updateCoolerSliderReadout();
    }
  }

  function updateCoolerSliderReadout() {
    const slider = document.getElementById('camera-target-temp');
    const readout = document.getElementById('camera-target-temp-readout');
    if (slider && readout) {
      readout.textContent = slider.value + ' °C';
    }
  }

  async function handleCameraApplyGain() {
    if (!state.cameraDeviceId) return;
    const v = parseInt(document.getElementById('camera-gain').value, 10);
    if (isNaN(v)) { showToast('Gain must be an integer', 'error'); return; }
    try {
      await api.cameraSetGain(state.cameraDeviceId, v);
      addLogEntry('camera', 'Gain set to ' + v);
      showToast('Gain applied');
    } catch (e) {
      showToast('Set gain failed: ' + e.message, 'error');
    }
  }

  async function handleCameraApplyOffset() {
    if (!state.cameraDeviceId) return;
    const v = parseInt(document.getElementById('camera-offset').value, 10);
    if (isNaN(v)) { showToast('Offset must be an integer', 'error'); return; }
    try {
      await api.cameraSetOffset(state.cameraDeviceId, v);
      addLogEntry('camera', 'Offset set to ' + v);
      showToast('Offset applied');
    } catch (e) {
      showToast('Set offset failed: ' + e.message, 'error');
    }
  }

  async function handleCameraApplyReadout() {
    if (!state.cameraDeviceId) return;
    const sel = document.getElementById('camera-readout-mode');
    if (!sel || sel.value === '') {
      showToast('Pick a readout mode first', 'error');
      return;
    }
    const idx = parseInt(sel.value, 10);
    if (isNaN(idx)) { showToast('Invalid readout mode', 'error'); return; }
    try {
      await api.cameraSetReadoutMode(state.cameraDeviceId, idx);
      state.selectedReadoutMode = idx;
      addLogEntry('camera', 'Readout mode set to ' + sel.options[sel.selectedIndex].textContent);
      showToast('Readout mode applied');
    } catch (e) {
      showToast('Set readout failed: ' + e.message, 'error');
    }
  }

  async function handleCameraCooler(enable) {
    if (!state.cameraDeviceId) return;
    // When turning on we use the current slider setpoint; when turning off
    // we pass null so the backend just disables the cooler without
    // adjusting target temperature.
    const slider = document.getElementById('camera-target-temp');
    const target = enable ? parseFloat(slider.value) : null;
    try {
      await api.cameraSetCooling(state.cameraDeviceId, enable, target);
      addLogEntry('camera',
        'Cooler ' + (enable ? 'on (target ' + target + ' °C)' : 'off'));
      showToast('Cooler ' + (enable ? 'on' : 'off'));
    } catch (e) {
      showToast('Cooler toggle failed: ' + e.message, 'error');
    }
  }

  async function handleCameraApplyCooling() {
    if (!state.cameraDeviceId) return;
    const target = parseFloat(document.getElementById('camera-target-temp').value);
    if (isNaN(target)) { showToast('Invalid target temperature', 'error'); return; }
    try {
      // Why pass enabled=true: the operator is explicitly setting a target
      // by pressing Set, which is meaningless if cooling is off. The
      // "Cooler OFF" button handles the disable path.
      await api.cameraSetCooling(state.cameraDeviceId, true, target);
      addLogEntry('camera', 'Cooling target set to ' + target + ' °C');
      showToast('Cooling target ' + target + ' °C');
    } catch (e) {
      showToast('Cooling failed: ' + e.message, 'error');
    }
  }

  function handleCameraBinningChange() {
    if (!state.cameraDeviceId) return;
    const v = parseInt(document.getElementById('camera-binning').value, 10) || 1;
    // Queue the binning for the next expose; ASCOM commits binning at
    // StartExposure time so applying it standalone wouldn't survive.
    api.cameraSetBinning(state.cameraDeviceId, v, v);
    addLogEntry('camera', 'Binning queued: ' + v + 'x' + v);
  }

  function handleCameraSubframeFull() {
    if (!state.cameraDeviceId) return;
    const s = state.cameraStatus;
    if (s && s.sensorWidth > 0 && s.sensorHeight > 0) {
      document.getElementById('camera-subframe-x').value = '0';
      document.getElementById('camera-subframe-y').value = '0';
      document.getElementById('camera-subframe-w').value = String(s.sensorWidth);
      document.getElementById('camera-subframe-h').value = String(s.sensorHeight);
    } else {
      // Clear all four fields if we don't know the sensor size — the
      // backend defaults to full-frame on missing x/y/w/h.
      for (const id of ['camera-subframe-x', 'camera-subframe-y',
                        'camera-subframe-w', 'camera-subframe-h']) {
        document.getElementById(id).value = '';
      }
    }
    // Drop any queued subframe so cameraExpose ships full-frame defaults.
    api.clearPendingSubframe();
    addLogEntry('camera', 'Subframe reset to full sensor');
  }

  function readSubframeFromInputs() {
    const ids = [
      'camera-subframe-x',
      'camera-subframe-y',
      'camera-subframe-w',
      'camera-subframe-h',
    ];
    const raw = ids.map((id) => document.getElementById(id).value.trim());
    if (raw.every((value) => value === '')) {
      return null;
    }
    if (raw.some((value) => value === '')) {
      throw new Error(
        'Enter X, Y, width, and height for a subframe, or clear all four for full frame',
      );
    }

    const [x, y, width, height] = raw.map(Number);
    if (![x, y, width, height].every(Number.isInteger)) {
      throw new Error('Subframe values must be whole pixels');
    }
    if (x < 0 || y < 0 || width < 1 || height < 1) {
      throw new Error('Subframe X/Y must be non-negative and size must be positive');
    }
    return { x, y, width, height };
  }

  function renderReadoutModeOptions() {
    const sel = document.getElementById('camera-readout-mode');
    if (!sel) return;
    // Preserve the previously selected mode if it still exists.
    const prev = sel.value;
    clearElement(sel);
    if (!state.readoutModes || state.readoutModes.length === 0) {
      const opt = document.createElement('option');
      opt.value = '';
      opt.textContent = '-- none reported --';
      sel.appendChild(opt);
      return;
    }
    state.readoutModes.forEach((mode, idx) => {
      const opt = document.createElement('option');
      opt.value = String(idx);
      // Readout modes can arrive as strings or objects depending on driver.
      opt.textContent = typeof mode === 'string'
        ? mode
        : (mode && (mode.name || mode.label)) || ('Mode ' + idx);
      sel.appendChild(opt);
    });
    if (prev !== '' && parseInt(prev, 10) < state.readoutModes.length) {
      sel.value = prev;
    }
  }

  // =========================================================================
  // Filter Wheel Controls
  // =========================================================================

  async function handleFilterWheelRotateTo(position) {
    if (!state.filterWheelDeviceId) return;
    try {
      await api.filterWheelSetPosition(state.filterWheelDeviceId, position);
      addLogEntry('focuser', 'Filter wheel rotating to slot ' + position);
      showToast('Rotating filter wheel');
    } catch (e) {
      showToast('Filter wheel rotate failed: ' + e.message, 'error');
    }
  }

  function renderFilterWheelPanel() {
    const positions = state.filterWheelPositions;
    const status = state.filterWheelStatus;
    const currentPos = status && status.position != null
      ? Number(status.position)
      : (positions && positions.currentPosition);
    const currentName = positions && positions.positions && currentPos >= 0
      && currentPos < positions.positions.length
      ? positions.positions[currentPos].name
      : (status && status.filterNames && currentPos >= 0
          ? status.filterNames[currentPos]
          : null);

    const badge = document.getElementById('fw-current-badge');
    if (badge) {
      badge.textContent = currentName || (currentPos >= 0 ? 'Slot ' + currentPos : '--');
      badge.className = 'badge ' + (currentName ? 'badge-completed' : 'badge-idle');
    }
    const posEl = document.getElementById('fw-current-position');
    if (posEl) posEl.textContent = currentPos >= 0 ? String(currentPos) : '--';
    const nameEl = document.getElementById('fw-current-name');
    if (nameEl) nameEl.textContent = currentName || '--';

    const listEl = document.getElementById('fw-list');
    if (!listEl) return;
    clearElement(listEl);

    const slots = (positions && positions.positions) || [];
    if (slots.length === 0) {
      // Fall back to the slot count from filter wheel status if positions
      // didn't load yet (e.g. focus-model offsets endpoint 404'd on a fresh
      // install).
      if (status && status.filterCount > 0 && status.filterNames) {
        for (let i = 0; i < status.filterCount; i++) {
          slots.push({
            position: i,
            name: status.filterNames[i] || ('Slot ' + i),
            offset: null,
          });
        }
      }
    }

    if (slots.length === 0) {
      listEl.appendChild(createEmptyState('No filters reported'));
      return;
    }

    const moving = status && status.moving;
    for (const slot of slots) {
      const row = document.createElement('button');
      row.type = 'button';
      row.className = 'filter-wheel-row';
      if (slot.position === currentPos) {
        row.classList.add('filter-wheel-row--current');
      }
      row.setAttribute('role', 'option');
      row.setAttribute('aria-selected', slot.position === currentPos ? 'true' : 'false');
      row.setAttribute('aria-label',
        'Rotate filter wheel to slot ' + slot.position + ', ' + slot.name +
        (slot.offset != null ? ', focuser offset ' + slot.offset : ''));
      row.disabled = !!moving;
      // Why click and not pointerdown: a filter wheel rotation is a discrete
      // one-shot command, not a press-and-hold motion. The press-and-hold
      // pattern applies only to streaming motion APIs.
      row.addEventListener('click', () => handleFilterWheelRotateTo(slot.position));

      const idxSpan = document.createElement('span');
      idxSpan.className = 'filter-wheel-row__index';
      idxSpan.textContent = String(slot.position);
      const nameSpan = document.createElement('span');
      nameSpan.className = 'filter-wheel-row__name';
      nameSpan.textContent = slot.name;
      const offsetSpan = document.createElement('span');
      offsetSpan.className = 'filter-wheel-row__offset';
      offsetSpan.textContent = slot.offset != null
        ? (slot.offset > 0 ? '+' + slot.offset : String(slot.offset))
        : '';
      offsetSpan.title = slot.offset != null
        ? 'Focuser offset for this filter (steps)'
        : '';

      row.appendChild(idxSpan);
      row.appendChild(nameSpan);
      row.appendChild(offsetSpan);
      listEl.appendChild(row);
    }
  }

  // =========================================================================
  // Focuser Controls
  // =========================================================================

  async function handleFocuserMoveTo() {
    if (!state.focuserDeviceId) return;
    const v = parseInt(document.getElementById('focuser-target').value, 10);
    if (isNaN(v) || v < 0) {
      showToast('Enter a target focuser position', 'error');
      return;
    }
    try {
      await api.focuserMoveTo(state.focuserDeviceId, v);
      addLogEntry('focuser', 'Focuser moving to ' + v);
      showToast('Focuser moving');
    } catch (e) {
      showToast('Focuser move failed: ' + e.message, 'error');
    }
  }

  async function handleFocuserMoveRelative(delta) {
    if (!state.focuserDeviceId) return;
    try {
      await api.focuserMoveRelative(state.focuserDeviceId, delta);
      addLogEntry('focuser', 'Focuser jog ' + (delta > 0 ? '+' : '') + delta);
    } catch (e) {
      showToast('Focuser jog failed: ' + e.message, 'error');
    }
  }

  async function handleFocuserHalt() {
    if (!state.focuserDeviceId) return;
    try {
      await api.focuserHalt(state.focuserDeviceId);
      addLogEntry('focuser', 'Focuser halted');
    } catch (e) {
      showToast('Focuser halt failed: ' + e.message, 'error');
    }
  }

  async function handleFocuserRunAutofocus() {
    if (!state.focuserDeviceId) {
      showToast('No focuser connected', 'error');
      return;
    }
    if (!state.cameraDeviceId) {
      showToast('Autofocus requires a connected camera', 'error');
      return;
    }
    try {
      const result = await api.autofocusStart(state.focuserDeviceId, state.cameraDeviceId);
      state.lastAutofocusResult = result;
      addLogEntry('focuser', 'Autofocus started');
      showToast('Autofocus started');
      renderFocuserPanel();
    } catch (e) {
      showToast('Autofocus failed: ' + e.message, 'error');
    }
  }

  async function handleFocuserCancelAutofocus() {
    if (!state.focuserDeviceId) return;
    try {
      await api.autofocusCancel(state.focuserDeviceId);
      addLogEntry('focuser', 'Autofocus cancel requested');
    } catch (e) {
      showToast('Autofocus cancel failed: ' + e.message, 'error');
    }
  }

  /// Same state-gating contract as updateSequencerButtons for the focuser:
  /// the absolute Move and every relative jog step are inadmissible while the
  /// focuser is moving, and Halt is inert when it is idle. Autofocus has no
  /// run-state field in the polled status, so it stays under connection-level
  /// enablement (refreshPanelEnablement). An unknown `moving` fails open.
  function updateFocuserButtons(status) {
    if (!status) return;
    const set = (id, enabled) => {
      const el = document.getElementById(id);
      if (el) el.disabled = !enabled;
    };
    const moving = status.moving ?? status.isMoving;
    const canMove = moving !== true;
    set('btn-focuser-move', canMove);
    set('btn-focuser--1000', canMove);
    set('btn-focuser--100', canMove);
    set('btn-focuser--10', canMove);
    set('btn-focuser--1', canMove);
    set('btn-focuser-+1', canMove);
    set('btn-focuser-+10', canMove);
    set('btn-focuser-+100', canMove);
    set('btn-focuser-+1000', canMove);
    set('btn-focuser-halt', moving !== false);
  }

  function renderFocuserPanel() {
    const s = state.focuserStatus;
    updateFocuserButtons(s);
    const posEl = document.getElementById('focuser-position');
    const tempEl = document.getElementById('focuser-temp');
    const movingEl = document.getElementById('focuser-moving');
    const afEl = document.getElementById('focuser-last-af');

    const focuserPosition = wireNumber(s && s.position);
    if (posEl) {
      posEl.textContent = focuserPosition != null
        ? String(focuserPosition) : '--';
    }
    const focuserTemp = wireNumber(s && s.temperature);
    if (tempEl) {
      tempEl.textContent = focuserTemp != null
        ? focuserTemp.toFixed(1) + ' °C'
        : '--';
    }
    if (movingEl) movingEl.classList.toggle('hidden-inline', !(s && s.moving));

    if (afEl) {
      const r = state.lastAutofocusResult;
      if (!r) {
        afEl.textContent = '--';
      } else {
        // Autofocus result fields can vary: bestFocus / bestPosition / hfr.
        const best = wireNumber(r.bestFocus ?? r.bestPosition ?? r.position);
        const hfr = wireNumber(r.hfr ?? r.bestHfr ?? r.minHfr);
        const success = r.success !== false; // default to true unless explicitly false
        const parts = [];
        if (best != null) parts.push('pos=' + Math.round(best));
        if (hfr != null) parts.push('HFR=' + hfr.toFixed(2));
        if (!success) parts.unshift('FAILED');
        afEl.textContent = parts.length ? parts.join(', ') : 'done';
      }
    }
  }

  // =========================================================================
  // Rotator Controls
  // =========================================================================

  async function handleRotatorMoveTo() {
    if (!state.rotatorDeviceId) return;
    const v = parseFloat(document.getElementById('rotator-target').value);
    if (isNaN(v)) {
      showToast('Enter a target sky PA in degrees', 'error');
      return;
    }
    // Normalise to [0, 360).
    const normalised = ((v % 360) + 360) % 360;
    try {
      await api.rotatorMoveTo(state.rotatorDeviceId, normalised);
      addLogEntry('system', 'Rotator slewing to ' + normalised.toFixed(2) + '°');
      showToast('Rotator slewing');
    } catch (e) {
      showToast('Rotator move failed: ' + e.message, 'error');
    }
  }

  async function handleRotatorHalt() {
    if (!state.rotatorDeviceId) return;
    try {
      await api.rotatorHalt(state.rotatorDeviceId);
      addLogEntry('system', 'Rotator halted');
    } catch (e) {
      showToast('Rotator halt failed: ' + e.message, 'error');
    }
  }

  async function handleRotatorSyncImage() {
    if (!state.rotatorDeviceId) return;
    if (state.lastImagePositionAngle == null) {
      showToast('No plate-solve PA available yet — take a frame first', 'error');
      return;
    }
    try {
      await api.rotatorSync(state.rotatorDeviceId, state.lastImagePositionAngle);
      addLogEntry('system',
        'Rotator synced to image PA ' + state.lastImagePositionAngle.toFixed(2) + '°');
      showToast('Rotator synced');
    } catch (e) {
      // Surface the failure: a silent no-op leaves the operator believing the
      // rotator is synced to the image PA when it is not.
      showToast('Rotator sync failed: ' + e.message, 'error');
    }
  }

  /// Same state-gating contract as updateSequencerButtons for the rotator:
  /// Slew and Sync-to-image are inadmissible while the rotator is moving, and
  /// Halt is inert when it is idle. An unknown `moving` fails open.
  function updateRotatorButtons(status) {
    if (!status) return;
    const set = (id, enabled) => {
      const el = document.getElementById(id);
      if (el) el.disabled = !enabled;
    };
    const moving = status.moving ?? status.isMoving;
    set('btn-rotator-move', moving !== true);
    set('btn-rotator-sync-image', moving !== true);
    set('btn-rotator-halt', moving !== false);
  }

  function renderRotatorPanel() {
    const s = state.rotatorStatus;
    updateRotatorButtons(s);
    const skyEl = document.getElementById('rotator-sky-pa');
    const mechEl = document.getElementById('rotator-mech-pa');
    const movingEl = document.getElementById('rotator-moving');
    const skyPa = wireNumber(s && s.position);
    const mechPa = wireNumber(s && s.mechanicalPosition);
    if (skyEl) {
      skyEl.textContent = skyPa != null ? skyPa.toFixed(2) + '°' : '--°';
    }
    if (mechEl) {
      mechEl.textContent = mechPa != null ? mechPa.toFixed(2) + '°' : '--°';
    }
    if (movingEl) {
      movingEl.classList.toggle('hidden-inline', !(s && (s.moving || s.isMoving)));
    }

    // Highlight Sync-to-image when we have a fresh plate-solve PA.
    const syncBtn = document.getElementById('btn-rotator-sync-image');
    if (syncBtn) {
      if (state.lastImagePositionAngle != null) {
        syncBtn.title = 'Sync to last plate-solve PA: ' +
          state.lastImagePositionAngle.toFixed(2) + '°';
      } else {
        syncBtn.title = 'No plate-solve PA available yet';
      }
    }
  }

  // =========================================================================
  // Mount Goto / Object Slew
  // =========================================================================

  // Parse HH:MM:SS or HH.hhh to decimal hours. Accepts negative values for
  // wrap-around inputs even though canonical RA is 0..24.
  function parseRaHours(value) {
    if (value == null) return NaN;
    const raw = String(value).trim();
    if (raw === '') return NaN;
    // Accept colon, space, or 'h'/'m'/'s' as separators.
    const parts = raw.split(/[:\s hms]+/).filter(Boolean);
    if (parts.length === 1) {
      const v = Number(parts[0]);
      return isFinite(v) ? v : NaN;
    }
    if (parts.length === 2 || parts.length === 3) {
      const h = Number(parts[0]);
      const m = Number(parts[1]);
      const s = parts.length === 3 ? Number(parts[2]) : 0;
      if (![h, m, s].every(isFinite)) return NaN;
      const sign = h < 0 ? -1 : 1;
      return sign * (Math.abs(h) + m / 60 + s / 3600);
    }
    return NaN;
  }

  // Parse +DD:MM:SS, -DD:MM:SS, or decimal degrees.
  function parseDecDegrees(value) {
    if (value == null) return NaN;
    const raw = String(value).trim();
    if (raw === '') return NaN;
    let sign = 1;
    let rest = raw;
    if (rest.startsWith('+')) { rest = rest.slice(1); }
    else if (rest.startsWith('-')) { sign = -1; rest = rest.slice(1); }
    const parts = rest.split(/[:\s d'°′″"]+/).filter(Boolean);
    if (parts.length === 1) {
      const v = Number(parts[0]);
      return isFinite(v) ? sign * v : NaN;
    }
    if (parts.length === 2 || parts.length === 3) {
      const d = Number(parts[0]);
      const m = Number(parts[1]);
      const s = parts.length === 3 ? Number(parts[2]) : 0;
      if (![d, m, s].every(isFinite)) return NaN;
      return sign * (d + m / 60 + s / 3600);
    }
    return NaN;
  }

  async function handleMountGoto() {
    if (!state.mountDeviceId) {
      showToast('No mount connected', 'error');
      return;
    }
    const ra = parseRaHours(document.getElementById('mount-goto-ra').value);
    const dec = parseDecDegrees(document.getElementById('mount-goto-dec').value);
    if (!isFinite(ra) || ra < 0 || ra >= 24) {
      showToast('RA must be 0..24h (HH:MM:SS or decimal hours)', 'error');
      return;
    }
    if (!isFinite(dec) || dec < -90 || dec > 90) {
      showToast('Dec must be -90..+90 degrees', 'error');
      return;
    }
    try {
      await api.mountSlewToRaDec(state.mountDeviceId, ra, dec);
      addLogEntry('mount', 'Slewing to RA ' + formatRA(ra) + ', Dec ' + formatDec(dec));
      showToast('Slewing');
    } catch (e) {
      showToast('Slew failed: ' + e.message, 'error');
    }
  }

  async function handleMountGotoAbort() {
    if (!state.mountDeviceId) return;
    try {
      await api.mountAbortSlew(state.mountDeviceId);
      addLogEntry('mount', 'Slew aborted');
    } catch (e) {
      showToast('Abort slew failed: ' + e.message, 'error');
    }
  }

  // Debounced autocomplete against /api/targets/search. Why debounce: each
  // keystroke would otherwise hit the database; the search executes a LIKE
  // across multiple columns and is cheap but not free.
  function handleTargetSearchInput() {
    if (state.targetSearchDebounce) {
      clearTimeout(state.targetSearchDebounce);
    }
    state.targetSearchDebounce = setTimeout(runTargetSearch, 220);
  }

  async function runTargetSearch() {
    const input = document.getElementById('mount-goto-name');
    if (!input) return;
    const query = input.value.trim();
    if (query.length < 1) {
      hideTargetSuggestions();
      return;
    }
    try {
      const result = await api.targetsSearch(query);
      const targets = (result && result.targets) || [];
      renderTargetSuggestions(targets);
    } catch (e) {
      // Surface but don't toast — autocomplete failures should not nag the
      // user mid-type. Log so debugging is possible.
      addLogEntry('error', describeApiError(e, 'Target search'));
      hideTargetSuggestions();
    }
  }

  function renderTargetSuggestions(targets) {
    const list = document.getElementById('mount-goto-suggestions');
    const input = document.getElementById('mount-goto-name');
    if (!list) return;
    clearElement(list);
    if (!targets || targets.length === 0) {
      hideTargetSuggestions();
      return;
    }
    // Cap at 8 results — phones don't have room for more.
    const cap = Math.min(8, targets.length);
    for (let i = 0; i < cap; i++) {
      const t = targets[i];
      const item = document.createElement('button');
      item.type = 'button';
      item.className = 'autocomplete-item';
      item.setAttribute('role', 'option');
      item.setAttribute('aria-label',
        t.name + (t.catalogId ? ' (' + t.catalogId + ')' : '') +
        (t.objectType ? ' ' + t.objectType : ''));

      const nameEl = document.createElement('span');
      nameEl.className = 'autocomplete-item__name';
      nameEl.textContent = t.name + (t.catalogId ? '  ' + t.catalogId : '');
      const metaEl = document.createElement('span');
      metaEl.className = 'autocomplete-item__meta';
      const meta = [];
      if (t.objectType) meta.push(t.objectType);
      if (t.constellation) meta.push(t.constellation);
      const magnitude = wireNumber(t.magnitude);
      if (magnitude != null) meta.push('mag ' + magnitude.toFixed(1));
      metaEl.textContent = meta.join(' · ');
      item.appendChild(nameEl);
      item.appendChild(metaEl);
      // mousedown not click: click fires after the input's blur which would
      // already have hidden the dropdown; mousedown wins the race.
      item.addEventListener('mousedown', (e) => {
        e.preventDefault();
        selectTargetSuggestion(t);
      });
      list.appendChild(item);
    }
    list.hidden = false;
    if (input) input.setAttribute('aria-expanded', 'true');
  }

  function selectTargetSuggestion(target) {
    document.getElementById('mount-goto-name').value = target.name || '';
    if (target.ra != null) {
      document.getElementById('mount-goto-ra').value = formatRA(Number(target.ra));
    }
    if (target.dec != null) {
      document.getElementById('mount-goto-dec').value = formatDec(Number(target.dec));
    }
    hideTargetSuggestions();
  }

  function hideTargetSuggestions() {
    const list = document.getElementById('mount-goto-suggestions');
    const input = document.getElementById('mount-goto-name');
    if (list) {
      list.hidden = true;
      clearElement(list);
    }
    if (input) input.setAttribute('aria-expanded', 'false');
  }

  function handleTargetSearchKeyDown(e) {
    if (e.key === 'Escape') {
      hideTargetSuggestions();
    } else if (e.key === 'Enter') {
      // Enter on the name field commits the slew if RA/Dec are populated,
      // otherwise dismisses the dropdown.
      const ra = document.getElementById('mount-goto-ra').value.trim();
      const dec = document.getElementById('mount-goto-dec').value.trim();
      if (ra && dec) {
        e.preventDefault();
        hideTargetSuggestions();
        handleMountGoto();
      }
    }
  }

  // =========================================================================
  // Rendering: Devices Panel
  // =========================================================================

  function renderDevicesPanel() {
    const container = document.getElementById('devices-list');
    if (!container) return;

    clearElement(container);
    if (state.connectedDevices.length === 0) {
      container.appendChild(createEmptyState('No devices connected'));
      return;
    }

    // Group by device type
    const groups = {};
    for (const dev of state.connectedDevices) {
      const type = dev.deviceType || 'unknown';
      if (!groups[type]) groups[type] = [];
      groups[type].push(dev);
    }

    const typeLabels = {
      camera: 'Cameras',
      mount: 'Mounts',
      focuser: 'Focusers',
      filterWheel: 'Filter Wheels',
      rotator: 'Rotators',
      guider: 'Guiders',
      dome: 'Domes',
      safetyMonitor: 'Safety Monitors',
      switch_: 'Switches',
      coverCalibrator: 'Cover Calibrators',
    };

    for (const [type, devices] of Object.entries(groups)) {
      const label = typeLabels[type] || type.charAt(0).toUpperCase() + type.slice(1);
      const groupEl = document.createElement('div');
      groupEl.className = 'device-group';
      const labelEl = document.createElement('div');
      labelEl.className = 'device-group-label';
      labelEl.textContent = label;
      groupEl.appendChild(labelEl);

      for (const dev of devices) {
        const itemEl = document.createElement('div');
        itemEl.className = 'device-item';
        const nameEl = document.createElement('span');
        nameEl.className = 'device-name';
        const statusIconEl = document.createElement('span');
        statusIconEl.className = 'device-status-icon connected';
        statusIconEl.setAttribute('aria-hidden', 'true');
        nameEl.appendChild(statusIconEl);
        nameEl.appendChild(document.createTextNode(' ' + (dev.name || dev.id || 'Unknown device')));

        const badgeEl = document.createElement('span');
        badgeEl.className = 'badge badge-running';
        badgeEl.textContent = dev.driverType || '';

        itemEl.appendChild(nameEl);
        itemEl.appendChild(badgeEl);
        groupEl.appendChild(itemEl);
      }
      container.appendChild(groupEl);
    }
  }

  // =========================================================================
  // Rendering: Camera Panel
  // =========================================================================

  // The live preview is a PER-PROCESS fact. `/api/camera/last-image/jpeg`
  // serves the driver's in-memory buffer, which holds the last exposure taken
  // since the server started and is empty again after a relaunch — while the
  // frames themselves are on disk and listed by `/api/images`. The panel used
  // to print "No image captured yet" over that 404, an absolute measured on
  // the same screen whose gallery said "14 images — 2 rejected". So when the
  // buffer is empty the panel reads the library's newest row and shows THAT,
  // labelled for what it is, and only says nothing was captured when the
  // library is empty too.
  //
  // Read at most once per empty streak: `fetchLastImage` puts it back to
  // 'unread', so the retry cadence is the panel's own (connect, every
  // exposure-complete event, the no-event fallback timer) and a re-render
  // never issues a request.
  const previewFallback = {
    status: 'unread', // 'unread' | 'reading' | 'read' | 'unreadable'
    item: null,
    error: '',
  };

  async function loadPreviewFallback() {
    if (previewFallback.status !== 'unread') return;
    previewFallback.status = 'reading';
    try {
      const resp = await api.imagesGetAll({ limit: 1 });
      // Same two spellings the gallery accepts, for the same reason.
      const named = resp && typeof resp === 'object' &&
        Array.isArray(resp.items) && !Array.isArray(resp.images)
        ? 'items' : 'images';
      const rows = requireWireList(resp, named, 'Image listing');
      previewFallback.item = rows.length ? rows[0] : null;
      previewFallback.error = '';
      previewFallback.status = 'read';
    } catch (e) {
      // The library could not be read, which is NOT the same fact as the
      // library being empty; the panel says so rather than falling back to
      // "nothing was captured".
      previewFallback.item = null;
      previewFallback.error = describeApiError(e, 'Image library');
      previewFallback.status = 'unreadable';
      addLogEntry('error', previewFallback.error);
    }
    await renderImagePreview();
  }

  // What the camera panel shows when this server process has no live preview.
  //
  // Every branch states its sentence twice: once as text in the panel, and
  // once as the container's aria-label, because `role="img"` makes the label
  // the only thing a screen reader hears.
  function renderEmptyLivePreview(container) {
    const noPreview = 'No live preview: this server has taken no exposure ' +
      'since it started.';
    const say = (sentence) => {
      container.setAttribute('aria-label', sentence);
      return sentence;
    };

    if (previewFallback.status === 'read' && previewFallback.item) {
      const item = previewFallback.item;
      const wrap = document.createElement('div');
      wrap.className = 'image-preview-library';
      const meta = formatGalleryMeta(item);
      const rejection = galleryRejection(item);
      const id = String(item.id ?? item.imageId ?? '');
      if (id) {
        const img = document.createElement('img');
        img.alt = 'Last capture in the library: ' + meta;
        img.onerror = () => replaceWithPreviewPlaceholder(img);
        loadGalleryThumbnail(
          img, id, { maxWidth: 1024, quality: 85 },
          replaceWithPreviewPlaceholder,
        );
        wrap.appendChild(img);
      }
      const caption = document.createElement('div');
      caption.className = 'image-preview-library-caption';
      caption.textContent = say('Last capture in the library — ' + meta +
        (rejection ? ' (rejected by the grader)' : '') + '. ' + noPreview);
      wrap.appendChild(caption);
      container.appendChild(wrap);
      return;
    }

    if (previewFallback.status === 'read') {
      container.appendChild(createImagePlaceholder(say(
        'No image captured yet: this server has taken no exposure since it ' +
        'started, and the image library is empty too.',
      )));
      return;
    }

    if (previewFallback.status === 'unreadable') {
      container.appendChild(createImagePlaceholder(say(
        noPreview + ' The image library could not be read, so what it holds ' +
        'is unknown (' + previewFallback.error + ').',
      )));
      return;
    }

    container.appendChild(createImagePlaceholder(say(
      noPreview + ' Looking for the last capture in the image library…',
    )));
    void loadPreviewFallback();
  }

  // A library thumbnail that will not load keeps the slot and says so, in the
  // camera panel's own placeholder rather than the gallery's card-sized one.
  function replaceWithPreviewPlaceholder(img, reason) {
    if (!img || !img.parentNode) return;
    const placeholder = createImagePlaceholder('Preview unavailable');
    if (reason) placeholder.title = String(reason);
    img.parentNode.replaceChild(placeholder, img);
  }

  async function renderImagePreview() {
    const container = document.getElementById('image-preview');
    const statsContainer = document.getElementById('image-stats');
    if (!container || !statsContainer) return;

    const previewBadge = document.getElementById('preview-badge');
    if (previewBadge && previewBadge.parentNode === container) {
      previewBadge.remove();
    }
    clearElement(container);
    if (previewBadge) {
      container.appendChild(previewBadge);
    }
    clearElement(statsContainer);

    // The container is `role="img"`, so its aria-label REPLACES everything
    // inside it for assistive tech — a caption painted into it is not read.
    // Whatever this render decides the panel is showing has to be said here.
    container.setAttribute('aria-label', 'Most recent exposure preview');

    if (!state.lastImage) {
      renderEmptyLivePreview(container);
      updatePreviewBadge();
      return;
    }

    const img = state.lastImage;

    if (state.lastImagePreviewUrl) {
      const el = document.createElement('img');
      el.src = state.lastImagePreviewUrl;
      el.alt = 'Last capture preview';
      el.style.maxWidth = '100%';
      el.style.maxHeight = '200px';
      el.style.objectFit = 'contain';
      container.appendChild(el);
    } else if (img.displayData) {
      // Legacy JSON path (base64 RGBA) — capped at 2 MiB decoded.
      const blob = decodeBase64ImageWithCap(img.displayData);
      if (!blob) {
        container.appendChild(createImagePlaceholder(
          'Image too large for preview (max 2 MiB). Use JPEG preview.',
        ));
      } else {
        try {
          const bitmap = await createImageBitmap(blob);
          const canvas = document.createElement('canvas');
          canvas.width = bitmap.width;
          canvas.height = bitmap.height;
          canvas.style.maxWidth = '100%';
          canvas.style.maxHeight = '200px';
          canvas.style.objectFit = 'contain';
          canvas.setAttribute('aria-label', 'Last capture preview');
          const ctx = canvas.getContext('2d');
          ctx.drawImage(bitmap, 0, 0);
          bitmap.close();
          container.appendChild(canvas);
        } catch (e) {
          addLogEntry('error', describeApiError(e, 'Image decode'));
          container.appendChild(createImagePlaceholder('Failed to decode image'));
        }
      }
    } else {
      container.appendChild(createImagePlaceholder('Preview unavailable'));
    }

    updatePreviewBadge();

    // Render image stats
    if (img.stats) {
      const stat = (raw, digits) => {
        const v = wireNumber(raw);
        return v != null ? v.toFixed(digits) : '--';
      };
      const width = wireNumber(img.width);
      const height = wireNumber(img.height);
      const stats = [
        { label: 'HFR', value: stat(img.stats.hfr, 2) },
        { label: 'Stars', value: stat(img.stats.starCount, 0) },
        { label: 'Mean', value: stat(img.stats.mean, 0) },
        { label: 'Median', value: stat(img.stats.median, 0) },
        { label: 'StdDev', value: stat(img.stats.stdDev, 0) },
        { label: 'Size', value: width != null && height != null
          ? width + 'x' + height : '--' },
        { label: 'Raw', value: rawStatLabel(), valueClass: rawStatClass() },
      ];
      for (const s of stats) {
        const itemEl = document.createElement('div');
        itemEl.className = 'image-stat';
        const labelEl = document.createElement('span');
        labelEl.className = 'image-stat-label';
        labelEl.textContent = s.label;
        const valueEl = document.createElement('span');
        valueEl.className = 'image-stat-value' + (s.valueClass ? ' ' + s.valueClass : '');
        valueEl.textContent = String(s.value);
        itemEl.appendChild(labelEl);
        itemEl.appendChild(valueEl);
        statsContainer.appendChild(itemEl);
      }
    }
  }

  /**
   * Validate a base64 string, enforce the 2 MiB cap, and decode to a Blob
   * so createImageBitmap can run off the main thread. Returns null when the
   * data is missing, malformed, or too large.
   */
  function decodeBase64ImageWithCap(b64) {
    if (!b64 || typeof b64 !== 'string') return null;
    // Each 4 chars of base64 decode to 3 bytes; this estimate is enough to
    // reject obviously-oversized inputs before we allocate.
    const approxBytes = Math.floor(b64.length * 3 / 4);
    if (approxBytes > MAX_IMAGE_BYTES) return null;
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(b64)) return null;
    try {
      const binary = atob(b64);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
      }
      // PNG and JPEG both work as image/* — the browser sniffs the magic
      // bytes. Use image/png since the server documents this as PNG/JPEG.
      return new Blob([bytes], { type: 'image/png' });
    } catch (_) {
      return null;
    }
  }

  /// Same state-gating contract as updateSequencerButtons for the camera:
  /// Expose is inert mid-exposure and Abort is inert when idle, and the cooler
  /// On/Off pair mirror each other so only the admissible one stays live. A
  /// connected camera with an unknown field fails open; a disconnected camera
  /// is already disabled wholesale by refreshPanelEnablement.
  function updateCameraButtons(status) {
    if (!status) return;
    const set = (id, enabled) => {
      const el = document.getElementById(id);
      if (el) el.disabled = !enabled;
    };
    const raw = status.state ?? status.cameraState;
    const s = raw != null ? String(raw).toLowerCase() : '';
    const known = s !== '';
    const busy = s === 'exposing' || s === 'waiting' || s === 'reading' || s === 'download';
    set('btn-expose', !known || !busy);
    set('btn-abort-expose', !known || busy);
    const coolerOn = status.coolerOn;
    set('btn-camera-cooler-on', coolerOn !== true);
    set('btn-camera-cooler-off', coolerOn !== false);
  }

  function renderCameraStatusInfo() {
    updateCameraButtons(state.cameraStatus);
    const el = document.getElementById('camera-status-info');
    if (!el) return;

    clearElement(el);
    if (!state.cameraStatus) {
      return;
    }

    const cs = state.cameraStatus;

    if (cs.cameraState !== undefined) {
      el.appendChild(createStatusRow('State', String(cs.cameraState)));
    }
    // A row is omitted when the camera reports no figure, and that is the only
    // reason it may be omitted: `ccdTemperature: null` used to reach
    // `null.toFixed` and throw, taking the Cooler and Exposure rows below it
    // off the panel along with the temperature — a cooling camera rendered as
    // a camera with no cooler at all.
    const ccdTemperature = wireNumber(cs.ccdTemperature);
    if (ccdTemperature != null) {
      const tempClass = ccdTemperature <= -10
        ? 'good' : ccdTemperature <= 0 ? 'warn' : 'error';
      el.appendChild(
        createStatusRow('Temp', ccdTemperature.toFixed(1) + ' C', tempClass));
    }
    const coolerPower = wireNumber(cs.coolerPower);
    if (coolerPower != null) {
      el.appendChild(createStatusRow('Cooler', coolerPower.toFixed(0) + '%'));
    }
    const percentCompleted = wireNumber(cs.percentCompleted);
    if (percentCompleted != null && percentCompleted > 0) {
      el.appendChild(
        createStatusRow('Exposure', percentCompleted.toFixed(0) + '%', 'info'));
    }
  }

  // =========================================================================
  // Rendering: Mount Panel
  // =========================================================================

  /// Same state-gating contract as updateSequencerButtons for the mount: Park
  /// is inert when parked, Unpark when unparked, Abort Slew when nothing is
  /// slewing, and every slew (Goto, the d-pad, the tracking toggle) is
  /// inadmissible while parked. Unknown fields fail open; the emergency STOP is
  /// left to refreshPanelEnablement, which keeps it live whenever connected.
  function updateMountButtons(status) {
    if (!status) return;
    const set = (id, enabled) => {
      const el = document.getElementById(id);
      if (el) el.disabled = !enabled;
    };
    const parked = status.parked ?? status.isParked;
    const slewing = status.slewing ?? status.isSlewing;
    const canMove = parked !== true;
    set('btn-mount-park', parked !== true);
    set('btn-mount-unpark', parked !== false);
    set('btn-mount-tracking', canMove);
    set('btn-mount-goto', canMove);
    set('btn-mount-n', canMove);
    set('btn-mount-s', canMove);
    set('btn-mount-e', canMove);
    set('btn-mount-w', canMove);
    set('btn-mount-goto-abort', slewing !== false);
  }

  function renderMountPanel() {
    if (!state.mountStatus) return;

    const ms = state.mountStatus;
    updateMountButtons(ms);

    // RA/Dec display
    const raEl = document.getElementById('mount-ra');
    const decEl = document.getElementById('mount-dec');
    if (raEl && ms.rightAscension !== undefined) {
      raEl.textContent = formatRA(ms.rightAscension);
    }
    if (decEl && ms.declination !== undefined) {
      decEl.textContent = formatDec(ms.declination);
    }

    // Tracking status
    const trackBtn = document.getElementById('btn-mount-tracking');
    if (trackBtn && ms.isTracking !== undefined) {
      trackBtn.textContent = ms.isTracking ? 'Tracking ON' : 'Tracking OFF';
      trackBtn.className = ms.isTracking ? 'btn btn-sm btn-success' : 'btn btn-sm';
    }

    // Slewing indicator
    const slewEl = document.getElementById('mount-slewing');
    if (slewEl) {
      slewEl.classList.toggle('hidden-inline', !ms.isSlewing);
    }

    // Pier side — centralised formatter.
    const pierEl = document.getElementById('mount-pier');
    if (pierEl && ms.sideOfPier !== undefined) {
      pierEl.textContent = formatPierSide(ms.sideOfPier);
    }

    // Alt/Az
    const altEl = document.getElementById('mount-alt');
    const azEl = document.getElementById('mount-az');
    const altitude = wireNumber(ms.altitude);
    const azimuth = wireNumber(ms.azimuth);
    if (altEl) {
      altEl.textContent = altitude != null ? altitude.toFixed(1) + '°' : '--';
    }
    if (azEl) {
      azEl.textContent = azimuth != null ? azimuth.toFixed(1) + '°' : '--';
    }
  }

  /**
   * Map the ASCOM PierSide integer to a human label. Backend returns:
   *   1  → pierEast    (counterweight points west; tube points east)
   *   0  → pierWest    (counterweight points east; tube points west)
   *  -1  → pierUnknown
   * Some drivers (or already-resolved API responses) send the string label
   * directly; pass that through unchanged.
   */
  function formatPierSide(value) {
    if (typeof value === 'string' && value.length > 0) return value;
    const n = Number(value);
    if (n === 1) return 'East';
    if (n === 0) return 'West';
    if (n === -1) return 'Unknown';
    return '--';
  }

  // =========================================================================
  // Rendering: Sequencer Panel
  // =========================================================================

  /// Show/hide the pairing/token bar, keeping the compact "Auth" chip in
  /// the top bar as the re-entry point whenever the bar is collapsed on an
  /// auth-requiring server.
  function setAuthBarVisible(visible) {
    const bar = document.getElementById('auth-bar');
    const reveal = document.getElementById('btn-auth-reveal');
    if (bar) bar.classList.toggle('hidden', !visible);
    const authRequired = Boolean(state.serverInfo && state.serverInfo.authRequired);
    if (reveal) {
      reveal.classList.toggle('hidden', !authRequired);
      reveal.setAttribute('aria-expanded', visible ? 'true' : 'false');
      reveal.setAttribute(
        'aria-label',
        visible
          ? 'Hide pairing and token controls'
          : 'Show pairing and token controls',
      );
    }
  }

  /// Enable exactly the run controls the executor state admits. Before this
  /// every button was always tappable — at IDLE, Pause/Resume/Stop looked
  /// live, fired a request, and surfaced an error toast; in the dark on a
  /// phone that reads as "the rig is broken", not "wrong button".
  function updateSequencerButtons(stateStr) {
    const s = String(stateStr || 'idle').toLowerCase().replace(/[_\s]/g, '');
    const set = (id, enabled) => {
      const el = document.getElementById(id);
      if (!el) return;
      // A control the rig has already refused for this credential stays
      // refused, whatever the run state would otherwise admit — the next
      // status poll used to hand it straight back.
      const refusal = refusedControls.get(id);
      if (refusal) {
        el.disabled = true;
        el.title = refusal;
        return;
      }
      el.disabled = !enabled;
    };
    const running = s === 'running' || s === 'executing';
    const paused = s === 'paused';
    const transitional = s === 'stopping' || s === 'finalizing';
    const recovering = s === 'recovering';
    const stopRetry = s === 'stopfailed' || s === 'cleanupfailed';
    set('btn-seq-start', !running && !paused && !transitional && !recovering && !stopRetry);
    set('btn-seq-pause', running);
    set('btn-seq-resume', paused);
    set('btn-seq-stop', running || paused || recovering || stopRetry);
  }

  /// The run state a `/api/sequencer/status` reply actually names, or null
  /// when it names none.
  ///
  /// `state` is documented non-null (`SequencerStatus.state` in
  /// packages/skotiq_core/lib/src/models/backend/sequencer_status.dart),
  /// so a null, empty or non-string value is a reply that declined to say.
  /// The panel read `s.state || 'idle'`, which turned exactly that into the
  /// word "idle" — a parked telescope — beside "0%" and aria-valuenow="0",
  /// announcing "0 percent" for a figure the server explicitly refused to
  /// supply. `/run-watch` renders the same wire as UNKNOWN.
  function sequencerStateOf(status) {
    if (!status) return null;
    const raw = status.state;
    if (typeof raw !== 'string') return null;
    const named = raw.trim();
    return named === '' ? null : named;
  }

  // `/api/sequencer/status` reports `progress` as a 0..1 FRACTION — see
  // `SequencerStatus.progress` ("Overall progress (0.0 to 1.0)") in
  // packages/skotiq_core/lib/src/models/backend/sequencer_status.dart,
  // which `sequencer_handlers.dart` passes through verbatim. Every dashboard
  // readout (text, bar width, aria-valuenow on a 0..100 progressbar, ETA
  // extrapolation) wants percent, so convert at the single point where the
  // fraction enters the render path. Without this a finished run rendered
  // "1%" with an empty bar. `/run-watch` already scales its own feed by 100.
  //
  // A wire that carries no number gets null, not 0. `/api/sequencer/status`
  // withholds `progress` on a rig that has never run — the same nulls
  // `/api/run-watch/snapshot` has always published there — and `Number(null)`
  // is 0, so the panels asserted "Progress 0%" with aria-valuenow="0" about a
  // fresh install that had never exposed a frame, beside a Current Node and a
  // Current target that both honestly read "--". Null is the absence of a
  // measurement and the renderers paint it with markProgressUnknown().
  function sequencerProgressPercent(raw) {
    if (raw == null || raw === '') return null;
    const n = Number(raw);
    if (!Number.isFinite(n)) return null;
    return Math.min(100, Math.max(0, n * 100));
  }

  // Paint a progress readout as UNKNOWN — no figure, no announcement, and a
  // bar that does not look like a run that has done nothing yet.
  //
  // An empty bar is a claim: it says "0% complete". That claim is true on a
  // rig that has just started and false on one whose backend died at 25%, and
  // both used to render identically down to the pixel. The `unknown` class
  // gives the track its own hatched fill, so an operator can tell "nothing has
  // happened" from "we have no idea" without reading the number.
  //
  // aria-valuenow is REMOVED rather than zeroed: a progressbar with no value is
  // announced as indeterminate, which is the truth, while aria-valuenow="0"
  // announces "0 percent" — a figure nobody sent.
  function markProgressUnknown(barId, containerId, textId) {
    const bar = document.getElementById(barId);
    if (bar) {
      bar.style.width = '0%';
      bar.classList.remove('completed');
      bar.classList.add('unknown');
    }
    const container = document.getElementById(containerId);
    if (container) {
      container.classList.add('unknown');
      container.removeAttribute('aria-valuenow');
    }
    if (textId) {
      const text = document.getElementById(textId);
      if (text) text.textContent = '--';
    }
  }

  // The other half of [markProgressUnknown]: a bar that has a real figure again
  // must stop wearing the unknown treatment.
  function markProgressKnown(barId, containerId) {
    const bar = document.getElementById(barId);
    if (bar) bar.classList.remove('unknown');
    const container = document.getElementById(containerId);
    if (container) container.classList.remove('unknown');
  }

  function renderSequencerPanel() {
    // Same gate as the ops mirror below: this fires on sequencer events and on
    // the recovery edge, and a repaint from the cached status while the route
    // is still refusing would put the frozen run back on screen.
    if (runDataIsStale()) {
      paintRunUnknown();
      return;
    }
    const statusEl = document.getElementById('seq-status');
    const nodeEl = document.getElementById('seq-node');
    const messageEl = document.getElementById('seq-message');
    const progressBar = document.getElementById('seq-progress-bar');
    const progressBarContainer = document.getElementById('seq-progress-bar-container');
    const progressText = document.getElementById('seq-progress-text');

    if (!state.sequencerStatus) {
      // No status has arrived. "idle" here was an assertion about a rig this
      // page had never heard from — a run in progress reads as a parked
      // telescope until the first answer lands. Say what is actually true:
      // we are still connecting. The bar is indeterminate, so it carries no
      // aria-valuenow — announcing "0 percent" would state a progress figure
      // the server never sent.
      if (statusEl) renderBadge(statusEl, 'connecting', 'badge-idle');
      if (nodeEl) nodeEl.textContent = '--';
      if (messageEl) messageEl.textContent = '';
      markProgressUnknown('seq-progress-bar', 'seq-progress-bar-container');
      if (progressText) progressText.textContent = '';
      updateSequencerButtons('idle');
      return;
    }

    const s = state.sequencerStatus;
    const runState = sequencerStateOf(s);
    if (runState == null) {
      // The reply arrived and named no state. The panel has nothing to assert
      // and says so on the same surface a dead route gets — the treatment a
      // malformed reply already received, and the one /run-watch gives this
      // exact payload.
      updateSequencerButtons(null);
      paintRunUnknown();
      return;
    }
    updateSequencerButtons(runState);

    if (statusEl) {
      const badgeClass = getSequencerBadgeClass(runState);
      renderBadge(statusEl, runState, badgeClass);
    }

    if (nodeEl) nodeEl.textContent = s.currentNodeName || '--';
    if (messageEl) messageEl.textContent = s.message || '';

    const progress = sequencerProgressPercent(s.progress);
    if (progress == null) {
      // The reply named a state but withheld the figure. That is what a rig
      // which has never run answers, and "--" is what the rest of this panel
      // already says about it.
      markProgressUnknown('seq-progress-bar', 'seq-progress-bar-container',
        'seq-progress-text');
      renderOpsSequencerLoadPanel();
      return;
    }
    markProgressKnown('seq-progress-bar', 'seq-progress-bar-container');
    if (progressBar) {
      progressBar.style.width = progress + '%';
      if (progress >= 100) progressBar.classList.add('completed');
      else progressBar.classList.remove('completed');
    }
    if (progressBarContainer) {
      progressBarContainer.setAttribute('aria-valuenow', String(Math.round(progress)));
    }
    if (progressText) progressText.textContent = progress.toFixed(0) + '%';
    // Keep the ops sequencer load/run panel in lock step with the main
    // sequencer panel. They read the same state but render different
    // field sets.
    renderOpsSequencerLoadPanel();
  }

  function getSequencerBadgeClass(stateStr) {
    if (!stateStr) return 'badge-idle';
    const s = stateStr.toLowerCase();
    if (s === 'running' || s === 'executing') return 'badge-running';
    if (s === 'paused') return 'badge-paused';
    if (s === 'error' || s === 'failed') return 'badge-error';
    if (s === 'completed' || s === 'done') return 'badge-completed';
    return 'badge-idle';
  }

  // =========================================================================
  // Rendering: Guiding Panel
  // =========================================================================

  function renderGuidingPanel() {
    const statusEl = document.getElementById('guide-status');
    const raRmsEl = document.getElementById('guide-ra-rms');
    const decRmsEl = document.getElementById('guide-dec-rms');
    const totalRmsEl = document.getElementById('guide-total-rms');

    if (!state.guidingStatus) {
      if (statusEl) renderBadge(statusEl, 'disconnected', 'badge-idle');
      if (raRmsEl) raRmsEl.textContent = '--';
      if (decRmsEl) decRmsEl.textContent = '--';
      if (totalRmsEl) totalRmsEl.textContent = '--';
      updateGuidingButtons('disconnected');
      return;
    }

    const g = state.guidingStatus;

    if (statusEl) {
      const guidingState = g.state || g.appState || 'unknown';
      const isGuiding = String(guidingState).toLowerCase().includes('guid');
      const badgeClass = isGuiding ? 'badge-running' : 'badge-idle';
      renderBadge(statusEl, guidingState, badgeClass);
    }
    updateGuidingButtons(g.state || g.appState || 'unknown');

    // RMS values. Two corrections live here:
    //
    //  * The key is `rmsRa`, not `rmsRA` (GET /api/phd2/status). The capitalised
    //    spelling matched nothing, so the RA row never left "--" even while
    //    guiding.
    //  * A disconnected PHD2 reports 0.0 for all three. Rendering that gave a
    //    dead guider a flawless 0.00" RMS — the most reassuring possible
    //    reading of no data at all. Only a connected guider's numbers show.
    const connected = g.connected === true;
    const rms = (v) => (connected && typeof v === 'number' && isFinite(v))
      ? v.toFixed(2) + '"'
      : '--';
    if (raRmsEl) raRmsEl.textContent = rms(g.rmsRa);
    if (decRmsEl) decRmsEl.textContent = rms(g.rmsDec);
    if (totalRmsEl) totalRmsEl.textContent = rms(g.rmsTotal);
  }

  /// Same state-gating contract as updateSequencerButtons: only offer the
  /// guider actions the current PHD2 state admits, instead of four
  /// always-live buttons that error-toast when mistapped.
  function updateGuidingButtons(stateStr) {
    const s = String(stateStr || 'disconnected').toLowerCase();
    const set = (id, enabled) => {
      const el = document.getElementById(id);
      if (el) el.disabled = !enabled;
    };
    const disconnected = s === 'disconnected' || s === 'unknown';
    const guiding = s.includes('guid') && !s.includes('stop');
    const paused = s === 'paused';
    set('btn-guide-connect', disconnected);
    set('btn-guide-start', !disconnected && !guiding);
    set('btn-guide-pause', guiding && !paused);
    set('btn-guide-stop', guiding || paused);
    set('btn-guide-dither', guiding && !paused);
  }

  function addGuideDataPoint(ra, dec) {
    state.guideHistory.ra.push(ra);
    state.guideHistory.dec.push(dec);

    if (state.guideHistory.ra.length > state.maxGuidePoints) {
      state.guideHistory.ra.shift();
      state.guideHistory.dec.shift();
    }

    drawGuideGraph();
  }

  // =========================================================================
  // Guide Graph (Canvas)
  // =========================================================================

  function setupGuideCanvas() {
    const canvas = document.getElementById('guide-canvas');
    if (!canvas) return;

    const resizeCanvas = () => {
      const container = canvas.parentElement;
      canvas.width = container.clientWidth;
      canvas.height = container.clientHeight;
      drawGuideGraph();
    };

    window.addEventListener('resize', resizeCanvas);
    resizeCanvas();
  }

  function drawGuideGraph() {
    const canvas = document.getElementById('guide-canvas');
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    const w = canvas.width;
    const h = canvas.height;

    ctx.fillStyle = themeColor('--color-background');
    ctx.fillRect(0, 0, w, h);

    ctx.strokeStyle = themeColor('--color-surface-alt');
    ctx.lineWidth = 1;
    const midY = h / 2;

    ctx.beginPath();
    ctx.moveTo(0, midY);
    ctx.lineTo(w, midY);
    ctx.stroke();

    ctx.strokeStyle = themeColor('--color-surface');
    for (const frac of [0.25, 0.75]) {
      ctx.beginPath();
      ctx.moveTo(0, h * frac);
      ctx.lineTo(w, h * frac);
      ctx.stroke();
    }

    const raData = state.guideHistory.ra;
    const decData = state.guideHistory.dec;
    if (raData.length < 2) return;

    let maxVal = 2; // minimum scale of 2 arcsec
    for (let i = 0; i < raData.length; i++) {
      maxVal = Math.max(maxVal, Math.abs(raData[i]), Math.abs(decData[i]));
    }
    maxVal *= 1.2;

    const xStep = w / (state.maxGuidePoints - 1);

    ctx.strokeStyle = themeColor('--color-primary');
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    for (let i = 0; i < raData.length; i++) {
      const x = i * xStep;
      const y = midY - (raData[i] / maxVal) * midY;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();

    ctx.strokeStyle = themeColor('--color-error');
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    for (let i = 0; i < decData.length; i++) {
      const x = i * xStep;
      const y = midY - (decData[i] / maxVal) * midY;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();

    ctx.fillStyle = themeColor('--color-text-muted');
    ctx.font = '10px sans-serif';
    ctx.fillText('+' + maxVal.toFixed(1) + '"', 4, 12);
    ctx.fillText('-' + maxVal.toFixed(1) + '"', 4, h - 4);
  }

  // =========================================================================
  // Log Panel
  // =========================================================================

  function addLogEntry(category, message) {
    const now = new Date();
    const ts = now.toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });

    state.logEntries.push({ ts, category, message });
    if (state.logEntries.length > state.maxLogEntries) {
      state.logEntries.shift();
    }

    renderLogEntry(ts, category, message);
  }

  function renderLogEntry(ts, category, message) {
    const container = document.getElementById('log-container');
    if (!container) return;

    const emptyState = container.querySelector('.empty-state');
    if (emptyState) emptyState.remove();

    const entry = document.createElement('div');
    entry.className = 'log-entry';

    const catClass = getCategoryClass(category);
    const timestampEl = document.createElement('span');
    timestampEl.className = 'log-timestamp';
    timestampEl.textContent = ts;
    const categoryEl = document.createElement('span');
    categoryEl.className = 'log-category ' + catClass;
    categoryEl.textContent = category;
    const messageEl = document.createElement('span');
    messageEl.className = 'log-message';
    messageEl.textContent = message;
    entry.appendChild(timestampEl);
    entry.appendChild(categoryEl);
    entry.appendChild(messageEl);

    container.appendChild(entry);

    // Auto-scroll to bottom
    container.scrollTop = container.scrollHeight;
  }

  function getCategoryClass(cat) {
    if (!cat) return '';
    const c = cat.toLowerCase();
    if (c === 'camera' || c === 'imaging') return 'camera';
    if (c === 'mount') return 'mount';
    if (c === 'focuser') return 'focuser';
    if (c === 'guiding' || c === 'phd2') return 'guiding';
    if (c === 'sequencer') return 'sequencer';
    if (c === 'error') return 'error';
    return 'system';
  }

  function clearLog() {
    state.logEntries = [];
    const container = document.getElementById('log-container');
    if (container) {
      clearElement(container);
      container.appendChild(createEmptyState('Log cleared'));
    }
  }

  // =========================================================================
  // Phone Layout
  // =========================================================================

  function applyResponsiveLayout() {
    const phone = window.matchMedia('(max-width: 600px)').matches;
    document.body.classList.toggle('layout--phone', phone);
    if (phone) {
      activatePhoneTab(state.activePhoneTab);
    } else {
      // Make every panel visible again on tablet/desktop.
      for (const id of allPhonePanelIds()) {
        const p = document.getElementById(id);
        if (p) p.classList.remove('phone-active');
      }
      // Guiding panel is reachable on phone via the Sequencer tab grouping
      // would hide it — leave it visible in the regular grid.
      const guiding = document.getElementById('panel-guiding');
      if (guiding) guiding.classList.remove('phone-active');
    }
  }

  // All panels that participate in the phone-tab visibility toggle: the
  // primary tab panels plus their grouped "extra" panels.
  function allPhonePanelIds() {
    const ids = [...PHONE_PANELS];
    for (const extras of Object.values(PHONE_TAB_EXTRA_PANELS)) {
      for (const e of extras) ids.push(e);
    }
    return ids;
  }

  function activatePhoneTab(panelId) {
    if (!PHONE_PANELS.includes(panelId)) return;
    state.activePhoneTab = panelId;
    const extras = PHONE_TAB_EXTRA_PANELS[panelId] || [];
    const visibleSet = new Set([panelId, ...extras]);
    for (const id of allPhonePanelIds()) {
      const p = document.getElementById(id);
      if (p) p.classList.toggle('phone-active', visibleSet.has(id));
    }
    // Hide the guiding panel on phone (it's accessible via the desktop layout
    // when rotating). Keeping it out of the tab strip avoids overcrowding the
    // 5-slot bar.
    const guiding = document.getElementById('panel-guiding');
    if (guiding) guiding.classList.remove('phone-active');

    for (const tab of document.querySelectorAll('.phone-tab')) {
      tab.setAttribute('aria-selected', tab.dataset.target === panelId ? 'true' : 'false');
    }
  }

  // =========================================================================
  // Utilities
  // =========================================================================

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  // `isNaN` coerces before it tests, so the old guard passed `[]` and `true`
  // straight through: an empty array printed "00h 00m 0.0s" — the pole, from a
  // payload that named no coordinate at all — and `true` printed 01h. Both
  // reach here from the wire (a target row, a mount status, a solve result),
  // so the gate is the type check, not the coercion.
  function formatRA(raHours) {
    const hours = wireNumber(raHours);
    if (hours == null) return '--h --m --s';
    const h = Math.floor(hours);
    const m = Math.floor((hours - h) * 60);
    const s = ((hours - h) * 60 - m) * 60;
    return pad2(h) + 'h ' + pad2(m) + 'm ' + pad2(s.toFixed(1)) + 's';
  }

  function formatDec(decDegrees) {
    const decDeg = wireNumber(decDegrees);
    if (decDeg == null) return '--° --\' --"';
    const sign = decDeg >= 0 ? '+' : '-';
    const abs = Math.abs(decDeg);
    const d = Math.floor(abs);
    const m = Math.floor((abs - d) * 60);
    const s = ((abs - d) * 60 - m) * 60;
    return sign + pad2(d) + '° ' + pad2(m) + "' " + pad2(s.toFixed(0)) + '"';
  }

  function pad2(val) {
    const s = String(val);
    return s.length < 2 ? '0' + s : s;
  }

  // There is deliberately no escapeHtml helper. Every rendering site uses
  // textContent / appendChild, which DOM-escapes automatically; a helper here
  // would invite reaching for innerHTML.

  function clearElement(el) {
    while (el.firstChild) {
      el.removeChild(el.firstChild);
    }
  }

  function createEmptyState(message) {
    const el = document.createElement('div');
    el.className = 'empty-state';
    el.textContent = message;
    return el;
  }

  function createImagePlaceholder(message) {
    const el = document.createElement('div');
    el.className = 'image-preview-placeholder';
    el.textContent = message;
    return el;
  }

  function createStatusRow(label, value, valueClass) {
    const row = document.createElement('div');
    row.className = 'status-row';
    const labelEl = document.createElement('span');
    labelEl.className = 'status-label';
    labelEl.textContent = label;
    const valueEl = document.createElement('span');
    valueEl.className = valueClass ? 'status-value ' + valueClass : 'status-value';
    valueEl.textContent = value;
    row.appendChild(labelEl);
    row.appendChild(valueEl);
    return row;
  }

  function renderBadge(container, label, badgeClass) {
    clearElement(container);
    const badge = document.createElement('span');
    badge.className = 'badge ' + badgeClass;
    badge.textContent = label;
    container.appendChild(badge);
  }

  // =========================================================================
  // Toast Notifications
  // =========================================================================

  function showToast(message, type) {
    const container = document.getElementById('toast-container');
    if (!container) return;

    const toast = document.createElement('div');
    toast.className = 'toast' + (type ? ' ' + type : '');
    toast.setAttribute('role', type === 'error' ? 'alert' : 'status');
    toast.textContent = message;
    container.appendChild(toast);

    setTimeout(() => {
      toast.classList.add('fading-out');
      setTimeout(() => toast.remove(), 300);
    }, 4000);
  }

  // ===========================================================================
  // Ops panels
  // ===========================================================================
  //
  // All handlers/renderers below own the seven ops panels: sequence load,
  // target catalog, weather + safety, dome, checkpoint resume, profile +
  // analytics. The setup() entry point wires DOM listeners; the fetchOps*
  // functions are called from fetchAllStatus and from the WS event handler.
  // Every id/class in this section carries the `ops-` prefix.

  function setupOpsPanels() {
    // --- Sequence load + start --------------------------------------------
    const seqRefreshBtn = document.getElementById('ops-btn-seq-refresh');
    if (seqRefreshBtn) {
      seqRefreshBtn.addEventListener('click', fetchOpsSequences);
    }
    const seqLoadStartBtn = document.getElementById('ops-btn-seq-load-start');
    if (seqLoadStartBtn) {
      seqLoadStartBtn.addEventListener('click', handleOpsSeqLoadStart);
    }
    const seqAbortBtn = document.getElementById('ops-btn-seq-abort');
    if (seqAbortBtn) {
      seqAbortBtn.addEventListener('click', handleOpsSeqAbort);
    }
    const seqSelect = document.getElementById('ops-seq-select');
    if (seqSelect) {
      seqSelect.addEventListener('change', () => {
        state.ops.selectedSequenceId = seqSelect.value || '';
      });
    }

    // --- Target catalog ---------------------------------------------------
    const targetSearch = document.getElementById('ops-target-search');
    if (targetSearch) {
      targetSearch.addEventListener('input', handleOpsTargetSearchInput);
    }

    // --- Dome controls ----------------------------------------------------
    const domeOpenBtn = document.getElementById('ops-btn-dome-open');
    if (domeOpenBtn) {
      domeOpenBtn.addEventListener('click', handleOpsDomeOpen);
    }
    const domeCloseBtn = document.getElementById('ops-btn-dome-close');
    if (domeCloseBtn) {
      domeCloseBtn.addEventListener('click', handleOpsDomeClose);
    }
    const domeParkBtn = document.getElementById('ops-btn-dome-park');
    if (domeParkBtn) {
      domeParkBtn.addEventListener('click', handleOpsDomePark);
    }
    const domeSlewBtn = document.getElementById('ops-btn-dome-slew');
    if (domeSlewBtn) {
      domeSlewBtn.addEventListener('click', handleOpsDomeSlew);
    }
    const domeSyncOnBtn = document.getElementById('ops-btn-dome-sync-on');
    if (domeSyncOnBtn) {
      domeSyncOnBtn.addEventListener('click', () => handleOpsDomeSync(true));
    }
    const domeSyncOffBtn = document.getElementById('ops-btn-dome-sync-off');
    if (domeSyncOffBtn) {
      domeSyncOffBtn.addEventListener('click', () => handleOpsDomeSync(false));
    }

    // --- Checkpoint resume ------------------------------------------------
    const checkpointRefreshBtn = document.getElementById(
      'ops-btn-checkpoint-refresh');
    if (checkpointRefreshBtn) {
      checkpointRefreshBtn.addEventListener('click', fetchOpsCheckpoints);
    }

    // --- Profile switching ------------------------------------------------
    const profileActivateBtn = document.getElementById(
      'ops-btn-profile-activate');
    if (profileActivateBtn) {
      profileActivateBtn.addEventListener('click', handleOpsProfileActivate);
    }
    const profileReloadBtn = document.getElementById('ops-btn-profile-reload');
    if (profileReloadBtn) {
      profileReloadBtn.addEventListener('click', handleOpsProfileReload);
    }

    // First-paint placeholders so the UI doesn't show blank rows before any
    // network calls return.
    renderOpsSequencerLoadPanel();
    renderOpsWeatherPanel();
    renderOpsDomePanel();
    renderOpsCheckpointPanel();
    renderOpsProfilePanel();
    renderOpsAnalyticsPanel();
  }

  // ---------------------------------------------------------------------------
  // Sequence load + run
  // ---------------------------------------------------------------------------

  async function fetchOpsSequences() {
    try {
      const result = await api.sequencerList();
      state.ops.sequences = requireWireList(result, 'sequences', 'Sequence list');
      markPanelFresh('sequences');
      renderOpsSequencesDropdown();
    } catch (e) {
      reportRefreshFailure('sequences', e, 'Sequence list fetch');
    }
  }

  function renderOpsSequencesDropdown() {
    const sel = document.getElementById('ops-seq-select');
    if (!sel) return;
    const previous = state.ops.selectedSequenceId;
    clearElement(sel);
    const placeholder = document.createElement('option');
    placeholder.value = '';
    placeholder.textContent = state.ops.sequences.length === 0
      ? '-- no saved sequences --'
      : '-- select a sequence --';
    sel.appendChild(placeholder);
    for (const seq of state.ops.sequences) {
      // Templates are listed via a separate endpoint and intentionally
      // excluded here — the ops panel runs concrete sequences only.
      if (seq.isTemplate) continue;
      const opt = document.createElement('option');
      opt.value = String(seq.id);
      opt.textContent = seq.name || ('Sequence #' + seq.id);
      if (String(seq.id) === String(previous)) opt.selected = true;
      sel.appendChild(opt);
    }
  }

  async function handleOpsSeqLoadStart() {
    const sel = document.getElementById('ops-seq-select');
    const id = sel ? sel.value : '';
    if (!id) {
      showToast('Pick a sequence to load', 'error');
      return;
    }
    try {
      await api.sequencerLoadAndStart(id);
      addLogEntry('sequencer', 'Loaded and started sequence id=' + id);
      showToast('Sequence started');
      state.ops.sequenceStartedAt = Date.now();
      // Refresh dependent panels immediately so the operator sees the new
      // running state without waiting for the next poll tick.
      fetchSequencerStatus();
      fetchOpsCheckpoints();
      fetchOpsAnalyticsSummary();
    } catch (e) {
      addLogEntry('error', 'Sequence load+start failed: ' + e.message);
      showToast('Load failed: ' + e.message, 'error');
    }
  }

  async function handleOpsSeqAbort() {
    try {
      await api.sequencerAbort();
      addLogEntry('sequencer', 'Sequence aborted from ops panel');
      showToast('Sequence aborted');
    } catch (e) {
      addLogEntry('error', describeApiError(e, 'Sequence abort'));
      showToast('Abort failed: ' + e.message, 'error');
    }
  }

  // Render the "current target / ETA / progress" block. Why a separate render
  // from the main sequencer panel: this panel also shows the load-time
  // dropdown + buttons, and reading from the same `state.sequencerStatus`
  // lets WS-driven updates flow into both places.
  function renderOpsSequencerLoadPanel() {
    // This panel quotes the same cached status the Run panel does, and it is
    // repainted by sibling fetches (analytics, slew, first paint) that go on
    // succeeding while the sequencer route fails. Without this gate those
    // repaints put the frozen run straight back after the clock cleared it.
    if (runDataIsStale()) {
      paintRunUnknown();
      return;
    }
    const targetEl = document.getElementById('ops-seq-current-target');
    const nodeEl = document.getElementById('ops-seq-current-node');
    const progressTextEl = document.getElementById('ops-seq-progress-text');
    const progressBar = document.getElementById('ops-seq-progress-bar');
    const progressBarContainer = document.getElementById(
      'ops-seq-progress-bar-container');
    const etaEl = document.getElementById('ops-seq-eta');

    if (!state.sequencerStatus) {
      if (targetEl) targetEl.textContent = '--';
      if (nodeEl) nodeEl.textContent = '--';
      if (etaEl) etaEl.textContent = '--';
      // Same rule as renderSequencerPanel: unknown progress carries no
      // aria-valuenow at all, and does not draw as an empty bar.
      markProgressUnknown(
        'ops-seq-progress-bar',
        'ops-seq-progress-bar-container',
        'ops-seq-progress-text',
      );
      return;
    }
    const s = state.sequencerStatus;
    // The TARGET, from the field that carries it. `/api/sequencer/status` now
    // publishes `currentTarget` — the executor's own `SequenceProgress`
    // target, the same one `/api/run-watch/snapshot` has always carried.
    //
    // What this replaces: the analytics session name, falling back to the
    // current node's name. On a headless run the imaging session is named
    // after the SEQUENCE, so a target called "M Long Field" rendered as
    // "M long night" for the whole run; once the run ended and the session
    // went null, the fallback named the Loop ROOT NODE and the field read
    // "Live root". Mid-autofocus it read "Autofocus (HFR Degradation)". The
    // panel never once showed the target. A run that has named no target
    // leaves this unknown, and unknown renders as "--" — not as the nearest
    // string to hand.
    if (targetEl) targetEl.textContent = s.currentTarget || '--';
    if (nodeEl) nodeEl.textContent = s.currentNodeName || '--';

    const progress = sequencerProgressPercent(s.progress);
    if (progress == null) {
      // Same rule as the Run panel: a state with no figure behind it renders
      // "--", and an ETA extrapolated from a percentage nobody sent would be
      // an invention on top of an invention.
      markProgressUnknown(
        'ops-seq-progress-bar',
        'ops-seq-progress-bar-container',
        'ops-seq-progress-text',
      );
      if (etaEl) etaEl.textContent = '--';
      return;
    }
    markProgressKnown('ops-seq-progress-bar', 'ops-seq-progress-bar-container');
    if (progressBar) {
      progressBar.style.width = progress + '%';
      if (progress >= 100) progressBar.classList.add('completed');
      else progressBar.classList.remove('completed');
    }
    if (progressBarContainer) {
      progressBarContainer.setAttribute('aria-valuenow',
        String(Math.round(progress)));
    }
    if (progressTextEl) progressTextEl.textContent = progress.toFixed(0) + '%';

    // ETA estimate: extrapolate from elapsed time + progress percent. Why
    // client-side: the sequencer status doesn't carry an ETA field; the
    // estimate is only valid when progress is monotonically increasing,
    // so we show "--" during the first second of execution.
    if (etaEl) {
      const startedAt = state.ops.sequenceStartedAt;
      if (!startedAt || progress <= 0 || progress >= 100) {
        etaEl.textContent = progress >= 100 ? 'complete' : '--';
      } else {
        const elapsed = (Date.now() - startedAt) / 1000;
        if (elapsed < 1) {
          etaEl.textContent = '...';
        } else {
          const total = elapsed * (100 / progress);
          const remaining = Math.max(0, total - elapsed);
          etaEl.textContent = formatDurationSeconds(remaining);
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Target catalog
  // ---------------------------------------------------------------------------

  function handleOpsTargetSearchInput() {
    if (state.ops.catalogSearchDebounce) {
      clearTimeout(state.ops.catalogSearchDebounce);
    }
    // 220ms matches the existing mount-goto search debounce so feel is uniform.
    state.ops.catalogSearchDebounce = setTimeout(runOpsCatalogSearch, 220);
  }

  async function runOpsCatalogSearch() {
    const input = document.getElementById('ops-target-search');
    const list = document.getElementById('ops-target-results');
    if (!input || !list) return;
    const query = input.value.trim();
    if (query.length === 0) {
      clearElement(list);
      list.appendChild(createEmptyState('Type to search the catalog'));
      state.ops.catalogResults = [];
      return;
    }
    try {
      const result = await api.targetsSearch(query);
      state.ops.catalogResults = requireWireList(
        result, 'targets', 'Catalog search');
      renderOpsTargetResults();
    } catch (e) {
      addLogEntry('error', describeApiError(e, 'Catalog search'));
      clearElement(list);
      list.appendChild(createEmptyState('Search failed: ' + e.message));
    }
  }

  function renderOpsTargetResults() {
    const list = document.getElementById('ops-target-results');
    if (!list) return;
    clearElement(list);
    if (state.ops.catalogResults.length === 0) {
      list.appendChild(createEmptyState('No matches'));
      return;
    }
    // Cap at 25 so the list stays scrollable on a phone without the bottom
    // tab bar overlapping useful rows.
    const cap = Math.min(25, state.ops.catalogResults.length);
    for (let i = 0; i < cap; i++) {
      const t = state.ops.catalogResults[i];
      const row = document.createElement('button');
      row.type = 'button';
      row.className = 'ops-target-row';
      row.setAttribute('role', 'option');
      const label = (t.name || 'Target #' + t.id)
        + (t.catalogId ? '  ' + t.catalogId : '');
      row.setAttribute('aria-label', label
        + (t.objectType ? ' ' + t.objectType : ''));

      const main = document.createElement('div');
      main.className = 'ops-target-row__main';
      const nameEl = document.createElement('span');
      nameEl.className = 'ops-target-row__name';
      nameEl.textContent = label;
      main.appendChild(nameEl);
      const metaParts = [];
      if (t.objectType) metaParts.push(t.objectType);
      if (t.constellation) metaParts.push(t.constellation);
      const magnitude = wireNumber(t.magnitude);
      if (magnitude != null) {
        metaParts.push('mag ' + magnitude.toFixed(1));
      }
      const metaEl = document.createElement('span');
      metaEl.className = 'ops-target-row__meta';
      metaEl.textContent = metaParts.join(' · ');
      main.appendChild(metaEl);
      row.appendChild(main);

      // RA/Dec coords on the right so the operator can sanity-check before
      // committing the slew.
      const coordsEl = document.createElement('span');
      coordsEl.className = 'ops-target-row__coords';
      const rowRa = wireNumber(t.ra);
      const rowDec = wireNumber(t.dec);
      if (rowRa != null && rowDec != null) {
        coordsEl.textContent = formatRA(rowRa) + '  ' + formatDec(rowDec);
      } else {
        coordsEl.textContent = '--';
      }
      row.appendChild(coordsEl);

      row.addEventListener('click', () => handleOpsTargetSelect(t));
      list.appendChild(row);
    }
  }

  async function handleOpsTargetSelect(target) {
    // The audit brief allows "send target to current sequence OR slew to
    // this". The simplest, no-stub behaviour is to commit the slew, which
    // is what the operator most often wants from a phone in the field. The
    // mount panel's goto inputs are also populated so a manual abort/retry
    // is one tap away.
    // A coordinate the catalogue did not send as a number is not a coordinate.
    // `Number(target.ra)` used to hand NaN to the slew call and print "RA NaNh"
    // in the log beside it, so the operator watched a mount being commanded to
    // a place that does not exist.
    const targetRa = wireNumber(target.ra);
    const targetDec = wireNumber(target.dec);
    if (targetRa == null || targetDec == null) {
      showToast('Target ' + (target.name || target.id)
        + ' has no coordinates', 'error');
      return;
    }
    if (!state.mountDeviceId) {
      showToast('No mount connected — cannot slew to '
        + (target.name || target.id), 'error');
      return;
    }
    // Mirror the selection in the mount goto inputs so the operator sees the
    // resolved values and can abort from the existing mount controls.
    const goName = document.getElementById('mount-goto-name');
    const goRa = document.getElementById('mount-goto-ra');
    const goDec = document.getElementById('mount-goto-dec');
    if (goName) goName.value = target.name || '';
    if (goRa) goRa.value = formatRA(targetRa);
    if (goDec) goDec.value = formatDec(targetDec);

    state.ops.currentTargetId = target.id;

    try {
      await api.mountSlewToRaDec(state.mountDeviceId, targetRa, targetDec);
      addLogEntry('mount', 'Slewing to ' + (target.name || target.id)
        + ' (RA ' + targetRa.toFixed(3)
        + 'h, Dec ' + targetDec.toFixed(3) + '°)');
      showToast('Slewing to ' + (target.name || target.id));
      renderOpsSequencerLoadPanel();
    } catch (e) {
      addLogEntry('error', describeApiError(e, 'Slew'));
      showToast('Slew failed: ' + e.message, 'error');
    }
  }

  // ---------------------------------------------------------------------------
  // Weather + safety
  // ---------------------------------------------------------------------------

  async function fetchOpsWeatherAndSafety() {
    try {
      const [weather, safety] = await Promise.all([
        api.weatherGetCurrent(),
        api.safetyGetStatus(),
      ]);
      state.ops.weather = weather;
      state.ops.safety = safety;
      markPanelFresh('weather');
      renderOpsWeatherPanel();
    } catch (e) {
      // Recorded, not only logged: this panel's verdict is the one an
      // operator acts on, so a refusal has to reach the stale line and
      // silence the verdict — not just print into the event log.
      reportRefreshFailure('weather', e, 'Weather/safety fetch');
      renderOpsWeatherPanel();
    }
  }

  /// True while the panel wears the unknown surface, so the recovery edge can
  /// be told from a run of healthy ticks.
  let weatherUnknownAsserted = false;

  /// Whether the Weather & Safety panel may go on quoting its last reading.
  /// Same rule as the Run panel's, callable between clock ticks because the
  /// renderer also fires on weather/safety events.
  function weatherDataIsStale() {
    return isServerContactStale(Date.now()) || isPanelDataStale('weather');
  }

  /// Stop asserting the sky. Every field the panel paints is a claim about
  /// conditions right now, and "safe to image: yes" is the one an operator
  /// acts on by leaving the roof open, so all of them fall silent together.
  function paintOpsWeatherUnknown() {
    for (const id of ['ops-weather-safe', 'ops-weather-alert-level',
      'ops-weather-message', 'ops-weather-temp', 'ops-weather-humidity',
      'ops-weather-clouds', 'ops-weather-wind', 'ops-weather-dew',
      'ops-safety-monitor-count']) {
      const el = document.getElementById(id);
      if (el) el.textContent = '--';
    }
    const safeEl = document.getElementById('ops-weather-safe');
    if (safeEl) safeEl.className = 'status-value';
    const badgeEl = document.getElementById('ops-safety-badge');
    if (badgeEl) {
      badgeEl.textContent = 'unknown';
      badgeEl.className = 'badge badge-error';
    }
    // The per-monitor list is the same verdict in another shape: a row
    // reading "SafetyMonitor / safe" outlives the answer it came from.
    const monListEl = document.getElementById('ops-safety-monitor-list');
    if (monListEl) clearElement(monListEl);
  }

  /// The Weather & Safety panel's own honesty, on the shared clock.
  function renderOpsWeatherDataState(view) {
    if (!view.panelStale('weather')) {
      if (weatherUnknownAsserted) {
        weatherUnknownAsserted = false;
        renderOpsWeatherPanel();
      }
      return;
    }
    weatherUnknownAsserted = true;
    paintOpsWeatherUnknown();
  }

  function renderOpsWeatherPanel() {
    // Same gate as the Run panel's: this renderer also fires on weather and
    // safety events, and a repaint from the cached reading while the route is
    // refusing would put the old verdict straight back on screen.
    if (weatherDataIsStale()) {
      paintOpsWeatherUnknown();
      return;
    }
    const w = state.ops.weather;
    const s = state.ops.safety;

    const safeEl = document.getElementById('ops-weather-safe');
    const alertEl = document.getElementById('ops-weather-alert-level');
    const msgEl = document.getElementById('ops-weather-message');
    const tempEl = document.getElementById('ops-weather-temp');
    const humEl = document.getElementById('ops-weather-humidity');
    const cloudEl = document.getElementById('ops-weather-clouds');
    const windEl = document.getElementById('ops-weather-wind');
    const dewEl = document.getElementById('ops-weather-dew');
    const badgeEl = document.getElementById('ops-safety-badge');
    const monCountEl = document.getElementById('ops-safety-monitor-count');
    const monListEl = document.getElementById('ops-safety-monitor-list');

    // Whether anything is measuring the sky at all. `dataSource: 'unavailable'`
    // means no weather hardware, no safety monitor and no API source; the
    // server still fills in `safeToImage: true` / `alertLevel: 'clear'`, and
    // rendering those verbatim gave an appliance with no sensors a green
    // "yes / clear / safe" — an affirmative safety verdict drawn from nothing.
    // Answer the sensor question before showing any AFFIRMATIVE verdict.
    const sourced = w != null && w.dataSource != null &&
      w.dataSource !== 'unavailable';
    const monitored = s != null && (
      (typeof s.monitorsConnected === 'number' && s.monitorsConnected > 0) ||
      (s.dataSource != null && s.dataSource !== 'unavailable'));

    // A refusal outranks the sensor question. `safeToImage: false` /
    // `isSafe: false` is the rig deciding not to image, and a fail-closed
    // policy decides exactly that when there is nothing to read — so the
    // refusal arrives WITH `dataSource: 'unavailable'` and zero monitors.
    // Rendering that as "no sensor" turns a decision into an absence.
    const weatherRefused = w != null && w.safeToImage === false;
    const safetyRefused = s != null && s.isSafe === false;

    if (safeEl) {
      if (w == null) {
        safeEl.textContent = '--';
        safeEl.className = 'status-value';
      } else if (weatherRefused) {
        // Why it refused is the Message row's job; that this IS a refusal is
        // this row's, and it says so whether or not anything was measured.
        safeEl.textContent = 'no';
        safeEl.className = 'status-value error';
      } else if (!sourced) {
        safeEl.textContent = 'no sensor';
        safeEl.className = 'status-value warn';
      } else {
        safeEl.textContent = 'yes';
        safeEl.className = 'status-value good';
      }
    }
    if (alertEl) {
      alertEl.textContent = w == null
        ? '--'
        : (sourced ? (w.alertLevel || 'none') : 'not measured');
    }
    if (msgEl) {
      msgEl.textContent = w == null
        ? '--'
        : weatherRefused
          ? (w.message || 'Not safe to image; the safety check gave no reason.')
          : (sourced
              ? (w.message || '--')
              : (w.message || 'No weather source configured.'));
    }

    // Telemetry from /api/weather/current — null when no hardware device.
    setOpsTelemetry(tempEl, w && w.temperature, (v) => v.toFixed(1) + ' °C');
    setOpsTelemetry(humEl, w && w.humidity, (v) => v.toFixed(0) + ' %');
    setOpsTelemetry(cloudEl, w && w.cloudCover, (v) => v.toFixed(0) + ' %');
    setOpsTelemetry(windEl, w && w.windSpeed, (v) => v.toFixed(1) + ' kph');
    setOpsTelemetry(dewEl, w && w.dewPoint, (v) => v.toFixed(1) + ' °C');

    if (badgeEl) {
      if (s == null) {
        badgeEl.textContent = '--';
        badgeEl.className = 'badge badge-idle';
      } else if (safetyRefused) {
        // A refusal is checked before the source question, because fail-closed
        // safety refuses BECAUSE nothing could be read: `isSafe: false` with
        // zero monitors and dataSource 'unavailable' is the rig saying it will
        // not image, and 'no source' would report that decision as an absence.
        badgeEl.textContent = 'unsafe';
        badgeEl.className = 'badge badge-error';
      } else if (!monitored && !sourced) {
        // `isSafe: true` with zero monitors and dataSource 'unavailable' is
        // the fail-honest case: nothing has looked at the sky. The server
        // already says so in `failModeWarning`; the badge must not overrule it
        // with a green "safe".
        badgeEl.textContent = 'no source';
        badgeEl.className = 'badge badge-paused';
      } else if (s.isSafe) {
        badgeEl.textContent = 'safe';
        badgeEl.className = 'badge badge-running';
      } else {
        badgeEl.textContent = 'unsafe';
        badgeEl.className = 'badge badge-error';
      }
    }
    if (monCountEl) {
      monCountEl.textContent = s && typeof s.monitorsConnected === 'number'
        ? String(s.monitorsConnected) : '--';
    }
    if (monListEl) {
      clearElement(monListEl);
      const monitors = (s && Array.isArray(s.monitors)) ? s.monitors : [];
      for (const m of monitors) {
        const item = document.createElement('div');
        item.className = 'ops-monitor-item';
        const nameEl = document.createElement('span');
        nameEl.className = 'ops-monitor-item__name';
        nameEl.textContent = m.deviceName || m.deviceId || 'monitor';
        item.appendChild(nameEl);
        const badge = document.createElement('span');
        if (!m.connected) {
          badge.className = 'badge badge-idle';
          badge.textContent = 'offline';
        } else if (m.isSafe) {
          badge.className = 'badge badge-running';
          badge.textContent = 'safe';
        } else {
          badge.className = 'badge badge-error';
          badge.textContent = 'unsafe';
        }
        item.appendChild(badge);
        monListEl.appendChild(item);
      }
      if (s && s.failModeWarning) {
        const warn = document.createElement('div');
        warn.className = 'ops-monitor-item';
        const t = document.createElement('span');
        t.className = 'ops-monitor-item__name';
        t.textContent = 'Fail mode: ' + s.failModeWarning;
        warn.appendChild(t);
        const b = document.createElement('span');
        b.className = 'badge badge-paused';
        b.textContent = '!';
        warn.appendChild(b);
        monListEl.appendChild(warn);
      }
    }
  }

  // `isNaN(Number(value))` coerced first and tested second, so every value that
  // Number() maps onto a number passed: `''` and `[]` became 0 and the weather
  // row read "0.0 °C" — a hard freeze warning — for a sensor that had reported
  // nothing, and `true` read "1.0 °C". Only a number the wire actually carried
  // is a reading.
  function setOpsTelemetry(el, value, formatter) {
    if (!el) return;
    const reading = wireNumber(value);
    el.textContent = reading != null ? formatter(reading) : '--';
  }

  // ---------------------------------------------------------------------------
  // Dome
  // ---------------------------------------------------------------------------

  async function fetchOpsDomeStatusIfConnected() {
    if (!state.ops.domeDeviceId) {
      state.ops.domeStatus = null;
      renderOpsDomePanel();
      return;
    }
    try {
      state.ops.domeStatus = await api.domeGetStatus(state.ops.domeDeviceId);
      markPanelFresh('dome');
      renderOpsDomePanel();
    } catch (e) {
      reportRefreshFailure('dome', e, 'Dome status fetch');
      renderOpsDomePanel();
    }
  }

  /// True while the Dome panel wears the unknown surface.
  let domeUnknownAsserted = false;

  /// Whether the Dome panel may go on quoting its last status.
  function domeDataIsStale() {
    return isServerContactStale(Date.now()) || isPanelDataStale('dome');
  }

  /// Stop asserting the dome. "Shutter: open" from a source that has stopped
  /// answering is the same shape of claim as a green "running" badge, and it
  /// is the one an operator reads before deciding whether the sky is covered.
  function paintOpsDomeUnknown() {
    for (const id of ['ops-dome-shutter', 'ops-dome-az', 'ops-dome-slewing',
      'ops-dome-sync']) {
      const el = document.getElementById(id);
      if (el) el.textContent = '--';
    }
    const badgeEl = document.getElementById('ops-dome-state-badge');
    if (badgeEl) {
      badgeEl.textContent = 'unknown';
      badgeEl.className = 'badge badge-error';
    }
  }

  /// The Dome panel's own honesty, on the shared clock.
  function renderOpsDomeDataState(view) {
    if (!view.panelStale('dome')) {
      if (domeUnknownAsserted) {
        domeUnknownAsserted = false;
        renderOpsDomePanel();
      }
      return;
    }
    domeUnknownAsserted = true;
    paintOpsDomeUnknown();
  }

  function renderOpsDomePanel() {
    if (domeDataIsStale()) {
      paintOpsDomeUnknown();
      return;
    }
    const d = state.ops.domeStatus;
    const shutterEl = document.getElementById('ops-dome-shutter');
    const azEl = document.getElementById('ops-dome-az');
    const slewEl = document.getElementById('ops-dome-slewing');
    const syncEl = document.getElementById('ops-dome-sync');
    const badgeEl = document.getElementById('ops-dome-state-badge');

    if (!d) {
      if (shutterEl) shutterEl.textContent = '--';
      if (azEl) azEl.textContent = '--';
      if (slewEl) slewEl.textContent = '--';
      if (syncEl) syncEl.textContent = '--';
      if (badgeEl) {
        badgeEl.textContent = state.ops.domeDeviceId ? 'unknown' : 'no dome';
        badgeEl.className = 'badge badge-idle';
      }
      return;
    }

    if (shutterEl) shutterEl.textContent = d.shutterState || '--';
    if (azEl) {
      const azimuth = wireNumber(d.azimuth);
      azEl.textContent = azimuth != null ? azimuth.toFixed(1) + ' °' : '--';
    }
    if (slewEl) slewEl.textContent = d.slewing ? 'yes' : 'no';
    if (syncEl) syncEl.textContent = d.syncEnabled ? 'enabled' : 'disabled';
    if (badgeEl) {
      const state2 = String(d.shutterState || '').toLowerCase();
      badgeEl.textContent = state2 || 'unknown';
      if (state2 === 'open') {
        badgeEl.className = 'badge badge-running';
      } else if (state2 === 'opening' || state2 === 'closing') {
        badgeEl.className = 'badge badge-paused';
      } else if (state2 === 'error') {
        badgeEl.className = 'badge badge-error';
      } else if (state2 === 'closed') {
        badgeEl.className = 'badge badge-completed';
      } else {
        badgeEl.className = 'badge badge-idle';
      }
    }
  }

  async function handleOpsDomeOpen() {
    if (!state.ops.domeDeviceId) {
      showToast('No dome connected', 'error');
      return;
    }
    try {
      await api.domeOpen(state.ops.domeDeviceId);
      addLogEntry('dome', 'Opening shutter');
      showToast('Opening shutter');
    } catch (e) {
      showToast('Dome open failed: ' + e.message, 'error');
      addLogEntry('error', describeApiError(e, 'Dome open'));
    }
  }

  async function handleOpsDomeClose() {
    if (!state.ops.domeDeviceId) {
      showToast('No dome connected', 'error');
      return;
    }
    try {
      await api.domeClose(state.ops.domeDeviceId);
      addLogEntry('dome', 'Closing shutter');
      showToast('Closing shutter');
    } catch (e) {
      showToast('Dome close failed: ' + e.message, 'error');
      addLogEntry('error', describeApiError(e, 'Dome close'));
    }
  }

  async function handleOpsDomePark() {
    if (!state.ops.domeDeviceId) {
      showToast('No dome connected', 'error');
      return;
    }
    try {
      await api.domePark(state.ops.domeDeviceId);
      addLogEntry('dome', 'Parking dome');
      showToast('Parking dome');
    } catch (e) {
      showToast('Dome park failed: ' + e.message, 'error');
      addLogEntry('error', describeApiError(e, 'Dome park'));
    }
  }

  async function handleOpsDomeSlew() {
    if (!state.ops.domeDeviceId) {
      showToast('No dome connected', 'error');
      return;
    }
    const input = document.getElementById('ops-dome-target-az');
    const az = input ? parseFloat(input.value) : NaN;
    if (isNaN(az) || az < 0 || az >= 360) {
      showToast('Enter an azimuth in [0, 360)', 'error');
      return;
    }
    try {
      await api.domeSlew(state.ops.domeDeviceId, az);
      addLogEntry('dome', 'Slewing dome to ' + az.toFixed(1) + '°');
      showToast('Slewing dome to ' + az.toFixed(1) + '°');
    } catch (e) {
      showToast('Dome slew failed: ' + e.message, 'error');
      addLogEntry('error', describeApiError(e, 'Dome slew'));
    }
  }

  async function handleOpsDomeSync(enabled) {
    if (!state.ops.domeDeviceId) {
      showToast('No dome connected', 'error');
      return;
    }
    try {
      await api.domeSyncToMount(state.ops.domeDeviceId, enabled);
      addLogEntry('dome', 'Dome slaving '
        + (enabled ? 'enabled' : 'disabled'));
      showToast('Dome slaving ' + (enabled ? 'enabled' : 'disabled'));
    } catch (e) {
      showToast('Dome sync failed: ' + e.message, 'error');
      addLogEntry('error', describeApiError(e, 'Dome sync'));
    }
  }

  // ---------------------------------------------------------------------------
  // Checkpoint resume picker
  // ---------------------------------------------------------------------------

  async function fetchOpsCheckpoints() {
    try {
      const result = await api.sequencerListCheckpoints();
      state.ops.checkpoints = requireWireList(
        result, 'checkpoints', 'Checkpoint list');
      renderOpsCheckpointPanel();
    } catch (e) {
      reportRefreshFailure(null, e, 'Checkpoint fetch');
    }
  }

  function renderOpsCheckpointPanel() {
    const list = document.getElementById('ops-checkpoint-list');
    if (!list) return;
    clearElement(list);
    if (state.ops.checkpoints.length === 0) {
      list.appendChild(createEmptyState('No checkpoints available'));
      return;
    }
    for (let i = 0; i < state.ops.checkpoints.length; i++) {
      const cp = state.ops.checkpoints[i];
      const row = document.createElement('div');
      row.className = 'ops-checkpoint-row';
      row.setAttribute('role', 'listitem');

      const title = document.createElement('div');
      title.className = 'ops-checkpoint-row__title';
      title.textContent = cp.target || cp.targetName
        || cp.sequenceName || ('Checkpoint #' + i);
      row.appendChild(title);

      const meta = document.createElement('div');
      meta.className = 'ops-checkpoint-row__meta';
      const fieldsToShow = [
        ['Frames done', cp.framesCompleted ?? cp.completedFrames
          ?? cp.frames_completed],
        ['Frames planned', cp.framesPlanned ?? cp.totalFrames],
        ['Saved at', formatCheckpointAge(cp.savedAt ?? cp.timestamp
          ?? cp.createdAt)],
        ['Filter', cp.filter ?? cp.currentFilter],
        ['Node', cp.nodeName ?? cp.currentNodeName],
      ];
      for (const [label, value] of fieldsToShow) {
        if (value == null) continue;
        const labelEl = document.createElement('span');
        labelEl.textContent = label;
        const valEl = document.createElement('span');
        valEl.textContent = String(value);
        meta.appendChild(labelEl);
        meta.appendChild(valEl);
      }
      row.appendChild(meta);

      const actions = document.createElement('div');
      actions.className = 'ops-checkpoint-row__actions';
      const resumeBtn = document.createElement('button');
      resumeBtn.type = 'button';
      resumeBtn.className = 'btn btn-sm btn-success';
      resumeBtn.textContent = 'Restore';
      resumeBtn.setAttribute('aria-label',
        'Restore the run from its checkpoint; nothing moves until Start');
      resumeBtn.addEventListener('click', () => handleOpsCheckpointResume());
      actions.appendChild(resumeBtn);
      const discardBtn = document.createElement('button');
      discardBtn.type = 'button';
      discardBtn.className = 'btn btn-sm btn-danger';
      discardBtn.textContent = 'Discard';
      discardBtn.setAttribute('aria-label',
        'Discard checkpoint without resuming');
      discardBtn.addEventListener('click', () => handleOpsCheckpointDiscard());
      actions.appendChild(discardBtn);
      row.appendChild(actions);

      list.appendChild(row);
    }
  }

  async function handleOpsCheckpointResume() {
    try {
      await api.sequencerResumeCheckpoint();
      addLogEntry('sequencer', 'Restored from checkpoint; waiting for Start');
      showToast('Restored. Nothing moves until you press Start.');
      fetchOpsCheckpoints();
      fetchSequencerStatus();
    } catch (e) {
      addLogEntry('error', describeApiError(e, 'Checkpoint restore'));
      showToast('Restore failed: ' + e.message, 'error');
    }
  }

  async function handleOpsCheckpointDiscard() {
    try {
      await api.sequencerDiscardCheckpoint();
      addLogEntry('sequencer', 'Checkpoint discarded');
      showToast('Checkpoint discarded');
      fetchOpsCheckpoints();
    } catch (e) {
      addLogEntry('error', describeApiError(e, 'Checkpoint discard'));
      showToast('Discard failed: ' + e.message, 'error');
    }
  }

  // ---------------------------------------------------------------------------
  // Profiles
  // ---------------------------------------------------------------------------

  async function fetchOpsProfiles() {
    try {
      const [list, active] = await Promise.all([
        api.profilesGetList(),
        api.profilesGetActive(),
      ]);
      state.ops.profiles = requireWireList(list, 'profiles', 'Profile list');
      state.ops.activeProfile = active && active.profile ? active.profile : null;
      renderOpsProfilePanel();
    } catch (e) {
      addLogEntry('error', describeApiError(e, 'Profile fetch'));
    }
  }

  function renderOpsProfilePanel() {
    const activeEl = document.getElementById('ops-profile-active');
    if (activeEl) {
      const ap = state.ops.activeProfile;
      activeEl.textContent = ap
        ? (ap.name || ('Profile #' + ap.id))
        : 'none';
    }
    const sel = document.getElementById('ops-profile-select');
    if (sel) {
      const previous = sel.value;
      clearElement(sel);
      const placeholder = document.createElement('option');
      placeholder.value = '';
      placeholder.textContent = state.ops.profiles.length === 0
        ? '-- no profiles --' : '-- select a profile --';
      sel.appendChild(placeholder);
      for (const p of state.ops.profiles) {
        const opt = document.createElement('option');
        opt.value = String(p.id);
        opt.textContent = p.name || ('Profile #' + p.id);
        if (state.ops.activeProfile
            && String(p.id) === String(state.ops.activeProfile.id)) {
          opt.textContent += ' (active)';
        }
        sel.appendChild(opt);
      }
      if (previous) sel.value = previous;
    }
  }

  async function handleOpsProfileActivate() {
    const sel = document.getElementById('ops-profile-select');
    const id = sel ? sel.value : '';
    if (!id) {
      showToast('Pick a profile to activate', 'error');
      return;
    }
    try {
      await api.profilesActivate(id);
      addLogEntry('profile', 'Activated profile id=' + id);
      showToast('Profile activated');
      // Re-fetch so the active marker updates and any cascading device
      // changes (filter offsets, etc.) flow through the next status poll.
      fetchOpsProfiles();
      fetchDevices();
    } catch (e) {
      addLogEntry('error', describeApiError(e, 'Profile activate'));
      showToast('Activate failed: ' + e.message, 'error');
    }
  }

  async function handleOpsProfileReload() {
    try {
      await api.profilesReload();
      addLogEntry('profile', 'Reloaded active profile');
      showToast('Profile reloaded');
      fetchOpsProfiles();
    } catch (e) {
      addLogEntry('error', describeApiError(e, 'Profile reload'));
      showToast('Reload failed: ' + e.message, 'error');
    }
  }

  // ---------------------------------------------------------------------------
  // Session analytics summary
  // ---------------------------------------------------------------------------

  async function fetchOpsAnalyticsSummary() {
    try {
      const summary = await api.analyticsGetSessionSummary();
      state.ops.sessionSummary = summary;
      markPanelFresh('analytics');
      renderOpsAnalyticsPanel();
      renderOpsSequencerLoadPanel();
    } catch (e) {
      reportRefreshFailure('analytics', e, 'Analytics fetch');
    }
  }

  function renderOpsAnalyticsPanel() {
    const summary = state.ops.sessionSummary;
    const session = summary && summary.session;
    const transparency = (summary && summary.transparency) || [];

    const setText = (id, text) => {
      const el = document.getElementById(id);
      if (el) el.textContent = text;
    };

    if (!session) {
      setText('ops-analytics-session-name', 'no active session');
      setText('ops-analytics-frames', '--');
      setText('ops-analytics-graded', '--');
      setText('ops-analytics-integration', '--');
      setText('ops-analytics-hfr', '--');
      setText('ops-analytics-rms', '--');
      setText('ops-analytics-transparency-summary', '--');
      drawOpsTransparencySparkline([]);
      return;
    }

    setText('ops-analytics-session-name', session.name
      || ('Session #' + session.id));
    // `successfulExposures` answers "did the camera return the frame", not
    // "was the frame worth keeping" — the label says "returned" and the
    // Graded row beside it carries what the culling actually decided.
    const successful = wireNumber(session.successfulExposures);
    const totalFrames = successful != null
      ? successful : wireNumber(session.totalExposures);
    setText('ops-analytics-frames', totalFrames != null
      ? String(totalFrames) : '--');
    const accepted = wireNumber(session.acceptedLights);
    const rejected = wireNumber(session.rejectedLights);
    if (accepted != null && rejected != null) {
      const decided = accepted + rejected;
      // The server counts only decided frames, so 0 + 0 means nobody has
      // looked yet — not a clean slate and not an all-rejected night.
      setText('ops-analytics-graded', decided > 0
        ? (accepted + ' accepted · ' + rejected + ' rejected')
        : 'nothing graded yet');
    } else {
      setText('ops-analytics-graded', '--');
    }
    const integrationSecs = wireNumber(session.totalIntegrationSecs);
    setText('ops-analytics-integration', integrationSecs != null
      ? formatDurationSeconds(integrationSecs) : '--');
    const hfr = wireNumber(session.avgHfr);
    setText('ops-analytics-hfr', hfr != null ? hfr.toFixed(2) : '--');
    const rms = wireNumber(session.avgGuidingRms);
    setText('ops-analytics-rms', rms != null ? rms.toFixed(2) + '"' : '--');

    // Transparency values: prefer the `mag_zero_point` field as the magnitude
    // proxy for transparency trend. The science DAO stores per-sample rows,
    // so we just feed the magnitude into the sparkline; a falling trend means
    // worsening transparency, rising means improving.
    const samples = [];
    for (const row of transparency) {
      const v = row.magZeroPoint != null ? Number(row.magZeroPoint)
        : (row.zeroPoint != null ? Number(row.zeroPoint)
        : (row.transparency != null ? Number(row.transparency) : null));
      if (v != null && isFinite(v)) samples.push(v);
    }
    if (samples.length === 0) {
      setText('ops-analytics-transparency-summary',
        transparency.length === 0 ? 'no samples' : 'no usable samples');
    } else {
      const last = samples[samples.length - 1];
      const first = samples[0];
      const trend = last >= first ? '↗' : '↘'; // up/down arrow
      setText('ops-analytics-transparency-summary',
        last.toFixed(2) + ' ' + trend + ' (' + samples.length + ' samples)');
    }
    drawOpsTransparencySparkline(samples);
  }

  function drawOpsTransparencySparkline(values) {
    const canvas = document.getElementById('ops-analytics-transparency-spark');
    if (!canvas) return;
    // Why DPR-aware sizing: a phone retina display would render at 0.5x
    // resolution otherwise. The container's CSS height stays 48px; the
    // backing store scales with devicePixelRatio.
    const container = canvas.parentElement;
    const cssW = container ? container.clientWidth : canvas.width;
    const cssH = container ? container.clientHeight : canvas.height;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.max(1, Math.floor(cssW * dpr));
    canvas.height = Math.max(1, Math.floor(cssH * dpr));
    const ctx = canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, cssW, cssH);

    if (!values || values.length < 2) {
      ctx.fillStyle = themeColor('--color-text-muted');
      ctx.font = '11px sans-serif';
      ctx.fillText(values && values.length === 1
        ? '1 sample (need >= 2 for trend)' : 'no transparency samples',
        6, Math.floor(cssH / 2) + 4);
      return;
    }
    let min = Infinity;
    let max = -Infinity;
    for (const v of values) {
      if (v < min) min = v;
      if (v > max) max = v;
    }
    if (max - min < 0.01) {
      // Constant series — draw a midline rather than collapsing on a divide-
      // by-zero.
      min -= 0.5;
      max += 0.5;
    }
    const pad = 4;
    const innerW = cssW - pad * 2;
    const innerH = cssH - pad * 2;
    const xStep = innerW / (values.length - 1);
    ctx.strokeStyle = themeColor('--color-primary');
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    for (let i = 0; i < values.length; i++) {
      const x = pad + i * xStep;
      const yFrac = (values[i] - min) / (max - min);
      const y = pad + (1 - yFrac) * innerH;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
    // Endpoint dot so the operator can see where the latest sample landed
    // even when the trend is flat.
    const last = values[values.length - 1];
    const lastX = pad + (values.length - 1) * xStep;
    const lastY = pad + (1 - (last - min) / (max - min)) * innerH;
    ctx.fillStyle = themeColor('--color-primary');
    ctx.beginPath();
    ctx.arc(lastX, lastY, 2.5, 0, Math.PI * 2);
    ctx.fill();
  }

  // ---------------------------------------------------------------------------
  // Misc ops helpers
  // ---------------------------------------------------------------------------

  // A finite number off the wire, or null when the value is not one.
  //
  // `x != null` is a presence check, not a type check: it admits every
  // non-null JSON shape into a numeric render. A payload carrying
  // `totalExposures: "banana"` reached String(...) and printed "banana" in the
  // frame count; `avgHfr: "NaN"` reached Number(...).toFixed(2) and printed
  // "NaN" as a measured seeing figure. Number.isFinite does not coerce, so a
  // string, a boolean, an object or an actual NaN all fail it and the caller
  // paints the honest '--' instead of an operator-facing fiction.
  function wireNumber(raw) {
    return Number.isFinite(raw) ? raw : null;
  }

  function formatDurationSeconds(secs) {
    if (secs == null || isNaN(secs)) return '--';
    const s = Math.max(0, Math.floor(Number(secs)));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const ss = s % 60;
    if (h > 0) {
      return h + 'h ' + pad2(m) + 'm ' + pad2(ss) + 's';
    }
    if (m > 0) {
      return m + 'm ' + pad2(ss) + 's';
    }
    return ss + 's';
  }

  function formatCheckpointAge(raw) {
    if (raw == null) return null;
    // The checkpoint info payload's timestamp shape varies by backend
    // version: it may be epoch ms (number) or an ISO-8601 string. Accept
    // either; surface the parse failure inline rather than throwing so the
    // panel still renders.
    let when;
    if (typeof raw === 'number') {
      when = new Date(raw);
    } else if (typeof raw === 'string') {
      const parsed = Date.parse(raw);
      if (!isFinite(parsed)) return raw;
      when = new Date(parsed);
    } else {
      return String(raw);
    }
    const ageMs = Date.now() - when.getTime();
    if (ageMs < 0 || !isFinite(ageMs)) return when.toISOString();
    return formatDurationSeconds(ageMs / 1000) + ' ago';
  }

  // ===========================================================================
  // Shared wizard modal infrastructure
  // ===========================================================================

  function setupWizardModals() {
    for (const btn of document.querySelectorAll('.wizard-next')) {
      btn.addEventListener('click', () => advanceWizard(btn.dataset.modal, +1));
    }
    for (const btn of document.querySelectorAll('.wizard-back')) {
      btn.addEventListener('click', () => advanceWizard(btn.dataset.modal, -1));
    }
    // Escape closes any open wizard. Why per-modal listener: each modal
    // already has its own close button; this gives keyboard parity with the
    // pairing modal.
    document.addEventListener('keydown', (e) => {
      if (e.key !== 'Escape') return;
      for (const id of Object.keys(state.wizardStep)) {
        const m = document.getElementById(id);
        if (m && m.classList.contains('visible')) {
          closeWizardModal(id);
        }
      }
    });
  }

  function openWizardModal(modalId) {
    const m = document.getElementById(modalId);
    if (!m) return;
    state.wizardStep[modalId] = 0;
    applyWizardStep(modalId);
    setWizardError(modalId, '');
    m.removeAttribute('hidden');
    m.classList.add('visible');
    // Focus the first focusable element so screen readers announce the
    // current step body instead of the backdrop.
    setTimeout(() => {
      const first = m.querySelector('.wizard-step.active input, .wizard-step.active select, .wizard-step.active button');
      if (first) first.focus();
    }, 50);
  }

  function closeWizardModal(modalId) {
    const m = document.getElementById(modalId);
    if (!m) return;
    m.classList.remove('visible');
    m.setAttribute('hidden', '');
  }

  function advanceWizard(modalId, delta) {
    const total = state.wizardStepCount[modalId];
    if (!total) return;
    if (modalId === 'framing-modal'
        && state.wizardStep[modalId] === 0 && delta > 0
        && !prepareFramingTargetForPreview()) {
      return;
    }
    const next = Math.max(0, Math.min(total - 1, state.wizardStep[modalId] + delta));
    if (next === state.wizardStep[modalId]) return;
    state.wizardStep[modalId] = next;
    applyWizardStep(modalId);
    // Step-specific hooks: when entering certain steps we lazy-load data or
    // refresh derived UI (e.g. flat filter list, framing FOV preview).
    onWizardStepEntered(modalId, next);
  }

  function applyWizardStep(modalId) {
    const m = document.getElementById(modalId);
    if (!m) return;
    const idx = state.wizardStep[modalId];
    const total = state.wizardStepCount[modalId];

    const steps = m.querySelectorAll('.wizard-step');
    for (const s of steps) {
      const stepIdx = parseInt(s.dataset.step, 10);
      s.classList.toggle('active', stepIdx === idx);
    }
    const dots = m.querySelectorAll('.wizard-dot');
    for (const d of dots) {
      const stepIdx = parseInt(d.dataset.step, 10);
      d.classList.toggle('active', stepIdx === idx);
      d.classList.toggle('completed', stepIdx < idx);
    }
    // Back disabled at step 0; Next disabled at last step.
    const back = m.querySelector('.wizard-back');
    const next = m.querySelector('.wizard-next');
    if (back) back.disabled = idx === 0;
    if (next) next.disabled = idx >= total - 1;

    // Modal-specific final-step CTA visibility.
    if (modalId === 'polar-align-modal') {
      const startBtn = document.getElementById('btn-polar-align-start');
      if (startBtn) startBtn.hidden = idx !== total - 1;
    } else if (modalId === 'framing-modal') {
      let hasCoordinates = false;
      try {
        readFramingCoordinates();
        hasCoordinates = true;
      } catch (_) {
        hasCoordinates = false;
      }
      const slew = document.getElementById('btn-framing-slew');
      const center = document.getElementById('btn-framing-center');
      const rotate = document.getElementById('btn-framing-rotate');
      const save = document.getElementById('btn-framing-save');
      if (slew) slew.disabled = !hasCoordinates || !state.mountDeviceId;
      if (center) center.disabled = !hasCoordinates || !state.mountDeviceId;
      if (rotate) rotate.disabled = !hasCoordinates || !state.rotatorDeviceId;
      if (save) save.disabled = !hasCoordinates;
    }
  }

  function setWizardError(modalId, message) {
    const map = {
      'polar-align-modal': 'polar-align-modal-error',
      'flat-wizard-modal': 'flat-wizard-modal-error',
      'mosaic-modal': 'mosaic-modal-error',
      'framing-modal': 'framing-modal-error',
    };
    const id = map[modalId];
    if (!id) return;
    const el = document.getElementById(id);
    if (el) {
      el.textContent = message || '';
      el.className = 'modal-status' + (message ? ' error' : '');
    }
  }

  function onWizardStepEntered(modalId, stepIdx) {
    if (modalId === 'flat-wizard-modal' && stepIdx === 0) {
      renderFlatWizardFilterList();
    } else if (modalId === 'mosaic-modal' && stepIdx === 3) {
      // Auto-preview when reaching the preview step.
      handleMosaicPreview().catch(() => {});
    } else if (modalId === 'framing-modal' && stepIdx === 1) {
      // Load FOV config when entering the preview step.
      loadFovConfigForFraming().then(renderFramingPreview).catch(() => {
        renderFramingPreview();
      });
    } else if (modalId === 'polar-align-modal' && stepIdx === 0) {
      updatePolarAlignmentFieldsForMode();
    }
  }

  // ===========================================================================
  // Plate solve
  // ===========================================================================

  async function handlePlateSolve(syncMount) {
    if (!api.isConnected) {
      showToast('Not connected', 'error');
      return;
    }
    const resultEl = document.getElementById('plate-solve-result');
    if (resultEl) resultEl.textContent = 'Solving...';
    try {
      // Find a path for the solver. Why /api/images/recent over the in-memory
      // last image: the bridge plate-solver reads a file from disk (FITS or
      // XISF), and the AutoSaveService persists each capture before it lands
      // in the images table. If no row exists yet (mid-exposure or no auto-
      // save target) we surface a clear error rather than silently solving
      // a stale path.
      const recent = await api.imagesGetRecent(1);
      const images = requireWireList(recent, 'images', 'Recent images');
      if (!images.length) {
        throw new Error(
          'No captured image is available on disk yet — take an exposure first',
        );
      }
      // The CapturedImages table column is `filePath`, but the json_serializable
      // output may snake_case it depending on schema. Accept both.
      const filePath = images[0].filePath || images[0].file_path;
      if (!filePath) {
        throw new Error('Last image row has no file path (auto-save may be disabled)');
      }
      // Hint with current mount position if we have one — speeds up the solve
      // substantially compared to a blind solve, especially on phones over
      // a slow link where every retry counts.
      const hint = state.mountStatus
        ? {
            ra: state.mountStatus.rightAscension,
            dec: state.mountStatus.declination,
          }
        : {};
      const result = await api.plateSolve(filePath, hint);
      state.lastPlateSolve = result;

      if (!result || !result.success) {
        const msg = result && result.error ? result.error : 'Plate solve failed';
        throw new Error(msg);
      }

      // Make the position-angle available to the rotator panel exactly the
      // same way an `imaging` WS event would, so "Sync to image PA" works
      // after a manual solve.
      if (typeof result.rotation === 'number' && isFinite(result.rotation)) {
        state.lastImagePositionAngle = Number(result.rotation);
        renderRotatorPanel();
      }

      renderPlateSolveResult(result, filePath);
      const solvedRotation = wireNumber(result.rotation);
      addLogEntry('imaging',
        'Plate-solve: RA ' + formatRA(result.ra) +
        ' Dec ' + formatDec(result.dec) +
        (solvedRotation != null ? ' PA ' + solvedRotation.toFixed(2) + '°' : ''));

      if (syncMount) {
        if (!state.mountDeviceId) {
          showToast('No mount connected — solved but cannot sync', 'error');
          return;
        }
        await api.mountSync(state.mountDeviceId, result.ra, result.dec);
        addLogEntry('mount', 'Mount synced to plate-solved RA/Dec');
        showToast('Plate-solved and synced mount');
      } else {
        showToast('Plate solve complete');
      }
    } catch (e) {
      if (resultEl) resultEl.textContent = 'Solve failed: ' + e.message;
      addLogEntry('error', describeApiError(e, 'Plate-solve'));
      showToast('Plate-solve failed: ' + e.message, 'error');
    }
  }

  function renderPlateSolveResult(result, filePath) {
    const el = document.getElementById('plate-solve-result');
    if (!el) return;
    const lines = [];
    lines.push('RA  ' + formatRA(result.ra));
    lines.push('Dec ' + formatDec(result.dec));
    const pixelScale = wireNumber(result.pixelScale);
    if (pixelScale != null) {
      lines.push('Scale ' + pixelScale.toFixed(3) + '"/px');
    }
    const rotation = wireNumber(result.rotation);
    if (rotation != null) {
      lines.push('PA ' + rotation.toFixed(2) + '°');
    }
    const fieldWidth = wireNumber(result.fieldWidth);
    const fieldHeight = wireNumber(result.fieldHeight);
    if (fieldWidth != null && fieldHeight != null) {
      lines.push('FOV ' + fieldWidth.toFixed(2) + '° × '
        + fieldHeight.toFixed(2) + '°');
    }
    const solveTimeSecs = wireNumber(result.solveTimeSecs);
    if (solveTimeSecs != null) {
      lines.push('Solved in ' + solveTimeSecs.toFixed(2) + 's');
    }
    if (filePath) {
      // Truncate long paths so the tile doesn't grow unbounded.
      const tail = String(filePath).split(/[\\/]/).slice(-2).join('/');
      lines.push('File ' + tail);
    }
    el.textContent = lines.join('\n');
  }

  // ===========================================================================
  // Polar alignment
  // ===========================================================================

  function updatePolarAlignmentFieldsForMode() {
    const mode = document.getElementById('pa-mode').value;
    const stepRow = document.getElementById('pa-step-row');
    const rotRow = document.getElementById('pa-rotation-row');
    // All-sky doesn't rotate the mount, so step + direction are irrelevant.
    if (stepRow) stepRow.style.display = (mode === 'all_sky') ? 'none' : 'flex';
    if (rotRow) rotRow.style.display = (mode === 'all_sky') ? 'none' : 'flex';
  }

  async function handleStartPolarAlignment() {
    if (!state.mountDeviceId) {
      setWizardError('polar-align-modal', 'No mount connected');
      return;
    }
    if (!state.cameraDeviceId) {
      setWizardError('polar-align-modal', 'No camera connected');
      return;
    }
    const mode = document.getElementById('pa-mode').value;
    const hemi = document.getElementById('pa-hemisphere').value;
    const exposure = parseFloat(document.getElementById('pa-exposure').value);
    const binning = parseInt(document.getElementById('pa-binning').value, 10);
    const step = parseFloat(document.getElementById('pa-step').value);
    const rotateDir = document.getElementById('pa-rotate-dir').value;

    if (!isFinite(exposure) || exposure <= 0) {
      setWizardError('polar-align-modal', 'Exposure must be positive');
      return;
    }
    if (mode === 'tppa' && (!isFinite(step) || step <= 0)) {
      setWizardError('polar-align-modal', 'Step size must be positive');
      return;
    }

    setWizardError('polar-align-modal', '');
    try {
      const opts = {
        exposureTime: exposure,
        binning: binning || 2,
        stepSize: step,
        isNorth: hemi === 'north',
        manualRotation: false,
        rotateEast: rotateDir === 'east',
      };
      if (mode === 'all_sky') {
        await api.polarAlignmentStartAllSky({
          exposureTime: exposure,
          binning: binning || 2,
          isNorth: hemi === 'north',
          solveTimeout: 60.0,
        });
      } else {
        await api.polarAlignmentStart(opts);
      }
      state.polarAlignment.phase = 'measuring';
      state.polarAlignment.statusMessage = 'Started ' + (mode === 'all_sky' ? 'all-sky' : 'TPPA') + ' polar alignment';
      renderPolarAlignmentPanel();
      addLogEntry('polarAlignment', state.polarAlignment.statusMessage);
      showToast('Polar alignment started');
    } catch (e) {
      setWizardError('polar-align-modal', e.message);
      addLogEntry('error', describeApiError(e, 'Polar alignment start'));
    }
  }

  async function handleStopPolarAlignment() {
    if (!api.isConnected) return;
    try {
      await api.polarAlignmentStop();
      state.polarAlignment.phase = 'idle';
      state.polarAlignment.statusMessage = 'Stopped';
      state.polarAlignment.totalErrorArcmin = null;
      renderPolarAlignmentPanel();
      addLogEntry('polarAlignment', 'Polar alignment stopped');
      showToast('Polar alignment stopped');
    } catch (e) {
      showToast('Stop failed: ' + e.message, 'error');
    }
  }

  function handlePolarAlignmentEvent(data) {
    const eventType = data.eventType || data.event || '';
    const payload = data.data || data;
    if (eventType === 'PolarAlignmentStatus') {
      state.polarAlignment.phase = String(payload.phase || payload.status || 'unknown');
      state.polarAlignment.statusMessage = String(payload.statusMessage || payload.status || '');
    } else if (eventType === 'PolarAlignment') {
      // The error event carries azArcmin/altArcmin and (optionally) total.
      const az = Number(payload.azArcmin != null ? payload.azArcmin : (payload.az_arcmin || 0));
      const alt = Number(payload.altArcmin != null ? payload.altArcmin : (payload.alt_arcmin || 0));
      const total = payload.totalArcmin != null
        ? Number(payload.totalArcmin)
        : Math.sqrt(az * az + alt * alt);
      state.polarAlignment.totalErrorArcmin = total;
    }
    renderPolarAlignmentPanel();
  }

  function renderPolarAlignmentPanel() {
    const phaseEl = document.getElementById('pa-phase');
    const errEl = document.getElementById('pa-total-error');
    if (phaseEl) phaseEl.textContent = state.polarAlignment.phase || 'idle';
    if (errEl) {
      // `isFinite` coerces, so a string error figure passed the guard and then
      // threw on `.toFixed`, leaving the whole panel — phase included —
      // unpainted. The colour class keys off the same gated value, so an
      // unreadable error can no longer render green.
      const v = wireNumber(state.polarAlignment.totalErrorArcmin);
      errEl.textContent = v != null ? v.toFixed(2) + "'" : '--';
      errEl.className = 'status-value' + (v != null
        ? (v < 1.0 ? ' good' : (v < 5.0 ? ' warn' : ' error'))
        : '');
    }
    // Mirror into the modal step-3 readout.
    const mPhase = document.getElementById('pa-modal-phase');
    const mErr = document.getElementById('pa-modal-error');
    const mStat = document.getElementById('pa-modal-status');
    if (mPhase) mPhase.textContent = state.polarAlignment.phase || 'idle';
    if (mErr) {
      const v = wireNumber(state.polarAlignment.totalErrorArcmin);
      mErr.textContent = v != null ? v.toFixed(2) + "'" : '--';
    }
    if (mStat) mStat.textContent = state.polarAlignment.statusMessage || '--';
  }

  // ===========================================================================
  // Flat wizard
  // ===========================================================================

  function openFlatWizard() {
    if (!state.cameraDeviceId) {
      showToast('No camera connected', 'error');
      return;
    }
    state.flatWizard.calibrations = [];
    state.flatWizard.running = false;
    state.flatWizard.selectedFilters = {};
    document.getElementById('flat-wizard-progress').textContent = '--';
    const resultsList = document.getElementById('flat-wizard-results-list');
    if (resultsList) clearElement(resultsList);
    document.getElementById('btn-flat-wizard-build').disabled = true;
    document.getElementById('flat-wizard-manual-filters').value = '';
    openWizardModal('flat-wizard-modal');
  }

  function renderFlatWizardFilterList() {
    const container = document.getElementById('flat-wizard-filter-list');
    if (!container) return;
    clearElement(container);
    const positions = state.filterWheelPositions
      ? state.filterWheelPositions.positions
      : [];
    if (!positions || positions.length === 0) {
      container.appendChild(createEmptyState('No filter wheel — use manual entry below'));
      return;
    }
    for (const slot of positions) {
      const chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'flat-wizard-filter-chip';
      chip.textContent = slot.name;
      const selected = !!state.flatWizard.selectedFilters[slot.name];
      chip.setAttribute('aria-pressed', selected ? 'true' : 'false');
      chip.addEventListener('click', () => {
        const cur = chip.getAttribute('aria-pressed') === 'true';
        chip.setAttribute('aria-pressed', cur ? 'false' : 'true');
        state.flatWizard.selectedFilters[slot.name] = !cur;
      });
      container.appendChild(chip);
    }
  }

  function collectFlatWizardFilters() {
    // Prefer chips when the filter wheel is connected.
    const chosen = Object.entries(state.flatWizard.selectedFilters)
      .filter(([, v]) => !!v)
      .map(([k]) => k);
    if (chosen.length > 0) return chosen;
    // Fall back to manual entry.
    const raw = document.getElementById('flat-wizard-manual-filters').value;
    return String(raw || '')
      .split(',')
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
  }

  async function handleFlatWizardCalibrate() {
    if (!state.cameraDeviceId) {
      setWizardError('flat-wizard-modal', 'No camera connected');
      return;
    }
    const filters = collectFlatWizardFilters();
    if (filters.length === 0) {
      setWizardError('flat-wizard-modal', 'Select at least one filter');
      return;
    }
    const targetAdu = parseFloat(document.getElementById('flat-wizard-adu').value);
    const tolerance = parseFloat(document.getElementById('flat-wizard-tolerance').value);
    const binning = parseInt(document.getElementById('flat-wizard-binning').value, 10);

    if (!isFinite(targetAdu) || targetAdu <= 0) {
      setWizardError('flat-wizard-modal', 'Target ADU must be positive');
      return;
    }

    setWizardError('flat-wizard-modal', '');
    state.flatWizard.running = true;
    document.getElementById('btn-flat-wizard-calibrate').disabled = true;
    document.getElementById('btn-flat-wizard-build').disabled = true;
    document.getElementById('flat-wizard-progress').textContent =
      'Calibrating ' + filters.length + ' filter' +
      (filters.length === 1 ? '' : 's') + '... this can take minutes';

    try {
      const result = await api.flatWizardCalibrateMulti(state.cameraDeviceId, filters, {
        targetAdu,
        tolerance: tolerance / 100 * targetAdu,  // tolerance is absolute ADU on the server
        binX: binning || 1,
        binY: binning || 1,
      });
      state.flatWizard.calibrations = requireWireList(
        result, 'results', 'Flat calibration');
      renderFlatWizardResults();
      const ok = state.flatWizard.calibrations.filter((c) => c.success).length;
      document.getElementById('flat-wizard-progress').textContent =
        'Calibration complete: ' + ok + '/' + state.flatWizard.calibrations.length + ' filters converged';
      document.getElementById('btn-flat-wizard-build').disabled = ok === 0;
    } catch (e) {
      setWizardError('flat-wizard-modal', e.message);
      addLogEntry('error', describeApiError(e, 'Flat calibration'));
    } finally {
      state.flatWizard.running = false;
      document.getElementById('btn-flat-wizard-calibrate').disabled = false;
    }
  }

  function renderFlatWizardResults() {
    const list = document.getElementById('flat-wizard-results-list');
    if (!list) return;
    clearElement(list);
    for (const c of state.flatWizard.calibrations) {
      const row = document.createElement('div');
      row.className = 'wizard-list-entry';
      const name = document.createElement('span');
      name.textContent = c.filter;
      const value = document.createElement('span');
      value.className = c.success
        ? 'wizard-list-entry__ok'
        : 'wizard-list-entry__bad';
      const exposure = wireNumber(c.exposure);
      const adu = wireNumber(c.adu);
      value.textContent = c.success
        ? ((exposure != null ? exposure.toFixed(3) + 's' : '--')
          + ' @ ' + (adu != null ? Math.round(adu) + ' ADU' : '-- ADU'))
        : ('FAILED: ' + (c.errorMessage || 'no convergence'));
      row.appendChild(name);
      row.appendChild(value);
      list.appendChild(row);
    }
  }

  async function handleFlatWizardBuild() {
    if (!state.flatWizard.calibrations.length) {
      setWizardError('flat-wizard-modal', 'Run calibration first');
      return;
    }
    const framesPerFilter = parseInt(document.getElementById('flat-wizard-frames').value, 10);
    if (!isFinite(framesPerFilter) || framesPerFilter < 1) {
      setWizardError('flat-wizard-modal', 'Frames per filter must be ≥1');
      return;
    }
    try {
      const seq = await api.flatWizardGenerateSequence(state.flatWizard.calibrations, {
        framesPerFilter,
        onlySuccessful: true,
      });
      // Load the sequence into the sequencer so the operator can press Start.
      if (seq && seq.sequence) {
        await api.sequencerLoad(seq.sequence);
        document.getElementById('flat-wizard-result').textContent =
          'Loaded flat sequence (' + framesPerFilter + '× per filter)';
        addLogEntry('sequencer', 'Loaded flat sequence');
        showToast('Flat sequence loaded — open Sequencer to start');
        closeWizardModal('flat-wizard-modal');
      } else {
        throw new Error('Server returned no sequence');
      }
    } catch (e) {
      setWizardError('flat-wizard-modal', e.message);
      addLogEntry('error', describeApiError(e, 'Flat sequence build'));
    }
  }

  // ===========================================================================
  // Mosaic planner
  // ===========================================================================

  async function openMosaicWizard() {
    if (!api.isConnected) {
      showToast('Not connected', 'error');
      return;
    }
    state.mosaic.panels = null;
    const previewEl = document.getElementById('mosaic-preview');
    if (previewEl) {
      clearElement(previewEl);
      previewEl.appendChild(createEmptyState('Press Preview to compute panel layout'));
    }
    document.getElementById('mosaic-total-panels').textContent = '--';
    document.getElementById('mosaic-est-time').textContent = '--';
    document.getElementById('btn-mosaic-build').disabled = true;

    // Try to seed center coords from current mount position.
    if (state.mountStatus) {
      const raInput = document.getElementById('mosaic-center-ra');
      const decInput = document.getElementById('mosaic-center-dec');
      if (raInput && !raInput.value) raInput.value = formatRA(state.mountStatus.rightAscension);
      if (decInput && !decInput.value) decInput.value = formatDec(state.mountStatus.declination);
    }

    openWizardModal('mosaic-modal');
    applyMosaicRecommendedExposure().catch((e) => {
      addLogEntry('warning', 'Mosaic exposure recommendation unavailable: ' + e.message);
    });
  }

  async function applyMosaicRecommendedExposure() {
    const recommendation = await api.mosaicRecommendedExposure();
    if (!recommendation) return;

    const seconds = Number(recommendation.exposureSeconds);
    const count = parseInt(recommendation.exposuresPerPanel, 10);
    const binning = parseInt(recommendation.binning, 10);
    const exposureInput = document.getElementById('mosaic-exp-sec');
    const countInput = document.getElementById('mosaic-exp-count');
    const filterInput = document.getElementById('mosaic-exp-filter');
    const binInput = document.getElementById('mosaic-exp-bin');

    if (exposureInput && isFinite(seconds) && seconds > 0) {
      exposureInput.value = formatNumberForInput(seconds);
    }
    if (countInput && isFinite(count) && count > 0) {
      countInput.value = String(count);
    }
    if (filterInput && recommendation.filterName != null) {
      filterInput.value = recommendation.filterName || '';
    }
    if (binInput && isFinite(binning) && binning > 0) {
      binInput.value = String(binning);
    }
  }

  function formatNumberForInput(value) {
    const rounded = Math.round(value);
    return Math.abs(value - rounded) < 0.05 ? String(rounded) : value.toFixed(1);
  }

  function handleMosaicUseMountPosition() {
    if (!state.mountStatus) {
      setWizardError('mosaic-modal', 'No mount position available');
      return;
    }
    document.getElementById('mosaic-center-ra').value = formatRA(state.mountStatus.rightAscension);
    document.getElementById('mosaic-center-dec').value = formatDec(state.mountStatus.declination);
    setWizardError('mosaic-modal', '');
  }

  function readMosaicConfig() {
    const ra = parseRaHours(document.getElementById('mosaic-center-ra').value);
    const dec = parseDecDegrees(document.getElementById('mosaic-center-dec').value);
    const cols = parseInt(document.getElementById('mosaic-cols').value, 10);
    const rows = parseInt(document.getElementById('mosaic-rows').value, 10);
    const overlap = parseFloat(document.getElementById('mosaic-overlap').value);
    const rotation = parseFloat(document.getElementById('mosaic-rotation').value);

    if (!isFinite(ra) || ra < 0 || ra >= 24) throw new Error('Invalid center RA');
    if (!isFinite(dec) || dec < -90 || dec > 90) throw new Error('Invalid center Dec');
    if (!isFinite(cols) || cols < 1) throw new Error('Columns must be ≥1');
    if (!isFinite(rows) || rows < 1) throw new Error('Rows must be ≥1');
    if (!isFinite(overlap) || overlap < 0 || overlap >= 100) throw new Error('Overlap must be 0..100');

    // Panel width/height come from the active FOV config — we cannot compute
    // a meaningful mosaic without them.
    const fov = state.framing.fovWidthDegrees != null
      ? { w: state.framing.fovWidthDegrees, h: state.framing.fovHeightDegrees }
      : null;
    if (!fov || !isFinite(fov.w) || fov.w <= 0 || !isFinite(fov.h) || fov.h <= 0) {
      throw new Error('Panel FOV unknown — set focal length / camera in the active profile first');
    }

    return {
      centerRa: ra,
      centerDec: dec,
      panelWidthArcmin: fov.w * 60.0,
      panelHeightArcmin: fov.h * 60.0,
      overlapPercent: overlap,
      rotation: rotation || 0,
      panelsHorizontal: cols,
      panelsVertical: rows,
    };
  }

  async function handleMosaicPreview() {
    setWizardError('mosaic-modal', '');
    // The mosaic FOV depends on the planetarium fov-config; load it lazily.
    try {
      await loadFovConfigForFraming();
    } catch (e) {
      setWizardError('mosaic-modal', 'Could not load FOV config: ' + e.message);
      return;
    }
    let config;
    try {
      config = readMosaicConfig();
    } catch (e) {
      setWizardError('mosaic-modal', e.message);
      return;
    }
    state.mosaic.cols = config.panelsHorizontal;
    state.mosaic.rows = config.panelsVertical;
    try {
      const [panelsResp, timeResp] = await Promise.all([
        api.mosaicGeneratePanels(config),
        api.mosaicEstimateTime(config, {
          exposureSeconds: parseFloat(document.getElementById('mosaic-exp-sec').value) || 1,
          exposuresPerPanel: parseInt(document.getElementById('mosaic-exp-count').value, 10) || 1,
          filterName: document.getElementById('mosaic-exp-filter').value || null,
          binning: parseInt(document.getElementById('mosaic-exp-bin').value, 10) || 1,
        }),
      ]);
      state.mosaic.panels = requireWireList(panelsResp, 'panels', 'Mosaic panels');
      renderMosaicPreview();
      document.getElementById('mosaic-total-panels').textContent =
        state.mosaic.panels.length + ' panels';
      const secs = timeResp && timeResp.estimatedTimeSecs ? Number(timeResp.estimatedTimeSecs) : 0;
      document.getElementById('mosaic-est-time').textContent = formatDurationSecs(secs);
      document.getElementById('btn-mosaic-build').disabled = state.mosaic.panels.length === 0;
    } catch (e) {
      setWizardError('mosaic-modal', 'Preview failed: ' + e.message);
    }
  }

  function renderMosaicPreview() {
    const container = document.getElementById('mosaic-preview');
    if (!container) return;
    clearElement(container);
    const cols = state.mosaic.cols;
    const rows = state.mosaic.rows;
    container.style.gridTemplateColumns = 'repeat(' + cols + ', 1fr)';
    container.style.gridTemplateRows = 'repeat(' + rows + ', 1fr)';
    // Render panel cells in raster order. The server returns them in
    // panelIndex order; we map (row,col) directly so the visual layout
    // mirrors the sky orientation (top = north).
    const grid = new Array(cols * rows).fill(null);
    for (const p of state.mosaic.panels) {
      // Map (row,col) — panel.row is 0-based from top, panel.col 0-based from left.
      const idx = p.row * cols + p.col;
      grid[idx] = p;
    }
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const cell = document.createElement('div');
        cell.className = 'mosaic-tile';
        const p = grid[r * cols + c];
        cell.textContent = p
          ? ('#' + (p.panelIndex + 1) + '\n' + formatRA(p.raHours).slice(0, 7))
          : '·';
        container.appendChild(cell);
      }
    }
  }

  async function handleMosaicBuild() {
    setWizardError('mosaic-modal', '');
    let config;
    try {
      config = readMosaicConfig();
    } catch (e) {
      setWizardError('mosaic-modal', e.message);
      return;
    }
    const exposure = {
      exposureSeconds: parseFloat(document.getElementById('mosaic-exp-sec').value) || 1,
      exposuresPerPanel: parseInt(document.getElementById('mosaic-exp-count').value, 10) || 1,
      filterName: document.getElementById('mosaic-exp-filter').value || null,
      binning: parseInt(document.getElementById('mosaic-exp-bin').value, 10) || 1,
    };
    try {
      const resp = await api.mosaicGenerateSequence({
        mosaicName: 'Mosaic ' + state.mosaic.cols + 'x' + state.mosaic.rows,
        config,
        exposure,
        options: {
          serpentineOrdering: true,
          centerAfterSlew: true,
        },
      });
      const seq = resp && resp.sequence;
      if (!seq) throw new Error('Server returned no sequence');
      await api.sequencerLoad(seq);
      // A panel count the server did not send as a number is not a count:
      // interpolating it printed "Loaded banana-panel mosaic" at the operator.
      const totalPanels = wireNumber(seq.totalPanels);
      const estimate = wireNumber(seq.estimatedTimeSecs);
      const loaded = totalPanels != null
        ? 'Loaded ' + totalPanels + '-panel mosaic'
        : 'Loaded mosaic (panel count not reported)';
      document.getElementById('mosaic-wizard-result').textContent = loaded
        + (estimate != null ? ' (~' + formatDurationSecs(estimate) + ')' : '');
      addLogEntry('sequencer', 'Mosaic sequence loaded: ' + (totalPanels != null
        ? totalPanels + ' panels' : 'panel count not reported'));
      showToast('Mosaic loaded — open Sequencer to start');
      closeWizardModal('mosaic-modal');
    } catch (e) {
      setWizardError('mosaic-modal', 'Build failed: ' + e.message);
      addLogEntry('error', describeApiError(e, 'Mosaic build'));
    }
  }

  // ===========================================================================
  // Framing assistant
  // ===========================================================================

  async function openFramingWizard() {
    if (!api.isConnected) {
      showToast('Not connected', 'error');
      return;
    }
    state.framing.target = null;
    state.framing.rotation = 0;
    document.getElementById('framing-search').value = '';
    document.getElementById('framing-target-ra').value = '';
    document.getElementById('framing-target-dec').value = '';
    document.getElementById('framing-rotation').value = '0';
    document.getElementById('framing-rotation-readout').textContent = '0°';
    document.getElementById('framing-action-status').textContent = '--';
    openWizardModal('framing-modal');
  }

  async function loadFovConfigForFraming() {
    if (state.framing.fovWidthDegrees != null && state.framing.fovHeightDegrees != null) {
      return;
    }
    const fov = await api.getFovConfig();
    state.framing.fovWidthDegrees = fov && fov.fovWidthDegrees != null
      ? Number(fov.fovWidthDegrees)
      : null;
    state.framing.fovHeightDegrees = fov && fov.fovHeightDegrees != null
      ? Number(fov.fovHeightDegrees)
      : null;
  }

  function handleFramingSearchInput() {
    if (state.framing.searchDebounce) {
      clearTimeout(state.framing.searchDebounce);
    }
    state.framing.searchDebounce = setTimeout(runFramingSearch, 220);
  }

  async function runFramingSearch() {
    const input = document.getElementById('framing-search');
    if (!input) return;
    const query = input.value.trim();
    if (query.length < 1) {
      hideFramingSuggestions();
      return;
    }
    try {
      const result = await api.targetsSearch(query);
      renderFramingSuggestions((result && result.targets) || []);
    } catch (e) {
      addLogEntry('error', describeApiError(e, 'Framing target search'));
      hideFramingSuggestions();
    }
  }

  function renderFramingSuggestions(targets) {
    const list = document.getElementById('framing-search-suggestions');
    if (!list) return;
    clearElement(list);
    if (!targets || targets.length === 0) {
      hideFramingSuggestions();
      return;
    }
    const cap = Math.min(8, targets.length);
    for (let i = 0; i < cap; i++) {
      const t = targets[i];
      const item = document.createElement('button');
      item.type = 'button';
      item.className = 'autocomplete-item';
      item.setAttribute('role', 'option');
      const nameEl = document.createElement('span');
      nameEl.className = 'autocomplete-item__name';
      nameEl.textContent = t.name + (t.catalogId ? '  ' + t.catalogId : '');
      const metaEl = document.createElement('span');
      metaEl.className = 'autocomplete-item__meta';
      const meta = [];
      if (t.objectType) meta.push(t.objectType);
      if (t.constellation) meta.push(t.constellation);
      metaEl.textContent = meta.join(' · ');
      item.appendChild(nameEl);
      item.appendChild(metaEl);
      item.addEventListener('mousedown', (e) => {
        e.preventDefault();
        selectFramingTarget(t);
      });
      list.appendChild(item);
    }
    list.hidden = false;
  }

  function hideFramingSuggestions() {
    const list = document.getElementById('framing-search-suggestions');
    if (list) {
      list.hidden = true;
      clearElement(list);
    }
  }

  function selectFramingTarget(target) {
    state.framing.target = {
      id: target.id,
      name: target.name,
      ra: Number(target.ra),
      dec: Number(target.dec),
    };
    document.getElementById('framing-search').value = target.name || '';
    document.getElementById('framing-target-ra').value = formatRA(Number(target.ra));
    document.getElementById('framing-target-dec').value = formatDec(Number(target.dec));
    hideFramingSuggestions();
  }

  function handleFramingRotationChange() {
    const v = parseFloat(document.getElementById('framing-rotation').value);
    if (!isFinite(v)) return;
    state.framing.rotation = v;
    document.getElementById('framing-rotation-readout').textContent =
      v.toFixed(0) + '°';
    renderFramingPreview();
  }

  function readFramingCoordinates() {
    // The search step may have populated state.framing.target; the user can
    // also override coordinates directly. Read both and reconcile.
    const rawRa = document.getElementById('framing-target-ra').value;
    const rawDec = document.getElementById('framing-target-dec').value;
    const ra = parseRaHours(rawRa);
    const dec = parseDecDegrees(rawDec);
    if (!isFinite(ra) || ra < 0 || ra >= 24) throw new Error('Invalid RA');
    if (!isFinite(dec) || dec < -90 || dec > 90) throw new Error('Invalid Dec');
    const name = (state.framing.target && state.framing.target.name)
      || document.getElementById('framing-search').value || '';
    return { ra, dec, name };
  }

  function prepareFramingTargetForPreview() {
    setWizardError('framing-modal', '');
    try {
      const coordinates = readFramingCoordinates();
      state.framing.target = {
        ...(state.framing.target || {}),
        name: coordinates.name || 'Coordinates',
        ra: coordinates.ra,
        dec: coordinates.dec,
      };
      return true;
    } catch (e) {
      setWizardError(
        'framing-modal',
        'Choose a catalog result or enter valid RA and Dec before continuing.',
      );
      return false;
    }
  }

  function renderFramingPreview() {
    const container = document.getElementById('framing-preview');
    if (!container) return;
    clearElement(container);

    const target = state.framing.target;
    if (!target) {
      container.appendChild(createEmptyState('Pick a target on step 1'));
      return;
    }

    // SVG layout: 100x100 viewBox centered on the target. The FOV rectangle
    // is drawn proportional to the sky chart's nominal extent. Why a fixed
    // 100x100: the preview is purely indicative (the user is choosing PA,
    // not pixel-perfect framing), so a simple square sky window is enough.
    const svgNS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(svgNS, 'svg');
    svg.setAttribute('viewBox', '0 0 100 100');
    svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');

    // Sky background fill.
    const bg = document.createElementNS(svgNS, 'rect');
    bg.setAttribute('x', '0');
    bg.setAttribute('y', '0');
    bg.setAttribute('width', '100');
    bg.setAttribute('height', '100');
    bg.setAttribute('fill', themeColor('--color-background'));
    svg.appendChild(bg);

    // Target marker (cross).
    const cx = 50, cy = 50;
    for (const off of [{ x1: cx - 4, y1: cy, x2: cx + 4, y2: cy },
                       { x1: cx, y1: cy - 4, x2: cx, y2: cy + 4 }]) {
      const line = document.createElementNS(svgNS, 'line');
      line.setAttribute('x1', off.x1);
      line.setAttribute('y1', off.y1);
      line.setAttribute('x2', off.x2);
      line.setAttribute('y2', off.y2);
      line.setAttribute('stroke', themeColor('--color-warning'));
      line.setAttribute('stroke-width', '0.6');
      svg.appendChild(line);
    }

    // FOV rectangle — sized by the camera's aspect ratio, rotated by PA.
    // If FOV is unknown we draw a default square so the user still has a
    // rotation handle to play with; the actual slew will use raw RA/Dec.
    const aspect = (state.framing.fovWidthDegrees && state.framing.fovHeightDegrees)
      ? state.framing.fovWidthDegrees / state.framing.fovHeightDegrees
      : 1.5;
    const boxH = 40; // half the viewBox so it sits comfortably inside
    const boxW = boxH * aspect;
    const rect = document.createElementNS(svgNS, 'rect');
    rect.setAttribute('x', String(cx - boxW / 2));
    rect.setAttribute('y', String(cy - boxH / 2));
    rect.setAttribute('width', String(boxW));
    rect.setAttribute('height', String(boxH));
    rect.setAttribute('fill', 'none');
    rect.setAttribute('stroke', themeColor('--color-primary'));
    rect.setAttribute('stroke-width', '0.8');
    rect.setAttribute('transform', 'rotate(' + (-state.framing.rotation) + ' ' + cx + ' ' + cy + ')');
    svg.appendChild(rect);

    // Up indicator at FOV top (north when PA=0).
    const upLine = document.createElementNS(svgNS, 'line');
    upLine.setAttribute('x1', String(cx));
    upLine.setAttribute('y1', String(cy));
    upLine.setAttribute('x2', String(cx));
    upLine.setAttribute('y2', String(cy - boxH / 2));
    upLine.setAttribute('stroke', themeColor('--color-success'));
    upLine.setAttribute('stroke-width', '0.5');
    upLine.setAttribute('transform', 'rotate(' + (-state.framing.rotation) + ' ' + cx + ' ' + cy + ')');
    svg.appendChild(upLine);

    // Target label.
    const label = document.createElementNS(svgNS, 'text');
    label.setAttribute('x', '4');
    label.setAttribute('y', '8');
    label.setAttribute('fill', themeColor('--color-text-primary'));
    label.setAttribute('font-size', '4');
    label.setAttribute('font-family', 'monospace');
    label.textContent = target.name || '(target)';
    svg.appendChild(label);

    container.appendChild(svg);
  }

  async function handleFramingSlew() {
    setWizardError('framing-modal', '');
    try {
      const { ra, dec } = readFramingCoordinates();
      await api.framingSlewToTarget(ra, dec);
      document.getElementById('framing-action-status').textContent =
        'Slewing to RA ' + formatRA(ra) + ' Dec ' + formatDec(dec);
      addLogEntry('mount', 'Framing: slew started');
      showToast('Slew started');
    } catch (e) {
      setWizardError('framing-modal', e.message);
    }
  }

  async function handleFramingCenter() {
    setWizardError('framing-modal', '');
    try {
      const { ra, dec } = readFramingCoordinates();
      document.getElementById('framing-action-status').textContent =
        'Centering on target (plate-solve iteration)...';
      const result = await api.framingCenterOnTarget(ra, dec, {
        maxIterations: 5,
        toleranceArcsec: 30.0,
        exposureTime: 3.0,
        binning: 2,
      });
      // An unreported iteration count reads '--', not 0: "0 iter" claims the
      // centering converged without moving, which is a result nobody sent.
      const iterCount = wireNumber(result && result.iterations);
      const iters = iterCount != null ? String(iterCount) : '--';
      const offset = wireNumber(result && result.finalOffsetArcsec);
      const off = offset != null ? offset.toFixed(1) + '"' : '--';
      if (result && result.success) {
        document.getElementById('framing-action-status').textContent =
          'Centered (' + iters + ' iter, residual ' + off + ')';
        addLogEntry('mount', 'Framing: centered (' + iters + ' iter)');
        showToast('Centered on target');
      } else {
        const err = result && result.errorMessage ? result.errorMessage : 'unknown failure';
        throw new Error('Centering failed: ' + err);
      }
    } catch (e) {
      setWizardError('framing-modal', e.message);
      addLogEntry('error', describeApiError(e, 'Centering'));
    }
  }

  async function handleFramingRotate() {
    setWizardError('framing-modal', '');
    try {
      const angle = ((state.framing.rotation % 360) + 360) % 360;
      await api.framingRotateTo(angle);
      document.getElementById('framing-action-status').textContent =
        'Rotator slewing to ' + angle.toFixed(2) + '°';
      addLogEntry('rotator', 'Framing: rotator -> ' + angle.toFixed(2) + '°');
      showToast('Rotator slewing');
    } catch (e) {
      setWizardError('framing-modal', e.message);
    }
  }

  async function handleFramingSave() {
    // Persist the chosen framing on the selected target so future sequences
    // inherit it. Falls back to saving on a brand-new target row if none was
    // selected (the API surface is the same — PUT or POST /api/targets).
    setWizardError('framing-modal', '');
    try {
      const { ra, dec, name } = readFramingCoordinates();
      const positionAngle = state.framing.rotation;
      const payload = {
        name: name || ('Framing ' + new Date().toISOString()),
        ra,
        dec,
        positionAngle,
      };
      if (state.framing.target && state.framing.target.id) {
        payload.targetId = state.framing.target.id;
      }
      const resp = await api.framingSave(payload);
      document.getElementById('framing-action-status').textContent =
        'Saved framing (PA ' + positionAngle.toFixed(2) + '°)';
      document.getElementById('framing-wizard-result').textContent =
        'Last framing: ' + payload.name + ' @ PA ' + positionAngle.toFixed(2) + '°';
      addLogEntry('system', 'Framing saved for target ' + (resp && (resp.id || payload.name)));
      showToast('Framing saved');
    } catch (e) {
      setWizardError('framing-modal', e.message);
      addLogEntry('error', describeApiError(e, 'Save framing'));
    }
  }

  // ===========================================================================
  // Misc helpers
  // ===========================================================================

  function formatDurationSecs(secs) {
    if (!isFinite(secs) || secs <= 0) return '--';
    const total = Math.round(secs);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    if (h > 0) return h + 'h ' + m + 'm';
    if (m > 0) return m + 'm ' + s + 's';
    return s + 's';
  }

  // ===========================================================================
  // Capability navigation + auxiliary panels
  // ===========================================================================

  function scrollToPanel(panelId) {
    const el = document.getElementById(panelId);
    if (!el) return;
    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    if (document.body.classList.contains('layout--phone')) {
      for (const tab of document.querySelectorAll('.phone-tab')) {
        const extras = PHONE_TAB_EXTRA_PANELS[tab.dataset.target] || [];
        if (tab.dataset.target === panelId || extras.includes(panelId)) {
          activatePhoneTab(tab.dataset.target);
          break;
        }
      }
    }
  }

  function setupCapabilityNav() {
    for (const btn of document.querySelectorAll('[data-scroll-panel]')) {
      btn.addEventListener('click', () => {
        scrollToPanel(btn.getAttribute('data-scroll-panel'));
      });
    }
    // Run-Watch is a sibling page on this same origin, and an operator who has
    // just signed in here is signed in there too. That handoff rides the two
    // credentials this file already leaves behind, so it must stay a SAME-TAB
    // navigation: `skotiq_token` in sessionStorage (the bearer path, which
    // /run-watch/ adopts in memory for the tab's lifetime and never persists),
    // and the HttpOnly session cookie (the remember-me path, which
    // /run-watch/ confirms with GET /api/auth/csrf). Before that contract
    // existed the link dropped an authenticated operator onto the pairing wall.
    // Neither credential is put anywhere new for it; changing where this file
    // stores the bearer means changing DASHBOARD_TAB_TOKEN_KEY in
    // web_run_watch/js/run-watch.js with it.
    const runWatch = document.getElementById('nav-run-watch');
    if (runWatch) {
      runWatch.addEventListener('click', (e) => {
        e.preventDefault();
        window.location.href = '/run-watch/';
      });
    }
    updateParityBanner();
  }

  function updateParityBanner() {
    const banner = document.getElementById('parity-banner');
    if (!banner) return;
    // Only surface the Flutter-app nudge for GPU planetarium rendering — the
    // web dashboard implements REST-backed slew/FOV; full sky GPU view stays
    // on desktop/mobile clients.
    banner.classList.toggle('hidden', true);
  }

  function setupPlanetariumPanel() {
    const btnSlew = document.getElementById('btn-planetarium-slew');
    const btnRefresh = document.getElementById('btn-planetarium-refresh-mount');
    if (btnSlew) {
      btnSlew.addEventListener('click', async () => {
        const ra = parseFloat(document.getElementById('planetarium-ra').value);
        const dec = parseFloat(document.getElementById('planetarium-dec').value);
        if (!isFinite(ra) || !isFinite(dec)) {
          showToast('Enter valid RA (hours) and Dec (degrees)', 'error');
          return;
        }
        try {
          await api.planetariumSlewTo(ra, dec);
          showToast('Slew started');
          addLogEntry('mount', 'Planetarium slew to RA ' + ra + ' Dec ' + dec);
        } catch (e) {
          showToast('Slew failed: ' + e.message, 'error');
        }
      });
    }
    if (btnRefresh) {
      btnRefresh.addEventListener('click', () => refreshPlanetariumPanel());
    }
  }

  async function refreshPlanetariumPanel() {
    const raEl = document.getElementById('planetarium-mount-ra');
    const decEl = document.getElementById('planetarium-mount-dec');
    const fovEl = document.getElementById('planetarium-fov-text');
    if (!api.isConnected) return;
    try {
      const [pos, fov] = await Promise.all([
        api.planetariumGetMountPosition(),
        api.getFovConfig(),
      ]);
      const raH = wireNumber(pos.raHours ?? pos.ra);
      const decD = wireNumber(pos.decDegrees ?? pos.dec);
      if (raEl && raH != null) raEl.textContent = formatRA(raH);
      if (decEl && decD != null) decEl.textContent = formatDec(decD);
      if (fovEl && fov) {
        const w = wireNumber(fov.fovWidthDegrees ?? fov.widthDegrees);
        const h = wireNumber(fov.fovHeightDegrees ?? fov.heightDegrees);
        fovEl.textContent = (w != null && h != null)
          ? w.toFixed(2) + '° × ' + h.toFixed(2) + '°'
          : '--';
      }
    } catch (e) {
      if (fovEl) fovEl.textContent = '--';
    }
  }

  function setupSettingsPanel() {
    const btn = document.getElementById('btn-settings-refresh');
    if (btn) btn.addEventListener('click', () => refreshSettingsPanel());
  }

  /// The settings panel's own hint line, as index.html ships it. Kept so the
  /// panel can go back to describing itself once a read succeeds.
  let settingsPanelHint = null;

  /// Rows the settings panel fills from the host. Named once so a refusal can
  /// mark every one of them without the list drifting.
  const SETTINGS_VALUE_IDS = [
    'settings-observer-name', 'settings-save-path', 'settings-plate-solver',
    'settings-latitude', 'settings-longitude', 'settings-elevation',
  ];

  /// Say who refused the settings read, and why, IN the panel.
  ///
  /// Reading host settings is control-scope on the appliance — the payload
  /// carries the operator's Discord webhook, Pushover key and host filesystem
  /// paths (see `path_classification.dart`) — so a read-only session is
  /// refused it by design. The panel used to answer that by leaving every row
  /// at "--", which reads as "this host has no observer, no save path, no
  /// coordinates" on a fully configured rig; the reason existed only as one
  /// line buried in the Event Log.
  function saySettingsWithheld(sentence) {
    for (const id of SETTINGS_VALUE_IDS) {
      const el = document.getElementById(id);
      if (!el) continue;
      el.textContent = 'not permitted';
      el.title = sentence;
    }
    const hint = document.querySelector('#panel-settings .panel-hint');
    if (hint) {
      if (settingsPanelHint === null) settingsPanelHint = hint.textContent;
      hint.textContent = sentence;
    }
  }

  /// Take a previous refusal off the panel before painting real values.
  function clearSettingsWithheld() {
    for (const id of SETTINGS_VALUE_IDS) {
      const el = document.getElementById(id);
      if (el) el.title = '';
    }
    const hint = document.querySelector('#panel-settings .panel-hint');
    if (hint && settingsPanelHint !== null) hint.textContent = settingsPanelHint;
  }

  async function refreshSettingsPanel() {
    if (!api.isConnected) return;
    const setEl = (id, text) => {
      const el = document.getElementById(id);
      if (el) el.textContent = text;
    };
    try {
      const [settingsResp, locResp] = await Promise.all([
        api.getSettings(),
        api.getLocation(),
      ]);
      clearSettingsWithheld();
      const settings = settingsResp && settingsResp.settings;
      const loc = locResp && locResp.location;
      // Key names come from what GET /api/settings and GET
      // /api/settings/location actually emit. The previous four —
      // observatoryName, defaultSavePath, plateSolveSolver, elevationMeters —
      // exist in no server response, so those rows read "--" on a fully
      // configured host and the panel silently lied about being empty.
      setEl('settings-observer-name',
        settings && settings.observerName ? settings.observerName : '--');
      setEl('settings-save-path',
        settings && settings.imageOutputPath ? settings.imageOutputPath : '--');
      setEl('settings-plate-solver',
        settings && settings.plateSolver ? settings.plateSolver : '--');
      if (loc) {
        const latitude = wireNumber(loc.latitude);
        const longitude = wireNumber(loc.longitude);
        const elevation = wireNumber(loc.elevation);
        setEl('settings-latitude',
          latitude != null ? latitude.toFixed(4) + '°' : '--');
        setEl('settings-longitude',
          longitude != null ? longitude.toFixed(4) + '°' : '--');
        setEl('settings-elevation',
          elevation != null ? elevation.toFixed(0) + ' m' : '--');
      } else {
        setEl('settings-latitude', '--');
        setEl('settings-longitude', '--');
        setEl('settings-elevation', '--');
      }
    } catch (e) {
      if (e && e.kind === 'scope_denied') {
        saySettingsWithheld(describeScopeRefusal(e, 'Reading host settings'));
      }
      addLogEntry('error', describeApiError(e, 'Settings fetch'));
    }
  }

  // ===========================================================================
  // SPA surfaces
  //
  // Hash routing: #/run, #/devices, #/gallery, #/logs map to "active
  // panel" focus on a single-page grid. We do NOT hide the off-route
  // panels (the dashboard is intentionally scrollable on a laptop) —
  // the route just scrolls the matching panel into view + adds a
  // highlight class so the operator's eye lands in the right place.
  //
  // Image gallery: paginated thumbnail grid backed by /api/images.
  // Clicking a thumb opens a modal preview (no separate route — the
  // modal is dismissed by Escape / close button).
  //
  // Log tail: subscribes to /api/logs/tail (SSE). The panel can be
  // paused so a long burst of debug noise doesn't push the line the
  // operator was reading off-screen.
  //
  // Login overlay: shown on first visit when the SPA can't auto-
  // connect. The overlay is a strict gate — the dashboard's auto-
  // connect path only fires once `bootstrapAuthFlow()` resolves the
  // credentials question.
  // ===========================================================================

  const HASH_ROUTES = {
    'run': 'panel-sequencer',
    'devices': 'panel-devices',
    'gallery': 'panel-gallery',
    'logs': 'panel-logs',
    'mount': 'panel-mount',
    'camera': 'panel-camera',
    'guiding': 'panel-guiding',
    'sequences': 'ops-seq-load-panel',
    'analytics': 'ops-profile-panel',
    'planetarium': 'panel-planetarium',
    'settings': 'panel-settings',
  };

  /** Parse a hash like `#/logs` or `#/run/42` into {route, param}. */
  function parseHashRoute() {
    const raw = (window.location.hash || '').replace(/^#\/?/, '').trim();
    if (!raw) return { route: '', param: '' };
    const parts = raw.split('/');
    return { route: (parts[0] || '').toLowerCase(), param: parts[1] || '' };
  }

  function setupHashRouting() {
    // Capability nav buttons (.cap-nav-btn[data-route]) update the hash
    // when clicked. The hashchange listener below drives the actual
    // highlight; clicks just push the new hash.
    for (const btn of document.querySelectorAll('.cap-nav-btn[data-route]')) {
      btn.addEventListener('click', (e) => {
        const route = btn.dataset.route;
        if (!route) return;
        e.preventDefault();
        const next = '#/' + route;
        if (window.location.hash !== next) {
          window.location.hash = next;
        } else {
          applyHashRoute();
        }
      });
    }
    // Direct hash bookmarks must work on first load too.
    window.addEventListener('hashchange', applyHashRoute);
    applyHashRoute();
  }

  function applyHashRoute() {
    const { route, param } = parseHashRoute();
    if (!route) return;
    const panelId = HASH_ROUTES[route];
    if (!panelId) return;
    const panel = document.getElementById(panelId);
    if (!panel) return;
    // Clear any previous highlight.
    for (const p of document.querySelectorAll('.panel.route-active')) {
      p.classList.remove('route-active');
    }
    panel.classList.add('route-active');
    panel.scrollIntoView({ behavior: 'smooth', block: 'start' });

    // Mark the matching capability-nav button as the active one so the
    // breadcrumb hint matches the URL on a reload.
    for (const btn of document.querySelectorAll('.cap-nav-btn[data-route]')) {
      btn.classList.toggle('cap-nav-active', btn.dataset.route === route);
    }

    // Route-specific side effects:
    // * #/gallery — fetch the latest gallery page so the operator
    //   doesn't have to click Refresh after deep-linking.
    // * #/logs — make sure the SSE stream is running; the panel may
    //   have been paused on a previous visit.
    if (route === 'gallery' && api.isConnected) {
      refreshGalleryFromServer();
    } else if (route === 'logs') {
      ensureLogTailRunning();
    } else if (route === 'run' && param) {
      // #/run/<runId> reserved for the replay scrubber (W7B). The
      // dashboard surface it lands on is the sequencer panel — the
      // deeper replay UI is desktop-only. Surface a hint instead of
      // failing silently.
      addLogEntry('system', 'Run replay #' + param +
          ' is available on the desktop client.');
    }
  }

  // =========================================================================
  // Image gallery
  // =========================================================================

  const gallery = {
    items: [],
    loading: false,
    freshSinceLastView: 0,
    thumbnailObjectUrls: new Set(),
    modalPreviewUrl: '',
    modalLoadGeneration: 0,
    downloadInFlight: false,
  };

  function setupGalleryPanel() {
    const refresh = document.getElementById('btn-gallery-refresh');
    if (refresh) {
      refresh.addEventListener('click', () => refreshGalleryFromServer());
    }
    const closeBtn = document.getElementById('btn-gallery-modal-close');
    if (closeBtn) {
      closeBtn.addEventListener('click', closeGalleryModal);
    }
    const modal = document.getElementById('gallery-modal');
    if (modal) {
      modal.addEventListener('click', (e) => {
        if (e.target === modal) closeGalleryModal();
      });
    }
    const download = document.getElementById('gallery-modal-download');
    if (download) {
      download.addEventListener('click', (e) => {
        if (!api.usesHeaderAuth) return;
        e.preventDefault();
        if (gallery.downloadInFlight) return;
        const imageId = download.dataset.imageId || '';
        if (imageId) downloadGalleryOriginal(imageId, download);
      });
    }
    // Listen for ExposureComplete events to surface the "NEW" badge.
    api.on('event', (data) => {
      const cat = data.category || data.event_category || '';
      if (cat !== 'camera' && cat !== 'imaging') return;
      const type = data.eventType || data.event || '';
      if (!isExposureCompleteEvent(type)) return;
      gallery.freshSinceLastView += 1;
      const badge = document.getElementById('gallery-fresh-badge');
      if (badge) {
        badge.textContent = 'NEW';
        badge.classList.remove('hidden-inline');
      }
    });
  }

  async function refreshGalleryFromServer() {
    if (gallery.loading) return;
    const grid = document.getElementById('gallery-grid');
    const status = document.getElementById('gallery-status');
    gallery.loading = true;
    if (status) status.textContent = 'Loading recent images...';
    try {
      const resp = await api.imagesGetAll({ limit: 24 });
      // `/api/images` names its listing `images`; `items` is accepted because
      // an older build of the same route used that name. Neither present means
      // the answer said nothing about this night's frames, and the branch
      // below would print "No images captured yet." over it.
      const named = resp && typeof resp === 'object' &&
        Array.isArray(resp.items) && !Array.isArray(resp.images)
        ? 'items' : 'images';
      gallery.items = requireWireList(resp, named, 'Image listing');
      renderGallery();
      if (status) status.textContent = galleryCountLine(gallery.items);
      gallery.freshSinceLastView = 0;
      const badge = document.getElementById('gallery-fresh-badge');
      if (badge) badge.classList.add('hidden-inline');
    } catch (e) {
      // The tiles already on screen stay: they are what the last good read
      // said, and this line is what says they may no longer be current. What
      // must not appear here is "No images captured yet." — that sentence is
      // reserved for an answer that listed zero frames.
      if (status) status.textContent = describeApiError(e, 'Gallery fetch');
      addLogEntry('error', describeApiError(e, 'Gallery fetch'));
    } finally {
      gallery.loading = false;
    }
  }

  // The grader's verdict on one frame, or null when the listing carried none.
  //
  // `/api/images` answers `isAccepted` + `rejectionReason` on every row, and
  // the gallery threw both away: a sub the grader had thrown out for "star
  // count 43 below minimum 100000 (likely cloud / off-target)" rendered
  // pixel-identical to a keeper — same markup, same aria-label, nothing in the
  // preview modal either. Measured against one harness night, 26 of the 38
  // tiles on screen were rejects and the panel called them all "38 images
  // shown."
  //
  // Absent is distinct from accepted: an older server, or a frame graded
  // before the column existed, says nothing about the verdict, and the card
  // must not invent one in either direction.
  function galleryRejection(item) {
    if (!item || item.isAccepted !== false) return null;
    const reason = typeof item.rejectionReason === 'string'
      ? item.rejectionReason.trim() : '';
    return { reason: reason };
  }

  /// The count line under the grid, which states the grader's tally as well as
  /// the total: a night whose frames were mostly thrown out must not read the
  /// same as a night that kept them all.
  function galleryCountLine(items) {
    const list = Array.isArray(items) ? items : [];
    if (list.length === 0) return 'No images captured yet.';
    const shown = list.length + ' image' + (list.length === 1 ? '' : 's');
    const rejected = list.filter((i) => galleryRejection(i)).length;
    if (rejected === 0) return shown + ' shown.';
    return shown + ' — ' + rejected + ' rejected.';
  }

  function renderGallery() {
    const grid = document.getElementById('gallery-grid');
    if (!grid) return;
    revokeGalleryThumbnailUrls();
    if (gallery.items.length === 0) {
      grid.innerHTML = '<div class="empty-state">No captured images yet.</div>';
      return;
    }
    grid.innerHTML = '';
    for (const item of gallery.items) {
      const card = document.createElement('button');
      card.type = 'button';
      card.className = 'gallery-card';
      card.setAttribute('role', 'listitem');
      const meta = formatGalleryMeta(item);
      const rejection = galleryRejection(item);
      // The verdict rides the accessible name too: a screen reader gets the
      // same fact the badge shows, in the same breath as the frame's identity.
      card.setAttribute('aria-label',
        rejection ? meta + ' — rejected by the grader' : meta);
      if (rejection) card.classList.add('gallery-card-rejected');
      const id = String(item.id ?? item.imageId ?? '');
      if (id) {
        const img = document.createElement('img');
        img.className = 'gallery-thumb';
        img.loading = 'lazy';
        img.alt = meta;
        img.onerror = () => markGalleryThumbUnavailable(img);
        loadGalleryThumbnail(img, id, { maxWidth: 280, quality: 70 });
        card.appendChild(img);
      }
      const label = document.createElement('div');
      label.className = 'gallery-caption';
      label.textContent = meta;
      card.appendChild(label);
      if (rejection) {
        const verdict = document.createElement('div');
        verdict.className = 'gallery-caption';
        const badge = document.createElement('span');
        badge.className = 'badge badge-error';
        badge.textContent = 'Rejected';
        verdict.appendChild(badge);
        // The reason as the grader wrote it. A rejection with no reason on the
        // wire keeps the badge and says no more — the badge is the part that
        // was actually asserted.
        if (rejection.reason) {
          const why = document.createElement('span');
          why.className = 'gallery-reject-reason';
          why.textContent = ' ' + rejection.reason;
          verdict.appendChild(why);
        }
        card.appendChild(verdict);
      }
      card.addEventListener('click', () => openGalleryModal(item));
      grid.appendChild(card);
    }
  }

  // A thumbnail can legitimately fail: `/api/images/<id>/thumbnail` returns
  // 404 "Image file not found" whenever the FITS behind a surviving DB row is
  // gone — moved to external storage that is currently detached, pruned, or
  // deleted by hand. Both failure paths used to set `display:none` on the
  // <img>, which collapsed the card's 100px media slot and left a bare
  // timestamp, so a gallery of unreachable frames rendered as a list of dates
  // with no hint that anything was missing. Keep the slot and label it.
  function markGalleryThumbUnavailable(img, reason) {
    if (!img || !img.parentNode) return;
    const placeholder = document.createElement('div');
    placeholder.className = 'gallery-thumb gallery-thumb-missing';
    placeholder.setAttribute('role', 'img');
    placeholder.setAttribute('aria-label', 'Preview unavailable');
    placeholder.textContent = 'Preview unavailable';
    if (reason) placeholder.title = String(reason);
    img.parentNode.replaceChild(placeholder, img);
  }

  function revokeGalleryThumbnailUrls() {
    for (const url of gallery.thumbnailObjectUrls) {
      URL.revokeObjectURL(url);
    }
    gallery.thumbnailObjectUrls.clear();
  }

  /// [onUnavailable] is how a caller outside the grid labels a thumbnail that
  /// will not load — the camera panel's library fallback shares this loader
  /// (and its two auth paths) but not the gallery card's markup.
  async function loadGalleryThumbnail(img, imageId, opts, onUnavailable) {
    const markUnavailable = onUnavailable || markGalleryThumbUnavailable;
    if (!api.usesHeaderAuth) {
      img.src = api.imageThumbnailUrl(imageId, opts);
      return;
    }
    try {
      const result = await api.imageThumbnailBlob(imageId, opts);
      if (!img.isConnected) return;
      const url = URL.createObjectURL(result.blob);
      gallery.thumbnailObjectUrls.add(url);
      img.src = url;
    } catch (e) {
      markUnavailable(img, e.message);
      addLogEntry(
        'error',
        'Gallery thumbnail ' + imageId + ' failed: ' + e.message,
      );
    }
  }

  function formatGalleryMeta(item) {
    if (!item) return 'Image';
    const target = item.targetName || item.target || '';
    const filter = item.filter || item.filterName || '';
    const exp = wireNumber(item.exposureTime ?? item.exposure);
    const created = item.createdAt || item.timestamp || item.capturedAt;
    const parts = [];
    if (target) parts.push(target);
    if (filter) parts.push(filter);
    if (exp != null) parts.push(exp + 's');
    if (created) {
      const ts = typeof created === 'number'
        ? new Date(created)
        : new Date(String(created));
      if (!isNaN(ts.getTime())) {
        parts.push(ts.toLocaleString());
      }
    }
    return parts.length ? parts.join(' · ') : ('Image #' + (item.id ?? ''));
  }

  /// The preview header: the frame's identity, plus the grader's verdict when
  /// there is one. Accepted frames read exactly as they did.
  function galleryModalMeta(item) {
    const meta = formatGalleryMeta(item);
    const rejection = galleryRejection(item);
    if (!rejection) return meta;
    return rejection.reason
      ? meta + ' — REJECTED: ' + rejection.reason
      : meta + ' — REJECTED';
  }

  async function openGalleryModal(item) {
    const modal = document.getElementById('gallery-modal');
    if (!modal) return;
    const id = String(item.id ?? item.imageId ?? '');
    if (!id) return;
    const meta = document.getElementById('gallery-modal-meta');
    // The verdict travels with the frame into the preview. Opening a reject
    // full-size used to show the same header line as a keeper — "L · 8/18/2026,
    // 7:51:35 AM / Download original / Close" — so the one place an operator
    // goes to judge a frame was the one place the grader's judgement was
    // missing.
    if (meta) meta.textContent = galleryModalMeta(item);
    const generation = ++gallery.modalLoadGeneration;
    if (gallery.modalPreviewUrl) {
      URL.revokeObjectURL(gallery.modalPreviewUrl);
      gallery.modalPreviewUrl = '';
    }
    const img = document.getElementById('gallery-modal-image');
    if (img) {
      img.alt = 'Preview of ' + galleryModalMeta(item);
      img.style.display = '';
      img.removeAttribute('src');
    }
    const dl = document.getElementById('gallery-modal-download');
    if (dl) {
      dl.dataset.imageId = id;
      dl.href = api.usesHeaderAuth ? '#' : api.imageDownloadUrl(id);
    }
    modal.removeAttribute('hidden');
    modal.classList.add('visible');

    if (!img) return;
    if (!api.usesHeaderAuth) {
      img.src = api.imageThumbnailUrl(id, { maxWidth: 1600, quality: 85 });
      return;
    }
    try {
      const result = await api.imageThumbnailBlob(id, {
        maxWidth: 1600,
        quality: 85,
      });
      if (generation !== gallery.modalLoadGeneration ||
          !modal.classList.contains('visible')) {
        return;
      }
      gallery.modalPreviewUrl = URL.createObjectURL(result.blob);
      img.src = gallery.modalPreviewUrl;
    } catch (e) {
      if (generation !== gallery.modalLoadGeneration) return;
      img.style.display = 'none';
      showToast('Preview failed: ' + e.message, 'error');
    }
  }

  function closeGalleryModal() {
    const modal = document.getElementById('gallery-modal');
    if (!modal) return;
    gallery.modalLoadGeneration += 1;
    if (gallery.modalPreviewUrl) {
      URL.revokeObjectURL(gallery.modalPreviewUrl);
      gallery.modalPreviewUrl = '';
    }
    modal.classList.remove('visible');
    modal.setAttribute('hidden', '');
  }

  async function downloadGalleryOriginal(imageId, control) {
    gallery.downloadInFlight = true;
    const previousText = control.textContent;
    control.setAttribute('aria-disabled', 'true');
    control.textContent = 'Downloading...';
    try {
      const result = await api.imageDownloadBlob(imageId);
      const url = URL.createObjectURL(result.blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = downloadFilename(
        result.contentDisposition,
        'skotiq-image-' + imageId + '.fits',
      );
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      setTimeout(() => URL.revokeObjectURL(url), 0);
    } catch (e) {
      showToast('Download failed: ' + e.message, 'error');
      addLogEntry('error', describeApiError(e, 'Image download'));
    } finally {
      gallery.downloadInFlight = false;
      control.removeAttribute('aria-disabled');
      control.textContent = previousText;
    }
  }

  function downloadFilename(contentDisposition, fallback) {
    const encoded = /filename\*=UTF-8''([^;]+)/i.exec(contentDisposition || '');
    if (encoded && encoded[1]) {
      try {
        return decodeURIComponent(encoded[1].replace(/^"|"$/g, ''));
      } catch (_) {
        return fallback;
      }
    }
    const plain = /filename="?([^";]+)"?/i.exec(contentDisposition || '');
    return plain && plain[1] ? plain[1] : fallback;
  }

  // =========================================================================
  // Server log tail (SSE)
  // =========================================================================

  const logTail = {
    eventSource: null,
    paused: false,
    minSeverity: 'info',
    entries: [],
    maxEntries: 500,
  };

  function setupLogsPanel() {
    const pause = document.getElementById('btn-logs-pause');
    if (pause) {
      pause.addEventListener('click', () => {
        logTail.paused = !logTail.paused;
        pause.textContent = logTail.paused ? 'Resume' : 'Pause';
        if (!logTail.paused) ensureLogTailRunning();
        else stopLogTail();
      });
    }
    const clear = document.getElementById('btn-logs-clear');
    if (clear) {
      clear.addEventListener('click', () => {
        logTail.entries = [];
        renderLogsPanel();
      });
    }
    const sev = document.getElementById('logs-min-severity');
    if (sev) {
      sev.addEventListener('change', () => {
        logTail.minSeverity = sev.value;
        // Re-subscribe so the server-side filter changes too — local
        // filtering would still pay the bandwidth of trace lines.
        stopLogTail();
        if (!logTail.paused) ensureLogTailRunning();
      });
    }
  }

  function ensureLogTailRunning() {
    if (logTail.eventSource) return;
    if (logTail.paused) return;
    if (!api.isConnected) {
      // The dashboard's connect path will re-call ensureLogTailRunning
      // through applyHashRoute or the user clicking the Logs nav after
      // we have authentication, so silently no-op rather than spinning
      // up an SSE that the server will immediately reject.
      setLogStreamState('offline');
      return;
    }
    try {
      setLogStreamState('connecting');
      logTail.eventSource = api.subscribeLogTail(
        logTail.minSeverity,
        handleLogEntry,
        (err) => {
          addLogEntry('error', 'Log tail error: ' +
              (err && err.message ? err.message : 'stream closed'));
          setLogStreamState('error');
          stopLogTail();
        },
        // "live" is claimed when the server says its replay is finished, not
        // when the socket opens. An open socket only proves the connection
        // exists — it is exactly what the badge read while the panel received
        // nothing at all — whereas `replay-done` is the server's own statement
        // that everything after it is happening now.
        () => setLogStreamState('live'),
      );
    } catch (e) {
      addLogEntry('error', describeApiError(e, 'Log tail subscribe'));
      setLogStreamState('error');
    }
  }

  function stopLogTail() {
    if (logTail.eventSource) {
      try { logTail.eventSource.close(); } catch (_) { /* ignore */ }
      logTail.eventSource = null;
    }
    setLogStreamState('offline');
  }

  function setLogStreamState(state) {
    const badge = document.getElementById('logs-stream-state');
    if (!badge) return;
    badge.textContent = state;
    badge.className = 'badge ' + (
      state === 'live' ? 'badge-running'
        : state === 'connecting' ? 'badge-paused'
        : state === 'error' ? 'badge-error'
        : 'badge-idle');
  }

  function handleLogEntry(payload) {
    if (!payload) return;
    logTail.entries.push(payload);
    if (logTail.entries.length > logTail.maxEntries) {
      logTail.entries.splice(0, logTail.entries.length - logTail.maxEntries);
    }
    appendLogRow(payload);
  }

  function appendLogRow(payload) {
    const container = document.getElementById('logs-container');
    if (!container) return;
    const empty = container.querySelector('.empty-state');
    if (empty) empty.remove();
    const row = document.createElement('div');
    // `LogEntry.toJson` (logging_service.dart) emits exactly timestamp /
    // severity / source / message / fields. `level`, `target`, `module`,
    // `category` and `msg` are keys no frame carries — the severity fell back
    // to "info" for every row and the source column was blank on all of them.
    const severity = String(payload.severity || 'info').toLowerCase();
    row.className = 'log-entry log-' + severity;
    const ts = payload.timestamp;
    const tsLabel = ts ? new Date(String(ts)).toLocaleTimeString() : '';
    const target = payload.source || '';
    const message = payload.message || JSON.stringify(payload);
    row.innerHTML = '';
    const tsEl = document.createElement('span');
    tsEl.className = 'log-time';
    tsEl.textContent = tsLabel;
    const sevEl = document.createElement('span');
    sevEl.className = 'log-sev';
    sevEl.textContent = severity.toUpperCase();
    const tgtEl = document.createElement('span');
    tgtEl.className = 'log-target';
    tgtEl.textContent = target;
    const msgEl = document.createElement('span');
    msgEl.className = 'log-message';
    msgEl.textContent = message;
    row.appendChild(tsEl);
    row.appendChild(sevEl);
    if (target) row.appendChild(tgtEl);
    row.appendChild(msgEl);
    container.appendChild(row);
    // Keep the DOM bounded — if we've gone over the limit, drop the
    // oldest rows. Reflows are cheap because the container has fixed
    // height + overflow-y: auto.
    while (container.childElementCount > logTail.maxEntries) {
      container.removeChild(container.firstElementChild);
    }
    // Auto-scroll only when the user is already at the bottom — don't
    // yank them off whatever they were reading.
    const atBottom = container.scrollTop + container.clientHeight + 50 >=
        container.scrollHeight;
    if (atBottom) container.scrollTop = container.scrollHeight;
  }

  function renderLogsPanel() {
    const container = document.getElementById('logs-container');
    if (!container) return;
    container.innerHTML = '';
    if (logTail.entries.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'empty-state';
      empty.textContent = 'Waiting for log entries…';
      container.appendChild(empty);
      return;
    }
    for (const e of logTail.entries) appendLogRow(e);
  }

  // =========================================================================
  // Login overlay + bootstrap
  // =========================================================================

  function setupLoginOverlay() {
    const submit = document.getElementById('btn-login-submit');
    const pair = document.getElementById('btn-login-pair');
    if (submit) submit.addEventListener('click', handleLoginSubmit);
    if (pair) {
      pair.addEventListener('click', () => {
        hideLoginOverlay();
        openPairModal();
      });
    }
    const tokenInput = document.getElementById('login-token');
    if (tokenInput) {
      tokenInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') handleLoginSubmit();
      });
    }
  }

  /**
   * Decide whether to show the login overlay and (when not shown) kick
   * off the auto-connect. We trust three signals:
   *   1. A sessionStorage bearer token (the existing dashboard path).
   *   2. An HttpOnly session cookie (validated via /api/auth/csrf).
   *   3. A reachable /api/info that reports `authRequired: false`.
   * If none of the above resolves to "authenticated", surface the
   * overlay so the user can pair or paste a token.
   */
  async function bootstrapAuthFlow() {
    const overlay = document.getElementById('login-overlay');
    const tokenInput = document.getElementById('login-token');
    const urlInput = document.getElementById('login-server-url');
    if (urlInput) {
      const current = normalizeServerUrl(
          document.getElementById('server-url').value);
      urlInput.value = current;
    }

    // If a token is already present (sessionStorage), just connect. The
    // overlay comes back if that token no longer works — a stored credential
    // the desktop has since refused is the same dead end as a mistyped one,
    // reached on a reload instead of on a click.
    const existingToken = readStoredToken();
    if (existingToken) {
      hideLoginOverlay();
      const outcome = await handleConnect();
      if (isCredentialFailure(outcome)) {
        reportLoginFailure(outcome);
        return;
      }
      // After connect, drive any route-specific side effects (e.g.
      // if the user landed on #/logs, start the SSE now that we
      // have credentials).
      applyHashRoute();
      return;
    }

    // Probe the server for an existing cookie session or an auth-off
    // host. The api singleton has already been configured by the
    // outer init() with the current URL + empty token; we issue a
    // minimal /api/info call to test reachability, then call
    // tryResumeCookieSession (cheap when no cookie).
    try {
      api.configure(
        normalizeServerUrl(document.getElementById('server-url').value),
        '',
        localStorage.getItem('skotiq_device_id') || generateDeviceId(),
      );
      const info = await api.testConnection();
      if (info && info.authRequired === false) {
        // No auth needed — auto-connect runs the rest of the
        // bootstrap. The overlay is hidden so the dashboard renders.
        hideLoginOverlay();
        const outcome = await handleConnect();
        if (isCredentialFailure(outcome)) {
          reportLoginFailure(outcome);
          return;
        }
        applyHashRoute();
        return;
      }
      const resumed = await api.tryResumeCookieSession();
      if (resumed) {
        hideLoginOverlay();
        // A cookie the server minted can still be refused later — it expires,
        // and the desktop can drop the bearer bound to it. The form is the way
        // back from that, and only from that.
        const outcome = await handleConnect();
        if (isCredentialFailure(outcome)) {
          reportLoginFailure(outcome);
          return;
        }
        applyHashRoute();
        return;
      }
    } catch (_) {
      // Reachability failed — fall through to the overlay so the
      // operator can paste a token or fix the URL.
    }
    if (tokenInput) tokenInput.value = '';
    showLoginOverlay();
  }

  async function handleLoginSubmit() {
    const urlEl = document.getElementById('login-server-url');
    const tokenEl = document.getElementById('login-token');
    const rememberEl = document.getElementById('login-remember');
    const statusEl = document.getElementById('login-status');
    const url = urlEl ? normalizeServerUrl(urlEl.value) : '';
    const token = tokenEl ? tokenEl.value.trim() : '';
    if (!url) {
      if (statusEl) {
        statusEl.textContent = 'Enter a valid http:// or https:// URL.';
        statusEl.className = 'login-status error';
      }
      return;
    }
    if (!token) {
      if (statusEl) {
        statusEl.textContent = 'Paste a bearer token, or click "Pair this browser".';
        statusEl.className = 'login-status error';
      }
      return;
    }
    // Reject an unreachable cross-origin URL while the overlay is still up.
    // Letting it through dismissed the overlay first and left the operator on
    // a permanently "Disconnected" dashboard with no way back to this form
    // short of reloading the page.
    if (!isSameOriginServerUrl(url)) {
      if (statusEl) {
        statusEl.textContent = crossOriginServerMessage(url);
        statusEl.className = 'login-status error';
      }
      return;
    }
    document.getElementById('server-url').value = url;
    document.getElementById('auth-token').value = token;
    const remember = rememberEl ? rememberEl.checked : true;
    document.getElementById('remember-token').checked = remember;
    writeStoredToken(token, remember);
    if (statusEl) {
      statusEl.textContent = 'Signing in...';
      statusEl.className = 'login-status';
    }
    // The overlay stays up until the connection is known good. Hiding it here
    // dismissed the only surface that can fix a credential: measured against
    // the release bundle, a rejected bearer left the dashboard "Disconnected"
    // with `#login-status` reading "Signing in..." forty seconds later, and
    // both fallback controls (#btn-apply-token, #btn-pair) zero-size inside a
    // collapsed <details>.
    const outcome = await handleConnect();
    if (!outcome || !outcome.ok) {
      reportLoginFailure(outcome);
      return;
    }
    hideLoginOverlay();
    applyHashRoute();
  }

  /// Whether a failed connect is the credential's fault.
  ///
  /// The automatic bootstrap paths use this to decide whether to raise the
  /// sign-in form: a server that did not answer is not asking for a token, and
  /// putting "Paste a bearer token" in front of that failure would send the
  /// operator hunting for a credential the server may not even want. Those
  /// failures are already stated by the link banner and the panels' own stale
  /// lines. A credential the desktop refused is a different matter — the form
  /// is the only place it can be replaced.
  ///
  /// A credential the desktop ACCEPTED and that is short of scope belongs here
  /// too: the dashboard cannot run on it, the form is where a wider pairing is
  /// started, and leaving it out raised the overlay with an empty status line —
  /// a sign-in that failed and said nothing. It is NOT scrubbed, though; see
  /// [reportLoginFailure].
  function isCredentialFailure(outcome) {
    return Boolean(outcome) &&
      (outcome.kind === 'rejected' ||
        outcome.kind === 'insufficient_scope' ||
        outcome.kind === 'needs_credential');
  }

  /// Put a failed sign-in back in front of the operator, in words, on the
  /// form that can act on it.
  ///
  /// A credential the desktop refused is also scrubbed from sessionStorage:
  /// left there it survives a reload, and `bootstrapAuthFlow` hides the
  /// overlay for any stored token, which is the same dead end reached by a
  /// different door.
  ///
  /// A credential that is merely short of scope is NOT scrubbed. The desktop
  /// accepted it; it still works for everything it does hold, and throwing it
  /// away would make the operator re-pair to get back to where they were.
  function reportLoginFailure(outcome) {
    const failure = outcome || { kind: 'failed', message: 'Sign-in failed.' };
    if (failure.kind === 'rejected') {
      writeStoredToken('', document.getElementById('remember-token').checked);
    }
    showLoginOverlay();
    const statusEl = document.getElementById('login-status');
    if (statusEl) {
      statusEl.textContent = failure.message;
      statusEl.className = 'login-status error';
    }
  }

  function showLoginOverlay() {
    const overlay = document.getElementById('login-overlay');
    if (!overlay) return;
    overlay.classList.remove('hidden');
    overlay.removeAttribute('hidden');
  }

  function hideLoginOverlay() {
    const overlay = document.getElementById('login-overlay');
    if (!overlay) return;
    overlay.classList.add('hidden');
    overlay.setAttribute('hidden', '');
  }

  // After a connect succeeds, surface any side effects the route
  // requested before credentials were available (e.g. start the log
  // tail subscription). We hook into api ws:connected as a proxy for
  // "the dashboard is authenticated and live."
  api.on('ws:connected', () => {
    // Re-run the hash route handler so #/logs auto-starts the SSE
    // subscription now that we have a bearer.
    const { route } = parseHashRoute();
    if (route === 'logs') ensureLogTailRunning();
    if (route === 'gallery') refreshGalleryFromServer();
  });

})();
