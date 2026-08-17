import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/models/manga.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/cover_art.dart';

final libraryItemsProvider =
    FutureProvider.autoDispose<List<Manga>>((ref) async {
  final state = ref.watch(userLibraryProvider.select((value) =>
      (bookmarks: value.bookmarks, bookmarkedManga: value.bookmarkedManga)));
  final repository = ref.watch(catalogProvider);
  final items = <Manga>[];
  for (final id in state.bookmarks) {
    try {
      final manga = repository.cached(id) ??
          state.bookmarkedManga[id] ??
          await repository.details(id);
      if (manga != null) {
        repository.remember(manga);
        items.add(manga);
      }
    } catch (_) {
      // Keep the rest of the library usable if one provider entry is missing.
    }
  }
  items.sort((a, b) => a.title.compareTo(b.title));
  return items;
});

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  bool _dragging = false;
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(userLibraryProvider);
    final itemsState = ref.watch(libraryItemsProvider);
    final items = itemsState.valueOrNull ?? const <Manga>[];
    return Scaffold(
        appBar: AppBar(
        titleSpacing: 16,
            title: const Text('Library'),
            actions: [
              Padding(
            padding: const EdgeInsets.only(right: 16),
                  child: IconButton(
                      onPressed: () => context.push('/settings'),
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: 'Settings'))
            ]),
        body: Stack(children: [
          if (state.loading || itemsState.isLoading)
            const Center(child: CircularProgressIndicator())
          else if (items.isEmpty)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('Your bookmarked manga will appear here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.muted))))
          else
            GridView.builder(
                padding: EdgeInsets.fromLTRB(16, 12, 16, _dragging ? 132 : 0),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: .56,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 20),
                itemCount: items.length,
                itemBuilder: (context, index) => _LibraryItem(
                    manga: items[index],
                    onDragStarted: () {
                      HapticFeedback.mediumImpact();
                      setState(() => _dragging = true);
                    },
                    onDragEnd: () => setState(() => _dragging = false))),
          AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              left: 16,
              right: 16,
              bottom: _dragging ? 104 : -110,
              child: _RemoveTarget(onRemoved: (manga) {
                setState(() => _dragging = false);
                ref.read(userLibraryProvider.notifier).toggleBookmark(manga);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('${manga.title} removed'),
                    action: SnackBarAction(
                        label: 'Undo',
                        onPressed: () => ref
                            .read(userLibraryProvider.notifier)
                            .restoreBookmark(manga))));
              }))
        ]));
  }
}

class _LibraryItem extends StatelessWidget {
  const _LibraryItem(
      {required this.manga,
      required this.onDragStarted,
      required this.onDragEnd});
  final Manga manga;
  final VoidCallback onDragStarted, onDragEnd;
  @override
  Widget build(BuildContext context) {
    final child = Card(
        child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () =>
                context.push('/manga/${Uri.encodeComponent(manga.id)}'),
            child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                          child: CoverArt(
                              url: manga.coverUrl,
                              title: manga.title,
                              borderRadius: 14)),
                      const SizedBox(height: 10),
                      Text(manga.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 6),
                      Row(children: [
                        const Icon(Icons.bookmark_rounded,
                            size: 15, color: AppColors.accent),
                        const SizedBox(width: 5),
                        Text('Saved',
                            style: Theme.of(context).textTheme.bodySmall)
                      ])
                    ]))));
    return LongPressDraggable<Manga>(
        data: manga,
        maxSimultaneousDrags: 1,
        onDragStarted: onDragStarted,
        onDragEnd: (_) => onDragEnd(),
        onDraggableCanceled: (_, __) => onDragEnd(),
        feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
                width: 160,
                height: 290,
                child: Transform.scale(scale: 1.04, child: child))),
        childWhenDragging: Opacity(opacity: .25, child: child),
        child: child);
  }
}

class _RemoveTarget extends StatelessWidget {
  const _RemoveTarget({required this.onRemoved});
  final ValueChanged<Manga> onRemoved;
  @override
  Widget build(BuildContext context) => DragTarget<Manga>(
      onWillAcceptWithDetails: (_) {
        HapticFeedback.selectionClick();
        return true;
      },
      onAcceptWithDetails: (details) => onRemoved(details.data),
      builder: (context, candidates, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 82,
          decoration: BoxDecoration(
              color: candidates.isEmpty ? AppColors.raised : AppColors.danger,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppColors.outline)),
          child:
              const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.bookmark_remove_rounded),
            SizedBox(width: 10),
            Text('Remove Bookmark',
                style: TextStyle(fontWeight: FontWeight.w700))
          ])));
}
