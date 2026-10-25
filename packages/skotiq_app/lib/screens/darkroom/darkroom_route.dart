/// What a `/darkroom` location asks for: a tab, and inside it a target, a
/// view, a master, a recipe or a pass.
///
/// Every Darkroom link is built by the helpers in `darkroom_navigation.dart`
/// and read back here, so the parameter names live in exactly two places.
library;

import 'package:flutter/widgets.dart';

import 'darkroom_controller.dart' show DarkroomScope;

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

/// A parsed `/darkroom` location.
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

  /// The location that reopens this route.
  String get location {
    final q = <String, String>{
      'tab': tab.name,
      if (target != null) 'target': target!,
      if (target != null && view == DarkroomTargetView.framing)
        'view': 'framing',
      if (masterId != null) 'master': '$masterId',
      if (recipeId != null) 'recipe': '$recipeId',
      if (passRunId != null) 'pass': passRunId!,
    };
    return Uri(path: '/darkroom', queryParameters: q).toString();
  }

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
  String toString() => 'DarkroomRoute($location)';
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
