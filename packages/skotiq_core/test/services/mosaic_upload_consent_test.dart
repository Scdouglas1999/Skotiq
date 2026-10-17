import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/models/collaboration/collaboration_models.dart';
import 'package:skotiq_core/src/services/mosaic/mosaic_upload_consent.dart';

class _MockSettingsDao extends Mock implements SettingsDao {}

void main() {
  test('upload consent is persisted as one complete decision', () async {
    final settings = _MockSettingsDao();
    when(() => settings.setSettings(any())).thenAnswer((_) async {});

    await persistMosaicUploadConsent(
      settings,
      const MosaicUploadConsent(
        license: ContributionLicense.ccBy,
        attributionConsent: false,
        autoUpload: true,
      ),
    );

    expect(verify(() => settings.setSettings(captureAny())).captured.single, {
      mosaicUploadConsentedSettingKey: '1',
      mosaicUploadLicenseSettingKey: 'cc-by',
      mosaicUploadAttributionSettingKey: '0',
      mosaicUploadAutoSettingKey: '1',
    });
    verifyNever(() => settings.setSetting(any(), any()));
  });
}
