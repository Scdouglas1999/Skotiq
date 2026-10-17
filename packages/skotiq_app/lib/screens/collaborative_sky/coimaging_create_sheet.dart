import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../constellation/constellation_format.dart';
import '../mosaic/mosaic_contribute_sheet.dart';
import '../sequencer/widgets/target_node_properties.dart'
    show TargetCoordinateMatch, targetCoordinateLookupProvider;

/// Open the "Start a live co-imaging session" sheet and return the created
/// [CoImagingSession], or null if the user cancelled.
///
/// The session-defining fields (target name + centre + radius) can be prefilled
/// from whatever surface launched the sheet — the current framing target on the
/// Collaborative Sky screen, or a shared target on its detail screen — while
/// staying fully editable, so this stays a single create surface rather than a
/// target-picker browser. The caller (not this sheet) runs the post-create
/// unattended-sharing consent gate via [ensureCoImagingSharingConsent], because
/// that gate itself presents a modal and its wording depends on the outcome.
Future<CoImagingSession?> showCoImagingCreateSheet(
  BuildContext context, {
  String? initialTargetName,
  double? initialRaDeg,
  double? initialDecDeg,
  double? initialRadiusDeg,
}) {
  return showAdaptiveModal<CoImagingSession>(
    context: context,
    designWidth: 560,
    phoneMode: PhoneModalMode.bottomSheet,
    builder: (_) => _CoImagingCreateSheet(
      initialTargetName: initialTargetName,
      initialRaDeg: initialRaDeg,
      initialDecDeg: initialDecDeg,
      initialRadiusDeg: initialRadiusDeg,
    ),
  );
}

/// Whether this rig's completed subs will actually co-add: an unattended
/// contribution consent is on record AND its auto-upload opt-in is enabled — the
/// exact gate the injected co-imaging consent resolver enforces, so a join /
/// create message never promises a co-add the egress will refuse. Mirrors the
/// mosaic upload path (subs and panel masters share ONE consent record).
Future<bool> coImagingUnattendedSharingEnabled(WidgetRef ref) async {
  final consent =
      await resolveMosaicUploadConsent(ref.read(settingsDaoProvider));
  return consent != null && consent.autoUpload;
}

/// Ensure unattended co-imaging sharing is enabled, routing the user through the
/// co-imaging contribute-consent sheet when it is not, then re-reading the
/// persisted record. Shared by the JOIN and CREATE flows: joining points a rig
/// at a framing slot and creating makes the caller the anchor participant, and
/// in both cases the rig's subs only co-add once the operator has an unattended
/// contribution consent (the fold fails closed otherwise), so both must gate the
/// same way and promise a co-add only when sharing is actually on.
///
/// Returns whether sharing is enabled after the (possibly shown) consent step,
/// or null when the originating element unmounted mid-flow — a non-null result
/// therefore guarantees [context] is still mounted and the caller may use it.
Future<bool?> ensureCoImagingSharingConsent(
  BuildContext context,
  WidgetRef ref,
) async {
  var sharing = await coImagingUnattendedSharingEnabled(ref);
  if (!context.mounted) return null;
  if (!sharing) {
    await showMosaicContributeSheet(
      context,
      purpose: CollaborativeContributeContext.coImagingSubs,
    );
    if (!context.mounted) return null;
    sharing = await coImagingUnattendedSharingEnabled(ref);
    if (!context.mounted) return null;
  }
  return sharing;
}

/// The create-session form: target name + sky centre + pooling radius, opened as
/// an adaptive modal by [showCoImagingCreateSheet].
class _CoImagingCreateSheet extends ConsumerStatefulWidget {
  const _CoImagingCreateSheet({
    this.initialTargetName,
    this.initialRaDeg,
    this.initialDecDeg,
    this.initialRadiusDeg,
  });

  final String? initialTargetName;
  final double? initialRaDeg;
  final double? initialDecDeg;
  final double? initialRadiusDeg;

