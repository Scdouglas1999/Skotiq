/// Pre-flight answers three questions before the operator commits a night:
///
///  * The executor's daylight gate refuses EVERY light frame while the Sun is
///    up, and the run dies in the same millisecond with zero frames — so the
///    dialog must not read "Ready with Warnings" beside a green "Start Anyway".
///  * With no observing site the gate cannot run at all. Absent is UNKNOWN, not
///    Null Island, and pre-flight names the real reason.
///  * A target with coordinates and no Slew/Center instruction exposes wherever
///    the mount was left and files the frames under the target's name.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart'
    show FrameType;
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/equipment/mount_state_provider.dart';
import 'package:skotiq_core/src/providers/sequence/rules/sky_readiness_rules.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

class _FakeAppSettings extends AppSettingsNotifier {
  _FakeAppSettings(this._initial);
  final AppSettingsState _initial;
  @override
  Future<AppSettingsState> build() async => _initial;
}

class _StubMount extends MountStateNotifier {
  _StubMount(super.ref, MountState initial) {
    state = initial;
  }
}

T _withRef<T>(ProviderContainer c, T Function(Ref ref) body) =>
    c.read(Provider<T>((ref) => body(ref)));

Future<ProviderContainer> _container({
  double latitude = 40.0,
  double longitude = -105.0,
  MountState mount = const MountState(),
}) async {
  final c = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(
        () => _FakeAppSettings(
          AppSettingsState(latitude: latitude, longitude: longitude),
        ),
      ),
      mountStateProvider.overrideWith((ref) => _StubMount(ref, mount)),
    ],
  );
  addTearDown(c.dispose);
  await c.read(appSettingsProvider.future);
  return c;
}

Sequence _sequence(Map<String, SequenceNode> nodes, {String? rootNodeId}) {
  return Sequence(
    id: 'seq',
    name: 'S',
    nodes: nodes,
    rootNodeId: rootNodeId,
    createdAt: DateTime.utc(2026),
    modifiedAt: DateTime.utc(2026),
  );
}

/// One target + one light exposure, the shape every repro in the report used.
Sequence _lightRun({
  double raHours = 5.5885,
  double decDegrees = -5.39,
  List<SequenceNode> extraChildren = const [],
}) {
  final exposure = ExposureNode(
    id: 'exp',
    parentId: 'target',
    durationSecs: 3.0,
    count: 4,
  );
  final target = TargetHeaderNode(
    id: 'target',
    name: 'M42-TEST',
    targetName: 'M42-TEST',
    raHours: raHours,
    decDegrees: decDegrees,
    childIds: ['exp', ...extraChildren.map((n) => n.id)],
  );
  return _sequence({
    'target': target,
    'exp': exposure,
    for (final node in extraChildren) node.id: node,
  }, rootNodeId: 'target');
}

