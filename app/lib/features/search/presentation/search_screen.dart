import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/manga.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/cover_art.dart';
import '../data/metadata_provider.dart';
import '../state/search_controller.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen>
    with TickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  static const _genres = <String>[
    'Action',
    'Adventure',
    'Comedy',
    'Drama',
    'Ecchi',
    'Fantasy',
    'Horror',
    'Mystery',
    'Psychological',
    'Romance',
    'Sci-Fi',
    'Slice of Life',
    'Sports',
    'Supernatural',
    'Thriller',
  ];

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

  Future<void> _openFilters() async {
    _focus.unfocus();
    final current = ref.read(searchProvider).filters;
    final animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      reverseDuration: const Duration(milliseconds: 260),
    );

    final selected = await showModalBottomSheet<SearchFilters>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .58),
      isScrollControlled: false,
      useSafeArea: true,
      transitionAnimationController: animation,
      builder: (sheetContext) =>
          _FilterSheet(initial: current, genres: _genres),
    );
    animation.dispose();

    if (!mounted || selected == null) return;
    final notifier = ref.read(searchProvider.notifier);
    notifier.updateFilters(selected);
    await notifier.applyFilters();
  }

  Future<void> _openManga(Manga manga) async {
    final adultMode = ref.read(adultModeProvider);
    try {
      await ref
          .read(catalogProvider)
          .prewarmChapters(manga, allowAdult: adultMode);
    } catch (_) {
      // Details still has source fallback/error handling.
    }
    if (!mounted) return;
    context.push('/manga/${Uri.encodeComponent(manga.id)}');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchProvider);
    final adultMode = ref.watch(adultModeProvider);
    final notifier = ref.read(searchProvider.notifier);

    ref.listen<bool>(adultModeProvider, (previous, next) {
      if (previous == null || previous == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _controller.clear();
        setState(() {});
      });
    });

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Text(adultMode ? 'Adult Search' : 'Search'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: IconButton(
              onPressed: () => context.push('/settings'),
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              onChanged: (value) {
                notifier.updateQuery(value);
                setState(() {});
              },
              onSubmitted: notifier.submit,
              decoration: InputDecoration(
                hintText: adultMode ? 'Search adult manga' : 'Search manga',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIconConstraints: const BoxConstraints(minWidth: 48),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _FilterButton(
                      count: state.filters.activeCount,
                      onPressed: _openFilters,
                    ),
                    if (_controller.text.isNotEmpty)
                      IconButton(
                        onPressed: () {
                          _controller.clear();
                          notifier.updateQuery('');
                          setState(() {});
                        },
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Clear search',
                      ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: state.loading
                ? const LinearProgressIndicator(
                    key: ValueKey('search-progress'),
                    minHeight: 2,
                  )
                : const SizedBox(key: ValueKey('search-idle'), height: 2),
          ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 2),
              child: Row(
                children: [
                  const Icon(
                    Icons.cloud_off_rounded,
                    color: AppColors.muted,
                    size: 17,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.error!,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: notifier.submit,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: !state.hasBrowseRequest
                ? _SearchHint(adultMode: adultMode)
                : state.results.isEmpty && !state.loading
                ? const _NoResults()
                : state.submitted || state.query.trim().length < 2
                ? _buildResultGrid(state.results)
                : _buildSuggestionList(state.results),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionList(List<Manga> items) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final manga = items[index];
        final adultMode = ref.read(adultModeProvider);
        unawaited(
          ref
              .read(catalogProvider)
              .prewarmChapters(manga, allowAdult: adultMode),
        );
        final chapterLabel =
            ref.watch(chapterSummaryLabelProvider(manga)).valueOrNull ??
            manga.chapterDisplayLabel;
        return Card(
          child: ListTile(
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
              padding: const EdgeInsets.only(top: 7),
              child: Wrap(
                spacing: 8,
                runSpacing: 5,
                children: [
                  _TinyMeta(Icons.star_rounded, manga.ratingLabel),
                  _TinyMeta(Icons.bolt_rounded, manga.statusLabel),
                  _TinyMeta(Icons.library_books_rounded, '$chapterLabel chp'),
                  _TinyMeta(
                    Icons.category_rounded,
                    manga.genres.isEmpty ? '—' : manga.genres.first,
                  ),
                ],
              ),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _openManga(manga),
          ),
        );
      },
    );
  }

  Widget _buildResultGrid(List<Manga> items) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: 382,
        crossAxisSpacing: 14,
        mainAxisSpacing: 18,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final manga = items[index];
        final adultMode = ref.read(adultModeProvider);
        if (index < 8) {
          unawaited(
            ref
                .read(catalogProvider)
                .prewarmChapters(manga, allowAdult: adultMode),
          );
        }
        final chapterLabel =
            ref.watch(chapterSummaryLabelProvider(manga)).valueOrNull ??
            manga.chapterDisplayLabel;

        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _openManga(manga),
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
              const SizedBox(height: 7),
              Wrap(
                spacing: 7,
                runSpacing: 5,
                children: [
                  _TinyMeta(Icons.star_rounded, manga.ratingLabel),
                  _TinyMeta(Icons.bolt_rounded, manga.statusLabel),
                  _TinyMeta(Icons.library_books_rounded, '$chapterLabel chp'),
                  _TinyMeta(
                    Icons.category_rounded,
                    manga.genres.isEmpty ? '—' : manga.genres.first,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          onPressed: onPressed,
          icon: const Icon(Icons.tune_rounded),
          tooltip: 'Filters',
        ),
        if (count > 0)
          Positioned(
            top: 2,
            right: 2,
            child: Container(
              width: 17,
              height: 17,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  color: AppColors.background,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.initial, required this.genres});

  final SearchFilters initial;
  final List<String> genres;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late SearchFilters _filters;

  @override
  void initState() {
    super.initState();
    _filters = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: EdgeInsets.fromLTRB(18, 10, 18, 16 + bottom),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          border: Border(top: BorderSide(color: AppColors.outline)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.outline,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Filters',
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    setState(() => _filters = const SearchFilters());
                  },
                  child: const Text('Reset'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _FilterValueRow<String>(
              icon: Icons.category_outlined,
              label: 'Genre',
              value: _filters.genre ?? '',
              display: _filters.genre ?? 'All genres',
              values: <String>['', ...widget.genres],
              labelFor: (value) => value.isEmpty ? 'All genres' : value,
              onChanged: (value) {
                setState(() {
                  _filters = value.isEmpty
                      ? _filters.copyWith(clearGenre: true)
                      : _filters.copyWith(genre: value);
                });
              },
            ),
            _FilterValueRow<MangaBrowseSort>(
              icon: Icons.swap_vert_rounded,
              label: 'Sort',
              value: _filters.sort,
              display: _sortLabel(_filters.sort),
              values: const <MangaBrowseSort>[
                MangaBrowseSort.relevance,
                MangaBrowseSort.popularity,
                MangaBrowseSort.rating,
                MangaBrowseSort.newest,
                MangaBrowseSort.chapters,
              ],
              labelFor: _sortLabel,
              onChanged: (value) {
                setState(() => _filters = _filters.copyWith(sort: value));
              },
            ),
            _FilterValueRow<MangaBrowseStatus>(
              icon: Icons.bolt_outlined,
              label: 'Status',
              value: _filters.status,
              display: _statusLabel(_filters.status),
              values: const <MangaBrowseStatus>[
                MangaBrowseStatus.all,
                MangaBrowseStatus.ongoing,
                MangaBrowseStatus.completed,
                MangaBrowseStatus.hiatus,
                MangaBrowseStatus.cancelled,
              ],
              labelFor: _statusLabel,
              onChanged: (value) {
                setState(() => _filters = _filters.copyWith(status: value));
              },
            ),
            _FilterValueRow<int>(
              icon: Icons.library_books_outlined,
              label: 'Min chapters',
              value: _filters.minimumChapters ?? 0,
              display: _filters.minimumChapters == null
                  ? 'Any'
                  : '${_filters.minimumChapters}+',
              values: const <int>[0, 10, 25, 50, 100],
              labelFor: (value) => value == 0 ? 'Any' : '$value+',
              onChanged: (value) {
                setState(() {
                  _filters = value == 0
                      ? _filters.copyWith(clearMinimumChapters: true)
                      : _filters.copyWith(minimumChapters: value);
                });
              },
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_filters),
                child: const Text('Apply filters'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _sortLabel(MangaBrowseSort value) => switch (value) {
    MangaBrowseSort.relevance => 'Best match',
    MangaBrowseSort.popularity => 'Popularity',
    MangaBrowseSort.rating => 'Rating',
    MangaBrowseSort.newest => 'Newest',
    MangaBrowseSort.chapters => 'Chapters',
    MangaBrowseSort.trending => 'Trending',
    MangaBrowseSort.title => 'Title',
  };

  static String _statusLabel(MangaBrowseStatus value) => switch (value) {
    MangaBrowseStatus.all => 'Any status',
    MangaBrowseStatus.ongoing => 'Ongoing',
    MangaBrowseStatus.completed => 'Completed',
    MangaBrowseStatus.hiatus => 'Hiatus',
    MangaBrowseStatus.cancelled => 'Cancelled',
  };
}

class _FilterValueRow<T> extends StatelessWidget {
  const _FilterValueRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.display,
    required this.values,
    required this.labelFor,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final T value;
  final String display;
  final List<T> values;
  final String Function(T) labelFor;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.only(left: 13, right: 4),
      decoration: BoxDecoration(
        color: AppColors.raised.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.muted),
          const SizedBox(width: 10),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          PopupMenuButton<T>(
            initialValue: value,
            color: AppColors.raised,
            surfaceTintColor: Colors.transparent,
            tooltip: label,
            onSelected: onChanged,
            itemBuilder: (context) => values
                .map(
                  (item) => PopupMenuItem<T>(
                    value: item,
                    child: Text(labelFor(item)),
                  ),
                )
                .toList(growable: false),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 135),
                    child: Text(
                      display,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  const Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: AppColors.muted,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TinyMeta extends StatelessWidget {
  const _TinyMeta(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: AppColors.accent),
        const SizedBox(width: 3),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 88),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10.5),
          ),
        ),
      ],
    );
  }
}

class _SearchHint extends StatelessWidget {
  const _SearchHint({required this.adultMode});

  final bool adultMode;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.manage_search_rounded,
              size: 42,
              color: AppColors.muted,
            ),
            const SizedBox(height: 12),
            Text(
              adultMode
                  ? 'Search adult manga or use Filters to browse.'
                  : 'Search manga or use Filters to browse.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted),
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
