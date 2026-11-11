import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/app_shell_desktop.dart';
import 'package:skotiq_app/screens/shell/shell_exit_recorder.dart';

class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  const channel = MethodChannel('window_manager');
  late List<String> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> sendClose() async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onEvent', {'eventName': 'close'}),
      ),
      (_) {},
    );
  }

  testWidgets('a close after the shell is disposed still closes the window',
      (tester) async {
    await tester.pumpWidget(const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));

    var asked = 0;
    initWindowManager(state, onCloseRequested: () async {
      asked++;
      return false;
    });
    await tester.pump();
    expect(calls, contains('setPreventClose'));

    // While the shell is up, its confirmation decides.
    await sendClose();
    await tester.pump();
    expect(asked, 1);
    expect(calls, isNot(contains('destroy')));

    // Outside the shell the close is still intercepted, so something must
    // answer it.
    disposeWindowManager(state);
    await sendClose();
    await tester.pump();
    expect(asked, 1);
    expect(calls, contains('destroy'));

    // A new shell takes the decision back.
    calls.clear();
    initWindowManager(state, onCloseRequested: () async {
      asked++;
      return false;
    });
    await sendClose();
    await tester.pump();
    expect(asked, 2);
    expect(calls, isNot(contains('destroy')));
    disposeWindowManager(state);
  });

  testWidgets(
      'an accepted close records the clean exit, starts the restart, then '
      'ends the process through the entry point instead of the window '
      'teardown', (tester) async {
    await tester.pumpWidget(const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));
    final steps = <String>[];
    void recorder(String reason) => steps.add('recorded: $reason');
    ShellExit.register(recorder);
    ShellExit.registerRelaunch(() async => steps.add('spawned'));
    ShellExit.registerEnd(() async => steps.add('ended'));
    addTearDown(() {
      ShellExit.unregister(recorder);
      ShellExit.registerEnd(null);
    });

    initWindowManager(state, onCloseRequested: () async => true);
    final restarted = ShellExit.requestRelaunch();
    await sendClose();
    await tester.pump();

    expect(steps, ['recorded: Window closed', 'spawned', 'ended']);
    expect(await restarted, isTrue);
    expect(calls, isNot(contains('destroy')));
    disposeWindowManager(state);
  });
}
