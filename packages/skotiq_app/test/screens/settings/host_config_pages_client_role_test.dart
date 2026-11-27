// A client's Settings pages that edit the imaging host's own config refuse
// on the client role, not only while linked: a desktop started with
// `--remote-host` that has not reached its host (or lost it) would otherwise
// save alert destinations, Home Assistant and plugin settings into its own
// database, where nothing ever sends them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/integrations_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_routing_settings.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

import '../../harness/harness.dart';

void main() {
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
      });
    });
  }
}
