// A control that gates a HOST-ONLY surface must ask the client ROLE, never the
// connection.
//
// The Darkroom and Session Review both read files that exist only on the
// imaging host — linear masters, full-resolution subs, their previews — so
// whether this machine may open them is a fact about what this process IS, and
// `isRemoteClientProvider` is what answers it. `backend.remoteHost != null`
// (and the `backend is NetworkBackend` it replaced) answers a different
// question: whether a remote connection is open RIGHT NOW. The two disagree for
// the whole of a client's life before its first handshake and again after
// every drop, and during exactly that window the connection says "not remote"
// about a machine that owns none of the host's rows.
//
// That confusion has now been fixed five separate times — the Darkroom screen,
// the Session Review screen, the master library card, the stack-result action,
// the session-detail dialog — and each fix left the class alive one file over.
// This is the guard, so there is no sixth: any file under `lib/screens/` that
// reaches one of the two host-only surfaces is scanned, and a connection test
// whose ANSWER is the value it produces fails the test.
//
// What is NOT an offence: taking the linked host in order to CALL it —
// `if (backend.remoteHost case final linkedHost?) { linkedHost.files... }`,
// `backend.remoteHost?.science.export(...)`, or a test in the condition of an
// `if`. That is a capability question with one honest answer — you cannot call
// a rig you are not connected to. Only binding the test into a value ("am I
// remote?") is the wrong question, and that is the shape this scans for.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The directory tree the rule covers, relative to the package root.
const String _screensRoot = 'lib/screens';

/// What makes a file a gate on a host-only surface.
///
/// A file that names one of these reaches the Darkroom or Session Review, so
/// its remote-ness decision is about who owns the pixels. Everything else under
/// `lib/screens` decides other things — whether a directory picker browses the
/// rig's filesystem, whether a settings page has a client to call — and this
/// guard does not speak to those.
const _hostOnlyEntryPoints = <String>[
  '/session-review',
  '/darkroom',
  'AppRoute.sessionReview',
  'AppRoutes.sessionReviewOf',
  'AppRoute.darkroom',
  'AppRoutes.darkroom',
  'darkroomTabLocation',
  'darkroomPassLocation',
  'darkroomTargetLocation',
  'darkroomFramingLocation',
  'darkroomEditLocation',
  'openDarkroomForMaster',
  'openDarkroomForMasterRow',
  'openDarkroomForSession',
  'resolveDarkroomTargetForSession',
  'darkroomSessionTargetProvider',
  'watchDarkroomSessionRefusal',
  'kDarkroomHostOnlyRefusal',
  'darkroomHostOnlyRefusal',
];

/// Files inside the covered set that are allowed to bind a connection test to
/// a value, each with the reason it is not the role question.
///
/// An entry here is a claim that some file answers "is a host linked right
/// now?" from the connection ON PURPOSE, about something other than opening a
/// host-only surface, and that claim has to be written down beside the path.
const _allowed = <String, String>{
  'lib/screens/stack_result/stack_result_screen.dart':
      'decides whether to stamp a stack result into the local database, which '
          'only exists to stamp when the database is this machine\'s',
};

void main() {
  test('no host-only gate decides remote-ness from the backend type', () {
    final root = Directory(_screensRoot);
    expect(
      root.existsSync(),
      isTrue,
      reason: '$_screensRoot is missing — run from the skotiq_app '
          'package root',
    );

    final offenders = <String>[];
    final excused = <String>{};
    var covered = 0;
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      // Membership is read from the RAW source, because older links name the
      // two routes in string literals — `'/session-review?session=$id'` — and
      // the blanking that keeps a comment from being read as code would erase
      // exactly the thing that makes the file a host-only gate. Over-including
      // a file that only MENTIONS the Darkroom costs nothing: the offence scan
      // below still runs on blanked code, so prose cannot fail this test.
      if (!_hostOnlyEntryPoints.any(source.contains)) continue;
      final code = codeOnly(source);
      covered++;
      final isExcused = _allowed.containsKey(entity.path);
      for (final line in backendTypeAnswers(code)) {
        if (isExcused) {
          excused.add(entity.path);
          continue;
        }
        offenders.add('${entity.path}:$line');
      }
    }

    expect(
      _allowed.keys.toSet().difference(excused),
      isEmpty,
      reason: 'these paths are excused from a rule they no longer break — an '
          'allowance nobody needs is an allowance nobody rereads, so it comes '
          'out with the code that earned it',
    );
    expect(
      covered,
      greaterThan(0),
      reason: 'the scan matched no host-only surface at all, so it is not '
          'testing the rule it claims to — check _hostOnlyEntryPoints against '
          'the current entry points',
    );
    expect(
      offenders,
      isEmpty,
      reason: 'these gates on a host-only surface answer "am I remote?" from '
          'the CONNECTION, which reads false for a client that has not '
          'reached its rig. Ask isRemoteClientProvider (or '
          'watchDarkroomHostOnlyRefusal) instead:\n${offenders.join('\n')}',
    );
  });

  group('the scanner', () {
    test('flags a connection test bound into a value', () {
      const source = '''
final isRemote = ref.watch(backendProvider).remoteHost != null;
final label = backend.remoteHost != null ? 'remote' : 'local';
_announce(remote: backend.remoteHost != null);
return backend.remoteHost != null;
final isLocal = backend.remoteHost == null;
final wrapped =
    ref.read(backendProvider).remoteHost != null;
''';
      expect(backendTypeAnswers(codeOnly(source)), [1, 2, 3, 4, 5, 7]);
    });

    test('still flags the type test the connection test replaced', () {
      const source = '''
final isRemote = ref.watch(backendProvider) is NetworkBackend;
final isLocal = backend is! NetworkBackend;
return backend is NetworkBackend;
''';
      expect(backendTypeAnswers(codeOnly(source)), [1, 2, 3]);
    });

    test('allows taking the linked host in order to call it', () {
      const source = '''
if (backend.remoteHost case final linkedHost?) {
  await linkedHost.files.downloadSessionExport(id, 'csv');
}
final linkedHost = backend.remoteHost;
if (linkedHost == null) return;
final rows = await backend.remoteHost?.imagingRecords.getAllSessions();
if (backend.remoteHost != null) {
  ref.invalidate(remoteRowsProvider);
}
''';
      expect(backendTypeAnswers(codeOnly(source)), isEmpty);
    });

    test('does not read a comment or a string as code', () {
      const source = '''
// final isRemote = backend.remoteHost != null; in prose is not code.
final note = 'x = backend.remoteHost != null';
''';
      expect(backendTypeAnswers(codeOnly(source)), isEmpty);
    });
  });
}

