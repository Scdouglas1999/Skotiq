import 'dart:convert';
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as path;

/// Test double that wires the file picker to deterministic in-test paths.
///
/// Pattern lifted from `sequence_file_service_test.dart` so both file
/// services share the same exercise harness — if the platform interface
/// shape changes, both tests fail together.
class TestSnippetFileSelectorPlatform extends FileSelectorPlatform {
  TestSnippetFileSelectorPlatform({
    required this.openPath,
    required this.savePath,
  });

  final String openPath;
  final String savePath;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    return XFile(openPath);
  }

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    return FileSaveLocation(savePath);
  }
}

TemplateSnippet _makeSnippet({
  String name = 'Test Snippet',
  String description = 'Round-trip fixture',
}) {
  return TemplateSnippet(
    id: 'src-id-${DateTime.now().microsecondsSinceEpoch}',
    name: name,
    description: description,
    category: SnippetCategory.custom,
    iconName: 'puzzle',
    nodeData: const [
      {
        'nodeType': 'InstructionSet',
        'name': 'Outer',
        'isEnabled': true,
        'children': [
          {
            'nodeType': 'Autofocus',
            'name': 'Autofocus',
            'isEnabled': true,
            'method': 'vCurve',
            'stepSize': 100,
            'stepsOut': 7,
            'exposuresPerPoint': 1,
            'exposureDuration': 3.0,
          },
          {
            'nodeType': 'Dither',
            'name': 'Dither',
            'isEnabled': true,
            'pixels': 5.0,
            'settleTime': 30.0,
            'settlePixels': 1.5,
          },
        ],
      },
    ],
    isBuiltIn: false,
    createdAt: DateTime.utc(2025, 1, 2, 3, 4, 5),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SnippetFileService', () {
    test('export then import preserves snippet contents', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'snippet_file_service_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));

      final filePath = path.join(tempDir.path, 'fixture.sknippet.json');
      final originalPlatform = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = TestSnippetFileSelectorPlatform(
        openPath: filePath,
        savePath: filePath,
      );
      addTearDown(() => FileSelectorPlatform.instance = originalPlatform);

      final original = _makeSnippet();
      final service = SnippetFileService();

      final savedTo = await service.exportSnippet(original);
      expect(savedTo, filePath);
      expect(File(filePath).existsSync(), isTrue);

      final imported = await service.importSnippet();
      expect(imported, isNotNull);

      // Fresh id on import — the in-memory ID changes, but every
      // user-meaningful field round-trips identically.
      expect(imported!.id, isNot(original.id));
      expect(imported.name, original.name);
      expect(imported.description, original.description);
      expect(imported.category, original.category);
      expect(imported.iconName, original.iconName);
      expect(imported.isBuiltIn, isFalse);
      expect(imported.createdAt.toUtc(), original.createdAt.toUtc());
      expect(imported.nodeData, original.nodeData);
    });

    test('encodeSnippet produces a stable checksum across encodes', () {
      final service = SnippetFileService();
      final snippet = _makeSnippet();

      final first = service.encodeSnippet(snippet);
      final second = service.encodeSnippet(snippet);

      expect(
        first,
        second,
        reason:
            'Encoding the same snippet twice must be byte-identical '
            'so checksums are reproducible across machines.',
      );

      final decoded = jsonDecode(first) as Map<String, dynamic>;
      expect(decoded['kind'], 'skotiq.snippet');
      expect(decoded['schemaVersion'], snippetFileCurrentSchemaVersion);
      expect(decoded['checksum'], isA<String>());
      expect(
        (decoded['checksum'] as String).length,
        64,
        reason: 'SHA-256 hex digest is 64 chars.',
      );
    });

    test('parseEncoded rejects checksum mismatch with a clear issue', () {
      final service = SnippetFileService();
      final snippet = _makeSnippet();

      // Take a valid envelope and tamper with the body. The on-disk
      // checksum no longer matches the recomputed digest.
      final encoded = service.encodeSnippet(snippet);
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      decoded['name'] = 'Hacked Name';
      final tampered = jsonEncode(decoded);

      expect(
        () => service.parseEncoded(tampered),
        throwsA(
          isA<SnippetImportException>().having(
            (e) => e.issues.any(
              (i) => i.field == 'checksum' && i.message.contains('mismatch'),
            ),
            'lists checksum mismatch',
            isTrue,
          ),
        ),
      );
    });

    test('parseEncoded surfaces every schema problem at once', () {
      final service = SnippetFileService();

      // Deliberately malformed: wrong kind, missing required strings, bad
      // nodeData entry. The importer must list ALL issues so the user can fix
      // the file in one pass.
      final bad = jsonEncode({
        'schemaVersion': 1,
        'kind': 'something.else',
        // name missing
        'description': 42, // wrong type
        'iconName': '',
        'category': 'custom',
        'createdAt': DateTime.utc(2025, 1, 1).toIso8601String(),
        'nodeData': [
          {'nodeType': ''},
          'not-an-object',
        ],
        'checksum': 'deadbeef',
      });

      try {
        service.parseEncoded(bad);
        fail('Expected SnippetImportException');
      } on SnippetImportException catch (e) {
        final fields = e.issues.map((i) => i.field).toSet();
        // Wrong kind
        expect(fields, contains('kind'));
        // Missing name
        expect(fields, contains('name'));
        // Wrong-type description
        expect(fields, contains('description'));
        // Empty iconName
        expect(fields, contains('iconName'));
        // Bad node entries
        expect(fields.any((f) => f.startsWith('nodeData[')), isTrue);
        // Checksum mismatch (since kind/name/etc changed)
        expect(fields, contains('checksum'));
      }
    });

    test('parseEncoded raises a version mismatch for newer files', () {
      final service = SnippetFileService();
      final future = jsonEncode({
        'schemaVersion': snippetFileCurrentSchemaVersion + 99,
        'kind': 'skotiq.snippet',
        'name': 'From the future',
        'description': '',
        'category': 'custom',
        'iconName': 'puzzle',
        'createdAt': DateTime.utc(2030, 1, 1).toIso8601String(),
        'nodeData': [
          {'nodeType': 'Delay', 'seconds': 1.0},
        ],
        'checksum': 'unused',
      });

      expect(
        () => service.parseEncoded(future),
        throwsA(
          isA<SnippetVersionMismatchException>().having(
            (e) => e.fileVersion,
            'fileVersion',
            snippetFileCurrentSchemaVersion + 99,
          ),
        ),
      );
    });

    test('suggestedFilename strips unsafe characters', () {
      final service = SnippetFileService();
      final snippet = _makeSnippet(name: 'My / Weird: Name?');
      final filename = service.suggestedFilename(snippet);
      expect(filename, endsWith('.sknippet.json'));
      expect(filename, isNot(contains('/')));
      expect(filename, isNot(contains(':')));
      expect(filename, isNot(contains('?')));
    });
  });
}
