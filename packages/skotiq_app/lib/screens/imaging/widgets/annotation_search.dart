import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Search bar widget for filtering annotation objects by name or catalog ID.
class AnnotationSearchBar extends StatelessWidget {
  final ValueChanged<String> onChanged;

  const AnnotationSearchBar({
    super.key,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: SkotiqTextField(
        hint: 'Search objects...',
        prefixIcon: SkotiqIcons.search,
        onChanged: onChanged,
      ),
    );
  }
}
