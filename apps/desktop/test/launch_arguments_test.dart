import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/launch_arguments.dart';

void main() {
  LaunchRequest desktop(List<String> args) =>
      readLaunchArguments(args, LaunchMode.desktop);
  LaunchRequest headless(List<String> args) =>
      readLaunchArguments(args, LaunchMode.headless);

  String errorOf(LaunchRequest request) =>
      (request as LaunchUsageError).message;

  test('no arguments start the app', () {
    expect(desktop(const []), isA<StartApp>());
    expect(headless(const ['--headless']), isA<StartApp>());
  });

  test('--help and --version answer in either mode, before any check', () {
    expect(desktop(const ['--help']), isA<ShowHelp>());
    expect(headless(const ['--headless', '--help']), isA<ShowHelp>());
    expect(desktop(const ['--bogus', '--help']), isA<ShowHelp>());
    expect(desktop(const ['--version']), isA<ShowVersion>());
    expect(headless(const ['--version', '--port=x']), isA<ShowVersion>());
  });

  test('an unknown or mistyped option is a usage error', () {
    expect(errorOf(desktop(const ['--hepl'])), contains('--hepl'));
    expect(errorOf(desktop(const ['-h'])), contains('unknown option'));
    expect(errorOf(desktop(const ['M42'])), contains('unknown option'));
    expect(desktop(const ['--remote-hots=rig.local']), isA<LaunchUsageError>());
  });

  test('host options need --headless and desktop options refuse it', () {
    expect(
      errorOf(desktop(const ['--port=8080'])),
      '--port works only with --headless',
    );
    expect(
      errorOf(headless(const ['--headless', '--remote-host=rig'])),
      '--remote-host is not an option for --headless',
    );
  });

  test('values are checked where the option has a shape', () {
    expect(
      errorOf(headless(const ['--port'])),
      '--port needs a value: --port=<port>',
    );
    expect(errorOf(headless(const ['--port=abc'])), contains('port number'));
    expect(errorOf(headless(const ['--port=70000'])), contains('port number'));
    expect(errorOf(headless(const ['--tls=1'])), '--tls takes no value');
    expect(headless(const ['--port=8080', '--tls']), isA<StartApp>());
    expect(desktop(const ['--serve']), isA<StartApp>());
    expect(desktop(const ['--serve=true']), isA<StartApp>());
    expect(
      desktop(const ['--remote-host=rig.local', '--remote-port=8080']),
      isA<StartApp>(),
    );
  });

  test('the usage lists every option but the internal ones', () {
    final usage = launchUsage();
    for (final option in LaunchOption.values) {
      expect(usage.contains(option.flag), !option.hidden, reason: option.flag);
    }
  });
}
