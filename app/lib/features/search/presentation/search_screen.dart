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
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _yearController = TextEditingController();
  late final AnimationController _filterController;
  late final Animation<double> _filterCurve;
  late final Animation<Offset> _filterSlide;
  bool _filtersOpen = false;

  static const _genres = <String>[
    'Action',
    'Adventure',
    'Comedy',
    'Drama',
    'Ecchi',
    'Fantasy',
    'Horror',
    'Mahou Shoujo',
    'Mecha',
    'Music',
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
    _filterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
      reverseDuration: const Duration(milliseconds: 280),
    );
    _filterCurve = CurvedAnimation(
      parent: _filterController,
      curve: const Cubic(0.22, 0.61, 0.36, 1),
      reverseCurve: const Cubic(0.22, 0.61, 0.36, 1),
    );
    _filterSlide = Tween<Offset>(
      begin: const Offset(0, -0.035),
      end: Offset.zero,
    ).animate(_filterCurve);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _yearController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  void _toggleFilters() {
    setState(() => _filtersOpen = !_filtersOpen);
    if (_filtersOpen) {
      _focus.unfocus();
      _filterController.forward();
    } else {
      _filterController.reverse();
    }
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
        _yearController.clear();
        _filtersOpen = false;
        _filterController.value = 0;
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
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
                      active: _filtersOpen,
                      count: state.filters.activeCount,
                      onPressed: _toggleFilters,
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
          ClipRect(
            child: SizeTransition(
              sizeFactor: _filterCurve,
              axisAlignment: -1,
              child: FadeTransition(
                opacity: _filterCurve,
                child: SlideTransition(
                  position: _filterSlide,
                  child: _FilterPanel(
                    filters: state.filters,
                    adultMode: adultMode,
                    genres: _genres,
                    yearController: _yearController,
                    onChanged: notifier.updateFilters,
                    onApply: () async {
                      _focus.unfocus();
                      if (mounted) {
                        setState(() => _filtersOpen = false);
                        await _filterController.reverse();
                      }
                      await notifier.applyFilters();
                    },
                    onReset: () async {
                      _yearController.clear();
                      await notifier.clearFilters();
                    },
                  ),
                ),
              ),
            ),
          ),
          if (state.loading) const LinearProgressIndicator(minHeight: 2),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Text(
                state.error!,
                style: const TextStyle(color: AppColors.muted),
              ),
            ),
          Expanded(
            child: !state.hasBrowseRequest
                ? _SearchHint(adultMode: adultMode)
                : state.query.trim().length < 2 &&
                      state.filters.hasActive &&
                      !state.submitted &&
                      state.results.isEmpty
                ? const _FilterReadyHint()
                : state.results.isEmpty && !state.loading
                ? const _NoResults()
                : state.submitted
                ? _buildResultGrid(state.results)
                : _buildSuggestionList(state.results),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionList(List<Manga> items) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    itemCount: items.length,
    separatorBuilder: (_, __) => const SizedBox(height: 10),
    itemBuilder: (context, index) {
      final manga = items[index];
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
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 3),
              Text(
                manga.compactIdentityLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppColors.muted),
              ),
              const SizedBox(height: 5),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _TinyMeta(Icons.star_rounded, manga.ratingLabel),
                  _TinyMeta(Icons.bolt_rounded, manga.statusLabel),
                  _TinyMeta(Icons.library_books_rounded, '$chapterLabel chp'),
                ],
              ),
            ],
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.push('/manga/${Uri.encodeComponent(manga.id)}'),
        ),
      );
    },
  );

  Widget _buildResultGrid(List<Manga> items) => GridView.builder(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      mainAxisExtent: 390,
      crossAxisSpacing: 14,
      mainAxisSpacing: 18,
    ),
    itemCount: items.length,
    itemBuilder: (context, index) {
      final manga = items[index];
      final chapterLabel =
          ref.watch(chapterSummaryLabelProvider(manga)).valueOrNull ??
          manga.chapterDisplayLabel;
      return InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => context.push('/manga/${Uri.encodeComponent(manga.id)}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: .68,
              child: CoverArt(url: manga.coverUrl, title: manga.title),
            ),
            const SizedBox(height: 9),
            Text(
              manga.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              manga.compactIdentityLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AppColors.muted),
            ),
            const SizedBox(height: 5),
            Wrap(
              spacing: 7,
              runSpacing: 4,
              children: [
                _TinyMeta(Icons.star_rounded, manga.ratingLabel),
                _TinyMeta(Icons.library_books_rounded, '$chapterLabel chp'),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              manga.statusLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AppColors.muted),
            ),
            if (manga.displayGenres.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                manga.displayGenres.take(2).join(' • '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: AppColors.muted),
              ),
            ],
          ],
        ),
      );
    },
  );
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.active,
    required this.count,
    required this.onPressed,
  });

  final bool active;
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      IconButton(
        onPressed: onPressed,
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: .86, end: 1).animate(animation),
              child: child,
            ),
          ),
          child: Icon(
            active ? Icons.tune_rounded : Icons.tune_outlined,
            key: ValueKey<bool>(active),
            color: active || count > 0 ? AppColors.accent : null,
          ),
        ),
        tooltip: 'Filters',
      ),
      if (count > 0)
        Positioned(
          right: 5,
          top: 3,
          child: Container(
            constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: const BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
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

class _FilterPanel extends StatelessWidget {
  const _FilterPanel({
    required this.filters,
    required this.adultMode,
    required this.genres,
    required this.yearController,
    required this.onChanged,
    required this.onApply,
    required this.onReset,
  });

  final SearchFilters filters;
  final bool adultMode;
  final List<String> genres;
  final TextEditingController yearController;
  final ValueChanged<SearchFilters> onChanged;
  final VoidCallback onApply;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.outline),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .52,
        ),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      adultMode ? 'Filter adult manga' : 'Filter manga',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  if (filters.activeCount > 0)
                    TextButton(onPressed: onReset, child: const Text('Reset')),
                ],
              ),
              const SizedBox(height: 4),
              _FilterSection(
                title: 'Sort',
                child: _HorizontalChoices(
                  children: MangaBrowseSort.values.map((value) {
                    return ChoiceChip(
                      label: Text(_sortLabel(value)),
                      selected: filters.sort == value,
                      onSelected: (_) =>
                          onChanged(filters.copyWith(sort: value)),
                    );
                  }).toList(),
                ),
              ),
              _FilterSection(
                title: 'Format',
                child: _HorizontalChoices(
                  children: MangaBrowseFormat.values.map((value) {
                    return ChoiceChip(
                      label: Text(_formatLabel(value)),
                      selected: filters.format == value,
                      onSelected: (_) =>
                          onChanged(filters.copyWith(format: value)),
                    );
                  }).toList(),
                ),
              ),
              _FilterSection(
                title: 'Status',
                child: _HorizontalChoices(
                  children: MangaBrowseStatus.values.map((value) {
                    return ChoiceChip(
                      label: Text(_statusLabel(value)),
                      selected: filters.status == value,
                      onSelected: (_) =>
                          onChanged(filters.copyWith(status: value)),
                    );
                  }).toList(),
                ),
              ),
              _FilterSection(
                title: 'Country',
                child: _HorizontalChoices(
                  children: MangaBrowseCountry.values.map((value) {
                    return ChoiceChip(
                      label: Text(_countryLabel(value)),
                      selected: filters.country == value,
                      onSelected: (_) =>
                          onChanged(filters.copyWith(country: value)),
                    );
                  }).toList(),
                ),
              ),
              _FilterSection(
                title: 'Minimum rating',
                child: _HorizontalChoices(
                  children: <int?>[null, 6, 7, 8, 9].map((value) {
                    return ChoiceChip(
                      label: Text(value == null ? 'Any' : '$value+'),
                      selected: filters.minimumRating == value,
                      onSelected: (_) => onChanged(
                        value == null
                            ? filters.copyWith(clearMinimumRating: true)
                            : filters.copyWith(minimumRating: value),
                      ),
                    );
                  }).toList(),
                ),
              ),
              _FilterSection(
                title: 'Minimum chapters',
                child: _HorizontalChoices(
                  children: <int?>[null, 10, 25, 50, 100].map((value) {
                    return ChoiceChip(
                      label: Text(value == null ? 'Any' : '$value+'),
                      selected: filters.minimumChapters == value,
                      onSelected: (_) => onChanged(
                        value == null
                            ? filters.copyWith(clearMinimumChapters: true)
                            : filters.copyWith(minimumChapters: value),
                      ),
                    );
                  }).toList(),
                ),
              ),
              _FilterSection(
                title: 'Year',
                child: SizedBox(
                  width: 150,
                  child: TextFormField(
                    controller: yearController,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    decoration: const InputDecoration(
                      hintText: 'e.g. 2024',
                      counterText: '',
                      isDense: true,
                    ),
                    onChanged: (raw) {
                      final year = int.tryParse(raw.trim());
                      if (raw.trim().isEmpty) {
                        onChanged(filters.copyWith(clearYear: true));
                      } else if (year != null && year >= 1900 && year <= 2100) {
                        onChanged(filters.copyWith(year: year));
                      }
                    },
                  ),
                ),
              ),
              _FilterSection(
                title: 'Genres',
                child: Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [...genres, if (adultMode) 'Hentai'].map((genre) {
                    final selected = filters.genres.contains(genre);
                    return FilterChip(
                      label: Text(genre),
                      selected: selected,
                      onSelected: (_) {
                        final next = <String>{...filters.genres};
                        selected ? next.remove(genre) : next.add(genre);
                        onChanged(filters.copyWith(genres: next));
                      },
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onApply,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Apply filters'),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Filters work without typing a title.',
                style: TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _sortLabel(MangaBrowseSort value) => switch (value) {
    MangaBrowseSort.relevance => 'Relevance',
    MangaBrowseSort.popularity => 'Popularity',
    MangaBrowseSort.rating => 'Rating',
    MangaBrowseSort.trending => 'Trending',
    MangaBrowseSort.newest => 'Newest',
    MangaBrowseSort.title => 'Title',
    MangaBrowseSort.chapters => 'Chapters',
  };

  String _formatLabel(MangaBrowseFormat value) => switch (value) {
    MangaBrowseFormat.all => 'All',
    MangaBrowseFormat.manga => 'Manga',
    MangaBrowseFormat.oneShot => 'One-shot',
    MangaBrowseFormat.novel => 'Novel',
  };

  String _statusLabel(MangaBrowseStatus value) => switch (value) {
    MangaBrowseStatus.all => 'All',
    MangaBrowseStatus.ongoing => 'Releasing',
    MangaBrowseStatus.completed => 'Finished',
    MangaBrowseStatus.hiatus => 'Hiatus',
    MangaBrowseStatus.cancelled => 'Cancelled',
    MangaBrowseStatus.notYetReleased => 'Upcoming',
  };

  String _countryLabel(MangaBrowseCountry value) => switch (value) {
    MangaBrowseCountry.all => 'All',
    MangaBrowseCountry.japan => 'Japan',
    MangaBrowseCountry.southKorea => 'Korea',
    MangaBrowseCountry.china => 'China',
    MangaBrowseCountry.taiwan => 'Taiwan',
  };
}

class _FilterSection extends StatelessWidget {
  const _FilterSection({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 7),
        child,
      ],
    ),
  );
}

class _HorizontalChoices extends StatelessWidget {
  const _HorizontalChoices({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    physics: const BouncingScrollPhysics(),
    child: Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          children[i],
          if (i != children.length - 1) const SizedBox(width: 7),
        ],
      ],
    ),
  );
}

class _TinyMeta extends StatelessWidget {
  const _TinyMeta(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: AppColors.accent),
      const SizedBox(width: 3),
      Text(text, style: const TextStyle(fontSize: 10.5)),
    ],
  );
}

class _SearchHint extends StatelessWidget {
  const _SearchHint({required this.adultMode});
  final bool adultMode;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        adultMode
            ? 'Search adult manga, or open Filters to browse without typing.'
            : 'Search manga, or open Filters to browse without typing.',
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.muted),
      ),
    ),
  );
}

class _FilterReadyHint extends StatelessWidget {
  const _FilterReadyHint();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Text(
        'Tap Apply filters to browse matching manga.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.muted),
      ),
    ),
  );
}

class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Text(
        'No manga match these filters.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.muted),
      ),
    ),
  );
}
