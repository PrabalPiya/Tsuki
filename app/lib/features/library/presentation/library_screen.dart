import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/manga.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/cover_art.dart';
import '../../../shared/widgets/logout_button.dart';

/* ===========================================================
 * LIBRARY PROVIDER
 * ========================================================= */

final libraryItemsProvider = Provider<List<Manga>>((ref) {
  final state = ref.watch(
    userLibraryProvider.select(
      (value) =>
          (bookmarks: value.bookmarks, bookmarkedManga: value.bookmarkedManga),
    ),
  );

  final repository = ref.watch(catalogProvider);

  final items = <Manga>[];

  for (final id in state.bookmarks) {
    try {
      final manga = repository.cached(id) ?? state.bookmarkedManga[id];

      if (manga != null && manga.isFriendlyContent) {
        repository.remember(manga);
        items.add(manga);
      }
    } catch (_) {
      // Keep loading other bookmarks.
    }
  }

  items.sort((a, b) => a.title.compareTo(b.title));

  return items;
});

/* ===========================================================
 * LIBRARY SCREEN
 * ========================================================= */

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  List<Manga> _lastItems = const <Manga>[];
  final Set<String> _selectedIds = <String>{};
  bool _selecting = false;

  void _startSelecting(String mangaId) {
    HapticFeedback.mediumImpact();
    setState(() {
      _selecting = true;
      _selectedIds
        ..clear()
        ..add(mangaId);
    });
  }

  void _stopSelecting() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelected(String mangaId) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_selectedIds.add(mangaId)) {
        _selectedIds.remove(mangaId);
      }
    });
  }

  void _toggleSelectAll(List<Manga> items) {
    HapticFeedback.selectionClick();
    final itemIds = items.map((manga) => manga.id).toSet();
    setState(() {
      if (_selectedIds.containsAll(itemIds)) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(itemIds);
      }
    });
  }

  void _removeSelected() {
    if (_selectedIds.isEmpty) return;

    final selectedIds = Set<String>.of(_selectedIds);
    HapticFeedback.mediumImpact();
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
    unawaited(
      ref.read(userLibraryProvider.notifier).removeBookmarks(selectedIds),
    );
  }

  @override
  Widget build(BuildContext context) {
    final libraryLoading = ref.watch(
      userLibraryProvider.select((state) => state.loading),
    );
    final freshItems = ref.watch(libraryItemsProvider);

    if (freshItems.isNotEmpty || !libraryLoading) {
      _lastItems = freshItems;
    }
    final items = freshItems;

    final visibleIds = items.map((manga) => manga.id).toSet();
    final staleSelectedIds = _selectedIds.difference(visibleIds);
    if (staleSelectedIds.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _selectedIds.removeAll(staleSelectedIds));
      });
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        backgroundColor: _selecting
            ? AppColors.surface.withValues(alpha: 0.92)
            : Colors.transparent,
        surfaceTintColor: Colors.transparent,

        leading: _selecting
            ? IconButton(
                onPressed: _stopSelecting,
                tooltip: 'Cancel selection',
                icon: const Icon(Icons.close_rounded),
              )
            : null,

        title: Text(_selecting ? '${_selectedIds.length} selected' : 'Library'),

        actions: _selecting
            ? [
                IconButton(
                  onPressed: () => _toggleSelectAll(items),
                  tooltip: _selectedIds.length == items.length
                      ? 'Clear selection'
                      : 'Select all',
                  icon: Icon(
                    _selectedIds.length == items.length
                        ? Icons.deselect_rounded
                        : Icons.select_all_rounded,
                  ),
                ),
                const SizedBox(width: 8),
              ]
            : [
                IconButton(
                  onPressed: () => context.push('/migration'),
                  tooltip: 'Import browser library',
                  icon: const Icon(Icons.move_to_inbox_outlined),
                ),
                const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: LogoutButton(),
                ),
              ],
      ),

      body: Stack(
        children: [
          Positioned.fill(child: _buildContent(libraryLoading, items)),

          AnimatedPositioned(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            left: 0.0,
            right: 0.0,
            bottom: _selecting ? 24.0 : -90.0,
            child: IgnorePointer(
              ignoring: !_selecting || _selectedIds.isEmpty,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 80),
                opacity: _selecting ? 1.0 : 0.0,
                child: _RemoveButton(
                  count: _selectedIds.length,
                  onPressed: _removeSelected,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(bool libraryLoading, List<Manga> items) {
    if (libraryLoading && _lastItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (items.isEmpty) {
      return const _LibraryMessage(
        icon: Icons.bookmark_border_rounded,
        title: 'Your library is empty',
        message: 'Manga you bookmark will appear here.',
      );
    }

    return _AnimatedLibraryGrid(
      items: items,
      itemBuilder: (context, manga, exiting) {
        return _LibraryItem(
          manga: manga,
          selecting: _selecting,
          selected: _selectedIds.contains(manga.id),
          onSelected: () => _toggleSelected(manga.id),
          onStartSelecting: () => _startSelecting(manga.id),
        );
      },
    );
  }
}

class _AnimatedLibraryGrid extends StatelessWidget {
  const _AnimatedLibraryGrid({required this.items, required this.itemBuilder});

  static const int _columns = 2;
  static const double _horizontalPadding = 16.0;
  static const double _topPadding = 12.0;
  static const double _bottomPadding = 96.0;
  static const double _crossAxisSpacing = 14.0;
  static const double _mainAxisSpacing = 18.0;
  static const double _childAspectRatio = 0.60;

  final List<Manga> items;
  final Widget Function(BuildContext context, Manga manga, bool exiting)
  itemBuilder;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        _horizontalPadding,
        _topPadding,
        _horizontalPadding,
        _bottomPadding,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _columns,
        crossAxisSpacing: _crossAxisSpacing,
        mainAxisSpacing: _mainAxisSpacing,
        childAspectRatio: _childAspectRatio,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => RepaintBoundary(
        key: ValueKey(items[index].id),
        child: itemBuilder(context, items[index], false),
      ),
    );
  }
}

/* ===========================================================
 * LIBRARY ITEM
 * ========================================================= */

class _LibraryItem extends StatelessWidget {
  const _LibraryItem({
    required this.manga,
    required this.selecting,
    required this.selected,
    required this.onSelected,
    required this.onStartSelecting,
  });

  final Manga manga;
  final bool selecting;
  final bool selected;
  final VoidCallback onSelected;
  final VoidCallback onStartSelecting;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: manga.title,
      selected: selecting ? selected : null,
      hint: selecting
          ? 'Tap to ${selected ? 'deselect' : 'select'}.'
          : 'Tap for details. Press and hold to select for removal.',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: selecting ? onSelected : null,
        onLongPress: selecting ? onSelected : onStartSelecting,
        child: _LibraryMangaTile(
          manga: manga,
          interactive: !selecting,
          selecting: selecting,
          selected: selected,
        ),
      ),
    );
  }
}

