// Action menu rows, stat rows and the linear RGBA renderers.
part of '../stack_result_screen.dart';

/// Export/share actions, all of them surfaced through the header's single
/// overflow menu (05 §5: a page header carries at most two actions, and the
/// other one here is "Refine in Darkroom").
enum _StackResultAction { png, jpeg, shareCard, astroBin, darkroom }

/// Icon + label row for a [_StackResultAction] popup-menu entry.
///
/// [reason] is the second line a DISABLED entry carries: a popup item has no
/// tooltip to hang an explanation on, so the reason is part of the row or it is
/// nowhere.
class _ActionMenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? reason;

  const _ActionMenuRow({required this.icon, required this.label, this.reason});

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final why = reason;
    return Row(
      children: [
        Icon(icon, size: SkotiqTokens.iconSm, color: colors.textSecondary),
        const SizedBox(width: SkotiqTokens.spaceMd),
        // Flexible, not min-sized: the menu is 256px wide on a phone and a
        // label that grows by a word must wrap rather than overflow the row.
        // Flexible, not min-sized: the menu is 256px wide on a phone and a
        // label that grows by a word must wrap rather than overflow the row.
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              if (why != null)
                Text(
                  why,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The linear-stretch pixel loops, top-level so they can run in a worker
/// isolate via `Isolate.run` — the closure that calls them captures only the
/// buffer and the pixel count, both of which cross an isolate boundary.
///
/// A 6000x4000 master is 24 million pixels: two full passes plus a 96 MB
/// allocation. On the UI isolate, inside `build`, that is a frame stall the
/// operator sees as the app hanging.
/// Linear min/max normalisation of a u16 mono buffer to grayscale RGBA.
Uint8List renderLinearGrayRgba(Uint16List mono) {
  var min = 65535;
  var max = 0;
  for (final v in mono) {
    if (v < min) min = v;
    if (v > max) max = v;
  }
  final span = max - min;
  final out = Uint8List(mono.length * 4);
  for (var i = 0; i < mono.length; i++) {
    final g = span <= 0 ? 0 : (((mono[i] - min) * 255) ~/ span);
    final o = i * 4;
    out[o] = g;
    out[o + 1] = g;
    out[o + 2] = g;
    out[o + 3] = 255;
  }
  return out;
}

/// Per-channel linear min/max normalisation of an interleaved RGB16 buffer to
/// RGBA. Each channel is stretched against its own extent so the colour
/// balance is preserved rather than dominated by the brightest channel.
Uint8List renderLinearColorRgba(Uint16List rgb, int pixelCount) {
  var rMin = 65535, gMin = 65535, bMin = 65535;
  var rMax = 0, gMax = 0, bMax = 0;
  for (var i = 0; i < pixelCount; i++) {
    final base = i * 3;
    final r = rgb[base];
    final g = rgb[base + 1];
    final b = rgb[base + 2];
    if (r < rMin) rMin = r;
    if (r > rMax) rMax = r;
    if (g < gMin) gMin = g;
    if (g > gMax) gMax = g;
    if (b < bMin) bMin = b;
    if (b > bMax) bMax = b;
  }
  final rSpan = rMax - rMin;
  final gSpan = gMax - gMin;
  final bSpan = bMax - bMin;
  final out = Uint8List(pixelCount * 4);
  for (var i = 0; i < pixelCount; i++) {
    final base = i * 3;
    final o = i * 4;
    out[o] = rSpan <= 0 ? 0 : (((rgb[base] - rMin) * 255) ~/ rSpan);
    out[o + 1] = gSpan <= 0 ? 0 : (((rgb[base + 1] - gMin) * 255) ~/ gSpan);
    out[o + 2] = bSpan <= 0 ? 0 : (((rgb[base + 2] - bMin) * 255) ~/ bSpan);
    out[o + 3] = 255;
  }
  return out;
}
