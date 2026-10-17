import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../utils/user_facing_error.dart';
import 'settings_widgets.dart';

String? _validatePositiveScienceId(String value) {
  if (value.isEmpty) return null;
  final parsed = int.tryParse(value);
  if (parsed == null || parsed <= 0) {
    return 'Enter a positive whole-number ID';
  }
  return null;
}

String? _validateAavsoObserverCode(String value) {
  if (value.isEmpty) return null;
  if (value.length > 5) return 'AAVSO codes must be 1-5 characters';
  return null;
}

String? _validateMpcObservatoryCode(String value) {
  if (value.isEmpty) return null;
  if (!RegExp(r'^[A-Z0-9]{3}$').hasMatch(value)) {
    return 'MPC codes must be exactly 3 letters or digits';
  }
  return null;
}

/// Raised by a science row when the operator's text fails that row's own
/// validation.
///
/// It has to be thrown rather than merely reported: [SettingsTextInput] treats
/// a callback that returns normally as an accepted write and would then show
/// the rejected text as if it were stored.
class _ScienceValueRejected implements Exception {
  final String message;
  const _ScienceValueRejected(this.message);

  @override
  String toString() => 'Science setting rejected: $message';
}

/// Authority key for a science row's [SettingsTextInput].
///
/// The backend identity on its own is not enough here: these rows normalise
/// what the operator typed (trim, upper-case, clamp to range), and when the
/// normalised value equals what was already stored the input has no change to
/// react to and would keep showing the raw text — "100000" over a stored
/// "65535". Folding a per-commit counter in makes every accepted write
/// re-assert the stored value. `identical` on two equal ints is true, which is
/// what [SettingsTextInput] compares.
Object _rowAuthority(Object? backend, int commits) =>
    Object.hash(identityHashCode(backend), commits);

class ScienceSettingsPage extends ConsumerWidget {
  final bool isMobile;

