// Connection-troubleshooter model + remediation knowledge base.
//
// When a device fails to connect during onboarding (or anywhere else),
// the raw driver error is hostile to the user — bare ASCOM HRESULTs like
// `0x800706ba`, Alpaca `connection refused`, INDI `timed out`. The device
// error pipeline keeps that raw text for the audit trail (see
// `PrettyError` in driver_error_pretty.dart), but a first-light user needs
// to be told, in plain language, *what to do next*.
//
// This file is a pure, side-effect-free knowledge base. Given the device
// type, the driver type, and the raw error string, [diagnoseConnectionFailure]
// classifies the failure into a [DiagnosticCategory] and produces a
// [ConnectionDiagnosis] with branched, hardware-aware [RemediationStep]s.
//
// Design rules:
//   * The raw error is ALWAYS carried through into [ConnectionDiagnosis.rawError]
//     verbatim — we never hide the real message just because we recognized it.
//   * There is no silent fallback. An unrecognized failure still produces a
//     concrete, non-empty list of useful steps under [DiagnosticCategory.unknown]
//     rather than an empty/"contact support" dead end.
//   * The classifier is pure and deterministic: identical inputs always yield
//     an identical diagnosis. No clocks, no randomness, no I/O.
//
// The marker tables below are seeded from the `PrettyError` mapping concepts
// and from the COM/`winerror.h` HRESULTs ASCOM drivers commonly surface.

import '../backend/device_types.dart';

/// The kind of problem behind a failed device connection. Drives which
/// remediation playbook the user is shown.
enum DiagnosticCategory {
  /// Physical-layer problem: cable, port, power, or a missing vendor SDK so
  /// the device never even enumerates.
  usb,

  /// The driver software itself is the problem: not running, not registered,
  /// crashed, or the driver process is unavailable.
  driver,

  /// The OS or another application is denying access (in use, blocked, or a
  /// privilege/elevation problem).
  permission,

  /// A network-layer problem reaching a remote Alpaca/INDI server: server not
  /// running, wrong host/port, or a firewall in the way.
  network,

  /// The connection reached the driver/server but it is misconfigured —
  /// wrong device selected, bad parameters, or a setup step skipped.
  configuration,

  /// We could not confidently classify the failure. Still returns concrete,
  /// generally-useful steps plus the raw error — never a dead end.
  unknown,
}

/// A single, actionable thing the user can try. [instruction] is the
/// imperative one-liner; [detail] is optional supporting context shown
/// underneath it.
class RemediationStep {
  /// The imperative action, e.g. "Check the USB cable is fully seated".
  final String instruction;

  /// Optional elaboration shown beneath the instruction, e.g. why it helps
  /// or how to do it. `null` when the instruction is self-explanatory.
  final String? detail;

  const RemediationStep({required this.instruction, this.detail});

  @override
  bool operator ==(Object other) =>
      other is RemediationStep &&
      other.instruction == instruction &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(instruction, detail);

  @override
  String toString() => detail == null
      ? 'RemediationStep($instruction)'
      : 'RemediationStep($instruction — $detail)';
}

/// The result of diagnosing a connection failure: a category, a short
/// headline, a plain-language explanation, an ordered list of remediation
/// steps, and the raw error carried through verbatim.
class ConnectionDiagnosis {
  /// The classified problem category.
  final DiagnosticCategory category;

  /// A short, human-readable headline, e.g. "Driver isn't running".
  final String headline;

  /// One or two sentences explaining, in plain language, what likely went
  /// wrong and why.
  final String plainLanguage;

  /// Ordered, branched remediation steps tailored to the device and driver.
  /// Always non-empty.
  final List<RemediationStep> steps;

  /// The original raw driver error, carried through verbatim. `null` only
  /// when the caller had no raw error to provide. Never hidden.
  final String? rawError;

  const ConnectionDiagnosis({
    required this.category,
    required this.headline,
    required this.plainLanguage,
    required this.steps,
    required this.rawError,
  });

