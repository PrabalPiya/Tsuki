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
    if (!manga.isFriendlyContent) return;
    unawaited(
      ref.read(catalogProvider).prewarmChapters(manga, allowAdult: false),
    );
    if (!mounted) return;
    context.push('/manga/${Uri.encodeComponent(manga.id)}');
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
          _SearchErrorBanner(onRetry: () => notifier.submit()),
          Expanded(child: _SearchResults(openManga: _openManga)),
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

class _SearchErrorBanner extends ConsumerWidget {
  const _SearchErrorBanner({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(searchProvider.select((state) => state.error));
    if (error == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 2),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: AppColors.muted, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.openManga});

  final Future<void> Function(Manga manga) openManga;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(searchProvider);

    if (!state.hasBrowseRequest) return const _SearchHint();
    if (state.results.isEmpty && !state.loading) return const _NoResults();
    if (state.submitted) {
      return _SearchResultGrid(items: state.results, openManga: openManga);
    }
    return _SearchSuggestionList(items: state.results, openManga: openManga);
  }
}

class _SearchSuggestionList extends StatelessWidget {
  const _SearchSuggestionList({required this.items, required this.openManga});

  final List<Manga> items;
  final Future<void> Function(Manga manga) openManga;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final manga = items[index];
        final chapterLabel = manga.catalogChapterDisplayLabel;

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
            child: _MetaStrip(
              manga: manga,
              chapterLabel: chapterLabel,
              mode: _MetaStripMode.suggestion,
            ),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => openManga(manga),
        );
      },
    );
  }
}

class _SearchResultGrid extends StatelessWidget {
  const _SearchResultGrid({required this.items, required this.openManga});

  final List<Manga> items;
  final Future<void> Function(Manga manga) openManga;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: 384,
        crossAxisSpacing: 14,
        mainAxisSpacing: 18,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final manga = items[index];
        final chapterLabel = manga.catalogChapterDisplayLabel;

        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => openManga(manga),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: CoverArt(url: manga.coverUrl, title: manga.title),
              ),
              const SizedBox(height: 9),
              Text(
                manga.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              _MetaStrip(
                manga: manga,
                chapterLabel: chapterLabel,
                mode: _MetaStripMode.result,
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _MetaStripMode { suggestion, result }

class _MetaStrip extends StatelessWidget {
  const _MetaStrip({
    required this.manga,
    required this.chapterLabel,
    required this.mode,
  });

  final Manga manga;
  final String? chapterLabel;
  final _MetaStripMode mode;

  @override
  Widget build(BuildContext context) {
    if (mode == _MetaStripMode.result) {
      return SizedBox(
        width: double.infinity,
        height: 61,
        child: Wrap(
          spacing: 5,
          runSpacing: 5,
          children: [
            _MetaPill(Icons.star_rounded, manga.ratingLabel),
            _MetaPill(Icons.bolt_rounded, manga.statusLabel),
            if (chapterLabel != null)
              _MetaPill(Icons.library_books_rounded, '$chapterLabel chp'),
          ],
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
            if (chapterLabel != null) ...[
              const SizedBox(width: 5),
              _MetaPill(Icons.library_books_rounded, '$chapterLabel chp'),
            ],
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
