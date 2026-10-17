import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/widgets/save_path_dialog.dart';

void main() {
  test('remote Flat Wizard uses the host directory picker', () async {
    var localCalls = 0;
    var remoteCalls = 0;

    final selected = await chooseFlatWizardSavePath(
      isRemote: true,
      pickLocal: () async {
        localCalls++;
        return '/controller/flats';
      },
      pickRemote: () async {
        remoteCalls++;
        return '/host/flats';
      },
    );

    expect(selected, '/host/flats');
    expect(localCalls, 0);
    expect(remoteCalls, 1);
  });

  test('local Flat Wizard preserves the native directory picker', () async {
    var localCalls = 0;
    var remoteCalls = 0;

    final selected = await chooseFlatWizardSavePath(
      isRemote: false,
      pickLocal: () async {
        localCalls++;
        return '/local/flats';
      },
      pickRemote: () async {
        remoteCalls++;
        return '/host/flats';
      },
    );

    expect(selected, '/local/flats');
    expect(localCalls, 1);
    expect(remoteCalls, 0);
  });
}
