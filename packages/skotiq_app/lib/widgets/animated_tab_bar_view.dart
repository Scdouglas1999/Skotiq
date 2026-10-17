import 'package:flutter/material.dart';

/// An animated TabBarView with smooth transitions between tabs
class AnimatedTabBarView extends StatefulWidget {
  final TabController controller;
  final List<Widget> children;
  final Duration animationDuration;
  final Curve animationCurve;

  const AnimatedTabBarView({
    super.key,
    required this.controller,
    required this.children,
    this.animationDuration = const Duration(milliseconds: 300),
    this.animationCurve = Curves.easeInOutCubic,
  });

  @override
  State<AnimatedTabBarView> createState() => _AnimatedTabBarViewState();
}

class _AnimatedTabBarViewState extends State<AnimatedTabBarView>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  int _previousIndex = 0;

  @override
  void initState() {
    super.initState();
    _previousIndex = widget.controller.index;
    _animationController = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: widget.animationCurve,
    ));

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0.02, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: widget.animationCurve,
    ));

    widget.controller.addListener(_onTabChanged);
    _animationController.forward();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTabChanged);
    _animationController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (widget.controller.index != _previousIndex) {
      setState(() {
        _previousIndex = widget.controller.index;
        _animationController.reset();
        _animationController.forward();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: TabBarView(
          controller: widget.controller,
          physics: const NeverScrollableScrollPhysics(),
          children: widget.children,
        ),
      ),
    );
  }
}
