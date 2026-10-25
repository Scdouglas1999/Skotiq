import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A native stand-in that records requests and writes the files a real build
/// would.
class FakeDarkroomNative {
  FakeDarkroomNative(this.lights);
  final Map<String, String> lights;
  final requests = <Map<String, dynamic>>[];
  final built = <String>[];
  final failFilters = <String>{};
  final cancelFilters = <String>{};
  double retained = .9;
  List<Map<String, dynamic>> limiting = const [];

  /// When set, every build waits for it, so a test can act mid-build.
  Completer<void>? buildGate;

  /// Completed when a build has started.
  Completer<void> buildStarted = Completer<void>();

  Future<Map<String, dynamic>> call(Map<String, dynamic> args) async {
    requests.add(jsonDecode(jsonEncode(args)) as Map<String, dynamic>);
    switch (args['op']) {
      case 'checkCalibration':
        return {};
      case 'registrationPreview':
        final frames = [
          for (final g in args['groups'] as List)
            for (final l in g['lights'] as List)
              {
                'path': l['path'],
                'group': g['label'],
                'side': l['side'],
                'corners': [
                  [2, 2],
                  [97, 2],
                  [97, 77],
                  [2, 77],
                ],
                'overlap': 1.0,
                'included': true,
              },
        ];
        return {
          'width': 100,
          'height': 80,
          'frames': frames,
          'crop': [2, 2, 97, 77],
          'retainedArea': retained,
          'minRetainedArea': args['minRetainedArea'],
          'meetsMinimum': retained >= (args['minRetainedArea'] as num),
          'limiting': limiting,
        };
      case 'build':
        final f = args['filter'] as String;
        built.add(f);
        if (!buildStarted.isCompleted) buildStarted.complete();
        if (buildGate != null) await buildGate!.future;
        if (cancelFilters.remove(f)) {
          throw '{"kind":"cancelled","runId":"x","stage":"registering"}';
        }
        if (failFilters.contains(f)) {
          throw StateError('none of the subs could be folded');
        }
        for (final key in [
          'masterFitsPath',
          'coverageFitsPath',
          'previewPngPath',
        ]) {
          await File(args[key] as String).writeAsString('artifact');
        }
        return {
          'filter': f,
          'masterPath': args['masterFitsPath'],
          'coveragePath': args['coverageFitsPath'],
          'frameCount': 1,
          'totalIntegrationSec': 90.0,
          'folded': [
            for (final g in args['groups'] as List)
              for (final l in g['lights'] as List) {'path': l['path']},
          ],
          'skipped': [],
        };
      case 'deliverUniform':
        await Directory(args['outputDir'] as String).create();
        final files = <Map<String, dynamic>>[];
        for (final m in args['masters'] as List) {
          final file = File('${args['outputDir']}/${m['filter']}.fits');
          await file.writeAsString('linear');
          files.add({
            'path': file.path,
            'previewPath': '${file.path}.png',
            'channels': 1,
          });
        }
        // The native export writes the RGB composite when R, G and B are all
        // built, and the LRGB one when L is too. Each master's filter arrives
        // as a file-safe key, `<filter>-<hash>`.
        final filters = {
          for (final m in args['masters'] as List)
            '${m['filter']}'.split('-').first,
        };
        Map<String, dynamic>? composites;
        if (filters.containsAll(['R', 'G', 'B'])) {
          composites = {};
          for (final kind in ['RGB', if (filters.contains('L')) 'LRGB']) {
            final stem = '${args['outputDir']}/${kind}_linear';
            await File('$stem.fits').writeAsString('linear rgb');
            final key = kind.toLowerCase();
            composites['${key}Path'] = '$stem.fits';
            composites['${key}XisfPath'] = '$stem.xisf';
            composites['${key}PreviewPath'] = '$stem.png';
          }
        }
        return {
          'masters': files,
          'width': 95,
          'height': 75,
          'crop': [2, 2, 97, 77],
          'retainedArea': retained,
          'composites': composites,
        };
    }
    throw StateError('unexpected op ${args['op']}');
  }
}
