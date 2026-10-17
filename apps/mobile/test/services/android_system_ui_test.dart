import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/android_system_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test(
    'disabled immersive preference keeps Android system bars visible',
    () async {
      await applyAndroidSystemUiPreference(false);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'SystemChrome.setEnabledSystemUIMode');
      expect(calls.single.arguments, 'SystemUiMode.edgeToEdge');
    },
  );

  test('enabled immersive preference uses immersive sticky mode', () async {
    await applyAndroidSystemUiPreference(true);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'SystemChrome.setEnabledSystemUIMode');
    expect(calls.single.arguments, 'SystemUiMode.immersiveSticky');
  });
}
