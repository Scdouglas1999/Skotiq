/// What a `/darkroom` location asks for: a tab, and inside it a target, a
/// view, a master, a recipe or a pass.
///
/// [query] writes the parameters and [DarkroomRoute.fromUri] reads them back,
/// so their names live in this file alone.
library;

import 'package:flutter/widgets.dart';

/// The four tabs of the Darkroom screen, in header order.
enum DarkroomTab {
  targets,
  calibration,
  edit,
  activity;

  String get label => switch (this) {
        DarkroomTab.targets => 'Targets',
        DarkroomTab.calibration => 'Calibration',
        DarkroomTab.edit => 'Edit',
        DarkroomTab.activity => 'Activity',
      };

  static DarkroomTab? parse(String? value) {
    for (final tab in values) {
      if (tab.name == value) return tab;
    }
    return null;
  }
}

/// The view a target opens on inside the Targets tab.
enum DarkroomTargetView { detail, framing }

@immutable
class DarkroomRoute {
  const DarkroomRoute({
    this.tab = DarkroomTab.targets,
    this.target,
    this.view = DarkroomTargetView.detail,
    this.masterId,
    this.recipeId,
    this.passRunId,
  });

  final DarkroomTab tab;

  /// The target key, as `loadDarkroomTargets` and the build jobs name it.
  final String? target;
  final DarkroomTargetView view;
  final int? masterId;
  final int? recipeId;
  final String? passRunId;

  /// Reads a location. A link without `tab` keeps its old meaning: a master
  /// or a recipe opens Edit, a pass opens Activity, anything else Targets.
  factory DarkroomRoute.fromUri(Uri uri) {
    final q = uri.queryParameters;
    int? id(String key) {
      final value = q[key];
      return value == null ? null : int.tryParse(value);
    }

    final masterId = id('master');
    final recipeId = id('recipe');
    final pass = q['pass'];
    final passRunId = pass == null || pass.isEmpty ? null : pass;
    final target = q['target']?.trim();
    final tab = DarkroomTab.parse(q['tab']) ??
        (masterId != null || recipeId != null
            ? DarkroomTab.edit
            : (passRunId != null ? DarkroomTab.activity : DarkroomTab.targets));
    final hasTarget = target != null && target.isNotEmpty;
    return DarkroomRoute(
      tab: tab,
      target: hasTarget ? target : null,
      view: hasTarget && q['view'] == 'framing'
          ? DarkroomTargetView.framing
          : DarkroomTargetView.detail,
      masterId: masterId,
      recipeId: recipeId,
      passRunId: passRunId,
    );
  }

  /// The route an editor scope stands for.
  factory DarkroomRoute.forScope(DarkroomScope scope) => DarkroomRoute(
        tab: scope.passRunId != null
            ? DarkroomTab.activity
            : (scope.isEmpty ? DarkroomTab.targets : DarkroomTab.edit),
        masterId: scope.masterId,
        recipeId: scope.recipeId,
        passRunId: scope.passRunId,
      );

  /// What the existing editor and pass page are scoped to.
  DarkroomScope get scope => DarkroomScope(
      recipeId: recipeId, masterId: masterId, passRunId: passRunId);

  /// The query that reopens this route.
  Map<String, String> get query => {
        'tab': tab.name,
        if (target != null) 'target': target!,
        if (target != null && view == DarkroomTargetView.framing)
          'view': 'framing',
        if (masterId != null) 'master': '$masterId',
        if (recipeId != null) 'recipe': '$recipeId',
        if (passRunId != null) 'pass': passRunId!,
      };

  @override
  bool operator ==(Object other) =>
      other is DarkroomRoute &&
      other.tab == tab &&
      other.target == target &&
      other.view == view &&
      other.masterId == masterId &&
      other.recipeId == recipeId &&
      other.passRunId == passRunId;

  @override
  int get hashCode =>
      Object.hash(tab, target, view, masterId, recipeId, passRunId);

  @override
  String toString() => 'DarkroomRoute($query)';
}

/// Hands the parsed route to the tab bodies, whose constructors take no
/// arguments.
class DarkroomRouteScope extends InheritedWidget {
  const DarkroomRouteScope({
    super.key,
    required this.route,
    required super.child,
  });

  final DarkroomRoute route;

  /// The route of the enclosing Darkroom screen, or the default Targets route
  /// when a tab body is shown on its own.
  static DarkroomRoute of(BuildContext context) =>
      maybeOf(context) ?? const DarkroomRoute();

  /// The route of the enclosing Darkroom screen, or null outside one.
  static DarkroomRoute? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DarkroomRouteScope>()?.route;

  @override
  bool updateShouldNotify(DarkroomRouteScope oldWidget) =>
      oldWidget.route != route;
}

/// What the `/darkroom` route was asked to open.
///
/// Both ids are nullable and both may be absent: a deep link that names neither
/// (or names one that is not an integer) resolves to [DarkroomScope.empty],
/// which the screen renders as an empty state rather than crashing on a bad
/// link. It is the family key, so it carries value equality.
@immutable
class DarkroomScope {
  /// `recipes.id` to open, or null when the link named a master instead.
  final int? recipeId;

  /// `integrated_masters.id` whose recipes are offered, or null.
  final int? masterId;

  /// The run id of a pass to show, or null.
  final String? passRunId;

  const DarkroomScope({this.recipeId, this.masterId, this.passRunId});

  /// A pass, live or recorded.
  const DarkroomScope.pass(String runId) : this(passRunId: runId);

  const DarkroomScope.recipe(int id) : this(recipeId: id);

  /// A master opened by row id; its newest recipe is loaded, and when it has
  /// none the screen offers to create one.
  const DarkroomScope.master(int id) : this(masterId: id);

  /// The link named nothing this screen can open.
  const DarkroomScope.empty() : this();

  bool get isEmpty => recipeId == null && masterId == null && passRunId == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DarkroomScope &&
          other.recipeId == recipeId &&
          other.masterId == masterId &&
          other.passRunId == passRunId;

  @override
  int get hashCode => Object.hash(recipeId, masterId, passRunId);

  @override
  String toString() =>
      'DarkroomScope(recipe=$recipeId, master=$masterId, pass=$passRunId)';
}