  const ScienceSettingsPage({super.key, this.isMobile = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scienceAsync = ref.watch(scienceSettingsProvider);
    final scienceNotifier = ref.read(scienceSettingsProvider.notifier);

    return scienceAsync.when(
      loading: () => SettingsLoadingState(
        isMobile: isMobile,
        message: 'Loading science settings...',
      ),
      error: (error, stack) => SettingsErrorState(
        isMobile: isMobile,
        error: error,
        onRetry: () => ref.invalidate(scienceSettingsProvider),
      ),
      data: (science) {
        return SettingsPage(
          title: 'Science',
          description:
              'Advanced, informational-only scientific analysis. No frames are auto-deleted.',
          isMobile: isMobile,
          hideHeader: isMobile,
          children: [
            SettingsSection(
              title: 'Mode',
              isMobile: isMobile,
              children: [
                SettingRow(
                  icon: LucideIcons.flaskConical,
                  title: 'Show advanced overlay controls',
                  subtitle:
                      'Adds PSF, residual, and tile-map layers to the Imaging overlays menu.',
                  trailing: SettingsSwitch(
                    value: science.advancedModeEnabled,
                    onChanged: (value) =>
                        scienceNotifier.setAdvancedModeEnabled(value),
                  ),
                  isMobile: isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.layers,
                  title: 'Science overlays',
                  subtitle:
                      'Enable overlays such as PSF map, residual vectors, and tracks',
                  trailing: SettingsSwitch(
                    value: science.overlayEnabled,
                    onChanged: (value) =>
                        scienceNotifier.setOverlayEnabled(value),
                  ),
                  isLast: true,
                  isMobile: isMobile,
                ),
              ],
            ),
            SettingsSection(
              title: 'Features',
              isMobile: isMobile,
              children: [
                SettingRow(
                  icon: LucideIcons.activity,
                  title: 'Live differential photometry',
                  subtitle: 'Target/comparison tracking and live light curves',
                  trailing: SettingsSwitch(
                    value: science.photometryEnabled,
                    onChanged: (value) => scienceNotifier.setFeatureEnabled(
                      ScienceFeature.photometry,
                      value,
                    ),
                  ),
                  isMobile: isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.gauge,
                  title: 'Per-frame photometric calibration',
                  subtitle: 'Compute zeropoint and limiting magnitude',
                  trailing: SettingsSwitch(
                    value: science.photometricCalibrationEnabled,
                    onChanged: (value) => scienceNotifier.setFeatureEnabled(
                      ScienceFeature.photometricCalibration,
                      value,
                    ),
                  ),
                  isMobile: isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.cloud,
                  title: 'Transparency and extinction',
                  subtitle: 'Track atmospheric transparency over time',
                  trailing: SettingsSwitch(
                    value: science.transparencyEnabled,
                    onChanged: (value) => scienceNotifier.setFeatureEnabled(
                      ScienceFeature.transparency,
                      value,
                    ),
                  ),
                  isMobile: isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.layoutGrid,
                  title: 'PSF field map',
                  subtitle: 'Analyze field-wide seeing and tilt patterns',
                  trailing: SettingsSwitch(
                    value: science.psfMapEnabled,
                    onChanged: (value) => scienceNotifier.setFeatureEnabled(
                      ScienceFeature.psfMap,
                      value,
                    ),
                  ),
                  isMobile: isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.map,
                  title: 'Astrometric residuals',
                  subtitle: 'Build residual heatmaps and mount feedback',
                  trailing: SettingsSwitch(
                    value: science.astrometricResidualsEnabled,
                    onChanged: (value) => scienceNotifier.setFeatureEnabled(
                      ScienceFeature.astrometricResiduals,
                      value,
                    ),
                  ),
                  isMobile: isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.rocket,
                  title: 'Moving object mode',
                  subtitle: 'Detect and track moving candidates',
                  trailing: SettingsSwitch(
                    value: science.movingObjectsEnabled,
                    onChanged: (value) => scienceNotifier.setFeatureEnabled(
                      ScienceFeature.movingObjects,
                      value,
                    ),
                  ),
                  isMobile: isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.slidersHorizontal,
                  title: 'Narrowband line ratios',
                  subtitle: 'Generate SII/Ha, OIII/Ha, and SII/OIII products',
                  trailing: SettingsSwitch(
                    value: science.narrowbandRatiosEnabled,
                    onChanged: (value) => scienceNotifier.setFeatureEnabled(
                      ScienceFeature.narrowbandRatios,
                      value,
                    ),
                  ),
                  isMobile: isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.layoutTemplate,
                  title: 'Frame quality maps',
                  subtitle:
                      'Compute clipping, uniformity, background and SNR tile maps',
                  trailing: SettingsSwitch(
                    value: science.frameQualityMapsEnabled,
                    onChanged: (value) => scienceNotifier.setFeatureEnabled(
                      ScienceFeature.frameQualityMaps,
                      value,
                    ),
                  ),
                  isMobile: isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.boxSelect,
                  title: '3D science surfaces',
                  subtitle:
                      'Enable surface explorer and interactive mesh rendering',
                  trailing: SettingsSwitch(
                    value: science.surface3dEnabled,
                    onChanged: (value) => scienceNotifier.setFeatureEnabled(
                      ScienceFeature.surface3d,
                      value,
                    ),
                  ),
                  isMobile: isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.sliders,
                  title: 'Auto-reject bad frames',
                  subtitle:
                      'After each light frame, reject captures that exceed '
                      'the thresholds set in Analytics → Science → Grade frames. '
                      'Files are never deleted — only excluded from stacks.',
                  trailing: SettingsSwitch(
                    value: science.autoFrameGradingEnabled,
                    onChanged: scienceNotifier.setAutoFrameGradingEnabled,
                  ),
                  isMobile: isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.fileText,
                  title: 'Write science keywords to FITS',
                  subtitle:
                      'Stamp MAGZP / MAGZPERR / TRANSPAR back into the FITS '
                      'header so PixInsight, AstroPixelProcessor, and Siril '
                      'can read Skotiq\'s photometric measurements '
                      'directly from the captured frame.',
                  trailing: SettingsSwitch(
                    value: science.fitsHeaderWritebackEnabled,
                    onChanged: scienceNotifier.setFitsHeaderWritebackEnabled,
                  ),
                  isLast: true,
                  isMobile: isMobile,
                ),
              ],
            ),
            SettingsSection(
              title: 'Photometric catalog',
              isMobile: isMobile,
              children: [
                _ScienceOnlineCatalogRow(isMobile: isMobile),
              ],
            ),
            SettingsSection(
              title: 'AAVSO',
              isMobile: isMobile,
              children: [
                _ScienceTextRow(
                  isMobile: isMobile,
                  icon: LucideIcons.userCheck,
                  title: 'AAVSO observer code',
                  subtitle: 'Your assigned AAVSO observer initials (1-5 chars, '
                      'e.g., "XYZ")',
                  hint: 'e.g. XYZ',
                  width: 100,
                  uppercase: true,
                  maxLength: 5,
                  validate: _validateAavsoObserverCode,
                  value: science.aavsoObserverCode,
                  onCommit: scienceNotifier.setAavsoObserverCode,
                  isLast: true,
                ),
              ],
            ),
            SettingsSection(
              title: 'Minor Planet Center (MPC)',
              isMobile: isMobile,
              children: [
                _ScienceTextRow(
                  isMobile: isMobile,
                  icon: LucideIcons.star,
                  title: 'MPC observatory code',
                  subtitle: 'Your 3-character MPC observatory code (e.g., '
                      '"G40"). Required for MPC report export.',
                  hint: 'e.g. G40',
                  width: 80,
                  uppercase: true,
                  maxLength: 3,
                  validate: _validateMpcObservatoryCode,
                  value: science.mpcObservatoryCode,
                  onCommit: scienceNotifier.setMpcObservatoryCode,
                ),
                _ScienceTextRow(
                  isMobile: isMobile,
                  icon: LucideIcons.bookOpen,
                  title: 'Astrometric catalog',
                  subtitle:
                      'Reference catalog your solver uses (ADES astCat, e.g. '
                      '"Gaia2"). Blank reports as UNK.',
                  hint: 'e.g. Gaia2',
                  width: 110,
                  value: science.mpcAstrometricCatalog,
                  onCommit: scienceNotifier.setMpcAstrometricCatalog,
                  isLast: true,
                ),
              ],
            ),
            SettingsSection(
              title: 'Observer identity',
              isMobile: isMobile,
              children: [
                _ScienceTextRow(
                  isMobile: isMobile,
                  icon: LucideIcons.user,
                  title: 'Observer name',
                  subtitle:
                      'Written into MPC ADES headers and the TNS reporter '
                      'field.',
                  hint: 'e.g. Jane Doe',
                  width: 160,
                  value: science.observerName,
                  onCommit: scienceNotifier.setObserverName,
                  isLast: true,
                ),
              ],
            ),
            SettingsSection(
              title: 'Transient Name Server (TNS)',
              isMobile: isMobile,
              children: [
                _ScienceTextRow(
                  isMobile: isMobile,
                  icon: LucideIcons.hash,
                  title: 'Bot id',
                  subtitle: 'Your TNS bot id (tns_marker tns_id).',
                  hint: 'e.g. 12345',
                  width: 100,
                  numeric: true,
                  validate: _validatePositiveScienceId,
                  value:
                      science.tnsBotId == 0 ? '' : science.tnsBotId.toString(),
                  onCommit: (v) => scienceNotifier.setTnsBotId(
                    int.tryParse(v) ?? 0,
                  ),
                ),
                _ScienceTextRow(
                  isMobile: isMobile,
                  icon: LucideIcons.bot,
                  title: 'Bot name',
                  subtitle: 'Your TNS bot name (tns_marker name).',
                  hint: 'e.g. SkotiqBot',
                  width: 160,
                  value: science.tnsBotName,
                  onCommit: scienceNotifier.setTnsBotName,
                ),
                _ScienceTextRow(
                  isMobile: isMobile,
                  icon: LucideIcons.users,
                  title: 'Reporting group id',
                  subtitle: 'Your TNS reporting_group_id.',
                  hint: 'e.g. 42',
                  width: 100,
                  numeric: true,
                  validate: _validatePositiveScienceId,
                  value: science.tnsReportingGroupId == 0
                      ? ''
                      : science.tnsReportingGroupId.toString(),
                  onCommit: (v) => scienceNotifier.setTnsReportingGroupId(
                    int.tryParse(v) ?? 0,
                  ),
                ),
                _ScienceTextRow(
                  isMobile: isMobile,
                  icon: LucideIcons.database,
                  title: 'Data source id',
                  subtitle: 'Your TNS discovery_data_source_id.',
                  hint: 'e.g. 7',
                  width: 100,
                  numeric: true,
                  validate: _validatePositiveScienceId,
                  value: science.tnsDataSourceId == 0
                      ? ''
                      : science.tnsDataSourceId.toString(),
                  onCommit: (v) => scienceNotifier.setTnsDataSourceId(
                    int.tryParse(v) ?? 0,
                  ),
                ),
                _ScienceTextRow(
                  isMobile: isMobile,
                  icon: LucideIcons.edit3,
                  title: 'Reporter name',
                  subtitle: 'Reporter shown on TNS (falls back to observer '
                      'name).',
                  hint: 'e.g. Jane Doe',
                  width: 160,
                  value: science.tnsReporterName,
                  onCommit: scienceNotifier.setTnsReporterName,
                ),
                const _TnsApiKeyRow(),
                _TnsSandboxRow(isMobile: isMobile),
              ],
            ),
            SettingsSection(
              title: 'Camera',
              isMobile: isMobile,
              children: [
                _ScienceCameraAutoRow(isMobile: isMobile),
                _ScienceCameraValueRow(
                  isMobile: isMobile,
                  settingKey: 'science.camera.read_noise_e',
                  icon: LucideIcons.zap,
                  title: 'Camera read noise (e⁻)',
                  subtitle:
                      'Used for limiting magnitude calculations (default 3.5)',
                  defaultText: '3.5',
                  min: 0.5,
                  max: 30.0,
                ),
                _ScienceCameraValueRow(
                  isMobile: isMobile,
                  settingKey: 'science.camera.gain_e_per_adu',
                  icon: LucideIcons.activity,
                  title: 'Camera gain (e⁻/ADU)',
                  subtitle: 'Converts sky background to electrons for limiting '
                      'magnitude (assumes 1.0 when unset)',
                  defaultText: '1.0',
                  min: 0.01,
                  max: 50.0,
                ),
                _ScienceCameraValueRow(
                  isMobile: isMobile,
                  settingKey: 'science.camera.saturation_adu',
                  icon: LucideIcons.sun,
                  title: 'Saturation level (ADU)',
                  subtitle: 'White level used to reject saturated stars from '
                      'photometry — 4095 for raw 12-bit, 16383 for 14-bit, '
                      '65535 for 16-bit output',
                  defaultText: '65535',
                  min: 255,
                  max: 65535,
                  integer: true,
                  isLast: true,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Single-line science-settings text row, rendered on the canonical
/// [SettingsTextInput].
///
/// The canonical input owns the parts every settings field needs and these
/// rows kept re-implementing badly: authoritative-value sync (so a value
/// written by another client or restored from a backup shows up here), an
/// authority key (so switching rigs discards a half-typed edit instead of
/// writing it to the new host), a serialised write tail, and a rollback that
/// puts the stored value back when a write is refused. This row adds only what
/// is science-specific — normalisation, per-field validation shown in the
/// subtitle, and the failure toast.
class _ScienceTextRow extends ConsumerStatefulWidget {
  final bool isMobile;
  final IconData icon;
  final String title;
  final String subtitle;
  final String hint;
  final double width;

  /// The stored value, watched by the caller. Blank renders the hint.
  final String value;

  final Future<void> Function(String) onCommit;

  /// Fold to upper case both as the operator types and before committing —
  /// the AAVSO and MPC codes are stored and reported upper-case.
  final bool uppercase;

  final int? maxLength;
  final bool numeric;
  final bool isLast;
  final String? Function(String value)? validate;

  const _ScienceTextRow({
    required this.isMobile,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.hint,
    required this.width,
    required this.value,
    required this.onCommit,
    this.uppercase = false,
    this.maxLength,
    this.numeric = false,
    this.isLast = false,
    this.validate,
  });

  @override
  ConsumerState<_ScienceTextRow> createState() => _ScienceTextRowState();
}

class _ScienceTextRowState extends ConsumerState<_ScienceTextRow> {
  final _controller = TextEditingController();
  late final List<TextInputFormatter>? _formatters = _buildFormatters();
  String? _rowError;
  int _commits = 0;

  List<TextInputFormatter>? _buildFormatters() {
    final formatters = <TextInputFormatter>[
      if (widget.maxLength != null)
        LengthLimitingTextInputFormatter(widget.maxLength),
      if (widget.uppercase)
        TextInputFormatter.withFunction(
          (_, value) => value.copyWith(text: value.text.toUpperCase()),
        ),
    ];
    return formatters.isEmpty ? null : formatters;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _commit(String raw) async {
    final value = widget.uppercase ? raw.trim().toUpperCase() : raw.trim();
    final rejection = widget.validate?.call(value);
    if (rejection != null) {
      setState(() => _rowError = rejection);
      throw _ScienceValueRejected(rejection);
    }
    if (_rowError != null) setState(() => _rowError = null);

    try {
      await widget.onCommit(value);
    } catch (error) {
      final message = 'Could not save ${widget.title.toLowerCase()}: '
          '${userFacingError(error)}';
      if (mounted) {
        setState(() => _rowError = message);
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(message)));
      }
      // Hands the failure back to SettingsTextInput, which restores the stored
      // value. Swallowing it here would leave unsaved text on screen looking
      // saved.
      rethrow;
    }
    if (mounted) setState(() => _commits++);
  }

  @override
  Widget build(BuildContext context) {
    return SettingRow(
      icon: widget.icon,
      title: widget.title,
      subtitle: _rowError ?? widget.subtitle,
      trailing: SettingsTextInput(
        controller: _controller,
        authoritativeValue: widget.value,
        authorityKey: _rowAuthority(ref.watch(backendProvider), _commits),
        hint: widget.hint,
        width: widget.width,
        isMobile: widget.isMobile,
        keyboardType: widget.numeric ? TextInputType.number : null,
        inputFormatters: _formatters,
        onChanged: _commit,
      ),
      isLast: widget.isLast,
      isMobile: widget.isMobile,
    );
  }
}

/// Secure-entry row for the TNS bot API key — stored in the keyring
/// (SecretField.tnsApiKey), NEVER in plaintext science settings / backup.
class _TnsApiKeyRow extends ConsumerStatefulWidget {
  const _TnsApiKeyRow();
  @override
  ConsumerState<_TnsApiKeyRow> createState() => _TnsApiKeyRowState();
}

class _TnsApiKeyRowState extends ConsumerState<_TnsApiKeyRow> {
  final _controller = TextEditingController();
  bool _hasKey = false;
  String? _writeError;

  /// Bumped after each stored key so [SettingsTextInput] treats the field as
  /// re-owned and clears it. The key itself is never read back, so a reset
  /// token is the only "authoritative value" this row can have.
  Object _authority = Object();

  @override
  void initState() {
    super.initState();
    _loadHas();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadHas() async {
    final has = await ref.read(secretsStoreProvider).has(SecretField.tnsApiKey);
    if (mounted) setState(() => _hasKey = has);
  }

  Future<void> _commit(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    try {
      await ref
          .read(secretsStoreProvider)
          .write(SecretField.tnsApiKey, trimmed);
    } catch (error) {
      // A locked keyring or an absent secret service is a real condition on a
      // headless host. Say so and keep the pasted key on screen so it can be
      // retried; clearing the field here would look exactly like success.
      if (mounted) {
        final message =
            'Could not store the TNS bot key: ${userFacingError(error)}';
        setState(() => _writeError = message);
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _hasKey = true;
      _writeError = null;
      _authority = Object();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingRow(
      icon: LucideIcons.keyRound,
      title: 'Bot API key',
      subtitle: _writeError ??
          (_hasKey
              ? 'Stored securely in the keyring. Enter a new value to replace '
                  'it.'
              : 'Your TNS bot API key — stored securely, never in backups.'),
      trailing: SettingsTextInput(
        controller: _controller,
        authoritativeValue: '',
        authorityKey: _authority,
        hint: _hasKey ? '•••••• (stored securely)' : 'paste key',
        width: 180,
        obscure: true,
        onChanged: _commit,
      ),
      isMobile: false,
    );
  }
}

/// Toggle between the TNS production endpoint and the sandbox (for testing —
/// sandbox submits never create a public AT record).
class _TnsSandboxRow extends ConsumerWidget {
  final bool isMobile;
  const _TnsSandboxRow({required this.isMobile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final science = ref.watch(scienceSettingsProvider).valueOrNull ??
        const ScienceSettings();
    return SettingRow(
      icon: LucideIcons.flaskConical,
      title: 'Use TNS sandbox',
      subtitle:
          'Submit to the TNS sandbox instead of production (no public record).',
      trailing: SettingsSwitch(
        value: science.tnsUseSandbox,
        onChanged: (value) =>
            ref.read(scienceSettingsProvider.notifier).setTnsUseSandbox(value),
      ),
      isLast: true,
      isMobile: isMobile,
    );
  }
}

/// Toggle for online APASS DR9 cone searches. Downloads are cached per
/// field, so disabling this only stops NEW lookups — previously visited
/// fields keep their deep photometry offline, and everything else falls
/// back to the bundled HYG catalog.
class _ScienceOnlineCatalogRow extends ConsumerStatefulWidget {
  final bool isMobile;
  const _ScienceOnlineCatalogRow({this.isMobile = false});

  @override
  ConsumerState<_ScienceOnlineCatalogRow> createState() =>
      _ScienceOnlineCatalogRowState();
}

class _ScienceOnlineCatalogRowState
    extends ConsumerState<_ScienceOnlineCatalogRow> {
  bool? _pendingValue;

  Future<void> _setEnabled(bool value) async {
    if (_pendingValue != null) return;
    setState(() => _pendingValue = value);
    try {
      await ref
          .read(scienceRawSettingsActionsProvider)
          .setOnlineCatalogEnabled(value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              'Could not save catalog setting: ${userFacingError(error)}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pendingValue = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rawSettings = ref.watch(scienceRawSettingsProvider).valueOrNull;
    final stored =
        rawSettings?[PhotometricCatalogService.onlineEnabledSettingKey];
    final enabled =
        _pendingValue ?? (stored == null || stored.toLowerCase() != 'false');
    return SettingRow(
      icon: LucideIcons.globe,
      title: 'Deep catalog lookups (APASS DR9)',
      subtitle: 'Fetch B/V photometry to ~mag 16 from VizieR for zero-point '
          'calibration and the transform wizard. Cached per field for '
          'offline reuse; falls back to the bundled star catalog when off '
          'or unreachable.',
      trailing: SettingsSwitch(
        value: enabled,
        onChanged: _setEnabled,
      ),
      isLast: true,
      isMobile: widget.isMobile,
    );
  }
}

/// "Auto-configure from camera" switch with provenance subtitle. When on,
/// [ScienceCameraAutoConfig] keeps the three numeric rows below in sync with
/// the connected camera (or active profile); manually editing any of them
/// flips this off so user values are never silently overwritten.
class _ScienceCameraAutoRow extends ConsumerStatefulWidget {
  final bool isMobile;
  const _ScienceCameraAutoRow({this.isMobile = false});

  @override
  ConsumerState<_ScienceCameraAutoRow> createState() =>
      _ScienceCameraAutoRowState();
}

class _ScienceCameraAutoRowState extends ConsumerState<_ScienceCameraAutoRow> {
  bool? _pendingValue;

  Future<void> _setAutoManaged(bool value) async {
    if (_pendingValue != null) return;
    setState(() => _pendingValue = value);
    try {
      await ref
          .read(scienceRawSettingsActionsProvider)
          .setCameraAutoManaged(value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              'Could not save camera setting: ${userFacingError(error)}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pendingValue = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rawSettings = ref.watch(scienceRawSettingsProvider).valueOrNull;
    final storedManaged = rawSettings?[ScienceCameraAutoConfig.autoManagedKey];
    final autoManaged = _pendingValue ??
        (storedManaged == null || storedManaged.toLowerCase() != 'false');
    final source = rawSettings?[ScienceCameraAutoConfig.autoSourceKey];
    final subtitle = autoManaged
        ? (source == null || source.isEmpty
            ? 'Read noise, gain, and saturation follow the connected camera '
                'or active profile'
            : 'Following: $source')
        : 'Manual — values below are user-set and will not be overwritten';
    return SettingRow(
      icon: LucideIcons.wand2,
      title: 'Auto-configure from camera',
      subtitle: subtitle,
      trailing: SettingsSwitch(
        value: autoManaged,
        onChanged: _setAutoManaged,
      ),
      isMobile: widget.isMobile,
    );
  }
}

/// Numeric camera-property row backed by a raw settings key, rendered on the
/// canonical [SettingsTextInput] so the read-noise, gain, and saturation rows
/// inherit the serialised write tail and the rollback-on-refusal, and so a
/// value the auto-configure switch writes from the connected camera reaches
/// the field without a hand-rolled post-frame resync.
///
/// The parse/clamp stays here rather than moving to [SettingsNumberInput]:
/// these rows have to *say* why an entry is refused, and a digits-only
/// formatter would swallow the offending text before the row ever sees it.
class _ScienceCameraValueRow extends ConsumerStatefulWidget {
  final bool isMobile;
  final String settingKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final String defaultText;
  final double min;
  final double max;
  final bool integer;
  final bool isLast;

  const _ScienceCameraValueRow({
    required this.settingKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.defaultText,
    required this.min,
    required this.max,
    this.integer = false,
    this.isLast = false,
    this.isMobile = false,
  });

  @override
  ConsumerState<_ScienceCameraValueRow> createState() =>
      _ScienceCameraValueRowState();
}

class _ScienceCameraValueRowState
    extends ConsumerState<_ScienceCameraValueRow> {
  final _controller = TextEditingController();
  String? _rowError;
  int _commits = 0;

  /// The text this row last stored, held until the settings provider catches
  /// up. It is what makes a clamped entry ("100000" → "65535") visible the
  /// moment it is written instead of a frame later.
  String? _pendingWrite;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _commit(String raw) async {
    final parsed = double.tryParse(raw.trim());
    if (parsed == null || !parsed.isFinite) {
      final message = 'Enter a number from ${widget.min} to ${widget.max}';
      setState(() => _rowError = message);
      throw _ScienceValueRejected(message);
    }
    if (_rowError != null) setState(() => _rowError = null);

    final clamped = parsed.clamp(widget.min, widget.max);
    final stored =
        widget.integer ? clamped.round().toString() : clamped.toString();
    try {
      await ref
          .read(scienceRawSettingsActionsProvider)
          .setManualCameraValue(widget.settingKey, stored);
    } catch (error) {
      ref.invalidate(scienceRawSettingsProvider);
      if (mounted) {
        setState(() => _rowError = 'Could not save this value');
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              'Could not save camera value: ${userFacingError(error)}',
            ),
          ),
        );
      }
      rethrow;
    }
    if (mounted) {
      setState(() {
        _pendingWrite = stored;
        _commits++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Once the provider has re-read the host, it is the authority again —
    // including when the auto-configure switch overwrote what this row wrote.
    ref.listen(scienceRawSettingsProvider, (_, next) {
      if (next.hasValue && _pendingWrite != null) {
        setState(() => _pendingWrite = null);
      }
    });
    final stored =
        ref.watch(scienceRawSettingsProvider).valueOrNull?[widget.settingKey];
    return SettingRow(
      icon: widget.icon,
      title: widget.title,
      subtitle: _rowError ?? widget.subtitle,
      trailing: SettingsTextInput(
        controller: _controller,
        authoritativeValue: _pendingWrite ?? stored ?? widget.defaultText,
        authorityKey: _rowAuthority(ref.watch(backendProvider), _commits),
        width: 72,
        isMobile: widget.isMobile,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: _commit,
      ),
      isLast: widget.isLast,
      isMobile: widget.isMobile,
    );
  }
}
