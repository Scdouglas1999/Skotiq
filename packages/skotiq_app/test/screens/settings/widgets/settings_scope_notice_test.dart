// On a linked client, Settings never said whose setting a change edits: Auto-
// connect flipped the host's value while Red night stayed on this computer,
// and both pages looked the same (qa-pair QP-17, qa-rig RIG-23).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_scope_notice.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/providers/host_settings/settings_key_scope.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

Future<void> _pump(WidgetTester tester, String key, SkotiqBackend? backend) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (backend != null)
          backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: SettingsScopeNotice(sectionKey: key)),
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
    expect(find.textContaining('Saved on this computer only'), findsOneWidget);
  });

  // SY-13: Annotations said "Saved on the imaging host" while its overlay
  // settings are device-local keys that never leave this computer.
  testWidgets('Annotations is this computer only, as its keys are', (
    tester,
  ) async {
    final backend = _MockNetworkBackend();
    when(() => backend.serverHost).thenReturn('192.168.1.100');
    await _pump(tester, 'annotations', backend);
    expect(find.textContaining('Saved on this computer only'), findsOneWidget);
    expect(find.textContaining('imaging host (192'), findsNothing);
    for (final key in const [
      'annotation_settings',
      'annotation_marker_style',
      'annotation_presets',
    ]) {
      expect(isDeviceLocalSettingKey(key), isTrue, reason: key);
    }
  });

  testWidgets('the machine that owns the rig shows nothing', (tester) async {
    await _pump(tester, 'general', null);
    expect(find.textContaining('Saved on'), findsNothing);
  });
}
