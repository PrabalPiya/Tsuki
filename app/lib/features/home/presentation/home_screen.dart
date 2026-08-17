import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/models/reading_progress.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/cover_art.dart';

class HomeEntry {
  const HomeEntry({
    required this.manga,
    required this.chapters,
    required this.progress,
    required this.currentIndex,
    required this.caughtUp,
    required this.sortTime,
  });

  final Manga manga;
  final List<CanonicalChapter> chapters;
  final ReadingProgress? progress;
  final int currentIndex;
  final bool caughtUp;
  final DateTime sortTime;

  int get unreadCount {
    if (chapters.isEmpty) return 0;

    return caughtUp
        ? 0
        : (chapters.length - currentIndex - 1)
            .clamp(0, chapters.length)
            .toInt();
  }

  CanonicalChapter? get latest =>
      chapters.isEmpty ? null : chapters.last;

  bool get hasChapters => chapters.isNotEmpty;
}

typedef _HomeCatalogEntry = ({
  Manga manga,
  List<CanonicalChapter> chapters,
});

final _homeCatalogProvider =
    FutureProvider<List<_HomeCatalogEntry>>((ref) async {
  ref.watch(_homeRefreshProvider);

  final state = ref.watch(
    userLibraryProvider.select(
      (value) => (
        bookmarks: value.bookmarks,
        bookmarkedManga: value.bookmarkedManga,
      ),
    ),
  );

  final repository =
      ref.watch(catalogProvider);

  final entries =
      <_HomeCatalogEntry>[];

  for (final id in state.bookmarks) {
    try {
      final manga =
          repository.cached(id) ??
          state.bookmarkedManga[id] ??
          await repository.details(id);

      if (manga == null) {
        continue;
      }

      repository.remember(manga);

      List<CanonicalChapter> chapters =
          const <CanonicalChapter>[];

      try {
        chapters =
            await repository.chapters(
          manga,
          refresh: true,
        );
      } catch (_) {
        /*
         * IMPORTANT:
         *
         * Chapter failure should NOT remove
         * the bookmarked manga from Home.
         *
         * We keep the manga and show it with
         * unavailable chapter information.
         */
        chapters =
            const <CanonicalChapter>[];
      }

      entries.add(
        (
          manga: manga,
          chapters: chapters,
        ),
      );
    } catch (_) {
      /*
       * Only completely unavailable manga
       * metadata is skipped.
       */
    }
  }

  return entries;
});

final homeEntriesProvider =
    Provider<AsyncValue<List<HomeEntry>>>((ref) {
  final libraryState =
      ref.watch(userLibraryProvider);

  final progress =
      libraryState.progress;

  final bool adultContentEnabled =
      libraryState.adultContent;

  return ref
      .watch(_homeCatalogProvider)
      .whenData(
    (catalog) {
      final entries = catalog
          /*
           * Adult visibility only.
           *
           * OFF:
           * adult manga hidden.
           *
           * ON:
           * adult manga visible.
           *
           * Bookmark and progress remain stored.
           */
          .where(
            (entry) =>
                adultContentEnabled ||
                !entry.manga.isAdult,
          )
          .map(
        (entry) {
          final mangaProgress =
              progress[entry.manga.id];

          int current = -1;

          if (mangaProgress != null &&
              entry.chapters.isNotEmpty) {
            current =
                entry.chapters.indexWhere(
              (chapter) =>
                  chapter.id ==
                  mangaProgress.chapterId,
            );
          }

          final bool caught =
              entry.chapters.isNotEmpty &&
                  current ==
                      entry.chapters.length -
                          1 &&
                  (mangaProgress
                              ?.chapterProgress ??
                          0.0) >=
                      0.95;

          /*
           * Manga without chapters still need
           * a stable sorting position.
           */
          final DateTime sort;

          if (caught) {
            sort =
                mangaProgress?.updatedAt ??
                    DateTime
                        .fromMillisecondsSinceEpoch(
                      0,
                    );
          } else if (entry.chapters.isNotEmpty) {
            sort =
                entry.chapters.last.publishedAt;
          } else {
            sort =
                mangaProgress?.updatedAt ??
                    DateTime
                        .fromMillisecondsSinceEpoch(
                      0,
                    );
          }

          return HomeEntry(
            manga: entry.manga,
            chapters: entry.chapters,
            progress: mangaProgress,
            currentIndex: current,
            caughtUp: caught,
            sortTime: sort,
          );
        },
      ).toList();

      entries.sort(
        (a, b) =>
            b.sortTime.compareTo(
          a.sortTime,
        ),
      );

      return entries;
    },
  );
});

final _homeRefreshProvider =
    StreamProvider<int>(
  (ref) => Stream<int>.periodic(
    const Duration(
      minutes: 15,
    ),
    (value) => value,
  ),
);

