import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/manga.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/cover_art.dart';
import '../../../shared/widgets/logout_button.dart';
import '../state/search_controller.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String? _openingMangaId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _openManga(Manga manga) async {
    if (!manga.isFriendlyContent || _openingMangaId != null) return;
    setState(() => _openingMangaId = manga.id);
    try {
      final repository = ref.read(catalogProvider);
      final verified = await repository.verifyForOpen(manga);
      if (!mounted) return;
      if (verified == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Manga details are unavailable. Please try again.'),
          ),
        );
        return;
      }
      unawaited(repository.prewarmChapters(verified, allowAdult: false));
      await context.push('/manga/${Uri.encodeComponent(verified.id)}');
    } finally {
      if (mounted) setState(() => _openingMangaId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(searchProvider.notifier);
    ref.listen<SearchState>(searchProvider, (previous, next) {
      if (_controller.text == next.query) return;

      _controller.value = TextEditingValue(
        text: next.query,
        selection: TextSelection.collapsed(offset: next.query.length),
      );
    });

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text('Search'),
        actions: const [
          Padding(padding: EdgeInsets.only(right: 16), child: LogoutButton()),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, _) {
                return TextField(
                  controller: _controller,
                  focusNode: _focus,
                  textInputAction: TextInputAction.search,
                  onChanged: notifier.updateQuery,
                  onSubmitted: notifier.submit,
                  decoration: InputDecoration(
                    hintText: 'Search manga',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: value.text.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _controller.clear();
                              notifier.updateQuery('');
                            },
                            icon: const Icon(Icons.close_rounded),
                            tooltip: 'Clear search',
                          ),
                  ),
                );
              },
            ),
          ),
          const _SearchProgress(),
          Expanded(
            child: _SearchResults(
              openManga: _openManga,
              onRetry: () => notifier.submit(),
              openingMangaId: _openingMangaId,
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchProgress extends ConsumerWidget {
  const _SearchProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loading = ref.watch(searchProvider.select((state) => state.loading));

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: loading
          ? const LinearProgressIndicator(
              key: ValueKey('search-progress'),
              minHeight: 2,
            )
          : const SizedBox(key: ValueKey('search-idle'), height: 2),
    );
  }
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({
    required this.openManga,
    required this.onRetry,
    required this.openingMangaId,
  });

  final Future<void> Function(Manga manga) openManga;
  final VoidCallback onRetry;
  final String? openingMangaId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(searchProvider);

    if (!state.hasBrowseRequest) return const _SearchHint();
    if (state.results.isEmpty && !state.loading && state.error != null) {
      return _SearchFailure(message: state.error!, onRetry: onRetry);
    }
    if (state.results.isEmpty && !state.loading) return const _NoResults();
    if (state.submitted) {
      return _SearchResultGrid(
        items: state.results,
        openManga: openManga,
        openingMangaId: openingMangaId,
      );
    }
    return _SearchSuggestionList(
      items: state.results,
      openManga: openManga,
      openingMangaId: openingMangaId,
    );
  }
}

class _SearchSuggestionList extends StatelessWidget {
  const _SearchSuggestionList({
    required this.items,
    required this.openManga,
    required this.openingMangaId,
  });

  final List<Manga> items;
  final Future<void> Function(Manga manga) openManga;
  final String? openingMangaId;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final manga = items[index];

        return ListTile(
          contentPadding: EdgeInsets.zero,
          minVerticalPadding: 10,
          leading: SizedBox(
            width: 52,
            child: CoverArt(
              url: manga.coverUrl,
              title: manga.title,
              borderRadius: 10,
            ),
          ),
          title: Text(
            manga.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _MetaStrip(manga: manga, mode: _MetaStripMode.suggestion),
          ),
          trailing: openingMangaId == manga.id
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right_rounded),
          onTap: openingMangaId == null ? () => openManga(manga) : null,
        );
      },
    );
  }
}

class _SearchResultGrid extends StatelessWidget {
  const _SearchResultGrid({
    required this.items,
    required this.openManga,
    required this.openingMangaId,
  });

  final List<Manga> items;
  final Future<void> Function(Manga manga) openManga;
  final String? openingMangaId;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = switch (constraints.maxWidth) {
          >= 900 => 5,
          >= 700 => 4,
          >= 520 => 3,
          >= 330 => 2,
          _ => 1,
        };
        return GridView.builder(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: 352,
            crossAxisSpacing: 14,
            mainAxisSpacing: 18,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final manga = items[index];

            return Stack(
              fit: StackFit.expand,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: openingMangaId == null ? () => openManga(manga) : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: CoverArt(
                          url: manga.coverUrl,
                          title: manga.title,
                        ),
                      ),
                      const SizedBox(height: 9),
                      Text(
                        manga.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      _MetaStrip(manga: manga, mode: _MetaStripMode.result),
                    ],
                  ),
                ),
                if (openingMangaId == manga.id)
                  const Center(child: CircularProgressIndicator()),
              ],
            );
          },
        );
      },
    );
  }
}

enum _MetaStripMode { suggestion, result }

class _MetaStrip extends StatelessWidget {
  const _MetaStrip({required this.manga, required this.mode});

  final Manga manga;
  final _MetaStripMode mode;

  @override
  Widget build(BuildContext context) {
    if (mode == _MetaStripMode.result) {
      return SizedBox(
        width: double.infinity,
        height: 28,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              _MetaPill(Icons.star_rounded, manga.ratingLabel),
              const SizedBox(width: 5),
              _MetaPill(Icons.bolt_rounded, manga.statusLabel),
              const SizedBox(width: 5),
              _MetaPill(Icons.auto_stories_rounded, manga.publicationTypeLabel),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      height: 28,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            _MetaPill(Icons.star_rounded, manga.ratingLabel),
            const SizedBox(width: 5),
            _MetaPill(Icons.bolt_rounded, manga.statusLabel),
            const SizedBox(width: 5),
            _MetaPill(Icons.auto_stories_rounded, manga.publicationTypeLabel),
          ],
        ),
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.raised.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13.5, color: AppColors.accent),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 94),
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchHint extends StatelessWidget {
  const _SearchHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.manage_search_rounded, size: 42, color: AppColors.muted),
            SizedBox(height: 12),
            Text(
              'Search manga by title.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'No manga match this search.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted),
        ),
      ),
    );
  }
}

class _SearchFailure extends StatelessWidget {
  const _SearchFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.search_off_rounded,
              size: 42,
              color: AppColors.muted,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
