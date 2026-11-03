// reverify RV-06: a linked client's Catalogs page said downloading here
// "will not fix" target search, while its Go to resolves names only from
// this device's catalog.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/catalog_settings_screen.dart';

void main() {
  test('the note says name lookups here use this device\'s catalogs', () {
    final note = rigCatalogNote(missing: true);
    expect(note, isNot(contains('will not fix')));
    expect(note, contains('Name lookups on this device (Go to, search) use'));
  });
}