class HomeScreen
    extends ConsumerStatefulWidget {
  const HomeScreen({
    super.key,
  });

  @override
  ConsumerState<HomeScreen>
      createState() =>
          _HomeScreenState();
}

class _HomeScreenState
    extends ConsumerState<HomeScreen> {
  PageController? _pageController;

  int _selectedSection = 0;

  bool _isAnimating = false;

  PageController get _page =>
      _pageController ??=
          PageController();

  void _switchTab(
    int index,
  ) {
    if (_isAnimating ||
        _selectedSection == index) {
      return;
    }

    setState(() {
      _selectedSection = index;
    });

    _isAnimating = true;

    _page
        .animateToPage(
      index,
      duration: const Duration(
        milliseconds: 300,
      ),
      curve: Curves.easeOutCubic,
    )
        .then(
      (_) {
        if (!mounted) return;

        setState(() {
          _isAnimating = false;
        });
      },
    );
  }

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final homeEntries =
        ref.watch(homeEntriesProvider);

    final activeCount =
        homeEntries.maybeWhen(
      data: (entries) =>
          entries
              .where(
                (entry) =>
                    !entry.caughtUp,
              )
              .length,
      orElse: () => null,
    );

    final caughtUpCount =
        homeEntries.maybeWhen(
      data: (entries) =>
          entries
              .where(
                (entry) =>
                    entry.caughtUp,
              )
              .length,
      orElse: () => null,
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title:
            const _TsukiTitle(),
        actions: [
          Padding(
            padding:
                const EdgeInsets.only(
              right: 16,
            ),
            child: IconButton(
              onPressed: () =>
                  context.push(
                '/settings',
              ),
              icon: const Icon(
                Icons.settings_outlined,
              ),
              tooltip: 'Settings',
            ),
          ),
        ],
      ),

      body: Column(
        children: [
          _HomeTabs(
            activeCount:
                activeCount,
            caughtUpCount:
                caughtUpCount,
            selectedIndex:
                _selectedSection,
            onTabChanged:
                _switchTab,
          ),

          Expanded(
            child: homeEntries.when(
              loading: () =>
                  const Center(
                child:
                    CircularProgressIndicator(),
              ),

              error: (_, __) =>
                  const _Empty(
                'Home is unavailable right now.',
              ),

              data: (entries) {
                final active =
                    entries
                        .where(
                          (entry) =>
                              !entry
                                  .caughtUp,
                        )
                        .toList();

                final caughtUp =
                    entries
                        .where(
                          (entry) =>
                              entry
                                  .caughtUp,
                        )
                        .toList();

                WidgetsBinding
                    .instance
                    .addPostFrameCallback(
                  (_) {
                    if (!mounted ||
                        !_page.hasClients) {
                      return;
                    }

                    final page =
                        _page.page?.round();

                    if (page !=
                        _selectedSection) {
                      _page.jumpToPage(
                        _selectedSection,
                      );
                    }
                  },
                );

                return PageView(
                  controller:
                      _page,

                  onPageChanged:
                      (index) {
                    if (!_isAnimating) {
                      setState(() {
                        _selectedSection =
                            index;
                      });
                    }
                  },

                  children: [
                    _EntryList(
                      entries: active,
                    ),

                    _EntryList(
                      entries: caughtUp,
                      caughtUpSection:
                          true,
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TsukiTitle
    extends StatelessWidget {
  const _TsukiTitle();

  @override
  Widget build(
    BuildContext context,
  ) {
    return Row(
      mainAxisSize:
          MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 48,
          padding:
              const EdgeInsets.all(
            4,
          ),
          decoration:
              BoxDecoration(
            color:
                AppColors.raised
                    .withValues(
              alpha: 0.55,
            ),
            borderRadius:
                BorderRadius.circular(
              16,
            ),
          ),
          child: ClipRRect(
            borderRadius:
                BorderRadius.circular(
              12,
            ),
            child: Image.asset(
              'assets/branding/quiet_reader_icon.png',
              fit: BoxFit.cover,
            ),
          ),
        ),

        const SizedBox(
          width: 12,
        ),

        const Text(
          'Tsuki',
          style: TextStyle(
            color: AppColors.text,
            fontSize: 32,
            fontWeight:
                FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _HomeTabs
    extends StatelessWidget {
  const _HomeTabs({
    required this.activeCount,
    required this.caughtUpCount,
    required this.selectedIndex,
    required this.onTabChanged,
  });

  final int? activeCount;
  final int? caughtUpCount;
  final int selectedIndex;
  final ValueChanged<int>
      onTabChanged;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(
        12,
        8,
        12,
        10,
      ),
      child: Container(
        height: 46,
        padding:
            const EdgeInsets.all(
          3,
        ),
        decoration:
            BoxDecoration(
          color:
              AppColors.raised
                  .withValues(
            alpha: 0.36,
          ),
          borderRadius:
              BorderRadius.circular(
            15,
          ),
        ),
        child: Stack(
          children: [
            AnimatedAlign(
              alignment:
                  selectedIndex == 0
                      ? Alignment
                          .centerLeft
                      : Alignment
                          .centerRight,
              duration:
                  const Duration(
                milliseconds:
                    220,
              ),
              curve:
                  Curves.easeOutCubic,
              child:
                  FractionallySizedBox(
                widthFactor: 0.5,
                heightFactor: 1.0,
                child: DecoratedBox(
                  decoration:
                      BoxDecoration(
                    color:
                        AppColors
                            .accent
                            .withValues(
                      alpha: 0.16,
                    ),
                    borderRadius:
                        BorderRadius
                            .circular(
                      12,
                    ),
                  ),
                ),
              ),
            ),

            Row(
              children: [
                Expanded(
                  child:
                      _HomeTabButton(
                    label: 'Active',
                    count:
                        activeCount,
                    selected:
                        selectedIndex ==
                            0,
                    onTap: () =>
                        onTabChanged(
                      0,
                    ),
                  ),
                ),

                Expanded(
                  child:
                      _HomeTabButton(
                    label:
                        'Caught Up',
                    count:
                        caughtUpCount,
                    selected:
                        selectedIndex ==
                            1,
                    onTap: () =>
                        onTabChanged(
                      1,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeTabButton
    extends StatelessWidget {
  const _HomeTabButton({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(
    BuildContext context,
  ) {
    final countLabel =
        count == null
            ? '-'
            : '$count';

    final contentColor =
        selected
            ? AppColors.text
            : AppColors.muted;

    return GestureDetector(
      onTap: onTap,
      behavior:
          HitTestBehavior.opaque,
      child:
          AnimatedDefaultTextStyle(
        duration:
            const Duration(
          milliseconds: 160,
        ),
        curve:
            Curves.easeOut,
        style: TextStyle(
          color: contentColor,
          fontSize: 13,
          fontWeight:
              FontWeight.w900,
        ),
        child: Center(
          child: Row(
            mainAxisAlignment:
                MainAxisAlignment
                    .center,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow:
                      TextOverflow
                          .ellipsis,
                ),
              ),

              const SizedBox(
                width: 6,
              ),

              Text(
                countLabel,
                style: TextStyle(
                  color:
                      selected
                          ? AppColors
                              .text
                              .withValues(
                              alpha:
                                  0.76,
                            )
                          : AppColors
                              .muted
                              .withValues(
                              alpha:
                                  0.80,
                            ),
                  fontSize: 12,
                  fontWeight:
                      FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryList
    extends StatelessWidget {
  const _EntryList({
    required this.entries,
    this.caughtUpSection = false,
  });

  final List<HomeEntry>
      entries;

  final bool
      caughtUpSection;

  @override
  Widget build(
    BuildContext context,
  ) {
    if (entries.isEmpty) {
      return _Empty(
        caughtUpSection
            ? 'Nothing caught up yet.'
            : 'Bookmark a manga to see updates here.',
      );
    }

    return ListView.separated(
      padding:
          const EdgeInsets.fromLTRB(
        12,
        8,
        12,
        0,
      ),
      itemCount:
          entries.length,
      separatorBuilder:
          (_, __) =>
              const SizedBox(
        height: 8,
      ),
      itemBuilder:
          (
        context,
        index,
      ) =>
              _HomeCard(
        entry:
            entries[index],
      ),
    );
  }
}

class _HomeCard
    extends StatelessWidget {
  const _HomeCard({
    required this.entry,
  });

  final HomeEntry entry;

  @override
  Widget build(
    BuildContext context,
  ) {
    final String last;

    if (entry.progress == null) {
      last = 'Not started';
    } else if (entry.currentIndex >= 0 &&
        entry.currentIndex <
            entry.chapters.length) {
      last = entry
          .chapters[
              entry.currentIndex]
          .numberLabel;
    } else {
      last = 'Saved';
    }

    const cardRadius =
        18.0;

    const buttonRadius =
        12.0;

    const contentHeight =
        146.0;

    const titleHeight =
        40.0;

    const buttonHeight =
        38.0;

    return Card(
      clipBehavior:
          Clip.antiAlias,
      shape:
          RoundedRectangleBorder(
        borderRadius:
            BorderRadius.circular(
          cardRadius,
        ),
      ),
      child: InkWell(
        borderRadius:
            BorderRadius.circular(
          cardRadius,
        ),
        onTap: () =>
            context.push(
          '/manga/${Uri.encodeComponent(entry.manga.id)}',
        ),
        child: Padding(
          padding:
              const EdgeInsets.all(
            10,
          ),
          child: SizedBox(
            height:
                contentHeight,
            child: Row(
              crossAxisAlignment:
                  CrossAxisAlignment
                      .stretch,
              children: [
                SizedBox(
                  width: 94,
                  child: CoverArt(
                    url:
                        entry.manga
                            .coverUrl,
                    title:
                        entry.manga
                            .title,
                    borderRadius:
                        12,
                  ),
                ),

                const SizedBox(
                  width: 12,
                ),

                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment
                            .start,
                    children: [
                      SizedBox(
                        height:
                            titleHeight,
                        child: Align(
                          alignment:
                              Alignment
                                  .topLeft,
                          child: Text(
                            entry.manga
                                .title,
                            maxLines: 2,
                            overflow:
                                TextOverflow
                                    .ellipsis,
                            style:
                                Theme.of(
                              context,
                            )
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      height:
                                          1.2,
                                    ),
                          ),
                        ),
                      ),

                      const SizedBox(
                        height: 5,
                      ),

                      _ChapterInfoLine(
                        label:
                            'New chapter',
                        value:
                            entry.latest
                                    ?.numberLabel ??
                                '—',
                        valueColor:
                            entry.hasChapters
                                ? AppColors
                                    .accent
                                : AppColors
                                    .muted,
                      ),

                      const SizedBox(
                        height: 2,
                      ),

                      _ChapterInfoLine(
                        label:
                            'Last read',
                        value: last,
                        valueColor:
                            entry.progress ==
                                    null
                                ? AppColors
                                    .muted
                                : AppColors
                                    .accent,
                      ),

                      const SizedBox(
                        height: 2,
                      ),

                      _ChapterInfoLine(
                        label:
                            'Unread chapters',
                        value:
                            entry.hasChapters
                                ? '${entry.unreadCount}'
                                : '—',
                        valueColor:
                            entry.hasChapters
                                ? AppColors
                                    .text
                                : AppColors
                                    .muted,
                      ),

                      const SizedBox(
                        height: 8,
                      ),

                      SizedBox(
                        height:
                            buttonHeight,
                        width:
                            double.infinity,
                        child:
                            FilledButton(
                          style:
                              FilledButton
                                  .styleFrom(
                            minimumSize:
                                const Size(
                              0,
                              buttonHeight,
                            ),
                            padding:
                                const EdgeInsets
                                    .symmetric(
                              horizontal:
                                  12,
                            ),
                            tapTargetSize:
                                MaterialTapTargetSize
                                    .shrinkWrap,
                            disabledBackgroundColor:
                                AppColors
                                    .raised,
                            disabledForegroundColor:
                                AppColors
                                    .muted,
                            shape:
                                RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius
                                      .circular(
                                buttonRadius,
                              ),
                            ),
                          ),

                          /*
                           * No chapters = keep manga visible,
                           * but don't open an invalid reader.
                           */
                          onPressed:
                              !entry
                                      .hasChapters ||
                                  entry
                                      .caughtUp
                              ? null
                              : () {
                                  final chapterId =
                                      entry
                                              .progress
                                              ?.chapterId ??
                                          entry
                                              .chapters
                                              .first
                                              .id;

                                  context.push(
                                    '/reader/${Uri.encodeComponent(entry.manga.id)}?chapter=${Uri.encodeComponent(chapterId)}',
                                  );
                                },

                          child: Text(
                            !entry.hasChapters
                                ? 'Chapters unavailable'
                                : entry.progress ==
                                        null
                                    ? 'Start Reading'
                                    : 'Continue Reading',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChapterInfoLine
    extends StatelessWidget {
  const _ChapterInfoLine({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(
    BuildContext context,
  ) {
    final style =
        Theme.of(context)
            .textTheme
            .bodySmall;

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text:
                '$label: ',
            style: style,
          ),
          TextSpan(
            text: value,
            style:
                style?.copyWith(
              color:
                  valueColor,
              fontWeight:
                  FontWeight.w800,
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow:
          TextOverflow.ellipsis,
    );
  }
}

class _Empty
    extends StatelessWidget {
  const _Empty(
    this.message,
  );

  final String message;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Center(
      child: Padding(
        padding:
            const EdgeInsets.all(
          32,
        ),
        child: Card(
          child: Padding(
            padding:
                const EdgeInsets.all(
              22,
            ),
            child: Column(
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                const Icon(
                  Icons
                      .auto_stories_outlined,
                  color:
                      AppColors.muted,
                ),
                const SizedBox(
                  height: 10,
                ),
                Text(
                  message,
                  textAlign:
                      TextAlign.center,
                  style:
                      const TextStyle(
                    color:
                        AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}