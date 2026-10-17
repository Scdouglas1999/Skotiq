import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/equipment/camera_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/filter_wheel_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/focuser_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/guider_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/mount_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/rotator_state_provider.dart';
import 'package:skotiq_core/src/providers/sequence/rules/equipment_rules.dart';
import 'package:skotiq_core/src/providers/sequence/rules/filter_rules.dart';
import 'package:skotiq_core/src/providers/sequence/rules/settings_rules.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

// Minimal fakes so we can drive the equipment / settings providers from
// tests without touching real device drivers or the on-disk SQLite store.
//
// Each fake StateNotifier is intentionally tiny — just enough surface to
// satisfy the rule under test.

// Tests extend the real notifier classes so they can be returned from
// `overrideWith`, but bypass their constructors (which would touch real
// Riverpod dependencies via the production `Ref`) by passing a fresh
// ProviderContainer-built ref. We don't need any of the notifier's
// production behaviour — only the initial state value.
class _StubCameraNotifier extends CameraStateNotifier {
  _StubCameraNotifier(super.ref, CameraStateSnapshot initial) {
    state = initial;
  }
}

class _StubMountNotifier extends MountStateNotifier {
  _StubMountNotifier(super.ref, MountState initial) {
    state = initial;
  }
}

class _StubFocuserNotifier extends FocuserStateNotifier {
  _StubFocuserNotifier(super.ref, FocuserState initial) {
    state = initial;
  }
}

class _StubFilterWheelNotifier extends FilterWheelStateNotifier {
  _StubFilterWheelNotifier(super.ref, FilterWheelState initial) {
    state = initial;
  }
}

class _StubGuiderNotifier extends GuiderStateNotifier {
  _StubGuiderNotifier(super.ref, GuiderState initial) {
    state = initial;
  }
}

class _StubRotatorNotifier extends RotatorStateNotifier {
  _StubRotatorNotifier(super.ref, RotatorState initial) {
    state = initial;
  }
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;
  @override
  Future<AppSettingsState> build() async => _initial;
}

/// Drives a closure with a real Riverpod [Ref] so tests can construct a
/// [ValidationContext]. We do not have a `Ref` from `ProviderContainer`
/// directly — they're constructed by provider builds — so wrap the call in
/// an ad-hoc test provider.
T _withRef<T>(ProviderContainer container, T Function(Ref ref) body) {
  final probe = Provider<T>((ref) => body(ref));
  return container.read(probe);
}