/// The 1-based lines of [code] where the ANSWER to "is a remote host linked?"
/// is the value the line produces: `x.remoteHost != null`, `x.remoteHost ==
/// null`, or the `is NetworkBackend` type test those replaced.
///
/// A test is read as TAKING THE HOST when it sits in the condition of an `if`
/// or a `while` — every legitimate use in these files does that in order to
/// call the rig (the `case final linkedHost?` and `?.` forms contain no test
/// at all and are never matched). It is read as a BINDING when what leads up
/// to it assigns, names an argument, or returns: there the answer itself is the
/// value, and the value means "am I remote?".
///
/// The lead-up is what stands before the tested expression on its line, and
/// the previous non-blank line when the expression opens its own line — a
/// binding that wrapped across two lines is the same binding.
List<int> backendTypeAnswers(String code) {
  final hits = <int>[];
  final lines = code.split('\n');
  final binds = RegExp(r'(?<![=!<>])=(?!=)|:\s*$|:\s|\breturn\b|=>');
  final test = RegExp(
    r'\.remoteHost\s*[!=]=\s*null|\bis!? NetworkBackend\b',
  );
  // The expression the test is applied to: `backend`, `ref.read(provider)`.
  final receiver = RegExp(
    r'(?:[A-Za-z_]\w*(?:\([^()]*\))?\.)*[A-Za-z_]\w*(?:\([^()]*\))?\s*$',
  );
  for (var i = 0; i < lines.length; i++) {
    final match = test.firstMatch(lines[i]);
    if (match == null) continue;
    var before =
        lines[i].substring(0, match.start).replaceFirst(receiver, '');
    if (RegExp(r'\b(if|while)\s*\(').hasMatch(before)) continue;
    if (before.trim().isEmpty) {
      for (var j = i - 1; j >= 0; j--) {
        if (lines[j].trim().isEmpty) continue;
        before = lines[j];
        if (RegExp(r'\b(if|while)\s*\($').hasMatch(before.trimRight())) {
          before = '';
        }
        break;
      }
    }
    if (binds.hasMatch(before)) hits.add(i + 1);
  }
  return hits;
}

/// [source] with every comment and string literal replaced by spaces.
///
/// Offsets and line breaks are preserved, so a hit still reports the line it is
/// on and a sentence about the rule cannot be read as the rule being broken.
String codeOnly(String source) {
  final out = List<String>.generate(source.length, (i) => source[i]);
  var i = 0;
  while (i < source.length) {
    final char = source[i];
    if (char == '/' && i + 1 < source.length) {
      final next = source[i + 1];
      if (next == '/') {
        while (i < source.length && source[i] != '\n') {
          out[i] = ' ';
          i++;
        }
        continue;
      }
      if (next == '*') {
        var depth = 0;
        while (i < source.length) {
          if (source.startsWith('/*', i)) {
            depth++;
            out[i] = out[i + 1] = ' ';
            i += 2;
            continue;
          }
          if (source.startsWith('*/', i)) {
            depth--;
            out[i] = out[i + 1] = ' ';
            i += 2;
            if (depth == 0) break;
            continue;
          }
          if (source[i] != '\n') out[i] = ' ';
          i++;
        }
        continue;
      }
    }
    if (char == "'" || char == '"') {
      final triple = source.startsWith(char * 3, i);
      final closer = triple ? char * 3 : char;
      out[i] = ' ';
      if (triple) out[i + 1] = out[i + 2] = ' ';
      i += closer.length;
      while (i < source.length) {
        if (source[i] == r'\') {
          out[i] = ' ';
          if (i + 1 < source.length) out[i + 1] = ' ';
          i += 2;
          continue;
        }
        if (source.startsWith(closer, i)) {
          for (var k = 0; k < closer.length; k++) {
            out[i + k] = ' ';
          }
          i += closer.length;
          break;
        }
        if (source[i] != '\n') out[i] = ' ';
        i++;
      }
      continue;
    }
    i++;
  }
  return out.join();
}
