import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/widgets/database_recovery_launcher.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// The quarantined file is gone, so nothing about it can be verified.
Future<QuarantinedDatabaseCheck> _missingBackup(String _) async =>
    QuarantinedDatabaseCheck.missing;

/// A quarantined file that turns out to be perfectly healthy — the shape
/// produced by the builds that rotated a database on SQLITE_BUSY.
Future<QuarantinedDatabaseCheck> _healthyBackup(String _) async =>
    const QuarantinedDatabaseCheck(
      exists: true,
      integrityOk: true,
      sizeBytes: 4 * 1024 * 1024,
    );

/// A quarantined file that really is damaged.
Future<QuarantinedDatabaseCheck> _corruptBackup(String _) async =>
    const QuarantinedDatabaseCheck(
      exists: true,
      integrityOk: false,
      sizeBytes: 4096,
      detail: 'database disk image is malformed',
    );

GoRouter _stubRouter() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('Dashboard')),
        ),
      ],
    );

void main() {
  testWidgets('outer-wrapper topology shows consumed recovery marker',
      (tester) async {
    final router = _stubRouter();
    addTearDown(router.dispose);
    var consumed = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appRouterProvider.overrideWithValue(router)
        ],
        child: DatabaseRecoveryLauncher(
          quarantineInspector: _missingBackup,
          markerConsumer: () async {
            consumed++;
            return DatabaseRecoveryMarker(
              markerPath: '/tmp/recovered.txt',
              backupPath: '/tmp/skotiq-corrupt.db',
              recoveredAtUtc: DateTime.utc(2026, 7, 14),
              reason: 'integrity check failed',
            );
          },
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(consumed, 1);
    expect(find.text('Database recovered'), findsOneWidget);
    expect(find.text('/tmp/skotiq-corrupt.db'), findsOneWidget);
  });

  testWidgets('acknowledges a recovery marker only after the warning closes',
      (tester) async {
    final router = _stubRouter();
    addTearDown(router.dispose);
    var acknowledgements = 0;
    final marker = DatabaseRecoveryMarker(
      markerPath: '/tmp/recovered.txt',
      backupPath: '/tmp/skotiq-corrupt.db',
      recoveredAtUtc: DateTime.utc(2026, 7, 14),
      reason: 'integrity check failed',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appRouterProvider.overrideWithValue(router)
        ],
        child: DatabaseRecoveryLauncher(
          quarantineInspector: _missingBackup,
          markerConsumer: () async => marker,
          markerAcknowledger: (value) async {
            expect(identical(value, marker), isTrue);
            acknowledgements++;
          },
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(find.text('Database recovered'), findsOneWidget);
    expect(acknowledgements, 0);

    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    await tester.pumpAndSettle();

    expect(acknowledgements, 1);
    expect(find.text('Database recovered'), findsNothing);
  });

  testWidgets('does not call a quarantined database corrupt when it is healthy',
      (tester) async {
    // The exact situation the data-loss bug produced: a healthy database was
    // quarantined because a second instance held it, and the user was told
    // their data was corrupted and offered no way back.
    final router = _stubRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appRouterProvider.overrideWithValue(router)
        ],
        child: DatabaseRecoveryLauncher(
          quarantineInspector: _healthyBackup,
          markerConsumer: () async => DatabaseRecoveryMarker(
            markerPath: '/tmp/recovered.txt',
            backupPath: '/tmp/skotiq-corrupt-1-skotiq.db',
            recoveredAtUtc: DateTime.utc(2026, 7, 14),
            reason: 'open-time error: database is locked',
          ),
          markerAcknowledger: (_) async {},
          restoreStager: (_) async {},
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(find.text('Skotiq started with a new database'), findsOneWidget);
    expect(find.text('Database recovered'), findsNothing);

    // No copy may ASSERT corruption about a file SQLite just called healthy.
    // Denying it ("it was not corrupt") is exactly what we want to keep, and
    // the backup's own filename still contains the word.
    const corruptionClaims = [
      'was corrupted',
      'the corruption',
      'corrupt file',
      'is corrupt',
    ];
    final claimsCorruption = find.byWidgetPredicate((w) {
      if (w is! Text) return false;
      final data = w.data?.toLowerCase();
      if (data == null) return false;
      return corruptionClaims.any(data.contains);
    });
    expect(
      claimsCorruption,
      findsNothing,
      reason: 'A verified-healthy database must not be described as corrupt.',
    );
    expect(find.textContaining('it is intact'), findsOneWidget);
  });

  testWidgets('offers a restore and stages it for the next launch',
      (tester) async {
    final router = _stubRouter();
    addTearDown(router.dispose);
    final staged = <String>[];
    var acknowledgements = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appRouterProvider.overrideWithValue(router)
        ],
        child: DatabaseRecoveryLauncher(
          quarantineInspector: _healthyBackup,
          markerConsumer: () async => DatabaseRecoveryMarker(
            markerPath: '/tmp/recovered.txt',
            backupPath: '/tmp/skotiq-corrupt-1-skotiq.db',
            recoveredAtUtc: DateTime.utc(2026, 7, 14),
            reason: 'open-time error: database is locked',
          ),
          markerAcknowledger: (_) async => acknowledgements++,
          restoreStager: (path) async => staged.add(path),
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Restore my database'));
    await tester.pumpAndSettle();

    expect(staged, equals(['/tmp/skotiq-corrupt-1-skotiq.db']));
    // A restore cannot happen under a live connection, so the user is told
    // exactly what has to happen next instead of being left guessing.
    expect(find.text('Restart to finish restoring'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    await tester.pumpAndSettle();
    expect(acknowledgements, 1);
  });

  testWidgets(
      'a genuinely corrupt backup is still reported as corrupt and '
      'is not offered for restore', (tester) async {
    final router = _stubRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appRouterProvider.overrideWithValue(router)
        ],
        child: DatabaseRecoveryLauncher(
          quarantineInspector: _corruptBackup,
          markerConsumer: () async => DatabaseRecoveryMarker(
            markerPath: '/tmp/recovered.txt',
            backupPath: '/tmp/skotiq-corrupt-1-skotiq.db',
            recoveredAtUtc: DateTime.utc(2026, 7, 14),
            reason: 'database disk image is malformed',
          ),
          markerAcknowledger: (_) async {},
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(find.text('Database recovered'), findsOneWidget);
    expect(find.textContaining('was corrupted'), findsOneWidget);
    // Putting a corrupt file back would just re-quarantine it next launch.
    expect(find.text('Restore my database'), findsNothing);
    expect(find.textContaining('still cannot read'), findsOneWidget);
  });

  testWidgets('a failed restore keeps the dialog open and says why',
      (tester) async {
    final router = _stubRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appRouterProvider.overrideWithValue(router)
        ],
        child: DatabaseRecoveryLauncher(
          quarantineInspector: _healthyBackup,
          markerConsumer: () async => DatabaseRecoveryMarker(
            markerPath: '/tmp/recovered.txt',
            backupPath: '/tmp/skotiq-corrupt-1-skotiq.db',
            recoveredAtUtc: DateTime.utc(2026, 7, 14),
            reason: 'open-time error: database is locked',
          ),
          markerAcknowledger: (_) async {},
          restoreStager: (_) async => throw StateError('read-only file system'),
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Restore my database'));
    await tester.pumpAndSettle();

    expect(find.text('Restart to finish restoring'), findsNothing);
    expect(find.textContaining('Could not stage the restore'), findsOneWidget);
  });
}
