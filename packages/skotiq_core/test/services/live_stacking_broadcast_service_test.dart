// Tests for the live-stacking broadcast service.
//
// Covers the three failure modes the brief calls out:
//   * Frame published → broadcast endpoint serves a JPEG.
//   * SSE stream emits one update per frame.
//   * Auth token enforced — both public and token-gated paths.
//   * Watermark template renders.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
// Validation rules are internal — import the implementation path
// directly. Same convention as the smart_exposure rules tests.
import 'package:skotiq_core/src/providers/sequence/rules/live_stacking_rules.dart';

LiveStackingNode _makeNode({
  String name = 'Live Stacking',
  LiveStackingMode mode = LiveStackingMode.broadcastOnly,
  LiveStackingMethod method = LiveStackingMethod.average,
  int port = 8081,
  String? token,
  String? watermark,
  int thumbW = 200,
  int thumbH = 150,
}) {
  return LiveStackingNode(
    id: 'ls-test',
    name: name,
    mode: mode,
    stackMethod: method,
    broadcastPort: port,
    authToken: token,
    watermarkText: watermark,
    thumbnailWidth: thumbW,
    thumbnailHeight: thumbH,
  );
}

/// Synthesize a u16 frame with a smooth gradient. Real bridge frames
/// are luminance-ordered; the gradient gives the auto-stretch
/// histogram something non-trivial to fit so we exercise the encode
/// path more than just a flat-tone shortcut.
Uint16List _syntheticGradient(int width, int height) {
  final out = Uint16List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      out[y * width + x] = ((x + y) * 32).clamp(0, 65535);
    }
  }
  return out;
}

ProviderContainer _container() {
  return ProviderContainer(overrides: []);
}

