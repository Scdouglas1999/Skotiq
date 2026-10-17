part of '../settings_widgets.dart';

/// How far the selected swatch's ring reaches past the circle, and how much of
/// that is the gap in the page's own ground (mockups/settings.html `.sel`).
const double _swatchRingExtent = 4;
const double _swatchRingGap = 2;

class SettingsColorPicker extends StatefulWidget {
  /// The seven hues, in the order [AppearanceAccents] lists them. The name is
  /// not decoration: it is the swatch's accessible label and its tooltip, so a
  /// control whose only other description is its own pixels can be found and
  /// read.
  static const List<String> accentNames = [
    'Violet',
    'Blue',
    'Green',
    'Amber',
    'Red',
    'Pink',
    'Teal',
  ];

  /// The swatches offered for [mode], as `(hex, name)`.
  ///
  /// A dark-safe accent is not light-safe (03 §1.4): `#6EB3EC` is 8.1:1 as link
  /// text on the dark canvas and 2.4:1 on white, so each theme gets its own
  /// seven, the same hues taken to where that theme's ink works.
  /// [AppearanceAccents] lists them in the [accentNames] order.
  static List<(String, String)> swatchesFor(AppThemeMode mode) {
    final palette = AppearanceAccents.forTheme(mode);
    return <(String, String)>[
      for (var i = 0; i < palette.length; i++)
        (
          '#${palette[i].toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
          accentNames[i],
        ),
    ];
  }

  /// The dark theme's swatches — the default when no list is supplied.
  static List<(String, String)> get accentColors =>
      swatchesFor(AppThemeMode.dark);

  final String selectedColor;

  /// May be asynchronous so a failed save can restore the confirmed color.
  final FutureOr<void> Function(String) onColorSelected;

  final bool isMobile;

  /// The swatches to offer, as `(hex, name)`. Defaults to the dark set; the
  /// Appearance page passes the set for the theme actually in force.
  final List<(String, String)>? swatches;

  const SettingsColorPicker({
    super.key,
    required this.selectedColor,
    required this.onColorSelected,
    this.isMobile = false,
    this.swatches,
  });

  /// Diameter of one swatch. Each swatch carries the Trails mark rendered in
  /// its accent, so the swatch is sized for the mark's 24–32 px band rather
  /// than the old 22 px flat disc — the tap target (swatch + ring margin)
  /// grows with it, never shrinking below the previous 30 px.
  static const double swatchSize = 30;

  @override
  State<SettingsColorPicker> createState() => _SettingsColorPickerState();
}

