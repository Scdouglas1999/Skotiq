import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/command_action_result.dart';
import 'package:skotiq_app/services/rotate_after_centering.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

class _Rotator extends RotatorStateNotifier {
  _Rotator(super.ref, {required bool connected}) {
    // ignore: invalid_use_of_protected_member
    state = RotatorState(
      connectionState: connected
          ? DeviceConnectionState.connected
          : DeviceConnectionState.disconnected,
      deviceId: 'rot-1',
    );
  }
}

class _Backend implements DeviceBackend {
  _Backend({this.fail = false});
  final bool fail;
  final moves = <(String, double)>[];

  @override
  Future<void> rotatorMoveTo(String deviceId, double position) async {
    if (fail) throw StateError('stuck');
    moves.add((deviceId, position));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '${invocation.memberName} not used in this test');
}

Future<CommandActionResult?> _rotate(
  WidgetTester tester, {
  required bool connected,
  required _Backend backend,
}) async {
  late WidgetRef widgetRef;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      rotatorStateProvider
          .overrideWith((ref) => _Rotator(ref, connected: connected)),
      deviceBackendProvider.overrideWithValue(backend),
    ],
    child: MaterialApp(
      home: Consumer(builder: (context, ref, _) {
        widgetRef = ref;
        return const SizedBox.shrink();
      }),
    ),
  ));
  return rotateAfterCentering(widgetRef, 42.25);
}

void main() {
  testWidgets('no connected rotator: nothing is sent', (tester) async {
    final backend = _Backend();
    final result = await _rotate(tester, connected: false, backend: backend);
    expect(result, isNull);
    expect(backend.moves, isEmpty);
  });

  testWidgets('a connected rotator turns to the angle', (tester) async {
    final backend = _Backend();
    final result = await _rotate(tester, connected: true, backend: backend);
    expect(backend.moves, [('rot-1', 42.25)]);
    expect(result!.isSuccess, isTrue);
    expect(result.message, 'Rotating to 42.3°');
  });

  testWidgets('a failed move says so', (tester) async {
    final result = await _rotate(
      tester,
      connected: true,
      backend: _Backend(fail: true),
    );
    expect(result!.isSuccess, isFalse);
    expect(result.message, startsWith('Rotation failed:'));
  });
}
