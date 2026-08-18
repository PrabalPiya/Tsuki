import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/manga.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/cover_art.dart';

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchProvider);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text('Search'),
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              onChanged: ref.read(searchProvider.notifier).updateQuery,
              onSubmitted: ref.read(searchProvider.notifier).submit,
              decoration: InputDecoration(
                hintText: 'Search manga',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _controller.clear();
                          ref.read(searchProvider.notifier).updateQuery('');
                          setState(() {});
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
              ),
            ),
          ),
          if (state.loading) const LinearProgressIndicator(minHeight: 2),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                state.error!,
                style: const TextStyle(color: AppColors.muted),
              ),
            ),
          Expanded(
            child: state.query.length < 2
                ? _SearchHint()
                : state.submitted
                ? _buildResultGrid(state.results)
                : _buildSuggestionList(state.results),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionList(List<Manga> items) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
    itemCount: items.length,
    separatorBuilder: (_, __) => const SizedBox(height: 10),
    itemBuilder: (context, index) {
      final manga = items[index];
      return Card(
        child: ListTile(
          leading: SizedBox(
            width: 46,
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
          subtitle: Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.star_rounded,
                    size: 14,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 3),
                  Text(manga.ratingLabel, style: const TextStyle(fontSize: 12)),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.bolt_rounded,
                    size: 14,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 3),
                  Text(manga.statusLabel, style: const TextStyle(fontSize: 12)),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.library_books_rounded,
                    size: 14,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${manga.chapterCount} chp',
                    style: const TextStyle(fontSize: 12),
                  ),
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
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      childAspectRatio: .57,
      crossAxisSpacing: 14,
      mainAxisSpacing: 18,
    ),
    itemCount: items.length,
    itemBuilder: (context, index) {
      final manga = items[index];
      return InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => context.push('/manga/${Uri.encodeComponent(manga.id)}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: CoverArt(url: manga.coverUrl, title: manga.title),
            ),
            const SizedBox(height: 10),
            Text(
              manga.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 3),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.star_rounded,
                      size: 14,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        manga.ratingLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Icon(
                      Icons.bolt_rounded,
                      size: 14,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        manga.statusLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(
                      Icons.library_books_rounded,
                      size: 14,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${manga.chapterCount} chp',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class _SearchHint extends StatelessWidget {
  const _SearchHint();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Text(
        'Type at least 2 characters to begin.',
        style: TextStyle(color: AppColors.muted),
      ),
    ),
  );
}