void main() {
  group('LiveStackingBroadcastService', () {
    test('starts inactive', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      expect(svc.state.active, isFalse);
      expect(svc.state.jpegBytes, isNull);
      expect(svc.state.framesStacked, 0);
    });

    test('activate copies node config into state', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.activate(
        _makeNode(
          port: 9090,
          method: LiveStackingMethod.sigma,
          token: 'secret',
          watermark: r'M42 — ${integration.hms}',
        ),
      );
      final s = svc.state;
      expect(s.active, isTrue);
      expect(s.port, 9090);
      expect(s.stackMethod, LiveStackingMethod.sigma);
      expect(s.authToken, 'secret');
      expect(s.isPublic, isFalse);
      expect(s.watermarkText, r'M42 — ${integration.hms}');
      expect(s.activatedAt, isNotNull);
    });

    test('deactivate clears state', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.activate(_makeNode());
      expect(svc.state.active, isTrue);
      svc.deactivate();
      expect(svc.state.active, isFalse);
      expect(svc.state.framesStacked, 0);
    });

    test('publishFrame renders a JPEG and increments counters', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.activate(_makeNode(thumbW: 64, thumbH: 48));
      svc.publishFrame(
        width: 64,
        height: 48,
        previewData: _syntheticGradient(64, 48),
        exposureSecs: 60.0,
      );
      final s = svc.state;
      expect(s.framesStacked, 1);
      expect(s.integrationSecs, 60.0);
      expect(s.jpegBytes, isNotNull);
      // JPEG magic bytes — sanity check we actually encoded something.
      expect(s.jpegBytes!.length, greaterThan(100));
      expect(s.jpegBytes![0], 0xFF);
      expect(s.jpegBytes![1], 0xD8);
    });

    test('publishFrame emits an update on the SSE stream', () async {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.activate(_makeNode(thumbW: 32, thumbH: 32));
      // Subscribe before publishing — the stream is broadcast, so
      // we'd miss synchronous events fired before the listener attaches.
      final future = svc.updates.first;
      svc.publishFrame(
        width: 32,
        height: 32,
        previewData: _syntheticGradient(32, 32),
        exposureSecs: 30.0,
      );
      final upd = await future.timeout(const Duration(seconds: 2));
      expect(upd.framesStacked, 1);
      expect(upd.integrationSecs, 30.0);
    });

    test('publishFrame no-ops when broadcast is inactive', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      // Service starts inactive — no activate() call.
      svc.publishFrame(
        width: 32,
        height: 32,
        previewData: _syntheticGradient(32, 32),
        exposureSecs: 30.0,
      );
      expect(svc.state.framesStacked, 0);
      expect(svc.state.jpegBytes, isNull);
    });

    test('authorize accepts everyone when public', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.activate(_makeNode(token: null));
      expect(svc.authorize(null), isTrue);
      expect(svc.authorize(''), isTrue);
      expect(svc.authorize('whatever'), isTrue);
    });

    test('authorize rejects missing or wrong token on private', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.activate(_makeNode(token: 'secret'));
      expect(svc.authorize(null), isFalse);
      expect(svc.authorize(''), isFalse);
      expect(svc.authorize('wrong'), isFalse);
      expect(svc.authorize('secret'), isTrue);
    });

    test('authorize denies any request when inactive', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      expect(svc.authorize(null), isFalse);
      expect(svc.authorize('any'), isFalse);
    });

    test('watermark template renders tokens', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.activate(
        _makeNode(watermark: r'M42 — ${integration.hms} (${frames} frames)'),
      );
      svc.updateCurrentTarget('M42');
      svc.publishFrame(
        width: 32,
        height: 32,
        previewData: _syntheticGradient(32, 32),
        exposureSecs: 60.0 * 60.0 * 2 + 12 * 60, // 2h12m
      );
      final rendered = svc.renderWatermark();
      expect(rendered, contains('M42'));
      expect(rendered, contains('2h12m'));
      expect(rendered, contains('1 frames'));
    });

    test('watermark passes through unknown tokens unmodified', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.activate(_makeNode(watermark: r'${not.a.token}'));
      expect(svc.renderWatermark(), r'${not.a.token}');
    });

    test('integrationHms formats correctly', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.activate(_makeNode());
      svc.publishFrame(
        width: 16,
        height: 16,
        previewData: _syntheticGradient(16, 16),
        exposureSecs: 90.0,
      );
      expect(svc.state.integrationHms, '1m30s');
    });

    test('replacement broadcast wins (last activate)', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.activate(_makeNode(port: 8081, token: 'one'));
      svc.activate(_makeNode(port: 9999, token: 'two'));
      expect(svc.state.port, 9999);
      expect(svc.state.authToken, 'two');
      // Counters reset on replacement so the new broadcast starts
      // from frame 0.
      expect(svc.state.framesStacked, 0);
    });
  });

  group('LiveStackingNode validation rules', () {
    test('LiveStackingNoExposureRule fires when no exposure sibling', () {
      final ls = LiveStackingNode();
      final root = TargetHeaderNode(
        targetName: 'M42',
        raHours: 5.6,
        decDegrees: -5.2,
        childIds: [ls.id],
      );
      final patchedLs = ls.copyWith(parentId: root.id);
      final sequence = Sequence.create(
        id: 's',
        name: 'Test',
        nodes: {root.id: root, patchedLs.id: patchedLs},
        rootNodeId: root.id,
      );
      final issues = LiveStackingNoExposureRule().validate(sequence);
      expect(issues, isNotEmpty);
      expect(issues.first.severity, ValidationSeverity.warning);
      expect(
        issues.first.title,
        contains('Live Stacking has nothing to broadcast'),
      );
    });

    test('LiveStackingNoExposureRule passes with sibling ExposureNode', () {
      final ls = LiveStackingNode();
      final ex = ExposureNode(durationSecs: 60, count: 5);
      final root = TargetHeaderNode(
        targetName: 'M42',
        raHours: 5.6,
        decDegrees: -5.2,
        childIds: [ls.id, ex.id],
      );
      final patchedLs = ls.copyWith(parentId: root.id);
      final patchedEx = ex.copyWith(parentId: root.id);
      final sequence = Sequence.create(
        id: 's',
        name: 'Test',
        nodes: {
          root.id: root,
          patchedLs.id: patchedLs,
          patchedEx.id: patchedEx,
        },
        rootNodeId: root.id,
      );
      final issues = LiveStackingNoExposureRule().validate(sequence);
      expect(issues, isEmpty);
    });

    test('LiveStackingPortClashRule flags collision with default 8080', () {
      final ls = LiveStackingNode(broadcastPort: 8080);
      final root = TargetHeaderNode(
        targetName: 'M42',
        raHours: 5.6,
        decDegrees: -5.2,
        childIds: [ls.id],
      );
      final patched = ls.copyWith(parentId: root.id);
      final sequence = Sequence.create(
        id: 's',
        name: 'Test',
        nodes: {root.id: root, patched.id: patched},
        rootNodeId: root.id,
      );
      final issues = LiveStackingPortClashRule().validate(sequence);
      expect(issues.length, 1);
      expect(issues.first.severity, ValidationSeverity.error);
      expect(issues.first.title, contains('clashes with main server'));
    });

    test('LiveStackingPortClashRule flags out-of-range port', () {
      final ls = LiveStackingNode(broadcastPort: 0);
      final root = TargetHeaderNode(
        targetName: 'M42',
        raHours: 5.6,
        decDegrees: -5.2,
        childIds: [ls.id],
      );
      final patched = ls.copyWith(parentId: root.id);
      final sequence = Sequence.create(
        id: 's',
        name: 'Test',
        nodes: {root.id: root, patched.id: patched},
        rootNodeId: root.id,
      );
      final issues = LiveStackingPortClashRule().validate(sequence);
      expect(issues.any((i) => i.title.contains('out of range')), isTrue);
    });

    test('LiveStackingPortClashRule passes with default 8081 port', () {
      final ls = LiveStackingNode(broadcastPort: 8081);
      final root = TargetHeaderNode(
        targetName: 'M42',
        raHours: 5.6,
        decDegrees: -5.2,
        childIds: [ls.id],
      );
      final patched = ls.copyWith(parentId: root.id);
      final sequence = Sequence.create(
        id: 's',
        name: 'Test',
        nodes: {root.id: root, patched.id: patched},
        rootNodeId: root.id,
      );
      final issues = LiveStackingPortClashRule().validate(sequence);
      expect(issues, isEmpty);
    });
  });

  group('LiveStackingNode model', () {
    test('isPublic is true when authToken is null or empty', () {
      expect(LiveStackingNode().isPublic, isTrue);
      expect(LiveStackingNode(authToken: '').isPublic, isTrue);
      expect(LiveStackingNode(authToken: 'x').isPublic, isFalse);
    });

    test('copyWith explicit null KEEPS authToken (plain `??` semantics)', () {
      // LiveStackingNode.copyWith carries no `_unset` sentinel: null and
      // omitted are indistinguishable and both keep. The editor clears via
      // rebuild-explicit (see
      // live_stacking_properties.dart::_rebuildWithCleared).
      final n = LiveStackingNode(authToken: 'secret');
      final stillSecret = n.copyWith(authToken: null);
      expect(stillSecret.authToken, 'secret');
      expect(stillSecret.isPublic, isFalse);
    });

    test('authToken cleared via rebuild-explicit makes broadcast public', () {
      // The rebuild-explicit recipe used by the editor.
      final n = LiveStackingNode(authToken: 'secret');
      final cleared = LiveStackingNode(
        id: n.id,
        name: n.name,
        isEnabled: n.isEnabled,
        childIds: n.childIds,
        parentId: n.parentId,
        orderIndex: n.orderIndex,
        comment: n.comment,
        mode: n.mode,
        stackMethod: n.stackMethod,
        maxFramesToStack: n.maxFramesToStack,
        broadcastEnabled: n.broadcastEnabled,
        broadcastPort: n.broadcastPort,
        broadcastPath: n.broadcastPath,
        watermarkText: n.watermarkText,
        thumbnailWidth: n.thumbnailWidth,
        thumbnailHeight: n.thumbnailHeight,
        // omit authToken
      );
      expect(cleared.authToken, isNull);
      expect(cleared.isPublic, isTrue);
    });

    test('copyWith preserves authToken when not provided', () {
      final n = LiveStackingNode(authToken: 'secret');
      final renamed = n.copyWith(name: 'Renamed');
      expect(renamed.authToken, 'secret');
    });

    test('LiveStackingMode round-trips storage key', () {
      for (final m in LiveStackingMode.values) {
        expect(LiveStackingMode.fromStorageKey(m.storageKey), m);
      }
    });

    test('LiveStackingMethod round-trips storage key', () {
      for (final m in LiveStackingMethod.values) {
        expect(LiveStackingMethod.fromStorageKey(m.storageKey), m);
      }
    });

    test('LiveStackingMode.fromStorageKey is lenient on unknown keys', () {
      expect(
        LiveStackingMode.fromStorageKey('garbage'),
        LiveStackingMode.broadcastOnly,
      );
    });

    test('LiveStackingMethod.fromStorageKey is lenient on unknown keys', () {
      expect(
        LiveStackingMethod.fromStorageKey('garbage'),
        LiveStackingMethod.average,
      );
    });
  });

  // Master kill switch (Settings → "Disable broadcast everywhere")
  group('LiveStackingBroadcastService master kill switch', () {
    test('killSwitchEnabled defaults to false', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      expect(svc.killSwitchEnabled, isFalse);
    });

    test('engaging the kill switch suppresses activate()', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.setKillSwitch(true);
      svc.activate(_makeNode());
      // activate() must return without flipping the state to active —
      // the per-node config is intact but the public surface stays off.
      expect(svc.state.active, isFalse);
    });

    test('flipping the kill switch ON force-deactivates a live session', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      // Activate normally first.
      svc.activate(_makeNode());
      expect(svc.state.active, isTrue);
      // Now engage the kill switch mid-run.
      svc.setKillSwitch(true);
      expect(
        svc.state.active,
        isFalse,
        reason: 'Master kill must force-stop the active session',
      );
    });

    test('flipping the kill switch back OFF re-allows activation', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.setKillSwitch(true);
      svc.activate(_makeNode());
      expect(svc.state.active, isFalse);
      svc.setKillSwitch(false);
      svc.activate(_makeNode());
      expect(svc.state.active, isTrue);
    });

    test('idempotent: setKillSwitch with same value is a no-op', () {
      final c = _container();
      addTearDown(c.dispose);
      final svc = c.read(liveStackingBroadcastServiceProvider);
      svc.activate(_makeNode());
      // Call setKillSwitch(false) while it's already false — must not
      // tear down the running session.
      svc.setKillSwitch(false);
      expect(svc.state.active, isTrue);
    });
  });
}
