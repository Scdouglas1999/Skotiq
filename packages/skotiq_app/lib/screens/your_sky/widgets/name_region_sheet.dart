import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Which sky source seeds the region's centre + name.
enum _RegionSource { target, custom }

/// Characters a sexagesimal or decimal coordinate can contain.
///
/// Accepts the sexagesimal and decimal forms the rest of the app prints:
/// Framing shows `05h 35m 16s`, the planetarium readout `0h 42m 44s`. A
/// degrees-only box silently puts the region tens of degrees from where the
/// operator meant when they paste the RA they are looking at.
final _coordinateCharacters =
    FilteringTextInputFormatter.allow(RegExp(r"""[0-9.:+\-hmsdHMSD°'" ]"""));

/// "Name a region" sheet — the explicit control that makes the entire Your Sky
/// region UX reachable by hand (alongside the automatic on-fold attach).
///
/// Pick a source — one of the user's targets (active target / library) or a
/// custom RA-Dec + radius (covers a mosaic, polar field, or any patch of sky) —
/// give it a name, and create the region through the authority-aware
/// [skyAtlasRegionWriterProvider]. On a companion the metadata write runs on
/// the imaging host; atlas pixels and fold history never move to the client.
class NameRegionSheet extends ConsumerStatefulWidget {
  const NameRegionSheet({super.key});

  /// Show the sheet; returns true when a region was created.
  static Future<bool?> show(BuildContext context) {
    return showAdaptiveModal<bool>(
      context: context,
      builder: (_) => const NameRegionSheet(),
    );
  }

  @override
  ConsumerState<NameRegionSheet> createState() => _NameRegionSheetState();
}

