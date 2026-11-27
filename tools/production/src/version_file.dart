/// `version.yaml`: the release this tree builds and its build number.
class VersionFile {
  const VersionFile({required this.version, required this.buildNumber});

  /// Reads `version: "9.3.5"` (quotes optional) and `build_number: 46`; a
  /// field that is missing or malformed is null.
  factory VersionFile.parse(String text) {
    final version = RegExp(
      r'''^version:\s*"?([^"#\s]+)"?''',
      multiLine: true,
    ).firstMatch(text)?.group(1);
    final build = RegExp(
      r'^build_number:\s*(\d+)',
      multiLine: true,
    ).firstMatch(text)?.group(1);
    return VersionFile(
      version: version,
      buildNumber: build == null ? null : int.tryParse(build),
    );
  }

  final String? version;
  final int? buildNumber;
}
