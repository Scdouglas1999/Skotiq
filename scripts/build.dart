// The one build recipe for the native libraries and the desktop app.
//
// Every other script, melos target and workflow that builds Skotiq calls this
// so the cargo and flutter invocations are written once.
//
//   dart scripts/build.dart bridge  [--target <triple>] [--unlocked]
//   dart scripts/build.dart updater [--target <triple>] [--unlocked]
//   dart scripts/build.dart flutter <linux|windows|macos> [--debug] [-- <flutter args>]
//   dart scripts/build.dart desktop <linux|windows|macos> [--debug] [--unlocked] [-- <flutter args>]
//
// `desktop` is `bridge` followed by `flutter`. The Rust side is always a
// release build: the Flutter runner bundles target/release whatever its own
// mode is. `--unlocked` drops cargo's `--locked` for the one case that needs
// it, a build that is meant to rewrite Cargo.lock.
//
// Uses dart:io only, so it runs before `melos bootstrap`.
import 'dart:io';

const _nativeWorkspace = 'native/skotiq_native';
const _desktopApp = 'apps/desktop';
const _flutterPlatforms = {'linux', 'windows', 'macos'};

Future<void> main(List<String> args) async {
  final split = args.indexOf('--');
  final own = split < 0 ? args : args.sublist(0, split);
  final passthrough = split < 0 ? const <String>[] : args.sublist(split + 1);
  if (own.isEmpty) _usage();

  final command = own.first;
  String? target;
  String? platform;
  var debug = false;
  var locked = true;
  for (var i = 1; i < own.length; i++) {
    final arg = own[i];
    if (arg == '--target' && i + 1 < own.length) {
      target = own[++i];
    } else if (arg == '--debug') {
      debug = true;
    } else if (arg == '--unlocked') {
      locked = false;
    } else if (_flutterPlatforms.contains(arg) && platform == null) {
      platform = arg;
    } else {
      _usage('unknown argument: $arg');
    }
  }

  final root = File.fromUri(Platform.script).parent.parent.path;
  switch (command) {
    case 'bridge':
      await _cargo(root, 'skotiq_bridge', target: target, locked: locked);
    case 'updater':
      await _cargo(root, 'skotiq_updater', target: target, locked: locked);
    case 'flutter':
      await _flutter(
        root,
        platform ?? _usage('flutter needs a platform'),
        debug: debug,
        extra: passthrough,
      );
    case 'desktop':
      final os = platform ?? _usage('desktop needs a platform');
      await _cargo(root, 'skotiq_bridge', target: target, locked: locked);
      await _flutter(root, os, debug: debug, extra: passthrough);
    default:
      _usage('unknown command: $command');
  }
}

Future<void> _cargo(
  String root,
  String package, {
  required String? target,
  required bool locked,
}) => _run('cargo', [
  'build',
  if (locked) '--locked',
  '--release',
  '--package',
  package,
  if (target != null) ...['--target', target],
], workingDirectory: '$root/$_nativeWorkspace');

Future<void> _flutter(
  String root,
  String platform, {
  required bool debug,
  required List<String> extra,
}) => _run('flutter', [
  'build',
  platform,
  debug ? '--debug' : '--release',
  ...extra,
], workingDirectory: '$root/$_desktopApp');

Future<void> _run(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  stdout.writeln('==> $executable ${arguments.join(' ')}  ($workingDirectory)');
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
    // flutter is a .bat on Windows, which only a shell can start.
    runInShell: Platform.isWindows,
  );
  final code = await process.exitCode;
  if (code != 0) {
    stderr.writeln('build.dart: $executable exited with $code');
    exit(code);
  }
}

Never _usage([String? problem]) {
  if (problem != null) stderr.writeln('build.dart: $problem');
  stderr.writeln('''
usage: dart scripts/build.dart <command> [options] [-- <flutter args>]
  bridge   build the Rust bridge library (release)
  updater  build the Rust updater binary (release)
  flutter  <linux|windows|macos>  build the desktop app only
  desktop  <linux|windows|macos>  bridge, then flutter
options: --target <triple>  --debug (flutter only)  --unlocked''');
  exit(64);
}
