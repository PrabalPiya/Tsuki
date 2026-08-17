import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../features/discover/presentation/discover_screen.dart';

class MainShell extends ConsumerWidget {
  const MainShell({
    super.key,
    required this.navigationShell,
  });

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(
          18,
          20,
          18,
          10,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.glass,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Color(0x52000000),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: NavigationBar(
              height: 58,
              labelBehavior:
                  NavigationDestinationLabelBehavior.alwaysHide,
              selectedIndex: navigationShell.currentIndex,

              onDestinationSelected: (index) {
                final currentIndex =
                    navigationShell.currentIndex;

                const discoverIndex = 1;

                final enteringDiscover =
                    index == discoverIndex &&
                    currentIndex != discoverIndex;

                // Only reset Discover when entering it
                // from another MAIN navigation tab.
                //
                // Home -> Discover
                // Search -> Discover
                // Library -> Discover
                //
                // This does NOT happen when:
                //
                // Trending -> Popular
                // Popular -> Top Rated
                // manga details -> Back
                // tapping Discover while already on Discover
                if (enteringDiscover) {
                  ref
                      .read(
                        discoverResetProvider.notifier,
                      )
                      .state++;
                }

                navigationShell.goBranch(
                  index,
                  initialLocation:
                      index == currentIndex,
                );
              },

              destinations: const [
                NavigationDestination(
                  icon: Icon(
                    Icons.home_outlined,
                  ),
                  selectedIcon: Icon(
                    Icons.home_rounded,
                  ),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(
                    Icons.explore_outlined,
                  ),
                  selectedIcon: Icon(
                    Icons.explore_rounded,
                  ),
                  label: 'Discover',
                ),
                NavigationDestination(
                  icon: Icon(
                    Icons.search_rounded,
                  ),
                  selectedIcon: Icon(
                    Icons.manage_search_rounded,
                  ),
                  label: 'Search',
                ),
                NavigationDestination(
                  icon: Icon(
                    Icons.bookmarks_outlined,
                  ),
                  selectedIcon: Icon(
                    Icons.bookmarks_rounded,
                  ),
                  label: 'Library',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}