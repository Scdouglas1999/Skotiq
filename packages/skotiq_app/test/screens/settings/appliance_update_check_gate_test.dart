// "Check for Updates" must not be offered to an appliance with nowhere to
// check — and must be offered to one that does have somewhere.
//
// Reproduced live against a paired headless appliance: the version card said
// there was no update server and the button was still enabled. Pressing it
// produced a GREEN snackbar ("Check request accepted") at the same instant as
// the status card flipped to "Update failed" with "Last error:
// UpdateException: Update server URL not configured" — a contradictory pair of
// answers to one press, and an alarming "Update failed" state manufactured out
// of a check that never ran.
//
// The mirror-image mistake is now possible too: a rig with no update server
// reads the project's GitHub releases, so gating on the server URL alone would
// gray out Check on a rig that updates perfectly well.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/update_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

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
        home: const Scaffold(body: UpdateSettings(isMobile: true)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

SkotiqButton _checkButton(WidgetTester tester) => tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Check for Updates'),
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