/// Build a ProviderContainer with all equipment + settings providers driven
/// from explicit state. Callers supply only the connection state they care
/// about; everything else defaults to disconnected.
ProviderContainer _container({
  DeviceConnectionState camera = DeviceConnectionState.disconnected,
  DeviceConnectionState mount = DeviceConnectionState.disconnected,
  DeviceConnectionState focuser = DeviceConnectionState.disconnected,
  DeviceConnectionState filterWheel = DeviceConnectionState.disconnected,
  DeviceConnectionState guider = DeviceConnectionState.disconnected,
  String? guiderId,
  String? guiderName,
  DeviceConnectionState rotator = DeviceConnectionState.disconnected,
  List<String> filterNames = const [],
  String imageOutputPath = '/tmp/out',
}) {
  final container = ProviderContainer(
    overrides: [
      cameraStateProvider.overrideWith(
        (ref) => _StubCameraNotifier(
          ref,
          CameraStateSnapshot(connectionState: camera),
        ),
      ),
      mountStateProvider.overrideWith(
        (ref) => _StubMountNotifier(ref, MountState(connectionState: mount)),
      ),
      focuserStateProvider.overrideWith(
        (ref) =>
            _StubFocuserNotifier(ref, FocuserState(connectionState: focuser)),
      ),
      filterWheelStateProvider.overrideWith(
        (ref) => _StubFilterWheelNotifier(
          ref,
          FilterWheelState(
            connectionState: filterWheel,
            filterNames: filterNames,
          ),
        ),
      ),
      guiderStateProvider.overrideWith(
        (ref) => _StubGuiderNotifier(
          ref,
          GuiderState(
            connectionState: guider,
            deviceId: guiderId,
            deviceName: guiderName,
          ),
        ),
      ),
      rotatorStateProvider.overrideWith(
        (ref) =>
            _StubRotatorNotifier(ref, RotatorState(connectionState: rotator)),
      ),
      appSettingsProvider.overrideWith(
        () => _FakeAppSettingsNotifier(
          AppSettingsState(imageOutputPath: imageOutputPath),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Make a sequence with the given children placed under a root container.
Sequence _sequenceWith(List<SequenceNode> children) {
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{root.id: root};
  final ids = <String>[];
  for (final child in children) {
    final placed = child.copyWith(parentId: root.id);
    nodes[placed.id] = placed;
    ids.add(placed.id);
  }
  nodes[root.id] = root.copyWith(childIds: ids);
  return Sequence.create(name: 'T', nodes: nodes, rootNodeId: root.id);
}

void main() {
  group('EquipmentConnectionRule', () {
    test('fires error when camera is required but not connected', () {
      final container = _container();
      final rule = EquipmentConnectionRule();
      final s = _sequenceWith([ExposureNode()]);
      final issues = _withRef(
        container,
        (ref) => rule.validate(s, ValidationContext(ref)),
      );
      final cam = issues.firstWhere((i) => i.title == 'No Camera Connected');
      expect(cam.severity, ValidationSeverity.error);
      expect(cam.category, ValidationCategory.equipment);
    });

    test('clean when required device is connected', () {
      final container = _container(camera: DeviceConnectionState.connected);
      final rule = EquipmentConnectionRule();
      final s = _sequenceWith([ExposureNode()]);
      final issues = _withRef(
        container,
        (ref) => rule.validate(s, ValidationContext(ref)),
      );
      expect(issues.where((i) => i.title.contains('Camera')), isEmpty);
    });

    // ONE missing guider is ONE warning per affected node, with no generic
    // summary alongside it: a duplicate pair double-counts in the
    // "N warnings" badge.
    test('reports a missing guider once per affected node, with no '
        'duplicate summary', () {
      final container = _container(
        camera: DeviceConnectionState.connected,
        mount: DeviceConnectionState.connected,
      );
      final rule = EquipmentConnectionRule();
      final s = _sequenceWith([ExposureNode(), StartGuidingNode()]);
      final issues = _withRef(
        container,
        (ref) => rule.validate(s, ValidationContext(ref)),
      );
      final guiderIssues = issues
          .where((i) => i.title.contains('Guider'))
          .toList();

      expect(guiderIssues, hasLength(1));
      expect(guiderIssues.single.title, 'Guider Not Connected');
      expect(guiderIssues.single.affectedNodeId, isNotNull);
      expect(
        issues.where((i) => i.title == 'No Guider Connected'),
        isEmpty,
        reason: 'the generic summary duplicates the per-node warning',
      );
    });

    test('one warning per guiding node, not one plus a summary', () {
      final container = _container(
        camera: DeviceConnectionState.connected,
        mount: DeviceConnectionState.connected,
      );
      final rule = EquipmentConnectionRule();
      final s = _sequenceWith([
        ExposureNode(),
        StartGuidingNode(),
        DitherNode(),
      ]);
      final issues = _withRef(
        container,
        (ref) => rule.validate(s, ValidationContext(ref)),
      );
      final guiderIssues = issues
          .where((i) => i.title.contains('Guider'))
          .toList();

      expect(guiderIssues, hasLength(2));
      expect(
        guiderIssues.every((i) => i.affectedNodeId != null),
        isTrue,
        reason: 'every guider warning must point at the node that needs one',
      );
    });

    // Pre-flight used to tell EVERY operator to "Connect to PHD2 in the
    // Guiding panel", in a build that ships a native guider and whose
    // Guiding panel only grows a Connect button when the selected guider IS
    // PHD2. With the built-in guider selected the advice pointed at a panel
    // with nothing to press.
    test('missing-guider advice names the panel that can connect the '
        'selected backend', () {
      final rule = EquipmentConnectionRule();
      final s = _sequenceWith([ExposureNode(), StartGuidingNode()]);

      ValidationIssue guiderIssue(ProviderContainer c) => _withRef(
        c,
        (ref) => rule.validate(s, ValidationContext(ref)),
      ).firstWhere((i) => i.title.contains('Guider'));

      final builtin = guiderIssue(
        _container(
          camera: DeviceConnectionState.connected,
          mount: DeviceConnectionState.connected,
          guiderId: 'native:builtin_guider:multi_star',
          guiderName: 'Built-in Multi-Star Guider',
        ),
      );
      expect(builtin.resolutionHint, isNot(contains('PHD2')));
      expect(builtin.resolutionHint, contains('Equipment'));
      expect(builtin.resolutionHint, contains('Built-in Multi-Star Guider'));
      expect(builtin.description, isNot(contains('PHD2')));

      final phd2 = guiderIssue(
        _container(
          camera: DeviceConnectionState.connected,
          mount: DeviceConnectionState.connected,
          guiderId: 'phd2',
          guiderName: 'PHD2',
        ),
      );
      expect(phd2.resolutionHint, contains('PHD2'));
      expect(phd2.resolutionHint, contains('Guiding panel'));

      // Nothing selected yet: both routes are real, so name both rather
      // than asserting PHD2 is the only guider this build has.
      final none = guiderIssue(
        _container(
          camera: DeviceConnectionState.connected,
          mount: DeviceConnectionState.connected,
        ),
      );
      expect(none.resolutionHint, contains('Equipment'));
      expect(none.resolutionHint, contains('PHD2'));
    });

    test(
      'a disabled guiding node still leaves the summary as the fallback',
      () {
        final container = _container(
          camera: DeviceConnectionState.connected,
          mount: DeviceConnectionState.connected,
        );
        final rule = EquipmentConnectionRule();
        // Disabled nodes contribute no required device, so nothing asks for a
        // guider at all and the rule is silent — the summary is reserved for
        // an unattributable requirement, never emitted alongside a per-node
        // warning.
        final guiding = StartGuidingNode().copyWith(isEnabled: false);
        final s = _sequenceWith([ExposureNode(), guiding]);
        final issues = _withRef(
          container,
          (ref) => rule.validate(s, ValidationContext(ref)),
        );
        expect(issues.where((i) => i.title.contains('Guider')), isEmpty);
      },
    );

    // Every test above constructs the rule directly, so all of them stay
    // green if the rule is dropped from the registry the app actually runs
    // — i.e. the whole guider pre-flight can be unwired without a single
    // failure. Pin the registration itself.
    test('is registered in the ref-aware validator set the app runs', () {
      expect(
        defaultRefAwareSequenceValidators.whereType<EquipmentConnectionRule>(),
        isNotEmpty,
        reason:
            'cutting EquipmentConnectionRule from '
            'defaultRefAwareSequenceValidators silently disables every '
            'missing-equipment pre-flight warning',
      );
    });
  });

  group('RotatorRotationConflictRule', () {
    test('fires when target has rotation but rotator is disconnected', () {
      final container = _container();
      final rule = RotatorRotationConflictRule();
      final t = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0,
        decDegrees: 0,
        rotation: 90,
      );
      final s = _sequenceWith([t]);
      final issues = _withRef(
        container,
        (ref) => rule.validate(s, ValidationContext(ref)),
      );
      expect(issues.single.title, 'Rotator Not Connected');
      expect(issues.single.affectedNodeId, t.id);
    });

    test('does not fire for a 0° rotation (no-op, no rotator needed)', () {
      // Auto-built targets request no rotation but carry a spurious 0.0;
      // a 0° rotation never needs a rotator, so it must not warn.
      final container = _container();
      final rule = RotatorRotationConflictRule();
      final t = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0,
        decDegrees: 0,
        rotation: 0,
      );
      final s = _sequenceWith([t]);
      final issues = _withRef(
        container,
        (ref) => rule.validate(s, ValidationContext(ref)),
      );
      expect(issues, isEmpty);
    });

    test('clean when rotator is connected', () {
      final container = _container(rotator: DeviceConnectionState.connected);
      final rule = RotatorRotationConflictRule();
      final t = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0,
        decDegrees: 0,
        rotation: 90,
      );
      final s = _sequenceWith([t]);
      expect(
        _withRef(container, (ref) => rule.validate(s, ValidationContext(ref))),
        isEmpty,
      );
    });
  });

  group('FilterInWheelRule', () {
    test('fires when exposure references a filter not in the wheel', () {
      final container = _container(
        filterWheel: DeviceConnectionState.connected,
        filterNames: ['L', 'R', 'G', 'B'],
      );
      final rule = FilterInWheelRule();
      final e = ExposureNode(filter: 'Ha');
      final s = _sequenceWith([e]);
      final issues = _withRef(
        container,
        (ref) => rule.validate(s, ValidationContext(ref)),
      );
      expect(issues.single.title, 'Filter Not in Wheel');
      expect(issues.single.affectedNodeId, e.id);
    });

    test('clean when filter is in the wheel', () {
      final container = _container(
        filterWheel: DeviceConnectionState.connected,
        filterNames: ['L', 'R', 'G', 'B'],
      );
      final rule = FilterInWheelRule();
      final e = ExposureNode(filter: 'L');
      final s = _sequenceWith([e]);
      expect(
        _withRef(container, (ref) => rule.validate(s, ValidationContext(ref))),
        isEmpty,
      );
    });

    test(
      'emits info when filter wheel is connected but reports no filters',
      () {
        final container = _container(
          filterWheel: DeviceConnectionState.connected,
        );
        final rule = FilterInWheelRule();
        final s = _sequenceWith([ExposureNode(filter: 'L')]);
        final issues = _withRef(
          container,
          (ref) => rule.validate(s, ValidationContext(ref)),
        );
        expect(issues.single.title, 'Filter Wheel Reports No Filters');
        expect(issues.single.severity, ValidationSeverity.info);
      },
    );

    test('skips check when filter wheel is disconnected', () {
      final container = _container();
      final rule = FilterInWheelRule();
      final s = _sequenceWith([ExposureNode(filter: 'L')]);
      expect(
        _withRef(container, (ref) => rule.validate(s, ValidationContext(ref))),
        isEmpty,
      );
    });
  });

  group('ImageOutputPathRule', () {
    test(
      'fires ERROR when no output path is configured and exposures exist',
      () async {
        // Empty path must hard-block sequence start. Pre- this
        // was only a warning so the start handler ignored it; the Rust
        // sequencer would then either fail to write or land frames in
        // the working directory with no operator signal.
        final container = _container(imageOutputPath: '');
        // Force settings to load
        await container.read(appSettingsProvider.future);
        final rule = ImageOutputPathRule();
        final s = _sequenceWith([ExposureNode()]);
        final issues = _withRef(
          container,
          (ref) => rule.validate(s, ValidationContext(ref)),
        );
        expect(issues.single.title, 'Image Output Path Not Configured');
        expect(issues.single.severity, ValidationSeverity.error);
      },
    );

    test('fires ERROR for whitespace-only output path', () async {
      final container = _container(imageOutputPath: '   \t  ');
      await container.read(appSettingsProvider.future);
      final rule = ImageOutputPathRule();
      final s = _sequenceWith([ExposureNode()]);
      final issues = _withRef(
        container,
        (ref) => rule.validate(s, ValidationContext(ref)),
      );
      expect(issues.single.title, 'Image Output Path Not Configured');
      expect(issues.single.severity, ValidationSeverity.error);
    });

    test('fires ERROR when output directory does not exist', () async {
      // Pick a path that definitely cannot exist — appending a random
      // suffix under tempdir without creating it.
      final missingDir =
          '${Directory.systemTemp.path}'
          '${Platform.pathSeparator}skotiq_does_not_exist_'
          '${DateTime.now().microsecondsSinceEpoch}';
      final container = _container(imageOutputPath: missingDir);
      await container.read(appSettingsProvider.future);
      final rule = ImageOutputPathRule();
      final s = _sequenceWith([ExposureNode()]);
      final issues = _withRef(
        container,
        (ref) => rule.validate(s, ValidationContext(ref)),
      );
      expect(issues.single.title, 'Image Output Path Missing');
      expect(issues.single.severity, ValidationSeverity.error);
      expect(issues.single.description, contains(missingDir));
    });

    test('clean when output directory exists and is writable', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_imageoutput_ok_',
      );
      addTearDown(() async {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      });
      final container = _container(imageOutputPath: tempDir.path);
      await container.read(appSettingsProvider.future);
      final rule = ImageOutputPathRule();
      final s = _sequenceWith([ExposureNode()]);
      expect(
        _withRef(container, (ref) => rule.validate(s, ValidationContext(ref))),
        isEmpty,
      );
    });

    test('skips check when sequence has no enabled exposures', () async {
      // Even with an empty path, a sequence that doesn't capture (e.g.
      // a pure slew test) should pass — no images means no save target.
      final container = _container(imageOutputPath: '');
      await container.read(appSettingsProvider.future);
      final rule = ImageOutputPathRule();
      final s = _sequenceWith([SlewNode(useTargetCoords: true)]);
      expect(
        _withRef(container, (ref) => rule.validate(s, ValidationContext(ref))),
        isEmpty,
      );
    });
  });

  group('DefaultSequenceNameRule', () {
    test('fires on "Untitled Sequence"', () async {
      final container = _container();
      await container.read(appSettingsProvider.future);
      final rule = DefaultSequenceNameRule();
      final s = Sequence.create(name: 'Untitled Sequence');
      final issues = _withRef(
        container,
        (ref) => rule.validate(s, ValidationContext(ref)),
      );
      expect(issues.single.title, 'Default Sequence Name');
      expect(issues.single.severity, ValidationSeverity.info);
    });

    test('clean on a real name', () async {
      final container = _container();
      await container.read(appSettingsProvider.future);
      final rule = DefaultSequenceNameRule();
      final s = Sequence.create(name: 'My Run');
      expect(
        _withRef(container, (ref) => rule.validate(s, ValidationContext(ref))),
        isEmpty,
      );
    });
  });

  group('LongEstimatedDurationRule', () {
    test('fires when estimatedDurationMins > 600', () async {
      final container = _container();
      await container.read(appSettingsProvider.future);
      final rule = LongEstimatedDurationRule();
      final s = Sequence.create(name: 'X', estimatedDurationMins: 700);
      final issues = _withRef(
        container,
        (ref) => rule.validate(s, ValidationContext(ref)),
      );
      expect(issues.single.title, 'Long Sequence');
    });

    test('clean when no estimate is set', () async {
      final container = _container();
      await container.read(appSettingsProvider.future);
      final rule = LongEstimatedDurationRule();
      final s = Sequence.create(name: 'X');
      expect(
        _withRef(container, (ref) => rule.validate(s, ValidationContext(ref))),
        isEmpty,
      );
    });
  });

  group('MeridianFlipTriggerRule', () {
    test('fires when long sequence has targets but no flip handling', () async {
      final container = _container();
      await container.read(appSettingsProvider.future);
      final rule = MeridianFlipTriggerRule();
      final target = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0,
        decDegrees: 0,
      );
      // 4 hour run (240 minutes well over the 120 minute threshold)
      final exposure = ExposureNode(durationSecs: 600, count: 24);
      final s = Sequence.create(
        name: 'X',
        nodes: {
          target.id: target.copyWith(childIds: [exposure.id]),
          exposure.id: exposure.copyWith(parentId: target.id),
        },
        rootNodeId: target.id,
      );
      final issues = _withRef(
        container,
        (ref) => rule.validate(s, ValidationContext(ref)),
      );
      expect(issues.single.title, 'No Meridian Flip Trigger');
    });

    test('clean when a MeridianFlipNode is present', () async {
      final container = _container();
      await container.read(appSettingsProvider.future);
      final rule = MeridianFlipTriggerRule();
      final flip = MeridianFlipNode();
      final target = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0,
        decDegrees: 0,
      );
      final exposure = ExposureNode(durationSecs: 600, count: 24);
      final s = Sequence.create(
        name: 'X',
        nodes: {
          target.id: target.copyWith(childIds: [exposure.id]),
          exposure.id: exposure.copyWith(parentId: target.id),
          flip.id: flip,
        },
        rootNodeId: target.id,
      );
      expect(
        _withRef(container, (ref) => rule.validate(s, ValidationContext(ref))),
        isEmpty,
      );
    });

    test('clean when run is short', () async {
      final container = _container();
      await container.read(appSettingsProvider.future);
      final rule = MeridianFlipTriggerRule();
      final target = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0,
        decDegrees: 0,
      );
      // 30 minute run — below threshold
      final exposure = ExposureNode(durationSecs: 60, count: 30);
      final s = Sequence.create(
        name: 'X',
        nodes: {
          target.id: target.copyWith(childIds: [exposure.id]),
          exposure.id: exposure.copyWith(parentId: target.id),
        },
        rootNodeId: target.id,
      );
      expect(
        _withRef(container, (ref) => rule.validate(s, ValidationContext(ref))),
        isEmpty,
      );
    });
  });
}
