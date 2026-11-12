// On a linked client, Settings never said whose setting a change edits: Auto-
// connect flipped the host's value while Red night stayed on this computer,
// and both pages looked the same (qa-pair QP-17, qa-rig RIG-23).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/settings_sections.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_scope_notice.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

Future<void> _pump(
  WidgetTester tester,
  String key,
  SkotiqBackend? backend, {
  LinkedRig? rig,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (backend != null)
          backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
        if (rig != null) launchLinkedRigProvider.overrideWithValue(rig),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SettingsScopeNotice.forSection(SettingsSectionId.resolve(key)!),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a host section names the imaging host', (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.serverHost).thenReturn('192.168.1.100');
    await _pump(tester, 'general', backend);
    expect(
      find.textContaining('Saved on the imaging host (192.168.1.100)'),
      findsOneWidget,
    );
  });

  testWidgets('Appearance is this computer only', (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.serverHost).thenReturn('192.168.1.100');
    await _pump(tester, 'appearance', backend);
    expect(find.textContaining('Saved on this device only'), findsOneWidget);
  });

  // SY-13: Annotations said "Saved on the imaging host" while its overlay
  // settings are device-local keys that never leave this computer.
  testWidgets('Annotations is this computer only, as its keys are', (
    tester,
  ) async {
    final backend = _MockNetworkBackend();
    when(() => backend.serverHost).thenReturn('192.168.1.100');
    await _pump(tester, 'annotations', backend);
    expect(find.textContaining('Saved on this device only'), findsOneWidget);
    expect(find.textContaining('imaging host (192'), findsNothing);
    for (final key in const [
      'annotation_settings',
      'annotation_marker_style',
      'annotation_presets',
    ]) {
      expect(isDeviceLocalSettingKey(key), isTrue, reason: key);
    }
  });

  // Connection keeps its link here and its discovery switches on the host,
  // so the page labels each group rather than the whole section.
  testWidgets('a section stored in both places has no one label', (
    tester,
  ) async {
    final backend = _MockNetworkBackend();
    when(() => backend.serverHost).thenReturn('192.168.1.100');
    await _pump(tester, 'connection', backend);
    expect(find.textContaining('Saved on'), findsNothing);
  });

  // Owner 2026-11-11: a link paired the normal way (one tap, control access)
  // changes the host's app settings, so the notice no longer says the host
  // refuses them.
  testWidgets('a one-tap link is told where a change is saved, not refused', (
    tester,
  ) async {
    final backend = _MockNetworkBackend();
    when(() => backend.serverHost).thenReturn('192.168.1.100');
    await _pump(
      tester,
      'general',
      backend,
      rig: LinkedRig(
        host: '192.168.1.100',
        port: 8080,
        name: 'home',
        tokenScope: 'control',
        pairedAt: DateTime.utc(2026, 11, 11),
      ),
    );
    expect(
      find.textContaining('Saved on the imaging host (192.168.1.100)'),
      findsOneWidget,
    );
    expect(find.textContaining('refuses'), findsNothing);
    expect(find.byType(SkotiqButton), findsNothing);
  });

  testWidgets('the host\'s updates and decision log are the host\'s', (
    tester,
  ) async {
    final backend = _MockNetworkBackend();
    when(() => backend.serverHost).thenReturn('192.168.1.100');
    for (final key in const ['updates', 'replay-debug']) {
      await _pump(tester, key, backend);
      expect(
        find.textContaining('Saved on the imaging host'),
        findsOneWidget,
        reason: key,
      );
    }
  });

  testWidgets('the machine that owns the rig shows nothing', (tester) async {
    await _pump(tester, 'general', null);
    expect(find.textContaining('Saved on'), findsNothing);
  });
}
