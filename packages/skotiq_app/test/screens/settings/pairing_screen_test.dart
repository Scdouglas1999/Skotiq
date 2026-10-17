import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/pairing_screen.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _ControllablePairingNotifier extends PairingNotifier {
  _ControllablePairingNotifier(super.database) : super.withDatabase();

  final deleteCompletion = Completer<bool>();
  int deleteCalls = 0;

  @override
  Future<bool> deleteDevice(String deviceId) {
    deleteCalls += 1;
    return deleteCompletion.future;
  }
}

class _FailingCancelDatabase extends PairingDatabase {
  _FailingCancelDatabase() : super.forTesting(NativeDatabase.memory());

  bool failCancellation = false;

  @override
  Future<void> deletePairingSession(String pairingCode) {
    if (failCancellation) {
      return Future<void>.error(StateError('cancel failed'));
    }
    return super.deletePairingSession(pairingCode);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an immediate Start waits for initialization and creates a live code',
      () async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    final notifier = PairingNotifier.withDatabase(database);
    addTearDown(() async {
      notifier.dispose();
      await database.close();
    });

    // Call immediately, before the constructor's asynchronous initial read can
    // complete. This used to hit a LateInitializationError on _tokenManager.
    final start = notifier.startPairing();
    // A second same-frame tap must not create another still-valid code that the
    // screen immediately loses track of.
    expect(await notifier.startPairing(), isFalse);
    final started = await start;

    expect(started, isTrue);
    final code = notifier.state.pairingCode;
    expect(code, isNotNull);
    expect(await database.getPairingSession(code!), isNotNull);

    expect(await notifier.cancelPairing(), isTrue);
    expect(notifier.state.pairingCode, isNull);
    expect(await database.getPairingSession(code), isNull);
  });

  test('failed cancellation keeps the still-live code visible', () async {
    final database = _FailingCancelDatabase();
    final notifier = PairingNotifier.withDatabase(database);
    addTearDown(() async {
      notifier.dispose();
      await database.close();
    });

    expect(await notifier.startPairing(), isTrue);
    final code = notifier.state.pairingCode!;
    database.failCancellation = true;

    expect(await notifier.cancelPairing(), isFalse);
    expect(notifier.state.pairingCode, code);
    expect(notifier.state.error, 'pairingErrorCancel');
    expect(await database.getPairingSession(code), isNotNull);
  });

  testWidgets('failed device deletion keeps confirmation open with retry',
      (tester) async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.addPairedDevice(
      deviceId: 'phone-1',
      deviceName: 'Observatory phone',
      sessionToken: 'ab' * 32,
      deviceType: 'mobile',
    );
    final notifier = _ControllablePairingNotifier(database);
    expect(await notifier.loadPairedDevices(), isTrue);

    await pumpAppScreen(
      tester,
      const PairingScreen(),
      extraOverrides: [
        pairingProvider.overrideWith((ref) => notifier),
      ],
    );

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete device').last);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Delete device'),
    );
    await tester.pump();
    expect(notifier.deleteCalls, 1);

    // Back/barrier dismissal must not hide an operation whose outcome is not
    // known yet.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    notifier.deleteCompletion.complete(false);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text('Skotiq could not delete that paired device.'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
