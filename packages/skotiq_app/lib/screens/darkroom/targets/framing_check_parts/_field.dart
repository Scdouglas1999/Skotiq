part of '../framing_check.dart';

class _FieldLegend extends StatelessWidget {
  const _FieldLegend({required this.preview, required this.referenceName});

  final DarkroomRegistrationPreview preview;
  final String referenceName;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final style = SkotiqTypography.caption.copyWith(
      color: colors.textSecondary,
    );
    Widget box(Color c, double w) => Container(
          width: 14,
          height: 10,
          decoration: BoxDecoration(border: Border.all(color: c, width: w)),
        );
    Widget item(Widget mark, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            mark,
            const SizedBox(width: SkotiqTokens.spaceSm),
            Text(label, style: style)
          ],
        );
    return Wrap(
      spacing: SkotiqTokens.spaceXl,
      runSpacing: SkotiqTokens.spaceXs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        item(box(colors.textPrimary.withValues(alpha: .45), 1),
            "Each sub's footprint"),
        item(box(colors.warning, 1.5), 'Limits the common area'),
        item(box(colors.primary, 1.5), 'Kept after stacking'),
        Text(
          'Field: $referenceName, ${preview.width} × ${preview.height} px',
          style: SkotiqTypography.monoXs.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

/// The reference sub with every footprint, the common area and the subs that
/// limit it drawn over it.
class DarkroomFramingField extends ConsumerWidget {
  const DarkroomFramingField({
    super.key,
    required this.preview,
    required this.referenceImageId,
    required this.limiting,
    this.highlighted,
  });

  final DarkroomRegistrationPreview preview;
  final int? referenceImageId;

  /// Paths of the limiting subs to outline, most limiting first.
  final List<String> limiting;
  final String? highlighted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final id = referenceImageId;
    final image = id == null ? null : ref.watch(subThumbnailProvider(id));
    final retained = (preview.retainedArea * 100).toStringAsFixed(1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final aspect = preview.width / math.max(1, preview.height);
        var w = constraints.maxWidth;
        var h = w / aspect;
        if (h > constraints.maxHeight) {
          h = constraints.maxHeight;
          w = h * aspect;
        }
        return Center(
          child: Semantics(
            image: true,
            label: 'Reference field with ${preview.included.length} sub '
                'footprints. The area every sub covers keeps $retained '
                'percent of the field'
                '${limiting.isEmpty ? '' : '; ${limiting.length} subs limit it'}.',
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: colors.background),
                  if (image case AsyncData<Uint8List>(:final value))
                    Image.memory(
                      value,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    ),
                  CustomPaint(
                    painter: _FieldPainter(
                      preview: preview,
                      limiting: limiting,
                      highlighted: highlighted,
                      colors: colors,
                      labelStyle: SkotiqTypography.monoXs,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FieldPainter extends CustomPainter {
  _FieldPainter({
    required this.preview,
    required this.limiting,
    required this.highlighted,
    required this.colors,
    required this.labelStyle,
  });

  final DarkroomRegistrationPreview preview;
  final List<String> limiting;
  final String? highlighted;
  final SkotiqColors colors;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / preview.width;
    final sy = size.height / preview.height;
    Offset map(Offset g) => Offset(g.dx * sx, g.dy * sy);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final crop = preview.crop;
    final shade = Paint()..color = colors.background.withValues(alpha: .66);
    Rect? cropRect;
    if (crop == null) {
      canvas.drawRect(Offset.zero & size, shade);
    } else {
      cropRect = Rect.fromPoints(
        map(Offset(crop[0].toDouble(), crop[1].toDouble())),
        map(Offset(crop[2].toDouble(), crop[3].toDouble())),
      );
      canvas.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(Offset.zero & size)
          ..addRect(cropRect),
        shade,
      );
    }
    Path outline(List<Offset> corners) =>
        Path()..addPolygon([for (final c in corners) map(c)], true);
    final footprint = Paint()
      ..color = colors.textPrimary.withValues(
        alpha: preview.included.length > 40 ? .12 : .32,
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final f in preview.included) {
      if (f.corners == null || limiting.contains(f.path)) continue;
      canvas.drawPath(outline(f.corners!), footprint);
    }
    void label(String text, Offset at, Color color, {bool right = false}) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle.copyWith(color: color)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, right ? at.translate(-tp.width, 0) : at);
    }

    for (final path in limiting.reversed) {
      final f = preview.frames.where((f) => f.path == path).firstOrNull;
      if (f?.corners == null) continue;
      final emphasized = path == highlighted;
      final poly = outline(f!.corners!);
      canvas.drawPath(
        poly,
        Paint()
          ..color = colors.warning
          ..style = PaintingStyle.stroke
          ..strokeWidth = emphasized ? 3 : 1.5,
      );
      final b = poly.getBounds().intersect(Offset.zero & size);
      final named = highlighted == null ? path == limiting.first : emphasized;
      if (named && !b.isEmpty) {
        label(
          p.basenameWithoutExtension(path),
          Offset(b.left + 8, b.bottom - 20),
          colors.warning,
        );
      }
    }
    if (cropRect != null) {
      canvas.drawRect(
        cropRect,
        Paint()
          ..color = colors.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      label(
        'common area',
        cropRect.topRight.translate(-8, 8),
        colors.textPrimary,
        right: true,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FieldPainter old) =>
      old.preview != preview ||
      old.highlighted != highlighted ||
      old.colors != colors ||
      !_sameList(old.limiting, limiting);

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
