// A sequence the app exported opens again on a rig whose filter names differ
// from the ones it uses, so the user can rename them in the editor; the
// sequence checks flag them instead. A broken file is reported in plain words.
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

/// The bundled "Mono LRGB M51" starter as the app exported it: it names its
/// luminance filter "Lum".
const _exportedStarter = 'test/fixtures/m51_starter_export.skseq.json';

class _OpenOnly extends FileSelectorPlatform {
  _OpenOnly(this.path);
  final String path;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => XFile(path);
}

/// A profile with a seven-position wheel named L, R, G, B, Ha, OIII, SII.
const _profile = EquipmentProfileModel(
  id: 1,
  name: 'My First Rig',
  isActive: true,
  filterNames: ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Sequence?> openThroughProvider(String path) async {
    final original = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = _OpenOnly(path);
    addTearDown(() => FileSelectorPlatform.instance = original);
    final container = ProviderContainer(
      overrides: [activeEquipmentProfileProvider.overrideWithValue(_profile)],
    );
    addTearDown(container.dispose);
    return container.read(sequenceFileServiceProvider).importSequence();
  }

  test('an exported sequence naming a filter the wheel lacks opens', () async {
    final sequence = await openThroughProvider(_exportedStarter);

    expect(sequence, isNotNull);
    expect(sequence!.name, 'Mono LRGB M51 (Whirlpool) - L then RGB');
    final filters = {
      for (final node in sequence.nodes.values)
        if (node is ExposureNode && node.filter != null) node.filter!,
    };
    expect(filters, contains('Lum'));
  });

  test('a truncated file is reported without exception type names', () async {
    final dir = await Directory.systemTemp.createTemp('seq_reopen');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/broken.skseq.json')
      ..writeAsStringSync('{\n');

    await expectLater(
      openThroughProvider(file.path),
      throwsA(
        isA<FormatException>()
            .having((e) => e.message, 'message', isNot(contains('Exception')))
            .having((e) => e.message, 'message', contains('not valid JSON'))
            .having((e) => e.message, 'message', contains('line 2')),
      ),
    );
  });
}
