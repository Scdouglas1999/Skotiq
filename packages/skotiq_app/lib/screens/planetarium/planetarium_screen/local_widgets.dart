part of '../planetarium_screen.dart';

/// Wraps the planetarium content in a luminance→red color filter when
/// night-vision mode is enabled, so the sky texture AND all overlays/HUD go
/// red to preserve dark adaptation at the eyepiece.
///
/// [ColorFiltered] does not capture pointer input, so gestures/hit-testing on
/// the underlying sky view are unaffected.
class _NightVisionFilter extends StatelessWidget {
  final bool enabled;
  final Widget child;

  const _NightVisionFilter({required this.enabled, required this.child});

  /// Collapse every pixel to a red-only output whose intensity tracks the
  /// source luminance (Rec. 601 weights), killing the green and blue channels.
  ///
  /// Row layout is [R G B A | bias] per output channel:
  ///   R_out = 0.299*R + 0.587*G + 0.114*B   (luminance → red)
  ///   G_out = 0
  ///   B_out = 0
  ///   A_out = A   (preserve alpha)
  static const ColorFilter _redLuminance = ColorFilter.matrix(<double>[
    0.299, 0.587, 0.114, 0, 0, //
    0, 0, 0, 0, 0, //
    0, 0, 0, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return ColorFiltered(
      colorFilter: _redLuminance,
      child: child,
    );
  }
}

/// Help overlay showing all keyboard shortcuts.
///
/// Rendered over the planetarium sky canvas inside [_NightVisionFilter], so its
/// colors are a deliberate fixed dark HUD palette (absolute white/black + the
/// `0xFF1E1E2E`/`0xFF00E676` cosmetic accents) rather than theme-relative
/// semantics: night-vision red adaptation is applied by the enclosing filter.
class _KeyboardShortcutsOverlay extends StatelessWidget {
  final VoidCallback onDismiss;

  const _KeyboardShortcutsOverlay({required this.onDismiss});

  void _consumeTap() {
    // Inner overlay absorbs taps so the outer scrim alone dismisses.
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onDismiss,
      child: Container(
        // absolute: dim scrim over the planetarium sky canvas (night-vision
        // red conversion is applied by the enclosing _NightVisionFilter)
        color: Colors.black.withValues(alpha: 0.7),
        child: Center(
          child: GestureDetector(
            onTap: _consumeTap,
            child: Container(
              constraints: AdaptiveDialogConstraints.hybrid(
                context,
                designMaxWidth: 420,
              ),
              margin: const EdgeInsets.all(32),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E2E),
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline8),
                // absolute: fixed HUD palette (see class doc)
                border: Border.all(color: Colors.white24),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Keyboard Shortcuts',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(SkotiqIcons.close,
                            size: 18, color: Colors.white54),
                        onPressed: onDismiss,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const _ShortcutSection(title: 'Navigation', shortcuts: [
                    ('Arrow Keys', 'Pan view'),
                    ('+ / -', 'Zoom in / out'),
                    ('H', 'Home (reset view)'),
                  ]),
                  const SizedBox(height: 12),
                  const _ShortcutSection(title: 'Overlays', shortcuts: [
                    ('G', 'Toggle coordinate grid'),
                    ('C', 'Toggle constellation lines'),
                    ('E', 'Toggle ecliptic'),
                    ('F', 'Toggle FOV overlay'),
                    ('M', 'Toggle mini-map'),
                  ]),
                  const SizedBox(height: 12),
                  const _ShortcutSection(title: 'Time', shortcuts: [
                    ('N', 'Jump to now (real-time)'),
                    ('Space', 'Play / Pause time'),
                  ]),
                  const SizedBox(height: 12),
                  const _ShortcutSection(title: 'Other', shortcuts: [
                    ('Escape', 'Deselect / close overlay'),
                    ('?', 'Show this help'),
                  ]),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      'Press Escape or ? to close',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Row of the keyboard-shortcuts overlay. Shares the absolute HUD palette of
/// [_KeyboardShortcutsOverlay] (white-on-dark over the sky canvas, red-adapted
/// by the enclosing [_NightVisionFilter]); colors here are intentionally not
/// theme-relative.
class _ShortcutSection extends StatelessWidget {
  final String title;
  final List<(String, String)> shortcuts;

  const _ShortcutSection({required this.title, required this.shortcuts});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: SkotiqTypography.labelStrong
              .copyWith(color: const Color(0xFF00E676)),
        ),
        const SizedBox(height: 6),
        ...shortcuts.map((s) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 100,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(
                            SkotiqTokens.radiusInline4),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.15)),
                      ),
                      child: Text(
                        s.$1,
                        style: const TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          fontWeight: FontWeight.w500,
                          color: Colors.white70,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    s.$2,
                    style: const TextStyle(
                      fontSize: SkotiqTypography.fontSize13,
                      color: Colors.white60,
                    ),
                  ),
                ],
              ),
            )),
      ],
    );
  }
}
