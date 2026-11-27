// A client that is not linked reads host data from a stand-in that refuses
// every call. The always-on services it runs meanwhile must not leave that
// refusal uncaught.

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/startup/always_on_services.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';

class _Offline extends BackendNotifier {
  _Offline(super.ref) {
    state = DisconnectedBackend();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final role in [LaunchRole.linkedClient, LaunchRole.mobile]) {
    test(
        '${role.name}: the always-on services leave no refusal of the '
        'unlinked host uncaught', () async {
      final root = Directory.systemTemp.createTempSync('sk-unlinked-svc-');
      addTearDown(() => root.deleteSync(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => root.path);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final refusals = <Object>[];
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          launchRoleProvider.overrideWithValue(role),
          backendProvider.overrideWith(
            (ref) => _Offline(ref),
          ),
        ],
      );
      await runZonedGuarded(() async {
        expect(container.read(unlinkedHostProvider), isNotNull);
        final services = startAlwaysOnServices(container, role);
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        services.stop();
      }, (error, _) {
        if (error is HostNotLinkedException) refusals.add(error);
      });
      container.dispose();
      await db.close();

      expect(refusals, isEmpty);
    });
  }
}
