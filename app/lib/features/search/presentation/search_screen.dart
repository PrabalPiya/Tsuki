import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/manga.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/cover_art.dart';
import '../../../shared/widgets/logout_button.dart';
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
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 240),
    );

    final selected = await showModalBottomSheet<SearchFilters>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .58),
      isScrollControlled: false,
      useSafeArea: true,
      transitionAnimationController: animation,
      builder: (_) => _FilterSheet(initial: current, genres: _genres),
    );
    animation.dispose();

    if (!mounted || selected == null) return;
    final notifier = ref.read(searchProvider.notifier);
    notifier.updateFilters(selected);
    await notifier.applyFilters();
  }

  Future<void> _openManga(Manga manga) async {
    if (manga.isAdult) return;
    try {
      await ref
          .read(catalogProvider)
          .prewarmChapters(manga, allowAdult: false);
    } catch (_) {
      // Details has its own fallback handling.
    }
    if (!mounted) return;
    context.push('/manga/${Uri.encodeComponent(manga.id)}');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchProvider);
    final notifier = ref.read(searchProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text('Search'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: LogoutButton(),
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
                hintText: 'Search manga',
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
                  TextButton(onPressed: notifier.submit, child: const Text('Retry')),
                ],
              ),
            ),
          Expanded(
            child: !state.hasBrowseRequest
                ? const _SearchHint()
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
        unawaited(
          ref
              .read(catalogProvider)
              .prewarmChapters(manga, allowAdult: false),
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
              padding: const EdgeInsets.only(top: 8),
              child: _MetaStrip(manga: manga, chapterLabel: chapterLabel),
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
        mainAxisExtent: 384,
        crossAxisSpacing: 14,
        mainAxisSpacing: 18,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final manga = items[index];
        if (index < 8) {
          unawaited(
            ref
                .read(catalogProvider)
                .prewarmChapters(manga, allowAdult: false),
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
              Expanded(child: CoverArt(url: manga.coverUrl, title: manga.title)),
              const SizedBox(height: 9),
              Text(
                manga.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              _MetaStrip(manga: manga, chapterLabel: chapterLabel),
            ],
          ),
        );
      },
    );
  }
}

class _MetaStrip extends StatelessWidget {
  const _MetaStrip({required this.manga, required this.chapterLabel});

  final Manga manga;
  final String chapterLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            _MetaPill(Icons.star_rounded, manga.ratingLabel),
            const SizedBox(width: 5),
            _MetaPill(Icons.bolt_rounded, manga.statusLabel),
            const SizedBox(width: 5),
            _MetaPill(Icons.library_books_rounded, '$chapterLabel chp'),
            const SizedBox(width: 5),
            _MetaPill(
              Icons.category_rounded,
              manga.genres.isEmpty ? '—' : manga.genres.first,
            ),
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
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: AppColors.raised.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.accent),
          const SizedBox(width: 3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 78),
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
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
                  onPressed: () => setState(() => _filters = const SearchFilters()),
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
            _FilterValueRow<MangaBrowseSort>(
              icon: Icons.star_outline_rounded,
              label: 'Sort by',
              value: _filters.sort,
              display: _sortLabel(_filters.sort),
              values: const <MangaBrowseSort>[
                MangaBrowseSort.relevance,
                MangaBrowseSort.rating,
              ],
              labelFor: _sortLabel,
              onChanged: (value) {
                setState(() => _filters = _filters.copyWith(sort: value));
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
    MangaBrowseSort.rating => 'Rating: High to Low',
    _ => 'Best match',
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
                    constraints: const BoxConstraints(maxWidth: 150),
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
              'Search manga or use Filters to browse.',
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
          'No readable manga match this search.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted),
        ),
      ),
    );
  }
}
