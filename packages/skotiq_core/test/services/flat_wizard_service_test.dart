import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/flat_wizard/flat_wizard_settings.dart';
import 'package:skotiq_core/src/services/flat_wizard_service.dart';

// The tuning constants in flat_wizard_service.dart are sourced from
// FlatWizardGlobalSettings, never hardcoded.

class _FakeBackend extends Mock implements SkotiqBackend {}

void main() {
  group('FlatWizardService.fromSettings', () {
    test('default settings reproduce the prior hardcoded values', () {
      final svc = FlatWizardService.fromSettings(
        _FakeBackend(),
        const FlatWizardGlobalSettings(),
      );
      expect(svc.imageDownloadTimeout, const Duration(seconds: 60));
      expect(svc.defaultMaxIterations, 8);
      expect(svc.quickMinExposure, 0.001);
      expect(svc.quickMaxExposure, 30.0);
    });

    test('overridden settings flow into the service fields', () {
      final svc = FlatWizardService.fromSettings(
        _FakeBackend(),
        const FlatWizardGlobalSettings(
          imageDownloadTimeoutSeconds: 180,
          maxIterations: 16,
          minExposure: 0.0005,
          maxExposure: 60.0,
        ),
      );
      expect(svc.imageDownloadTimeout, const Duration(seconds: 180));
      expect(svc.defaultMaxIterations, 16);
      expect(svc.quickMinExposure, 0.0005);
      expect(svc.quickMaxExposure, 60.0);
    });
  });
}
