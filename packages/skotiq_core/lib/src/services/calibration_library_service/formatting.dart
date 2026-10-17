part of '../calibration_library_service.dart';

bool _sameOptional(String? a, String? b) {
  final na = a?.trim();
  final nb = b?.trim();
  if ((na == null || na.isEmpty) && (nb == null || nb.isEmpty)) return true;
  return na == nb;
}

bool _sameExposure(double? a, double? b) {
  if (a == null || b == null) return a == b;
  return (a - b).abs() < 0.001;
}

String _fmtSecs(double secs) {
  final isWhole = secs == secs.roundToDouble();
  return isWhole ? '${secs.round()}s' : '${secs.toStringAsFixed(2)}s';
}

String _typeLabel(CalibrationMasterType type) {
  return switch (type) {
    CalibrationMasterType.dark => 'Master dark',
    CalibrationMasterType.bias => 'Master bias',
    CalibrationMasterType.flat => 'Master flat',
    CalibrationMasterType.defectMap => 'Defect map',
  };
}

Provenance? _provenanceFromTag(CalibrationTagEntry? tag) {
  final raw = tag?.provenanceJson;
  if (raw == null || raw.trim().isEmpty) return null;
  return Provenance.fromJsonString(raw);
}

ContributionLicense? _licenseFromTag(CalibrationTagEntry? tag) {
  final raw = tag?.license;
  if (raw == null || raw.trim().isEmpty) return null;
  return ContributionLicense.fromWire(raw);
}