  @override
  ConsumerState<_CoImagingCreateSheet> createState() =>
      _CoImagingCreateSheetState();
}

class _CoImagingCreateSheetState extends ConsumerState<_CoImagingCreateSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _raController;
  late final TextEditingController _decController;
  late final TextEditingController _radiusController;

  /// Show per-field "required" errors only after a submit attempt, so the form
  /// does not open pre-scolded; live invalid-format errors show as soon as a
  /// non-empty field cannot parse.
  ///
  /// "Start session" therefore stays pressable on an incomplete form: [_create]
  /// is the only thing that sets this flag, so gating the button on validation
  /// would keep the required messages from ever rendering.
  bool _submitted = false;
  bool _busy = false;
  String? _error;

  /// The name that was submitted for catalog resolution, or null when no lookup
  /// is open. Kept separate from the name field so the result list does not
  /// churn while the user is still typing.
  String? _lookupQuery;

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: widget.initialTargetName ?? '');
    _raController = TextEditingController(
      text: widget.initialRaDeg == null
          ? ''
          : _formatDegrees(widget.initialRaDeg!),
    );
    _decController = TextEditingController(
      text: widget.initialDecDeg == null
          ? ''
          : _formatDegrees(widget.initialDecDeg!),
    );
    _radiusController = TextEditingController(
      text: _formatDegrees(widget.initialRadiusDeg ?? 1.5),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _raController.dispose();
    _decController.dispose();
    _radiusController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final name = _nameController.text.trim();
    final raDeg = _parseRaDegrees(_raController.text);
    final decDeg = _parseDecDegrees(_decController.text);
    final radiusDeg = _parseRadiusDegrees(_radiusController.text);
    final isComplete =
        name.isNotEmpty && raDeg != null && decDeg != null && radiusDeg != null;

    // Surface, not SkotiqDialog: showAdaptiveModal already supplies the
    // frame (a Dialog on desktop, a bottom sheet on a phone). Nesting a second
    // dialog stretched that frame into a full-height slab.
    return SkotiqDialogSurface(
      title: 'Start co-imaging session',
      icon: LucideIcons.radio,
      showCloseButton: !_busy,
      closeEnabled: !_busy,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        // Pressable whenever the sheet is idle. An incomplete form is answered
        // by _create marking the fields that are missing, not by a dead button
        // that gives the operator nothing to act on.
        SkotiqButton(
          label: _busy ? 'Starting…' : 'Start session',
          icon: LucideIcons.radio,
          isLoading: _busy,
          onPressed: _busy ? null : _create,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Open a live session on a target so other rigs can pool their '
            'integration into the same combined stack across the night. You '
            'stay the anchor and can end it anytime.',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          SkotiqTextField(
            controller: _nameController,
            label: 'Target name',
            hint: 'e.g. NGC 7000',
            prefixIcon: LucideIcons.target,
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {
              // A newly typed name invalidates the last resolution.
              _lookupQuery = null;
            }),
            errorText:
                _submitted && name.isEmpty ? 'Enter a target name.' : null,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          // Nobody should be hand-typing RA/Dec for a target the app can
          // already resolve: the installed catalogs and the target library
          // answer the name above, and a connected mount is by definition
          // pointing at what the operator wants to share.
          _CoordinateSources(
            canLookUp: name.length >= 2,
            onLookUp: () => setState(() => _lookupQuery = name),
            onUseMount: _applyMountPosition,
          ),
          if (_lookupQuery != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            _LookupResults(
              query: _lookupQuery!,
              onApply: _applyMatch,
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqTextField(
            controller: _raController,
            label: 'Center RA (degrees)',
            hint: 'e.g. 314.75 or 20:58:47',
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
            errorText: _fieldError(
              _raController.text,
              raDeg,
              emptyMessage: 'Enter the target center RA.',
              invalidMessage: 'Enter RA in degrees (0–360) or HH:MM:SS.',
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqTextField(
            controller: _decController,
            label: 'Center Dec (degrees)',
            hint: 'e.g. 44.31 or +44:18:48',
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
            errorText: _fieldError(
              _decController.text,
              decDeg,
              emptyMessage: 'Enter the target center Dec.',
              invalidMessage: 'Enter Dec in degrees (-90 to 90) or ±DD:MM:SS.',
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqTextField(
            controller: _radiusController,
            label: 'Session radius (degrees)',
            hint: '1.5',
            suffix: '°',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (isComplete && !_busy) _create();
            },
            errorText: _fieldError(
              _radiusController.text,
              radiusDeg,
              emptyMessage: 'Enter a session radius.',
              invalidMessage: 'Enter a radius in degrees (0–30).',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqBanner(title: _error!, tone: BannerTone.error),
          ],
        ],
      ),
    );
  }

  /// Fill the centre from a resolved catalog / library match, adopting its
  /// canonical name so the session is advertised under the name other rigs will
  /// search for.
  void _applyMatch(TargetCoordinateMatch match) {
    setState(() {
      _nameController.text = match.name;
      // The lookup speaks RA HOURS; this form's field is RA DEGREES.
      _raController.text = _formatDegrees((match.raHours * 15.0) % 360);
      _decController.text = _formatDegrees(match.decDegrees);
      _lookupQuery = null;
      _error = null;
    });
  }

  /// Fill the centre from where the mount is actually pointing. The name is
  /// left alone: only the operator knows what they are looking at.
  void _applyMountPosition() {
    final mount = ref.read(mountStateProvider);
    final ra = mount.ra;
    final dec = mount.dec;
    if (ra == null || dec == null) return;
    setState(() {
      // MountState reports RA in HOURS; this form's field is RA DEGREES.
      _raController.text = _formatDegrees((ra * 15.0) % 360);
      _decController.text = _formatDegrees(dec);
      _error = null;
    });
  }

  /// The error string for a coordinate/radius field: a "required" message only
  /// after a submit attempt, else an "invalid format" message while the field is
  /// non-empty but does not parse (and no error once it parses).
  String? _fieldError(
    String raw,
    Object? parsed, {
    required String emptyMessage,
    required String invalidMessage,
  }) {
    if (raw.trim().isEmpty) return _submitted ? emptyMessage : null;
    return parsed == null ? invalidMessage : null;
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    final raDeg = _parseRaDegrees(_raController.text);
    final decDeg = _parseDecDegrees(_decController.text);
    final radiusDeg = _parseRadiusDegrees(_radiusController.text);
    if (name.isEmpty || raDeg == null || decDeg == null || radiusDeg == null) {
      setState(() => _submitted = true);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session =
          await ref.read(coImagingSessionServiceProvider).createSession(
                targetName: name,
                raDeg: raDeg,
                decDeg: decDeg,
                radiusDeg: radiusDeg,
              );
      if (!mounted) return;
      // Refresh the browse list + this rig's memberships so the new session (and
      // the creator's own anchor membership) render immediately on return.
      ref.invalidate(coImagingSessionsProvider);
      ref.invalidate(coImagingMembershipsProvider);
      Navigator.of(context).pop(session);
    } catch (error) {
      if (!mounted) return;
      // Keep the sheet open on failure so the user can correct + retry.
      setState(() {
        _busy = false;
        _error = describeConstellationError(error);
      });
    }
  }
}

/// The two ways to fill the centre without typing coordinates: resolve the
/// typed name against the installed catalogs / target library, or take the
/// mount's current pointing.
class _CoordinateSources extends ConsumerWidget {
  final bool canLookUp;
  final VoidCallback onLookUp;
  final VoidCallback onUseMount;

  const _CoordinateSources({
    required this.canLookUp,
    required this.onLookUp,
    required this.onUseMount,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mount = ref.watch(mountStateProvider);
    final mountReady =
        mount.connectionState == DeviceConnectionState.connected &&
            mount.ra != null &&
            mount.dec != null;

    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceXs,
      children: [
        Tooltip(
          message: canLookUp
              ? 'Resolve the name above against your catalogs'
              : 'Type at least two characters of a target name',
          child: SkotiqButton(
            label: 'Look up coordinates',
            icon: LucideIcons.search,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: canLookUp ? onLookUp : null,
          ),
        ),
        Tooltip(
          message: mountReady
              ? 'Use where the mount is pointing right now'
              : 'Connect a mount to use its position',
          child: SkotiqButton(
            label: 'From mount',
            icon: LucideIcons.move,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: mountReady ? onUseMount : null,
          ),
        ),
      ],
    );
  }
}

/// Candidate list for a resolved name.
///
/// Reuses [targetCoordinateLookupProvider] — the app's single name-to-
/// coordinates resolver, which searches the target library (over the wire on a
/// remote client) and then the installed planetarium catalogs. It lives beside
/// the sequencer's Target editor today; this is the second consumer.
class _LookupResults extends ConsumerWidget {
  final String query;
  final void Function(TargetCoordinateMatch match) onApply;

  const _LookupResults({required this.query, required this.onApply});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final lookup = ref.watch(targetCoordinateLookupProvider(query));

    Widget message(String text, {bool isProblem = false}) => Text(
          text,
          style: SkotiqTypography.captionSm.copyWith(
            color: isProblem ? colors.warning : colors.textMuted,
          ),
        );

    return lookup.when(
      loading: () => message('Searching for "$query"…'),
      error: (_, __) => message(
        'Lookup failed. Enter RA/Dec below.',
        isProblem: true,
      ),
      data: (matches) {
        if (matches.isEmpty) {
          return message(
            'No match for "$query" in your target library or installed '
            'catalogs. Install a catalog from Settings → Catalogs, or enter '
            'RA/Dec below.',
            isProblem: true,
          );
        }
        return Container(
          constraints: const BoxConstraints(maxHeight: 170),
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(color: colors.border),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: matches.length,
              itemBuilder: (context, index) {
                final match = matches[index];
                return ListTile(
                  dense: true,
                  title: Text(
                    match.name,
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textPrimary),
                  ),
                  subtitle: Text(
                    '${_formatDegrees((match.raHours * 15.0) % 360)}°  '
                    '${_formatDegrees(match.decDegrees)}°',
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textMuted),
                  ),
                  onTap: () => onApply(match),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Trim a degrees value to a compact editable string (no trailing-zero noise),
/// so a prefilled field reads "44.31" / "1.5" rather than "44.3100" / "1.5000".
String _formatDegrees(double value) {
  final fixed = value.toStringAsFixed(4);
  if (!fixed.contains('.')) return fixed;
  return fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// Parse an RA field that is primarily decimal DEGREES (the field's stated unit)
/// but also accepts the sexagesimal / hour forms [CoordinateParser.parseRa]
/// understands. A bare decimal is read as degrees, never hours — so "150" means
/// 150°, sidestepping the parser's hours-for-values-under-24 heuristic — while a
/// colon/HMS string falls back to the shared parser (hours → degrees).
double? _parseRaDegrees(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;
  final decimal = double.tryParse(trimmed);
  if (decimal != null) {
    return (decimal.isFinite && decimal >= 0 && decimal < 360) ? decimal : null;
  }
  final hours = CoordinateParser.parseRa(trimmed);
  return hours == null ? null : hours * 15.0;
}

/// Parse a Dec field in decimal degrees or the sexagesimal forms
/// [CoordinateParser.parseDec] understands — both already return degrees.
double? _parseDecDegrees(String input) => CoordinateParser.parseDec(input);

/// Parse the pooling radius (degrees): a positive decimal capped at a sane sky
/// cone so a fat-fingered value cannot request a hemisphere-wide session.
double? _parseRadiusDegrees(String input) {
  final value = double.tryParse(input.trim());
  if (value == null || !value.isFinite || value <= 0 || value > 30) return null;
  return value;
}
