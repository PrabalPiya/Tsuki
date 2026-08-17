import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/theme/app_theme.dart';

class MainShell extends StatelessWidget {
  const MainShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;
  @override
  Widget build(BuildContext context) => Scaffold(
      body: navigationShell,
      bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(18, 20, 18, 10),
          child: DecoratedBox(
              decoration: BoxDecoration(
                  color: AppColors.glass,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x52000000),
                        blurRadius: 20,
                        offset: Offset(0, 10))
                  ]),
              child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: NavigationBar(
                      height: 58,
                      labelBehavior:
                          NavigationDestinationLabelBehavior.alwaysHide,
                      selectedIndex: navigationShell.currentIndex,
                      onDestinationSelected: (index) =>
                          navigationShell.goBranch(index,
                              initialLocation:
                                  index == navigationShell.currentIndex),
                      destinations: const [
                        NavigationDestination(
                            icon: Icon(Icons.home_outlined),
                            selectedIcon: Icon(Icons.home_rounded),
                            label: 'Home'),
                        NavigationDestination(
                            icon: Icon(Icons.explore_outlined),
                            selectedIcon: Icon(Icons.explore_rounded),
                            label: 'Discover'),
                        NavigationDestination(
                            icon: Icon(Icons.search_rounded),
                            selectedIcon: Icon(Icons.manage_search_rounded),
                            label: 'Search'),
                        NavigationDestination(
                            icon: Icon(Icons.bookmarks_outlined),
                            selectedIcon: Icon(Icons.bookmarks_rounded),
                            label: 'Library'),
                      ])))));
}