void main() {
  // Local mid-morning at lon -105: 16:10 UTC is 10:10 local.
  DateTime daytime() => DateTime.utc(2026, 8, 11, 16, 10);
  DateTime night() => DateTime.utc(2026, 8, 11, 8, 10);

  test('all three rules are wired into the pre-flight registry', () {
    expect(
      defaultRefAwareSequenceValidators.map((rule) => rule.name),
      containsAll(<String>[
        'DaylightGate',
        'ObserverLocationUnset',
        'MountOffTarget',
      ]),
      reason: 'a rule the validator never runs protects nobody',
    );
  });

  group('DaylightGateRule', () {
    test('blocks a light run started while the Sun is up', () async {
      final c = await _container();
      final issues = _withRef(
        c,
        (ref) => DaylightGateRule(
          clock: daytime,
        ).validate(_lightRun(), ValidationContext(ref)),
      );
      expect(issues, hasLength(1));
      expect(
        issues.single.severity,
        ValidationSeverity.error,
        reason:
            'the engine refuses this categorically — it cannot be a warning',
      );
      expect(issues.single.title, contains('Daylight Gate'));
    });

    test('clean at night', () async {
      final c = await _container();
      expect(
        _withRef(
          c,
          (ref) => DaylightGateRule(
            clock: night,
          ).validate(_lightRun(), ValidationContext(ref)),
        ),
        isEmpty,
      );
    });

    test('clean when the sequence waits for twilight', () async {
      final c = await _container();
      final wait = WaitTimeNode(
        id: 'wait',
        parentId: 'target',
        waitForTwilight: TwilightType.astronomical,
      );
      expect(
        _withRef(
          c,
          (ref) => DaylightGateRule(
            clock: daytime,
          ).validate(_lightRun(extraChildren: [wait]), ValidationContext(ref)),
        ),
        isEmpty,
      );
    });

    test('clean for a daytime calibration run (no light frames)', () async {
      final c = await _container();
      final flats = ExposureNode(
        id: 'flat',
        frameType: FrameType.flat,
        durationSecs: 2.0,
        count: 10,
      );
      expect(
        _withRef(
          c,
          (ref) => DaylightGateRule(clock: daytime).validate(
            _sequence({'flat': flats}, rootNodeId: 'flat'),
            ValidationContext(ref),
          ),
        ),
        isEmpty,
      );
    });

    test(
      'abstains with no observing site rather than judging Null Island',
      () async {
        final c = await _container(latitude: 0.0, longitude: 0.0);
        expect(
          _withRef(
            c,
            (ref) => DaylightGateRule(
              clock: daytime,
            ).validate(_lightRun(), ValidationContext(ref)),
          ),
          isEmpty,
        );
      },
    );
  });

  group('ObserverLocationUnsetRule', () {
    final rule = ObserverLocationUnsetRule();

    test('names the missing site as the reason the gate is off', () async {
      final c = await _container(latitude: 0.0, longitude: 0.0);
      final issues = _withRef(
        c,
        (ref) => rule.validate(_lightRun(), ValidationContext(ref)),
      );
      expect(issues, hasLength(1));
      expect(issues.single.title, 'No Observing Location Set');
      expect(issues.single.severity, ValidationSeverity.warning);
    });

    test('clean once a site is configured', () async {
      final c = await _container();
      expect(
        _withRef(
          c,
          (ref) => rule.validate(_lightRun(), ValidationContext(ref)),
        ),
        isEmpty,
      );
    });
  });

  group('MountOffTargetRule', () {
    final rule = MountOffTargetRule();

    const onTarget = MountState(
      connectionState: DeviceConnectionState.connected,
      ra: 5.5885,
      dec: -5.39,
    );
    const wayOff = MountState(
      connectionState: DeviceConnectionState.connected,
      ra: 12.0,
      dec: -35.0,
    );

    test('flags a target with no Slew while the mount is elsewhere', () async {
      final c = await _container(mount: wayOff);
      final issues = _withRef(
        c,
        (ref) => rule.validate(_lightRun(), ValidationContext(ref)),
      );
      expect(issues, hasLength(1));
      expect(issues.single.title, contains('M42-TEST'));
      expect(issues.single.affectedNodeId, 'target');
    });

    test('clean when the sequence slews to the target', () async {
      final c = await _container(mount: wayOff);
      final slew = SlewNode(
        id: 'slew',
        parentId: 'target',
        useTargetCoords: true,
      );
      expect(
        _withRef(
          c,
          (ref) => rule.validate(
            _lightRun(extraChildren: [slew]),
            ValidationContext(ref),
          ),
        ),
        isEmpty,
      );
    });

    test('clean when the mount is already on target', () async {
      final c = await _container(mount: onTarget);
      expect(
        _withRef(
          c,
          (ref) => rule.validate(_lightRun(), ValidationContext(ref)),
        ),
        isEmpty,
      );
    });

    test('clean when no mount is connected', () async {
      final c = await _container();
      expect(
        _withRef(
          c,
          (ref) => rule.validate(_lightRun(), ValidationContext(ref)),
        ),
        isEmpty,
      );
    });
  });
}
