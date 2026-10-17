/// Preview board for the "Trails" mark: every motion at 256 / 64 / 32 / 24 /
/// 16 px in each tone, plus the tile, lockup, wordmark and spinner.
///
/// This is a reviewer entry point, not part of the shipped app. Run it from
/// a platform host — e.g. the desktop app:
///
/// ```sh
/// cd apps/desktop
/// flutter run -t ../../packages/skotiq_ui/example/brand_preview.dart -d linux
/// ```
library;

import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() => runApp(const BrandPreviewApp());

class BrandPreviewApp extends StatelessWidget {
  const BrandPreviewApp({super.key});

  static const _sizes = <double>[256, 64, 32, 24, 16];

  static const _motions = <(SkotiqMarkMotion, String)>[
    (SkotiqMarkMotion.draw, 'draw — once, on mount'),
    (SkotiqMarkMotion.loading, 'loading — 2.2 s loop'),
    (SkotiqMarkMotion.working, 'working — 2.6 s loop'),
    (SkotiqMarkMotion.none, 'none — still mark'),
  ];

  static const _tones = <(SkotiqMarkTone, String, Color)>[
    (SkotiqMarkTone.violet, 'violet', Color(0xFF0E0C16)),
    (SkotiqMarkTone.light, 'light (light ground)', Color(0xFFF3F1F8)),
    (SkotiqMarkTone.red, 'red (black ground)', Color(0xFF000000)),
    (SkotiqMarkTone.mono, 'mono', Color(0xFF0E0C16)),
  ];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: SkotiqTheme.dark,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF08070D),
        body: ListView(
          padding: const EdgeInsets.all(32),
          children: [
            for (final (motion, motionLabel) in _motions)
              _Section(
                title: motionLabel,
                rows: [
                  for (final (tone, toneLabel, ground) in _tones)
                    _SizeRow(
                      label: toneLabel,
                      ground: ground,
                      children: [
                        for (final size in _sizes)
                          _Cell(
                            caption: '${size.toInt()}',
                            ground: ground,
                            child: SkotiqMark(
                              size: size,
                              motion: motion,
                              tone: tone,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            const _Section(
              title: 'tile (app-icon ground)',
              rows: [
                _SizeRow(
                  label: 'violet / red',
                  children: [
                    _Cell(
                      caption: '256',
                      ground: Color(0xFF0E0C16),
                      child: SkotiqMark(size: 256, tile: true),
                    ),
                    _Cell(
                      caption: '64',
                      ground: Color(0xFF0E0C16),
                      child: SkotiqMark(size: 64, tile: true),
                    ),
                    _Cell(
                      caption: '256 red',
                      ground: Color(0xFF0E0C16),
                      child: SkotiqMark(
                        size: 256,
                        tile: true,
                        tone: SkotiqMarkTone.red,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const _Section(
              title: 'spinner',
              rows: [
                _SizeRow(
                  label: 'inline',
                  children: [
                    _Cell(
                      caption: '16',
                      ground: Color(0xFF0E0C16),
                      child: SkotiqSpinner(),
                    ),
                    _Cell(
                      caption: '24',
                      ground: Color(0xFF0E0C16),
                      child: SkotiqSpinner(size: 24),
                    ),
                    _Cell(
                      caption: '32',
                      ground: Color(0xFF0E0C16),
                      child: SkotiqSpinner(size: 32),
                    ),
                    _Cell(
                      caption: 'red',
                      ground: Color(0xFF000000),
                      child: SkotiqSpinner(color: Color(0xFFF0564A)),
                    ),
                  ],
                ),
              ],
            ),
            const _Section(
              title: 'wordmark + lockup',
              rows: [
                _SizeRow(
                  label: 'lockups',
                  children: [
                    _Cell(
                      caption: 'lockup 48',
                      ground: Color(0xFF0E0C16),
                      tall: true,
                      child: SkotiqLockup(markSize: 48),
                    ),
                    _Cell(
                      caption: 'lockup 24',
                      ground: Color(0xFF0E0C16),
                      tall: true,
                      child: SkotiqLockup(markSize: 24),
                    ),
                    _Cell(
                      caption: 'wordmark',
                      ground: Color(0xFF0E0C16),
                      tall: true,
                      child: SkotiqWordmark(
                        fontSize: 28,
                        color: Color(0xFFECE8F6),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows});

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFECE8F6),
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          ...rows,
        ],
      ),
    );
  }
}

class _SizeRow extends StatelessWidget {
  const _SizeRow({
    required this.label,
    required this.children,
    this.ground = const Color(0xFF0E0C16),
  });

  final String label;
  final List<Widget> children;
  final Color ground;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFFA49DB8), fontSize: 13),
            ),
          ),
          for (final child in children)
            Padding(padding: const EdgeInsets.only(right: 24), child: child),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.caption,
    required this.ground,
    required this.child,
    this.tall = false,
  });

  final String caption;
  final Color ground;
  final Widget child;
  final bool tall;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: ground,
            borderRadius: BorderRadius.circular(8),
          ),
          child: tall ? child : Center(child: child),
        ),
        const SizedBox(height: 6),
        Text(
          caption,
          style: const TextStyle(color: Color(0xFFA49DB8), fontSize: 11),
        ),
      ],
    );
  }
}
