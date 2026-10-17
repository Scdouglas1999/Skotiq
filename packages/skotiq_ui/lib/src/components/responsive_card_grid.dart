import 'package:flutter/material.dart';

import '../theme/skotiq_tokens.dart';

class ResponsiveCardGrid extends StatelessWidget {
  final List<Widget> children;
  final double minCardWidth;
  final double spacing;

  const ResponsiveCardGrid({
    super.key,
    required this.children,
    this.minCardWidth = 320,
    this.spacing = SkotiqTokens.spaceLg,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = (constraints.maxWidth / minCardWidth)
            .floor()
            .clamp(1, 4);

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: children.map((child) {
            final cardWidth =
                (constraints.maxWidth - (spacing * (crossAxisCount - 1))) /
                crossAxisCount;
            return SizedBox(width: cardWidth, child: child);
          }).toList(),
        );
      },
    );
  }
}