/* ===========================================================
 * TILE
 * ========================================================= */

class _LibraryMangaTile extends StatelessWidget {
  const _LibraryMangaTile({
    required this.manga,
    this.interactive = true,
    this.selecting = false,
    this.selected = false,
  });

  final Manga manga;
  final bool interactive;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,

      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              CoverArt(
                url: manga.coverUrl,
                title: manga.title,
                borderRadius: 16,
              ),
              if (selecting) ...[
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      decoration: BoxDecoration(
                        color: selected
                            ? AppColors.accent.withValues(alpha: 0.12)
                            : AppColors.background.withValues(alpha: 0.64),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: selected
                              ? AppColors.accent
                              : AppColors.outline,
                          width: selected ? 2.5 : 1,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: selected ? AppColors.raised : AppColors.glass,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: selected
                              ? AppColors.accent
                              : AppColors.outline,
                          width: selected ? 1.5 : 1,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x66000000),
                            blurRadius: 12,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Icon(
                        selected
                            ? Icons.check_rounded
                            : Icons.crop_square_rounded,
                        size: 19,
                        color: selected ? AppColors.accent : AppColors.muted,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 10),

        Text(
          manga.title,

          maxLines: 1,

          overflow: TextOverflow.ellipsis,

          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700, height: 1.2),
        ),
      ],
    );

    if (!interactive) {
      return content;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,

      onTap: () {
        context.push('/manga/${Uri.encodeComponent(manga.id)}');
      },

      child: content,
    );
  }
}

/* ===========================================================
 * REMOVE BUTTON
 * ========================================================= */

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width - 32,
        ),
        child: Material(
          color: AppColors.glass,
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.36),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: AppColors.danger.withValues(alpha: 0.55)),
          ),
          child: InkWell(
            onTap: count == 0 ? null : onPressed,
            borderRadius: BorderRadius.circular(18),
            splashColor: AppColors.danger.withValues(alpha: 0.12),
            child: SizedBox(
              height: 56,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.delete_outline_rounded,
                      size: 21,
                      color: AppColors.danger,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      count == 1
                          ? 'Remove bookmark'
                          : 'Remove $count bookmarks',
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/* ===========================================================
 * MESSAGE
 * ========================================================= */

class _LibraryMessage extends StatelessWidget {
  const _LibraryMessage({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),

        child: Column(
          mainAxisSize: MainAxisSize.min,

          children: [
            Container(
              width: 58,
              height: 58,

              decoration: BoxDecoration(
                color: AppColors.raised.withValues(alpha: 0.65),

                borderRadius: BorderRadius.circular(18),

                border: Border.all(color: AppColors.outline),
              ),

              child: Icon(icon, size: 27, color: AppColors.accent),
            ),

            const SizedBox(height: 18),

            Text(
              title,

              textAlign: TextAlign.center,

              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),

            const SizedBox(height: 7),

            Text(
              message,

              textAlign: TextAlign.center,

              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: AppColors.muted, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
