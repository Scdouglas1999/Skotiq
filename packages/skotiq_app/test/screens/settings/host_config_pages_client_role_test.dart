// A client's Settings pages that edit the imaging host's own config refuse
// on the client role, not only while linked: a desktop started with
// `--remote-host` that has not reached its host (or lost it) would otherwise
// save alert destinations, phone pushes, Home Assistant and plugin settings
// and the host's storage paths into its own database, where nothing reads
// them.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/integrations_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/file_path_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_app/services/host_folders.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_routing_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_settings.dart';
import 'package:skotiq_core/backend.dart' show DemoBackend;
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

Future<HarnessHandle> _typeImageOutput(
  WidgetTester tester,
  List<Override> overrides,
) async {
  final handle = await pumpAppScreen(
    tester,
    const SettingsFormScope(
      narrow: false,
      embedded: true,
      child: FilePathSettings(),
    ),
    size: const Size(1280, 1000),
    extraOverrides: [
      localFoldersProvider.overrideWithValue(FakeHostFolders()),
      ...overrides,
    ],
    settle: false,
  );
  await tester.pump();
  await tester.pump();
  final field = find.descendant(
    of: find.byType(SettingsPathInput).first,
    matching: find.byType(TextField),
  );
  await tester.ensureVisible(field);
  await tester.enterText(field, '/mnt/nas/lights');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return handle;
}

void main() {
  // The phone's demo rig runs in this process: its captures are saved where
  // this database says, so its storage paths are this database's to set.
  testWidgets('the demo rig on the phone stores its own image output path', (
    tester,
  ) async {
    final demo = DemoBackend(latitudeDeg: 40, longitudeDeg: -105);
    addTearDown(demo.dispose);
    final handle = await _typeImageOutput(tester, [
      launchRoleProvider.overrideWithValue(LaunchRole.mobile),
      backendProvider.overrideWith((ref) => TestBackendNotifier(ref, demo)),
    ]);

    expect(
      handle.container.read(appSettingsProvider).value!.imageOutputPath,
      '/mnt/nas/lights',
    );
  });

  for (final role in [LaunchRole.linkedClient, LaunchRole.mobile]) {
    group('a ${role.name} launch that is not linked', () {
      testWidgets('is told alert destinations are set up on the host', (
        tester,
      ) async {
        await pumpAppScreen(
          tester,
          const SingleChildScrollView(child: NotificationRoutingSettings()),
          extraOverrides: [
            launchRoleProvider.overrideWithValue(role),
            secretsStoreProvider.overrideWithValue(
              SecretsStore(InMemorySecureKeyValueStore()),
            ),
          ],
          settle: false,
        );
        await tester.pump();

        expect(find.text('Set up on the imaging computer'), findsOneWidget);
        expect(find.text('Send alerts'), findsNothing);
        expect(
          find.text('Device name'),
          findsNothing,
          reason: 'the local Home Assistant editor saves into this database',
        );
      });

      testWidgets('is told phone pushes are set on the host', (tester) async {
        await pumpAppScreen(
          tester,
          const NotificationSettings(),
          extraOverrides: [
            launchRoleProvider.overrideWithValue(role),
            secretsStoreProvider.overrideWithValue(
              SecretsStore(InMemorySecureKeyValueStore()),
            ),
          ],
          settle: false,
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        expect(find.text('Set on the imaging computer'), findsOneWidget);
        expect(
          find.textContaining('phones paired with this computer'),
          findsNothing,
          reason: 'the local push editor saves into this database',
        );
      });

      testWidgets('cannot store a host storage path in its own database', (
        tester,
      ) async {
        final handle = await _typeImageOutput(tester, [
          launchRoleProvider.overrideWithValue(role),
        ]);

        expect(
          handle.container.read(appSettingsProvider).value!.imageOutputPath,
          isEmpty,
        );
        expect(
          find.text('This path can only be changed on the host machine.'),
          findsOneWidget,
        );
      });

      testWidgets('is told plugins are managed on the host', (tester) async {
        final host = PluginHost(
          contextFactory: PluginContextFactory(
            storageFactory: (_) => InMemoryPluginStorage(),
          ),
        );
        await pumpAppScreen(
          tester,
          const IntegrationsSettings(),
          extraOverrides: [
            launchRoleProvider.overrideWithValue(role),
            pluginHostProvider.overrideWithValue(host),
            pluginRegistrationProvider.overrideWith((ref) {}),
            pluginActivityTrackerProvider.overrideWith(
              (ref) => PluginActivityTracker(host: host, descriptors: const []),
            ),
          ],
          settle: false,
        );
        await tester.pump();

        expect(find.text('Managed on the imaging host'), findsOneWidget);
        // Discord, Pushover and Home Assistant are reachable from a phone,
        // on the Notifications page.
        expect(
          find.widgetWithText(SkotiqButton, 'Open notifications'),
          findsOneWidget,
        );
      });
    });
  }
}