  @override
  bool operator ==(Object other) =>
      other is ConnectionDiagnosis &&
      other.category == category &&
      other.headline == headline &&
      other.plainLanguage == plainLanguage &&
      other.rawError == rawError &&
      _listEquals(other.steps, steps);

  @override
  int get hashCode => Object.hash(
    category,
    headline,
    plainLanguage,
    rawError,
    Object.hashAll(steps),
  );

  @override
  String toString() =>
      'ConnectionDiagnosis($category, "$headline", ${steps.length} steps, raw: $rawError)';

  static bool _listEquals(List<RemediationStep> a, List<RemediationStep> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Diagnose a failed device connection into a [ConnectionDiagnosis].
///
/// Pure and deterministic — identical inputs always produce an identical
/// result. Never throws for ordinary inputs; an unrecognized failure resolves
/// to [DiagnosticCategory.unknown] with concrete generic steps.
///
/// Classification order (first confident match wins):
///   0. First-party preflight markers (`built-in guider requires …`) →
///      [DiagnosticCategory.configuration], with steps naming the exact
///      profile value the check wanted.
///   1. Permission markers (`access is denied`, HRESULT `0x80070005`) →
///      [DiagnosticCategory.permission].
///   2. Driver/RPC markers (`RPC server unavailable`, HRESULT `0x800706ba`,
///      class-not-registered `0x80040154`, not-connected `0x80040403`) →
///      [DiagnosticCategory.driver].
///   3. For Alpaca/INDI, network markers (`connection refused`, `timed out`,
///      `unreachable`, `no route`, `connection reset`) →
///      [DiagnosticCategory.network].
///   4. Enumeration markers (`not found`, `no devices`, `no camera`, empty
///      discovery) → [DiagnosticCategory.usb].
///   5. Configuration markers (`invalid value`, `not set`, `invalid operation`,
///      ASCOM `0x80040401`/`0x80040402`/`0x80040404`) →
///      [DiagnosticCategory.configuration].
///   6. Otherwise → [DiagnosticCategory.unknown].
///
/// The raw error is always carried through into [ConnectionDiagnosis.rawError].
ConnectionDiagnosis diagnoseConnectionFailure({
  required DeviceType deviceType,
  required DriverType driverType,
  String? rawError,
}) {
  final normalized = (rawError ?? '').toLowerCase();
  final category = _classify(
    normalized,
    driverType: driverType,
    deviceType: deviceType,
  );

  return ConnectionDiagnosis(
    category: category,
    headline: _headlineFor(category, error: normalized),
    plainLanguage: _plainLanguageFor(
      category,
      deviceType: deviceType,
      driverType: driverType,
      error: normalized,
    ),
    steps: _stepsFor(
      category,
      deviceType: deviceType,
      driverType: driverType,
      error: normalized,
    ),
    rawError: rawError,
  );
}

// Classification

bool _containsAny(String haystack, List<String> needles) {
  for (final needle in needles) {
    if (haystack.contains(needle)) return true;
  }
  return false;
}

const List<String> _permissionMarkers = [
  'access is denied',
  'access denied',
  'e_accessdenied',
  '0x80070005',
  'permission denied',
  'is in use',
  'already in use',
  'currently in use',
  'busy by another',
];

const List<String> _driverMarkers = [
  'rpc server unavailable',
  'rpc server is unavailable',
  '0x800706ba',
  'class not registered',
  '0x80040154', // CoCreateInstance failed (class not registered)
  'not connected',
  '0x80040403', // ASCOM NotConnectedException
  'driver process not running',
  'cocreateinstance',
  'dispatch failed',
  '0x80020009', // Driver raised an exception (DISP_E_EXCEPTION)
  '0x80004005', // Unspecified COM error (E_FAIL)
];

const List<String> _networkMarkers = [
  'connection refused',
  'timed out',
  'timeout',
  'unreachable',
  'no route to host',
  'connection reset',
  'host not found',
  'name resolution',
  'network is unreachable',
  'could not connect',
  'failed to connect',
  'econnrefused',
];

const List<String> _enumerationMarkers = [
  'not found',
  'no devices',
  'no device',
  'no camera',
  'no mount',
  'no focuser',
  'no filter wheel',
  'no such device',
  'device not present',
  'enumerate',
  'no compatible',
  'sdk not',
  'library not',
];

const List<String> _configurationMarkers = [
  'invalid value',
  '0x80040401', // ASCOM InvalidValueException
  'value not set',
  'not set',
  '0x80040402', // ASCOM ValueNotSetException
  'invalid operation',
  '0x80040404', // ASCOM InvalidOperationException
  'invalid while parked',
  'misconfigured',
  'bad request',
];

/// Preflight failures raised by SKOTIQ ITSELF, not by a driver.
///
/// The built-in guider is a software guider that reuses the imaging camera: it
/// has no cable, no power switch and no vendor driver. Its preflight refuses
/// with a fully-specified message naming the exact profile value it wanted, so
/// matching those here routes them to a configuration cause whose steps name
/// that setting — the driver playbooks would send the operator to reseat a
/// cable that does not exist.
const List<String> _firstPartySetupMarkers = ['built-in guider requires'];

bool _isNetworkDriver(DriverType driverType) =>
    driverType == DriverType.alpaca || driverType == DriverType.indi;

DiagnosticCategory _classify(
  String error, {
  required DriverType driverType,
  required DeviceType deviceType,
}) {
  // 0. First-party preflight beats every driver-shaped marker below: these are
  //    our own setup checks and the remediation is a Skotiq setting, never
  //    a cable, a COM registration or a firewall.
  if (_containsAny(error, _firstPartySetupMarkers)) {
    return DiagnosticCategory.configuration;
  }

  // 1. Permission is checked first: "access denied" is unambiguous and would
  //    otherwise be mistaken for a generic driver failure.
  if (_containsAny(error, _permissionMarkers)) {
    return DiagnosticCategory.permission;
  }

  // 2. Driver / RPC. For native USB drivers, an RPC-server / class-not-
  //    registered failure most often means the device is unplugged or the SDK
  //    process died — but the remediation playbook for "driver" already covers
  //    the unplugged case, so we keep it as driver.
  if (_containsAny(error, _driverMarkers)) {
    return DiagnosticCategory.driver;
  }

  // 3. Network markers only mean a network problem for remote protocols.
  //    A local USB driver that "timed out" is a driver/hardware issue, not a
  //    host/port/firewall issue, so we do not route it to network.
  if (_isNetworkDriver(driverType) && _containsAny(error, _networkMarkers)) {
    return DiagnosticCategory.network;
  }

  // 4. Enumeration / discovery failures, including an empty discovery result
  //    (empty rawError) — the device simply was not seen.
  if (error.isEmpty || _containsAny(error, _enumerationMarkers)) {
    return DiagnosticCategory.usb;
  }

  // 5. Configuration-level driver complaints.
  if (_containsAny(error, _configurationMarkers)) {
    return DiagnosticCategory.configuration;
  }

  // 6. No confident match. Concrete generic steps, never a dead end.
  return DiagnosticCategory.unknown;
}

// Copy: headlines, plain-language, and branched remediation steps

String _headlineFor(DiagnosticCategory category, {required String error}) {
  switch (category) {
    case DiagnosticCategory.usb:
      return "We couldn't find the device";
    case DiagnosticCategory.driver:
      return "The driver isn't responding";
    case DiagnosticCategory.permission:
      return 'Access to the device was denied';
    case DiagnosticCategory.network:
      return "We couldn't reach the server";
    case DiagnosticCategory.configuration:
      // No driver is involved in a first-party preflight, so naming one would
      // be its own small lie.
      return _containsAny(error, _firstPartySetupMarkers)
          ? 'Your equipment profile is missing a value'
          : 'The driver is connected but misconfigured';
    case DiagnosticCategory.unknown:
      return "The connection didn't complete";
  }
}

/// A short, friendly noun for the device, e.g. "camera", "mount".
String _deviceNoun(DeviceType deviceType) {
  switch (deviceType) {
    case DeviceType.camera:
      return 'camera';
    case DeviceType.mount:
      return 'mount';
    case DeviceType.focuser:
      return 'focuser';
    case DeviceType.filterWheel:
      return 'filter wheel';
    case DeviceType.guider:
      return 'guide camera';
    case DeviceType.dome:
      return 'dome';
    case DeviceType.rotator:
      return 'rotator';
    case DeviceType.weather:
      return 'weather station';
    case DeviceType.safetyMonitor:
      return 'safety monitor';
    case DeviceType.switch_:
      return 'switch device';
    case DeviceType.coverCalibrator:
      return 'cover/calibrator';
  }
}

/// Friendly name for the driver protocol.
String _driverNoun(DriverType driverType) {
  switch (driverType) {
    case DriverType.ascom:
      return 'ASCOM';
    case DriverType.alpaca:
      return 'Alpaca';
    case DriverType.indi:
      return 'INDI';
    case DriverType.native:
      return 'native';
    case DriverType.simulator:
      return 'simulator';
  }
}

String _plainLanguageFor(
  DiagnosticCategory category, {
  required DeviceType deviceType,
  required DriverType driverType,
  required String error,
}) {
  final device = _deviceNoun(deviceType);
  final driver = _driverNoun(driverType);
  switch (category) {
    case DiagnosticCategory.usb:
      return 'Skotiq never saw your $device. This is almost always a '
          'physical connection or driver-install problem rather than a '
          'software bug — the $device has to enumerate on the computer before '
          'we can talk to it.';
    case DiagnosticCategory.driver:
      return 'Skotiq reached the $driver driver layer, but the driver '
          "itself didn't answer. The driver may not be running, may have "
          'crashed, or the $device may have been unplugged after it was '
          'selected.';
    case DiagnosticCategory.permission:
      return 'Something is blocking Skotiq from opening the $device. Most '
          'often another program already has it open, or Windows is denying '
          'access until Skotiq is run with the right permissions.';
    case DiagnosticCategory.network:
      return 'Skotiq tried to reach your $driver server over the network '
          "but couldn't get a response. The server may not be running, the "
          'host or port may be wrong, or a firewall may be blocking the '
          'connection.';
    case DiagnosticCategory.configuration:
      if (_containsAny(error, _firstPartySetupMarkers)) {
        return "Skotiq's built-in guider is software — it reuses your "
            'imaging camera and mount, so there is no cable or power to '
            'check. It stopped before connecting because a value it needs '
            'from your equipment profile is missing or zero. The raw message '
            'below names it exactly.';
      }
      return 'Skotiq connected to the $driver driver, but it rejected the '
          'request because something is set up incorrectly. The wrong $device '
          'may be selected, or a required setup value is missing or invalid.';
    case DiagnosticCategory.unknown:
      return "The $device connection didn't complete and we couldn't pin down "
          'the exact cause. The steps below resolve the large majority of '
          'connection problems; the raw error is shown so you can dig deeper '
          'or share it with support.';
  }
}

List<RemediationStep> _stepsFor(
  DiagnosticCategory category, {
  required DeviceType deviceType,
  required DriverType driverType,
  required String error,
}) {
  switch (category) {
    case DiagnosticCategory.usb:
      return _usbSteps(deviceType: deviceType, driverType: driverType);
    case DiagnosticCategory.driver:
      return _driverSteps(deviceType: deviceType, driverType: driverType);
    case DiagnosticCategory.permission:
      return _permissionSteps(deviceType: deviceType, driverType: driverType);
    case DiagnosticCategory.network:
      return _networkSteps(deviceType: deviceType, driverType: driverType);
    case DiagnosticCategory.configuration:
      return _configurationSteps(
        deviceType: deviceType,
        driverType: driverType,
        error: error,
      );
    case DiagnosticCategory.unknown:
      return _unknownSteps(deviceType: deviceType, driverType: driverType);
  }
}

bool _isPowered(DeviceType deviceType) =>
    deviceType == DeviceType.camera ||
    deviceType == DeviceType.mount ||
    deviceType == DeviceType.dome ||
    deviceType == DeviceType.coverCalibrator;

List<RemediationStep> _usbSteps({
  required DeviceType deviceType,
  required DriverType driverType,
}) {
  final device = _deviceNoun(deviceType);
  final steps = <RemediationStep>[
    RemediationStep(
      instruction:
          'Check the USB cable is fully seated and try a different '
          'USB port',
      detail:
          'Reseat both ends of the cable and prefer a port directly on '
          'the computer over a hub. A marginal cable is the single most '
          'common cause of a missing $device.',
    ),
  ];

  if (_isPowered(deviceType)) {
    final supply = deviceType == DeviceType.mount
        ? 'confirm the mount power supply is connected and switched on'
        : 'confirm the 12V power supply is connected';
    steps.add(
      RemediationStep(
        instruction: 'For powered devices, $supply',
        detail:
            'Cooled cameras and motorized mounts will not enumerate on '
            'USB at all without their main power. A lit status LED is a good '
            'sign the device has power.',
      ),
    );
  }

  if (driverType == DriverType.native) {
    steps.add(
      RemediationStep(
        instruction: "Reinstall the manufacturer's SDK / driver",
        detail:
            'The native backend talks to the vendor SDK directly. If the '
            'SDK or its USB driver is missing or outdated, the $device will '
            'never appear in discovery.',
      ),
    );
  } else if (driverType == DriverType.ascom) {
    steps.add(
      const RemediationStep(
        instruction: "Verify the device's ASCOM driver is installed",
        detail:
            'Open the ASCOM Diagnostics or the Chooser to confirm the '
            'driver is registered. If it is missing, reinstall it from the '
            "manufacturer's site.",
      ),
    );
  } else if (_isNetworkDriver(driverType)) {
    final driver = _driverNoun(driverType);
    steps.add(
      RemediationStep(
        instruction:
            'Confirm the device is attached to the $driver server '
            'host, not this computer',
        detail:
            'With $driver the hardware connects to the server machine. '
            'Check the cable and power on that host, then re-run discovery.',
      ),
    );
  }

  steps.add(
    RemediationStep(
      instruction: 'Power-cycle the $device, then run discovery again',
      detail:
          'Unplug the $device, wait a few seconds, plug it back in, and '
          'rescan. This clears a stuck USB enumeration.',
    ),
  );

  return steps;
}

List<RemediationStep> _driverSteps({
  required DeviceType deviceType,
  required DriverType driverType,
}) {
  final device = _deviceNoun(deviceType);
  final driver = _driverNoun(driverType);
  final steps = <RemediationStep>[
    RemediationStep(
      instruction:
          'Confirm the $device is still physically connected and '
          'powered',
      detail:
          'An "RPC server unavailable" / driver-not-responding error '
          'usually means the $device was unplugged or lost power after it was '
          'selected. Reseat the cable and check the power.',
    ),
  ];

  if (driverType == DriverType.ascom) {
    steps.add(
      const RemediationStep(
        instruction:
            'Close and reopen the ASCOM driver, then any vendor '
            'control app',
        detail:
            "If the driver's own setup window or a vendor utility is "
            'open, close it so Skotiq can take exclusive control, then '
            'reconnect.',
      ),
    );
    steps.add(
      const RemediationStep(
        instruction: 'Re-run ASCOM Diagnostics to confirm the driver loads',
        detail:
            'A "class not registered" error means the driver is not '
            'installed correctly — reinstall it from the manufacturer.',
      ),
    );
  } else if (_isNetworkDriver(driverType)) {
    steps.add(
      RemediationStep(
        instruction: 'Restart the $driver server on its host',
        detail:
            'The server process may have crashed or stopped. Restart it, '
            'wait for it to report ready, then reconnect.',
      ),
    );
  } else {
    steps.add(
      RemediationStep(
        instruction: 'Restart Skotiq so the $driver driver reloads cleanly',
        detail:
            'A crashed driver process is cleared by reloading it. '
            'Restarting Skotiq reinitializes the $driver backend.',
      ),
    );
  }

  steps.add(
    RemediationStep(
      instruction: 'Power-cycle the $device, then reconnect',
      detail:
          'A full power cycle clears a hung firmware state that a '
          'software-only reconnect cannot.',
    ),
  );

  return steps;
}

List<RemediationStep> _permissionSteps({
  required DeviceType deviceType,
  required DriverType driverType,
}) {
  final device = _deviceNoun(deviceType);
  final steps = <RemediationStep>[
    RemediationStep(
      instruction: 'Close any other program that may be using the $device',
      detail:
          'A $device can only be opened by one application at a time. '
          'Vendor capture utilities, PHD2, or another planetarium app will '
          'hold it open and block Skotiq.',
    ),
    const RemediationStep(
      instruction: 'Try running Skotiq as administrator',
      detail:
          'An "access denied" error can mean Windows is withholding '
          'access until the app is elevated. Right-click Skotiq and '
          'choose "Run as administrator".',
    ),
  ];

  if (driverType == DriverType.native) {
    steps.add(
      const RemediationStep(
        instruction:
            'Check the device is not claimed by a generic Windows '
            'driver',
        detail:
            "Reinstall the manufacturer's USB driver so it owns the "
            'device instead of a generic system driver.',
      ),
    );
  }

  steps.add(
    RemediationStep(
      instruction: 'Power-cycle the $device and restart Skotiq',
      detail:
          'This releases any stale handle held by a crashed process and '
          'gives Skotiq a clean claim on the $device.',
    ),
  );

  return steps;
}

List<RemediationStep> _networkSteps({
  required DeviceType deviceType,
  required DriverType driverType,
}) {
  final driver = _driverNoun(driverType);
  final defaultPortHint = driverType == DriverType.alpaca
      ? 'the default Alpaca port is 11111'
      : 'the default INDI port is 7624';
  return <RemediationStep>[
    RemediationStep(
      instruction: 'Confirm the $driver server is running on the host',
      detail:
          'Open the $driver server application on the host machine and '
          'check it reports running/ready before reconnecting.',
    ),
    RemediationStep(
      instruction: 'Verify the host address and port',
      detail:
          'Double-check the IP/hostname matches the server machine and '
          'that the port is correct — $defaultPortHint.',
    ),
    RemediationStep(
      instruction: 'Check the firewall allows the connection',
      detail:
          'A firewall on the host (or on this computer) can silently drop '
          'the connection. Allow the $driver server through, or temporarily '
          'disable the firewall to test.',
    ),
    const RemediationStep(
      instruction: 'Confirm both machines are on the same network',
      detail:
          'Make sure this computer and the server host are on the same '
          'subnet/VLAN, and ping the host to confirm it is reachable.',
    ),
  ];
}

/// Steps for a Skotiq preflight refusal, keyed on the value the check
/// named. Returns `null` when [error] is not one of ours, so the caller falls
/// back to the generic driver-configuration playbook.
List<RemediationStep>? _firstPartySetupSteps(String error) {
  if (!_containsAny(error, _firstPartySetupMarkers)) return null;

  const openProfile = RemediationStep(
    instruction: 'Open Equipment → your active profile → Edit',
    detail:
        'The built-in guider reads its setup from the active equipment '
        'profile, not from a driver setup dialog.',
  );

  if (error.contains('focal length') || error.contains('focal_length_mm')) {
    return const [
      openProfile,
      RemediationStep(
        instruction: 'Enter the Focal Length of the scope you are guiding with',
        detail:
            'It is 0 (or unset) right now. The guider divides pixel size by '
            'focal length to work out how far each star has moved, so it '
            'cannot start without it. Enter the value in millimetres.',
      ),
      RemediationStep(
        instruction: 'Save the profile, then connect the guider again',
        detail:
            'No restart is needed — the guider re-reads the profile on '
            'each connect.',
      ),
    ];
  }

  if (error.contains('pixel')) {
    return const [
      RemediationStep(
        instruction: "Check your imaging camera is reporting its pixel size",
        detail:
            'The built-in guider guides on the imaging camera, and that '
            'camera reported a pixel size of 0. Reconnect it, or set the '
            'pixel size in its driver setup dialog.',
      ),
      openProfile,
    ];
  }

  if (error.contains('binning')) {
    return const [
      RemediationStep(
        instruction: 'Set guide binning to 1 or more in Guiding settings',
        detail:
            'The guider was handed a binning of zero, which has no pixel '
            'scale to guide on.',
      ),
    ];
  }

  // "requires a connected camera / mount in the active profile".
  return const [
    RemediationStep(
      instruction: 'Assign and connect a camera and a mount in this profile',
      detail:
          'The built-in guider has no hardware of its own — it guides using '
          'the imaging camera and pulses the mount, so both have to be '
          'assigned in the active profile and connected first.',
    ),
    openProfile,
  ];
}

List<RemediationStep> _configurationSteps({
  required DeviceType deviceType,
  required DriverType driverType,
  required String error,
}) {
  final firstParty = _firstPartySetupSteps(error);
  if (firstParty != null) return firstParty;

  final device = _deviceNoun(deviceType);
  final driver = _driverNoun(driverType);
  final steps = <RemediationStep>[
    RemediationStep(
      instruction: 'Confirm the correct $device is selected',
      detail:
          'If more than one device is available to the $driver driver, '
          'make sure the one you picked is the $device you actually want to '
          'use.',
    ),
  ];

  if (driverType == DriverType.ascom) {
    steps.add(
      const RemediationStep(
        instruction: "Open the driver's Setup dialog and check its settings",
        detail:
            'Most ASCOM drivers expose a Properties/Setup window. A '
            'missing COM port, model selection, or required value there '
            'causes an invalid-value error on connect.',
      ),
    );
  } else if (_isNetworkDriver(driverType)) {
    steps.add(
      RemediationStep(
        instruction: 'Review the $device parameters on the $driver server',
        detail:
            'Check the server-side device configuration — an unset or '
            'out-of-range parameter will be rejected when Skotiq '
            'connects.',
      ),
    );
  }

  steps.add(
    RemediationStep(
      instruction: 'Re-run the equipment setup for this $device',
      detail:
          'Stepping back through the equipment configuration lets you '
          'correct any value the driver rejected, then reconnect.',
    ),
  );

  return steps;
}

List<RemediationStep> _unknownSteps({
  required DeviceType deviceType,
  required DriverType driverType,
}) {
  final device = _deviceNoun(deviceType);
  final driver = _driverNoun(driverType);
  return <RemediationStep>[
    RemediationStep(
      instruction: 'Check the $device is connected and powered',
      detail:
          'Reseat the cable, confirm power, and make sure the $device is '
          'switched on before trying again.',
    ),
    RemediationStep(
      instruction: 'Make sure no other program is using the $device',
      detail:
          'Close vendor utilities or other astronomy apps that may be '
          'holding the $device open.',
    ),
    RemediationStep(
      instruction: 'Restart Skotiq and reconnect',
      detail:
          'Reloading the $driver backend clears most transient connection '
          'problems.',
    ),
    const RemediationStep(
      instruction: 'Read the raw error below for the specific cause',
      detail:
          'The original driver message is shown verbatim — it often names '
          'the exact problem, and is what to share with support if you get '
          'stuck.',
    ),
  ];
}