class _NameRegionSheetState extends ConsumerState<NameRegionSheet> {
  _RegionSource _source = _RegionSource.target;
  DbTarget? _selectedTarget;
  final _nameController = TextEditingController();
  final _raController = TextEditingController();
  final _decController = TextEditingController();
  final _radiusController = TextEditingController(text: '0.5');
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // A validation message must not outlive the state that produced it: "Pick
    // a target first." left on screen after a switch to Custom RA/Dec — a mode
    // with no target to pick — contradicts the sheet's own copy.
    for (final c in [
      _nameController,
      _raController,
      _decController,
      _radiusController,
    ]) {
      c.addListener(_clearError);
    }
  }

  void _clearError() {
    if (_error == null) return;
    setState(() => _error = null);
  }

  /// Whether [_create] could possibly succeed as the form now stands. Only the
  /// unsatisfiable case is blocked: the range errors on the custom fields still
  /// have to be reachable, because they say what a valid entry looks like.
  bool get _canSubmit =>
      _source != _RegionSource.target || _selectedTarget != null;

  @override
  void dispose() {
    for (final c in [
      _nameController,
      _raController,
      _decController,
      _radiusController,
    ]) {
      c.removeListener(_clearError);
    }
    _nameController.dispose();
    _raController.dispose();
    _decController.dispose();
    _radiusController.dispose();
    super.dispose();
  }

  /// The target library has loaded and is empty, so `From a target` can never
  /// produce a region no matter what the user does in this mode.
  ///
  /// A dim `Create region` here still reads to the accessibility tree as a
  /// plain actionable button, and clicking it produces nothing at all — no
  /// error, no toast, no region. A control that cannot work in the state it is
  /// shown in is not made honest by dimming it, so in this state the sheet
  /// offers the only action that CAN work instead (see
  /// [_buildPrimaryAction]).
  bool _libraryIsEmpty(AsyncValue<List<DbTarget>> targetsAsync) =>
      _source == _RegionSource.target &&
      (targetsAsync.valueOrNull?.isEmpty ?? false);

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final targetsAsync = ref.watch(allDbTargetsProvider);

    final sheet = SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: SkotiqTokens.spaceLg,
          right: SkotiqTokens.spaceLg,
          top: SkotiqTokens.spaceLg,
          bottom:
              MediaQuery.of(context).viewInsets.bottom + SkotiqTokens.spaceLg,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.plus,
                      size: SkotiqTokens.iconMd, color: colors.primary),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Text(
                    'Name a region',
                    style: SkotiqTypography.bodyStrong
                        .copyWith(color: colors.textPrimary),
                  ),
                ],
              ),
              const SizedBox(height: SkotiqTokens.spaceXs),
              Text(
                'Group the sky you have imaged into a named region to track its '
                'depth and scrub it through time. Future folds at this position '
                'deepen it automatically.',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceLg),
              _SourceToggle(
                source: _source,
                onChanged: (s) => setState(() {
                  _source = s;
                  _error = null;
                }),
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
              if (_source == _RegionSource.target)
                _buildTargetPicker(colors, targetsAsync)
              else
                _buildCustomFields(colors),
              const SizedBox(height: SkotiqTokens.spaceMd),
              SkotiqTextField(
                controller: _nameController,
                label: 'Region name',
                hint: _source == _RegionSource.target
                    ? 'Defaults to the target name'
                    : 'e.g. Cygnus Wall mosaic',
              ),
              if (_error != null) ...[
                const SizedBox(height: SkotiqTokens.spaceMd),
                Text(
                  _error!,
                  style: SkotiqTypography.caption.copyWith(color: colors.error),
                ),
              ],
              const SizedBox(height: SkotiqTokens.spaceLg),
              Row(
                children: [
                  Expanded(
                    child: SkotiqButton(
                      label: 'Cancel',
                      variant: ButtonVariant.secondary,
                      // Live even mid-write: the write is fire-and-forget from
                      // here on (`_create` re-checks `mounted`), and a sheet
                      // that can only be left by killing the app takes any
                      // running sequence with it.
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Expanded(child: _buildPrimaryAction(targetsAsync)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return sheet;
  }

  /// The sheet's primary action.
  ///
  /// Normally `Create region`. With an empty library in `From a target` mode
  /// there is nothing to create from, so the slot carries the escape hatch the
  /// mode's own copy names — one live control instead of a dead one.
  Widget _buildPrimaryAction(AsyncValue<List<DbTarget>> targetsAsync) {
    if (_libraryIsEmpty(targetsAsync)) {
      return SkotiqButton(
        label: 'Switch to Custom RA/Dec',
        icon: LucideIcons.arrowRight,
        onPressed: () => setState(() {
          _source = _RegionSource.custom;
          _error = null;
        }),
      );
    }
    final blocked = !_canSubmit;
    return Semantics(
      // A disabled primary action has to say what is missing: the button's own
      // label cannot, and the dimming alone carries no reason.
      hint: blocked ? 'Choose a target first' : null,
      child: SkotiqButton(
        label: 'Create region',
        icon: LucideIcons.check,
        isLoading: _saving,
        onPressed: _saving || blocked ? null : _create,
      ),
    );
  }

  Widget _buildTargetPicker(
    SkotiqColors colors,
    AsyncValue<List<DbTarget>> targetsAsync,
  ) {
    return targetsAsync.when(
      data: (targets) {
        if (targets.isEmpty) {
          return SkotiqPanel(
              padding: SkotiqTokens.cardPadding,
              child: Text(
                'No targets in your library yet — switch to Custom to enter a '
                'sky position by hand.',
                style:
                    SkotiqTypography.caption.copyWith(color: colors.textMuted),
              ));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Target',
              style: SkotiqTypography.captionSm
                  .copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: SkotiqTokens.spaceXs),
            SkotiqDropdown(
              value: _selectedTarget == null ? null : '${_selectedTarget!.id}',
              hint: 'Choose a target',
              isExpanded: true,
              items: [for (final t in targets) '${t.id}'],
              itemLabels: [for (final t in targets) t.name],
              onChanged: (idStr) => setState(() {
                final id = int.tryParse(idStr ?? '');
                DbTarget? t;
                for (final x in targets) {
                  if (x.id == id) {
                    t = x;
                    break;
                  }
                }
                _selectedTarget = t;
                _error = null;
                if (t != null && _nameController.text.trim().isEmpty) {
                  _nameController.text = t.name;
                }
              }),
            ),
          ],
        );
      },
      loading: () => const Center(
        child: SkotiqCircularProgress(
          value: 0,
          indeterminate: true,
          size: SkotiqTokens.iconLg,
        ),
      ),
      error: (_, __) => Text(
        'Could not load targets.',
        style: SkotiqTypography.caption.copyWith(color: colors.error),
      ),
    );
  }

  Widget _buildCustomFields(SkotiqColors colors) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: SkotiqTextField(
                controller: _raController,
                label: 'RA',
                hint: '05h 35m 16s or 83.82°',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [_coordinateCharacters],
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: SkotiqTextField(
                controller: _decController,
                label: 'Dec',
                hint: "-05° 23' 24\" or -5.39",
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [_coordinateCharacters],
              ),
            ),
          ],
        ),
        _buildInterpretation(colors),
        const SizedBox(height: SkotiqTokens.spaceMd),
        SkotiqTextField(
          controller: _radiusController,
          label: 'Radius (degrees)',
          hint: 'cone radius, e.g. 0.5',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
        ),
      ],
    );
  }

  /// The typed centre, or null when either field does not read as a coordinate.
  ///
  /// [CoordinateParser] is the app's one RA/Dec reader — the same one Framing
  /// and the mount's slew box use — so `05h 35m 16s`, `5.588`, `83.82` and
  /// `83.82°` all mean the same place here that they mean everywhere else.
  ({double raDeg, double decDeg})? _parsedCentre() {
    final raHours = CoordinateParser.parseRa(_raController.text);
    final decDeg = CoordinateParser.parseDec(_decController.text);
    if (raHours == null || decDeg == null) return null;
    return (raDeg: raHours * 15.0, decDeg: decDeg);
  }

  /// Echo the interpretation back. Two conventions share these boxes, so the
  /// only honest input is one that says which it read.
  Widget _buildInterpretation(SkotiqColors colors) {
    return ListenableBuilder(
      listenable: Listenable.merge([_raController, _decController]),
      builder: (context, _) {
        final centre = _parsedCentre();
        final text = centre == null
            ? 'Enter a position in either convention — sexagesimal or decimal.'
            : 'Reads as ${CoordinateParser.formatRaHms(centre.raDeg / 15.0)} '
                '${CoordinateParser.formatDecDms(centre.decDeg)} '
                '(${centre.raDeg.toStringAsFixed(3)}°, '
                '${centre.decDeg.toStringAsFixed(3)}°)';
        return Padding(
          padding: const EdgeInsets.only(top: SkotiqTokens.spaceXs),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              text,
              style: SkotiqTypography.captionSm.copyWith(
                color: centre == null ? colors.textMuted : colors.textSecondary,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _create() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    double raDeg;
    double decDeg;
    double radiusDeg;
    String kind;
    final name = _nameController.text.trim();

    if (_source == _RegionSource.target) {
      final target = _selectedTarget;
      if (target == null) {
        setState(() {
          _saving = false;
          _error = 'Pick a target first.';
        });
        return;
      }
      raDeg = target.ra * 15.0; // RA hours -> degrees.
      decDeg = target.dec;
      radiusDeg = 0.5;
      kind = 'target';
    } else {
      final centre = _parsedCentre();
      final radius = double.tryParse(_radiusController.text.trim());
      if (centre == null ||
          radius == null ||
          !radius.isFinite ||
          radius <= 0 ||
          radius > 180) {
        setState(() {
          _saving = false;
          _error = 'Enter RA as 05h 35m 16s or 83.82°, Dec from -90° to +90°, '
              'and a radius greater than 0° and no more than 180°.';
        });
        return;
      }
      raDeg = centre.raDeg;
      decDeg = centre.decDeg;
      radiusDeg = radius;
      kind = 'custom';
    }

    final effectiveName =
        name.isNotEmpty ? name : (_selectedTarget?.name ?? 'Custom region');

    final authority = ref.read(backendProvider);
    try {
      await ref.read(skyAtlasRegionWriterProvider).ensureRegion(
            name: effectiveName,
            centerRaDeg: raDeg,
            centerDecDeg: decDeg,
            radiusDeg: radiusDeg,
            kind: kind,
            targetId:
                _source == _RegionSource.target ? _selectedTarget?.id : null,
          );
      if (!mounted) return;
      if (!identical(ref.read(backendProvider), authority)) {
        setState(() {
          _saving = false;
          _error = 'The imaging host changed while the region was being '
              'created. Check the active host before trying again.';
        });
        return;
      }
      ref.invalidate(skyAtlasRegionsProvider);
      // `pop`, not `maybePop`: `maybePop` consults the `PopScope(canPop:
      // !_saving)` guard this sheet sets, so a write taking longer than one
      // frame would leave the region created and the app behind a modal
      // barrier no key, button or click could lift.
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not create region: $e';
      });
    }
  }
}

class _SourceToggle extends StatelessWidget {
  final _RegionSource source;
  final ValueChanged<_RegionSource> onChanged;

  const _SourceToggle({required this.source, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SkotiqChip(
            label: 'From a target',
            selected: source == _RegionSource.target,
            onTap: () => onChanged(_RegionSource.target),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: SkotiqChip(
            label: 'Custom RA/Dec',
            selected: source == _RegionSource.custom,
            onTap: () => onChanged(_RegionSource.custom),
          ),
        ),
      ],
    );
  }
}
