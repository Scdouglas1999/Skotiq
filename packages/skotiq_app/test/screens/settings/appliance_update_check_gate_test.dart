// "Check for Updates" must not be offered to an appliance with nowhere to
// check — and must be offered to one that does have somewhere.
//
// With no update server and no other source, pressing Check would answer a
// green "Check request accepted" beside an "Update failed" status for a check
// that never ran. A rig with no update server reads the project's GitHub
// releases, though, so gating on the server URL alone would gray out Check
// on a rig that updates perfectly well.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_app/screens/settings/widgets/update_settings.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/models.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

RemoteVersionInfo _version({String? updateServerUrl, String? updateSource}) =>
    RemoteVersionInfo(
      currentVersion: '6.1.0',
      buildNumber: 25,
      platform: 'linux',
      updateServerUrl: updateServerUrl,
      updateSource: updateSource,
    );

Future<void> _pump(WidgetTester tester, _MockNetworkBackend backend) async {
  when(() => backend.getUpdateStatus())
      .thenAnswer((_) async => const RemoteUpdateStatus(state: 'idle'));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider
            .overrideWith((ref) => _FixedBackendNotifier(ref, backend)),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
            body: SettingsFormScope(narrow: true, child: UpdateSettings())),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

SkotiqButton _checkButton(WidgetTester tester) => tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Check for updates'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the check is disabled when the rig reports no source at all',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.getSystemVersion())
        .thenAnswer((_) async => _version(updateServerUrl: null));

    await _pump(tester, backend);

    expect(find.textContaining('no update source'), findsOneWidget);
    expect(_checkButton(tester).onPressed, isNull);
  });

  testWidgets('a rig reading GitHub releases can still be checked',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.getSystemVersion()).thenAnswer(
      (_) async => _version(updateSource: 'github-releases'),
    );

    await _pump(tester, backend);

    expect(
      find.textContaining('published GitHub releases'),
      findsOneWidget,
    );
    expect(_checkButton(tester).onPressed, isNotNull);
  });

  testWidgets('the check is offered when the rig has an update server',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.getSystemVersion()).thenAnswer(
      (_) async => _version(
        updateServerUrl: 'https://updates.example.com',
        updateSource: 'https://updates.example.com',
      ),
    );

    await _pump(tester, backend);

    expect(_checkButton(tester).onPressed, isNotNull);
  });
}
