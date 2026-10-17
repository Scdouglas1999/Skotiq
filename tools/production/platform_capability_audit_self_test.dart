import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/platform_capability_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Platform capability audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_platform_capability_audit_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    await _runAudit(script, temp);
    var report = _readJson(
      temp,
      'docs/production-readiness/platform-capability-audit.json',
    );
    _expect(report['passed'] == true, 'passing fixture should pass');
    _expect(report['issueCount'] == 0, 'passing fixture should have no issues');
    _expect(report['fileCount'] == 14, 'should audit 14 files');

    await _writeDoc(
      temp,
      'packages/skotiq_app/lib/screens/equipment/widgets/backend_selector_chips.dart',
      'class BackendSelectorChips {}',
    );
    final failing = await _runAudit(script, temp, allowFailure: true);
    _expect(failing.exitCode == 1, 'deficient fixture should fail');
    report = _readJson(
      temp,
      'docs/production-readiness/platform-capability-audit.json',
    );
    _expect(report['passed'] == false, 'deficient report should fail');
    final issues = (report['issues'] as List? ?? const []).join('\n');
    _expect(
      issues.contains('backend_selector_chips.dart'),
      'deficient report should identify backend selector capability gating',
    );

    stdout.writeln('Platform capability audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await _writeDoc(
    root,
    'packages/skotiq_core/lib/src/models/backend/platform_capabilities.dart',
    '''
class PlatformCapabilityMatrix {
  static const windows = 'windows';
  static const rows = [
    PlatformDriverCapability(backend: 'ascom', label: 'ASCOM COM', supportedPlatforms: [windows]),
    PlatformDriverCapability(backend: 'alpaca'),
    PlatformDriverCapability(backend: 'indi'),
    PlatformDriverCapability(backend: 'native', label: 'Native SDK', statusOverride: 'capability-gated'),
    PlatformDriverCapability(backend: 'simulator', statusOverride: 'capability-gated'),
  ];
  static PlatformCapabilityReport forPlatform(String platform) => PlatformCapabilityReport();
}
class PlatformCapabilityReport {
  Map<String, dynamic> toJson() => {};
}
class PlatformDriverCapability {
  const PlatformDriverCapability({String? backend, String? label, List<String>? supportedPlatforms, String? statusOverride});
}
''',
  );
  await _writeDoc(
    root,
    'packages/skotiq_core/test/models/platform_capabilities_test.dart',
    '''
void main() {
  // marks ASCOM COM as Windows-only
  // serializes deterministic unsupported reasons for API responses
  // serializes capability-gated backends for API responses
  // matches the public driver backend status matrix
  print(PlatformCapabilityMatrix.windows);
  print('capability-gated');
}
''',
  );
  await _writeDoc(
    root,
    'apps/desktop/lib/headless_api/handlers/system_handlers.dart',
    '''
void info() {
  final platformCapabilities = PlatformCapabilityMatrix.forPlatform(Platform.operatingSystem);
  final map = {
    'platformCapabilities': platformCapabilities.toJson(),
    'deviceDrivers': platformCapabilities.toJson(),
    'platform': platformCapabilities.platform,
  };
}
''',
  );
  await _writeDoc(
    root,
    'apps/desktop/lib/headless_api/handlers/system_endpoint_catalog.dart',
    '''
const availableHeadlessEndpoints = [
  'GET /api/equipment/camera/capabilities',
  'GET /api/equipment/mount/capabilities',
  'GET /api/equipment/focuser/capabilities',
  'GET /api/equipment/filter-wheel/capabilities',
  'GET /api/equipment/rotator/capabilities',
];
''',
  );
  await _writeDoc(
    root,
    'apps/desktop/lib/headless_api/handlers/equipment_handlers.dart',
    '''
class EquipmentHandlers {
  Future<void> handleCameraCapabilities(request) async {
    final caps = await backend.getCameraCapabilities(deviceId);
    if (caps == null) print('Device not found or capabilities unavailable');
    return jsonOk(caps.toJson());
  }
  Future<void> handleMountCapabilities(request) async {
    final caps = await backend.getMountCapabilities(deviceId);
    return jsonOk(caps.toJson());
  }
  Future<void> handleFocuserCapabilities(request) async {
    final caps = await backend.getFocuserCapabilities(deviceId);
    return jsonOk(caps.toJson());
  }
  Future<void> handleFilterWheelCapabilities(request) async {
    final caps = await backend.getFilterWheelCapabilities(deviceId);
    return jsonOk(caps.toJson());
  }
  Future<void> handleRotatorCapabilities(request) async {
    final caps = await backend.getRotatorCapabilities(deviceId);
    return jsonOk(caps.toJson());
  }
}
''',
  );
  await _writeDoc(
    root,
    'apps/desktop/test/headless_api/equipment_handlers_test.dart',
    '''
void main() {
  // capability backend failures return JSON internal server errors
  print(handleCameraCapabilities);
  print(handleMountCapabilities);
  print(handleFocuserCapabilities);
  print(handleFilterWheelCapabilities);
  print(handleRotatorCapabilities);
  print(HttpStatus.internalServerError);
  print(response.headers['content-type'], 'application/json');
}
''',
  );
  await _writeDoc(
    root,
    'apps/desktop/test/headless_api/auth_middleware_test.dart',
    '''
void _expectReleaseScopedDriverMatrix() {
  print(info.body['platformCapabilities']);
  print(selfTest.body['deviceDrivers']);
  print(containsAll(['ascom', 'alpaca', 'indi', 'native', 'simulator']));
  print('Windows COM drivers');
  print(native['status'], 'capability-gated');
  print(simulator['status'], 'capability-gated');
}
''',
  );
  await _writeDoc(
    root,
    'packages/skotiq_app/lib/screens/equipment/widgets/backend_selector_chips.dart',
    '''
String? unsupportedBackendReasonFor() {
  print(PlatformCapabilityMatrix.rows);
  final backendEnabled = isEnabled && unsupportedReason == null;
  print(backendEnabled);
  print(onTap: widget.isEnabled ? widget.onTap : null);
  print(enabled: widget.isEnabled);
}
''',
  );
  await _writeDoc(
    root,
    'packages/skotiq_app/test/screens/equipment/backend_selector_chips_test.dart',
    '''
void main() {
  // unsupportedBackendReasonFor gates ASCOM COM off Linux
  // BackendSelectorChips disables unsupported platform backends
  print(PlatformCapabilityMatrix.linux);
  print(LucideIcons.ban);
}
''',
  );
  await _writeDoc(
    root,
    'packages/skotiq_app/lib/screens/settings/widgets/connection_settings.dart',
    '''
void settings() {
  PlatformCapabilityMatrix.forPlatform(Platform.operatingSystem);
  print('Platform capabilities');
  print('Current platform:');
  print(statusFor(platform));
  print('Capability-gated');
  print(unsupportedReason);
  print(deviceCoverage);
}
''',
  );
  await _writeDoc(
    root,
    'packages/skotiq_app/test/screens/settings/platform_capabilities_settings_test.dart',
    '''
void main() {
  // Connection settings render release-scoped platform capabilities
  print('Platform capabilities');
  print('ASCOM COM');
  print('Native SDK');
  print('Capability-gated');
  print('reachable INDI server');
  print('Simulator');
}
''',
  );
  await _writeDoc(root, 'docs/supported-hardware-by-platform.md', '''
# Supported Hardware By Platform
## Driver Backend Availability
ASCOM COM | Available | Unsupported | Unsupported
ASCOM Alpaca | Available | Available | Available
INDI | Available | Available | Available
Native SDK | Capability-gated | Capability-gated | Capability-gated
Simulator | Capability-gated | Capability-gated | Capability-gated
## Linux Packaging And Permissions
native shared libraries
udev rules
dialout
plugdev
video
DSLR/gphoto2
/api/info.platformCapabilities
in-app Platform Capabilities
''');
  await _writeDoc(
    root,
    'docs/production-readiness/feature-parity-matrix.md',
    '''
# Feature Parity Matrix
## Driver Backend Platform Matrix
ASCOM COM | Available | Unsupported | Unsupported
ASCOM Alpaca | Available | Available | Available
INDI | Available | Available | Available
Native SDK | Capability-gated | Capability-gated | Capability-gated
Simulator | Capability-gated | Capability-gated | Capability-gated
/api/info
platformCapabilities
Unsupported
controls disabled
''',
  );
  await _writeDoc(root, 'docs/api/web-server-api.md', '''
# API
platformCapabilities
ASCOM COM
supportedPlatforms
unsupportedReason
GET /api/equipment/camera/capabilities
GET /api/equipment/mount/capabilities
GET /api/equipment/focuser/capabilities
GET /api/equipment/filter-wheel/capabilities
GET /api/equipment/rotator/capabilities
capability response is device-specific
''');
}

Future<ProcessResult> _runAudit(
  File script,
  Directory root, {
  bool allowFailure = false,
}) async {
  final result = await Process.run(
    'dart',
    [script.path, '--root', root.path],
    workingDirectory: root.path,
    runInShell: Platform.isWindows,
  );
  if (!allowFailure && result.exitCode != 0) {
    throw StateError(
      '${script.path} failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
  return result;
}

Future<void> _writeDoc(
  Directory root,
  String relativePath,
  String content,
) async {
  final file = File('${root.path}/$relativePath');
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

Map<String, dynamic> _readJson(Directory root, String relativePath) {
  final file = File('${root.path}/$relativePath');
  if (!file.existsSync()) {
    throw StateError('Expected report was not written: ${file.path}');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
