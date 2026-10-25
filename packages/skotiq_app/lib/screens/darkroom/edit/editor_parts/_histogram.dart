part of '../darkroom_editor.dart';

/// Bins across the display range.
const int _kHistogramBins = 64;

/// One line per channel of the preview: the share of pixels at each display
/// level.
///
/// Read from the preview the screen shows, so it describes exactly the pixels
/// on screen — the stretched color at the preview's level. A color image gets
/// a red, a green and a blue line; three lines that sit on one another over
/// the sky are a neutral background, and a line running into the right edge is
/// clipping in that channel.
@immutable
class DarkroomHistogram {
  /// Per channel, the share of pixels (0-1) in each bin.
  final List<List<double>> channels;

  /// Per channel, the share of pixels at full scale.
  final List<double> clipped;

  const DarkroomHistogram({required this.channels, required this.clipped});

  /// The histogram of [rgba] (RGBA8, row-major), one channel when [isColor]
  /// is false.
  factory DarkroomHistogram.of(Uint8List rgba, {required bool isColor}) {
    final count = isColor ? 3 : 1;
    final bins =
        List.generate(count, (_) => List<double>.filled(_kHistogramBins, 0));
    final full = List<double>.filled(count, 0);
    final pixels = rgba.length ~/ 4;
    for (var i = 0; i < pixels; i++) {
      for (var c = 0; c < count; c++) {
        final v = rgba[i * 4 + c];
        bins[c][v * _kHistogramBins ~/ 256] += 1;
        if (v == 255) full[c] += 1;
      }
    }
    final scale = pixels == 0 ? 0.0 : 1.0 / pixels;
    return DarkroomHistogram(
      channels: [
        for (final b in bins) [for (final v in b) v * scale],
      ],
      clipped: [for (final v in full) v * scale],
    );
  }

  /// The largest bin share across every channel.
  double get peak =>
      channels.expand((c) => c).fold<double>(0, (a, b) => a > b ? a : b);
}

class _DarkroomHistogramCard extends StatefulWidget {
  final DarkroomPreviewImage preview;

  const _DarkroomHistogramCard({required this.preview});

  @override
  State<_DarkroomHistogramCard> createState() => _DarkroomHistogramCardState();
}

class _DarkroomHistogramCardState extends State<_DarkroomHistogramCard> {
  /// The histogram and the buffer it was counted from: the panel rebuilds on
  /// every scroll, and a preview's pixels are counted once.
  Uint8List? _countedFrom;
  DarkroomHistogram? _histogram;

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final colors = SkotiqColors.of(context);
    if (!identical(_countedFrom, preview.rgba) || _histogram == null) {
      _countedFrom = preview.rgba;
      _histogram = DarkroomHistogram.of(preview.rgba, isColor: preview.isColor);
    }
    final histogram = _histogram!;
    final names =
        preview.isColor ? const ['Red', 'Green', 'Blue'] : const ['Gray'];
    final lineColors = preview.isColor
        ? [
            SkotiqChartColors.forTheme(SkotiqChartColors.seriesRed, colors),
            SkotiqChartColors.forTheme(SkotiqChartColors.seriesGreen, colors),
            SkotiqChartColors.forTheme(SkotiqChartColors.seriesBlue, colors),
          ]
        : [colors.textSecondary];
    final clipped = [
      for (var c = 0; c < names.length; c++)
        if (histogram.clipped[c] >= 0.0005)
          '${names[c]} ${(histogram.clipped[c] * 100).toStringAsFixed(1)}%',
    ];
    final summary = preview.isColor
        ? 'Histogram of the preview, one line per color channel.'
        : 'Histogram of the preview.';
    return Semantics(
      label: '$summary '
          '${clipped.isEmpty ? 'No channel is clipped at full scale.' : 'Clipped at full scale: ${clipped.join(', ')}.'}',
      container: true,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Histogram',
            style:
                SkotiqTypography.labelSm.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          SizedBox(
            height: 140,
            child: CustomPaint(
              size: Size.infinite,
              painter: _HistogramPainter(
                histogram: histogram,
                lineColors: lineColors,
                axisColor: colors.border,
                labelStyle: SkotiqTypography.captionSm.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Wrap(
            spacing: SkotiqTokens.spaceMd,
            runSpacing: SkotiqTokens.spaceXs,
            children: [
              for (var c = 0; c < names.length; c++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 10, height: 2, color: lineColors[c]),
                    const SizedBox(width: SkotiqTokens.spaceXs),
                    Text(
                      names[c],
                      style: SkotiqTypography.captionSm.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (clipped.isNotEmpty) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            Text(
              'At full scale: ${clipped.join(', ')} of pixels.',
              style: SkotiqTypography.captionSm.copyWith(color: colors.warning),
            ),
          ],
        ],
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  final DarkroomHistogram histogram;
  final List<Color> lineColors;
  final Color axisColor;
  final TextStyle labelStyle;

  _HistogramPainter({
    required this.histogram,
    required this.lineColors,
    required this.axisColor,
    required this.labelStyle,
  });

  TextPainter _label(String text) => TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr)
    ..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final peak = histogram.peak;
    final yTop = _label('${(peak * 100).toStringAsFixed(1)}%');
    final yZero = _label('0%');
    final yTitle = _label('Pixels');
    final xTitle = _label('Display level');
    final left = [yTop.width, yZero.width, yTitle.width]
            .reduce((a, b) => a > b ? a : b) +
        6;
    final bottom = yZero.height + xTitle.height + 4;
    final plot = Rect.fromLTRB(
      left,
      yTitle.height + yTop.height / 2 + 4,
      size.width - 4,
      size.height - bottom,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    final axis = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, axis);
    canvas.drawLine(plot.bottomLeft, plot.topLeft, axis);

    yTitle.paint(canvas, Offset.zero);
    yTop.paint(
        canvas, Offset(left - 4 - yTop.width, plot.top - yTop.height / 2));
    yZero.paint(
        canvas, Offset(left - 4 - yZero.width, plot.bottom - yZero.height / 2));
    for (final (value, text) in [(0.0, '0'), (0.5, '0.5'), (1.0, '1')]) {
      final x = plot.left + value * plot.width;
      canvas.drawLine(Offset(x, plot.bottom), Offset(x, plot.bottom + 3), axis);
      final label = _label(text);
      final dx = (x - label.width / 2)
          .clamp(plot.left - label.width / 2, size.width - label.width);
      label.paint(canvas, Offset(dx, plot.bottom + 3));
    }
    xTitle.paint(
      canvas,
      Offset(plot.center.dx - xTitle.width / 2, size.height - xTitle.height),
    );

    if (peak <= 0) return;
    for (var c = 0; c < histogram.channels.length; c++) {
      final bins = histogram.channels[c];
      final path = Path();
      for (var i = 0; i < bins.length; i++) {
        final x = plot.left + (i + 0.5) / bins.length * plot.width;
        final y = plot.bottom - bins[i] / peak * plot.height;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = lineColors[c]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) =>
      old.histogram != histogram ||
      old.axisColor != axisColor ||
      old.lineColors != lineColors;
}
