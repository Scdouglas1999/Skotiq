// The plan column of Tonight: target, plan, steps, and coming up (or "The
// night" before a run).
//
// In the column modes the layout gives this slot a bounded height and the
// column scrolls on its own, the header staying put. In the single column
// the page scrolls, so the sections only size to their content.
import 'package:flutter/material.dart';

import '../night_control_layout.dart';
import 'coming_up_section.dart';
import 'plan_section.dart';
import 'steps_section.dart';
import 'target_section.dart';

/// The left slot of [NightControlLayout].
class NightLeftColumn extends StatefulWidget {
  const NightLeftColumn({super.key});

  @override
  State<NightLeftColumn> createState() => _NightLeftColumnState();
}

class _NightLeftColumnState extends State<NightLeftColumn> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const sections = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        NightTargetSection(),
        NightPlanSection(),
        NightStepsSection(),
        NightComingUpSection(),
      ],
    );
    final scrollsItself =
        NightControlDensity.maybeOf(context)?.slotsScrollThemselves ?? true;
    if (!scrollsItself) return sections;
    return Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        primary: false,
        child: sections,
      ),
    );
  }
}