class _SettingsColorPickerState extends State<SettingsColorPicker> {
  late String _selectedColor;
  int _editGeneration = 0;
  int _activeWrites = 0;
  Future<void> _writeTail = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _selectedColor = widget.selectedColor;
  }

  @override
  void didUpdateWidget(covariant SettingsColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_activeWrites == 0) _selectedColor = widget.selectedColor;
  }

  void _selectColor(String color) {
    if (color.toLowerCase() == _selectedColor.toLowerCase()) return;
    final generation = ++_editGeneration;
    final callback = widget.onColorSelected;
    setState(() => _selectedColor = color);

    _activeWrites++;
    final operation = _writeTail.then((_) async {
      try {
        await Future<void>.sync(() => callback(color));
      } catch (e) {
        // The swatch snaps back to the confirmed colour, which is the honest
        // rendering, but the revert alone does not say a save was attempted
        // and refused. Log so a settings backend that is rejecting writes is
        // diagnosable instead of looking like a UI that ignores taps.
        developer.log(
          'Settings colour write failed; reverted the swatch to the last '
          'confirmed value: $e',
          name: 'SettingsInput',
          level: 900,
        );
        if (mounted && generation == _editGeneration) {
          setState(() => _selectedColor = widget.selectedColor);
        }
      } finally {
        _activeWrites--;
      }
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    unawaited(operation);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    // Always wrap. A fixed `Row` of seven swatches needs ~210 px and cannot
    // shrink, so on a narrowed settings detail pane it pushed the last
    // swatches off-screen (unpickable) and overflowed by >100 px. `Wrap`
    // still renders as one line whenever the row has room.
    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      alignment: WrapAlignment.end,
      children: (widget.swatches ?? SettingsColorPicker.accentColors)
          .map((colorData) {
        final (hex, name) = colorData;

        return _buildColorCircle(
          colors,
          hex,
          name,
          SettingsColorPicker.swatchSize,
        );
      }).toList(),
    );
  }

  Widget _buildColorCircle(
    SkotiqColors colors,
    String hex,
    String name,
    double size,
  ) {
    final color = Color(int.parse(hex.substring(1), radix: 16) + 0xFF000000);

    final isSelected = _selectedColor.toLowerCase() == hex.toLowerCase();

    // These were seven bare GestureDetectors: no name, no role, no focus. The
    // live accessibility tree for Settings → Appearance listed "Accent color"
    // with ZERO children, so a screen-reader or keyboard user could neither
    // find the swatches nor tell which one was active — while the switch in the
    // row below reported itself as "toggle button … [off]". The colour names
    // were already in `accentColors` and simply thrown away; a swatch whose
    // only description is its pixels needs them most.
    return MergeSemantics(
      child: Semantics(
        // Semantics publishes isEnabled only when this field is given;
        // omitting it makes assistive tech announce a live control as
        // disabled. Measured on the running app 2026-08-09.
        enabled: true,
        button: true,
        inMutuallyExclusiveGroup: true,
        selected: isSelected,
        label: name,
        child: Tooltip(
          message: name,
          child: InkWell(
            key: ValueKey('settings-color-$hex'),
            onTap: () => _selectColor(hex),
            customBorder: const CircleBorder(),
            child: Container(
              // The selected swatch is ringed, not outlined: a 2 px ring held
              // off the mark by a 2 px gap in the page's own ground.
              // Painted last-on-top, so the gap ring covers the inner half of
              // the outer one.
              margin: const EdgeInsets.all(_swatchRingExtent),
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: colors.textPrimary,
                          spreadRadius: _swatchRingExtent,
                        ),
                        BoxShadow(
                          color: colors.background,
                          spreadRadius: _swatchRingGap,
                        ),
                      ]
                    : null,
              ),
              // The swatch IS the mark in this accent's colorway: it previews
              // the logo each choice produces, on the same ground the logo
              // will sit on. Decorative — the Semantics wrapper above is what
              // announces the swatch's name and state.
              child: SkotiqMark(
                size: size,
                tone: SkotiqMarkTone.theme,
                themeAccent: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Path input with browse button for file/directory selection.
///
/// The box only LOOKS like a text field when [onPathEntered] is supplied.
/// A bordered, filled box that is really a [Text] swallows every keystroke.
///
/// On a real rig the typed path is often the only way in — a UNC share, a NAS
/// mount that is not up yet, a folder on the imaging host — so the storage rows
/// accept one, and the rows that genuinely cannot (a solver executable the app
/// has to verify) render a plain label rather than inviting the attempt.
class SettingsPathInput extends StatefulWidget {
  final String path;

  final FutureOr<void> Function() onBrowse;

  /// Commit a hand-typed path. Null makes this control read-only.
  ///
  /// Called on Enter and on focus loss, only when the text differs from
  /// [path]. The callback owns validation: it may reject the value, in which
  /// case the field snaps back to [path] on the next build.
  final FutureOr<void> Function(String)? onPathEntered;

  final bool isMobile;

  /// If true, use flexible width (useful for stacked mobile layouts)

  final bool flexible;

  /// Identity of the backend/host that owns [onBrowse]. A changed identity
  /// invalidates an in-flight picker and immediately unlocks this control.
  final Object? authorityKey;

  const SettingsPathInput({
    super.key,
    required this.path,
    required this.onBrowse,
    this.onPathEntered,
    this.isMobile = false,
    this.flexible = false,
    this.authorityKey,
  });

  @override
  State<SettingsPathInput> createState() => _SettingsPathInputState();
}

class _SettingsPathInputState extends State<SettingsPathInput> {
  bool _browsing = false;
  int _browseGeneration = 0;

  TextEditingController? _controller;
  FocusNode? _focusNode;
  bool _committing = false;

  bool get _editable => widget.onPathEntered != null;

  @override
  void initState() {
    super.initState();
    if (_editable) {
      _controller = TextEditingController(text: widget.path);
      _focusNode = FocusNode()..addListener(_onFocusChange);
    }
  }

  @override
  void dispose() {
    _focusNode?.removeListener(_onFocusChange);
    _focusNode?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SettingsPathInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_browsing && !identical(oldWidget.authorityKey, widget.authorityKey)) {
      _browseGeneration++;
      _browsing = false;
    }
    // Adopt the stored value whenever it is not being typed into: a browse, a
    // host switch, or a refused write all have to be visible here. Never while
    // focused, or the caret would jump under the operator's hands.
    final controller = _controller;
    if (controller != null &&
        !_committing &&
        _focusNode?.hasFocus != true &&
        controller.text != widget.path) {
      controller.text = widget.path;
    }
  }

  void _onFocusChange() {
    if (_focusNode?.hasFocus != true) {
      // Leaving the field commits it. Tabbing away or clicking elsewhere is
      // how people leave a path box; requiring Enter loses the edit silently.
      _commit();
    }
  }

  Future<void> _commit() async {
    final controller = _controller;
    final handler = widget.onPathEntered;
    if (controller == null || handler == null || _committing) return;
    final typed = controller.text;
    if (typed == widget.path) return;
    _committing = true;
    try {
      await Future<void>.sync(() => handler(typed));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not use that path: $error')),
        );
      }
    } finally {
      _committing = false;
      // Whatever the handler decided, the stored value is the truth.
      if (mounted && controller.text != widget.path) {
        setState(() => controller.text = widget.path);
      }
    }
  }

  Future<void> _browse() async {
    if (_browsing) return;
    final generation = ++_browseGeneration;
    setState(() => _browsing = true);
    try {
      await Future<void>.sync(widget.onBrowse);
    } catch (error) {
      if (mounted && generation == _browseGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update this path: $error')),
        );
      }
    } finally {
      if (mounted && generation == _browseGeneration) {
        setState(() => _browsing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final textStyle = (widget.isMobile
            ? SkotiqTypography.caption
            : SkotiqTypography.captionSm)
        .copyWith(
      color: widget.path.isEmpty ? colors.textMuted : colors.textPrimary,
    );
    final verticalPadding =
        widget.isMobile ? SkotiqTokens.spaceSm : SkotiqTokens.radiusSm;

    Widget pathContainer = _editable
        ? Container(
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: verticalPadding,
            ),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
              border: Border.all(color: colors.border),
            ),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              style: textStyle.copyWith(color: colors.textPrimary),
              maxLines: 1,
              // A path is longer than the box: keep the END visible, which is
              // the part that says which folder this is.
              textAlign: TextAlign.left,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: 'Not set',
                hintStyle: textStyle.copyWith(color: colors.textMuted),
              ),
              onSubmitted: (_) => _commit(),
            ),
          )
        // Read-only: no border, no fill, no placeholder box — this is a label,
        // and dressing it as an input only invites typing that goes nowhere.
        : Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: verticalPadding + 1,
            ),
            child: Text(
              widget.path.isEmpty ? 'Not set' : widget.path,
              style: textStyle,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          );

    final designWidth = widget.isMobile ? 140.0 : 180.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        // The browse button is the only way to change this path, so it must
        // never be the thing that gets pushed off the edge. When the row is
        // narrower than the design width can afford, fall back to the
        // flexible layout (path shrinks, button stays) instead of holding a
        // fixed 180 px box and overflowing.
        final flexible = widget.flexible ||
            (constraints.hasBoundedWidth &&
                constraints.maxWidth <
                    designWidth + _browseButtonAllowance + _spaceSm);
        return _buildRow(colors, pathContainer, designWidth, flexible);
      },
    );
  }

  /// Width reserved for the trailing browse button (icon + padding + border).
  static const double _browseButtonAllowance = 32;
  static const double _spaceSm = SkotiqTokens.spaceSm;

  Widget _buildRow(
    SkotiqColors colors,
    Widget pathContainer,
    double designWidth,
    bool flexible,
  ) {
    if (!flexible) {
      pathContainer = SizedBox(
        width: designWidth,
        child: pathContainer,
      );
    }

    return Row(
      mainAxisSize: flexible ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (flexible) Expanded(child: pathContainer) else pathContainer,
        const SizedBox(width: SkotiqTokens.spaceSm),
        GestureDetector(
          onTap: _browsing ? null : _browse,
          child: Container(
            padding: EdgeInsets.all(
                widget.isMobile ? SkotiqTokens.spaceSm : SkotiqTokens.radiusSm),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
              border: Border.all(color: colors.border),
            ),
            child: _browsing
                ? SizedBox.square(
                    dimension: widget.isMobile
                        ? SkotiqTokens.iconSm
                        : SkotiqTokens.iconXs,
                    child: SkotiqSpinner(
                        size: widget.isMobile
                            ? SkotiqTokens.iconSm
                            : SkotiqTokens.iconXs,
                        color: colors.primary),
                  )
                : Icon(
                    LucideIcons.folderOpen,
                    size: widget.isMobile
                        ? SkotiqTokens.iconSm
                        : SkotiqTokens.iconXs,
                    color: colors.textSecondary,
                  ),
          ),
        ),
      ],
    );
  }
}

/// A clickable link-style button with an icon and label.
