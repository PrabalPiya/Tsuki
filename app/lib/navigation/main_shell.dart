import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/state/providers.dart';
import '../core/theme/app_theme.dart';
import '../features/discover/presentation/discover_screen.dart';

class MainShell extends ConsumerWidget {
  const MainShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentIndex = navigationShell.currentIndex;

    return Scaffold(
      body: navigationShell,

      bottomNavigationBar: SafeArea(
        top: false,

        child: Container(
          height: 58,

          decoration: BoxDecoration(
            color: AppColors.background.withValues(alpha: 0.98),

            border: Border(
              top: BorderSide(
                color: AppColors.outline.withValues(alpha: 0.26),
                width: 0.5,
              ),
            ),
          ),

          child: Row(
            children: [
              Expanded(
                child: _NavItem(
                  label: 'Home',
                  icon: Icons.home_outlined,
                  selectedIcon: Icons.home_rounded,
                  selected: currentIndex == 0,
                  onTap: () {
                    _selectDestination(ref, 0);
                  },
                ),
              ),

              Expanded(
                child: _NavItem(
                  label: 'Discover',
                  icon: Icons.auto_awesome_outlined,
                  selectedIcon: Icons.auto_awesome_rounded,
                  selected: currentIndex == 1,
                  onTap: () {
                    _selectDestination(ref, 1);
                  },
                ),
              ),

              Expanded(
                child: _NavItem(
                  label: 'Search',
                  icon: Icons.search_rounded,
                  selectedIcon: Icons.search_rounded,
                  selected: currentIndex == 2,
                  onTap: () {
                    _selectDestination(ref, 2);
                  },
                ),
              ),

              Expanded(
                child: _NavItem(
                  label: 'Library',
                  icon: Icons.bookmark_border_rounded,
                  selectedIcon: Icons.bookmark_rounded,
                  selected: currentIndex == 3,
                  onTap: () {
                    _selectDestination(ref, 3);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectDestination(WidgetRef ref, int index) {
    final currentIndex = navigationShell.currentIndex;

    const discoverIndex = 1;
    const searchIndex = 2;

    final enteringDiscover =
        index == discoverIndex && currentIndex != discoverIndex;
    final leavingSearch = currentIndex == searchIndex && index != searchIndex;

    if (enteringDiscover) {
      ref.read(discoverResetProvider.notifier).state++;
    }

    if (leavingSearch) {
      ref.read(searchProvider.notifier).reset();
    }

    navigationShell.goBranch(index, initialLocation: index == currentIndex);
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;

  final bool selected;

  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 1.08,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 45,
      ),

      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.08,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 55,
      ),
    ]).animate(_controller);
  }

  @override
  void didUpdateWidget(covariant _NavItem oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!oldWidget.selected && widget.selected) {
      _controller.forward(from: 0.0);
    }
  }

  void _handleTap() {
    if (!widget.selected) {
      HapticFeedback.selectionClick();
    }

    widget.onTap();
  }

  @override
  void dispose() {
    _controller.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label,
      button: true,
      selected: widget.selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: Center(
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              child: ExcludeSemantics(
                child: Icon(
                  widget.selected ? widget.selectedIcon : widget.icon,
                  size: widget.selected ? 27 : 24,
                  color: widget.selected
                      ? AppColors.accent
                      : AppColors.muted.withValues(alpha: 0.78),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
