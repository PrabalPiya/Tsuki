import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/models/reading_progress.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/cover_art.dart';
import '../../../shared/widgets/logout_button.dart';

class HomeEntry {
  const HomeEntry({
    required this.manga,
    required this.chapters,
    required this.progress,
    required this.currentIndex,
    required this.highestReadIndex,
    required this.caughtUp,
    required this.sortTime,
  });

  final Manga manga;
  final List<CanonicalChapter> chapters;
  final ReadingProgress? progress;
  final int currentIndex;
  final int highestReadIndex;
  final bool caughtUp;
  final DateTime sortTime;

  CanonicalChapter? get latest {
    if (chapters.isEmpty) return null;

    CanonicalChapter? latestNumbered;
    CanonicalChapter? latestDated;
    for (final chapter in chapters) {
      final number = chapter.number;
      if (number != null &&
          (latestNumbered == null || number > (latestNumbered.number ?? -1))) {
        latestNumbered = chapter;
      }
      if (latestDated == null ||
          chapter.publishedAt.isAfter(latestDated.publishedAt)) {
        latestDated = chapter;
      }
    }
    return latestNumbered ?? latestDated;
  }

  bool get hasChapters => chapters.isNotEmpty;

  CanonicalChapter? get highestReadChapter {
    if (highestReadIndex < 0 || highestReadIndex >= chapters.length) {
      return null;
    }
    return chapters[highestReadIndex];
  }
}

typedef _HomeCatalogEntry = ({Manga manga, List<CanonicalChapter> chapters});

final Provider<void> _homeRefreshProvider = Provider<void>((ref) {
  final timer = Timer.periodic(const Duration(minutes: 15), (_) {
    ref.invalidate(_homeCatalogProvider);
  });
  ref.onDispose(timer.cancel);
});

final _homeChaptersProvider = StreamProvider.autoDispose
    .family<List<CanonicalChapter>, Manga>((ref, manga) {
      final repository = ref.watch(catalogProvider);
      final controller = StreamController<List<CanonicalChapter>>();
      var pending = Future<void>.value();

      Future<void> emitLocal() async {
        final chapters = await repository.localChapters(
          manga,
          allowAdult: false,
        );
        if (!controller.isClosed) {
          // An empty value still refreshes instant catalog/summary metadata
          // without leaving the card in an AsyncLoading state.
          controller.add(chapters ?? const <CanonicalChapter>[]);
        }
      }

      void scheduleEmit() {
        pending = pending.then((_) => emitLocal());
      }

      final memory = repository.memoryChapters(manga, allowAdult: false);
      if (memory != null) controller.add(memory);

      final subscription = repository.chapterUpdates
          .where((mangaId) => mangaId == manga.id)
          .listen((_) => scheduleEmit());

      ref.onDispose(() {
        unawaited(subscription.cancel());
        unawaited(pending.whenComplete(controller.close));
      });

      scheduleEmit();
      // Full indexes are discovered through the bounded repository queue so
      // Home never creates a burst of source requests while scrolling.
      repository.queueLibraryWarmup([manga]);
      return controller.stream;
    });

final StreamProvider<List<_HomeCatalogEntry>>
_homeCatalogProvider = StreamProvider<List<_HomeCatalogEntry>>((ref) async* {
  ref.watch(_homeRefreshProvider);
  // Card-level chapter streams update their labels, but tab membership is
  // computed from this catalog. Rebuild it whenever any verified chapter
  // index changes so a newly caught-up bookmark moves tabs immediately.
  ref.watch(chapterSummaryUpdatesProvider);

  final state = ref.watch(
    userLibraryProvider.select(
      (value) =>
          (bookmarks: value.bookmarks, bookmarkedManga: value.bookmarkedManga),
    ),
  );

  final repository = ref.watch(catalogProvider);
  final manga = <Manga>[];
  for (final id in state.bookmarks) {
    try {
      final item = repository.cached(id) ?? state.bookmarkedManga[id];
      if (item == null) continue;
      repository.remember(item);

      if (item.isFriendlyContent) manga.add(item);
    } catch (_) {
      // Keep the rest of Home usable when one title/source is unavailable.
    }
  }

  final entries = manga
      .map(
        (item) => (
          manga: item,
          chapters:
              repository.memoryChapters(item, allowAdult: false) ?? const [],
        ),
      )
      .toList(growable: false);

  // Register every bookmark for chapter discovery before the first Home
  // payload is emitted. The repository starts the queue immediately while
  // keeping source traffic bounded, so rendering never waits for the network.
  repository.queueLibraryWarmup(manga);

  // Show the library immediately from memory. On-device chapter indexes are
  // filled below without holding the first Home frame behind every bookmark.
  yield entries;

  const batchSize = 6;
  var changed = false;
  for (var start = 0; start < entries.length; start += batchSize) {
    final end = (start + batchSize).clamp(0, entries.length);
    final loaded = await Future.wait(
      entries
          .sublist(start, end)
          .map(
            (entry) => repository.localChapters(entry.manga, allowAdult: false),
          ),
    );
    for (var offset = 0; offset < loaded.length; offset++) {
      final chapters = loaded[offset];
      if (chapters == null || chapters.isEmpty) continue;
      entries[start + offset] = (
        manga: entries[start + offset].manga,
        chapters: chapters,
      );
      changed = true;
    }
  }

  if (changed) yield List<_HomeCatalogEntry>.unmodifiable(entries);
});

final homeEntriesProvider = Provider<AsyncValue<List<HomeEntry>>>((ref) {
  final libraryState = ref.watch(userLibraryProvider);
  final progress = libraryState.progress;

  return ref.watch(_homeCatalogProvider).whenData((catalog) {
    final entries = catalog.where((entry) => entry.manga.isFriendlyContent).map(
      (entry) {
        final chapters = entry.chapters;
        final mangaProgress = progress[entry.manga.id];
        var current = -1;
        var highest = -1;

        if (mangaProgress != null && chapters.isNotEmpty) {
          current = chapters.indexWhere(
            (chapter) => chapter.id == mangaProgress.chapterId,
          );

          final opened = mangaProgress.openedChapterIds;
          double? highestNumber;
          var highestUnnumbered = -1;

          for (var i = 0; i < chapters.length; i++) {
            final chapter = chapters[i];
            if (!opened.contains(chapter.id)) continue;

            final number = chapter.number;
            if (number != null) {
              if (highestNumber == null || number > highestNumber) {
                highestNumber = number;
                highest = i;
              }
            } else if (highestUnnumbered < 0) {
              highestUnnumbered = i;
            }
          }

          if (highest < 0) highest = highestUnnumbered;
          if (highest < 0 && current >= 0) highest = current;
        }

        var latestIndex = -1;
        double? latestNumber;
        var latestDatedIndex = -1;
        var latestDate = DateTime.fromMillisecondsSinceEpoch(0);
        for (var i = 0; i < chapters.length; i++) {
          final chapter = chapters[i];
          final number = chapter.number;
          if (number != null &&
              (latestNumber == null || number > latestNumber)) {
            latestNumber = number;
            latestIndex = i;
          }
          if (latestDatedIndex < 0 || chapter.publishedAt.isAfter(latestDate)) {
            latestDate = chapter.publishedAt;
            latestDatedIndex = i;
          }
        }
        if (latestIndex < 0) latestIndex = latestDatedIndex;

        final caught = isReadingCaughtUp(mangaProgress, chapters);

        final DateTime sort;
        if (caught) {
          sort =
              mangaProgress?.updatedAt ??
              DateTime.fromMillisecondsSinceEpoch(0);
        } else if (latestIndex >= 0) {
          sort = chapters[latestIndex].publishedAt;
        } else {
          sort =
              mangaProgress?.updatedAt ??
              DateTime.fromMillisecondsSinceEpoch(0);
        }

        return HomeEntry(
          manga: entry.manga,
          chapters: chapters,
          progress: mangaProgress,
          currentIndex: current,
          highestReadIndex: highest,
          caughtUp: caught,
          sortTime: sort,
        );
      },
    ).toList();

    entries.sort((a, b) => b.sortTime.compareTo(a.sortTime));
    return entries;
  });
});

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  PageController? _pageController;
  int _selectedSection = 0;
  bool _isAnimating = false;

  PageController get _page => _pageController ??= PageController();

  void _switchTab(int index) {
    if (_isAnimating || _selectedSection == index) return;
    setState(() => _selectedSection = index);
    _isAnimating = true;
    _page
        .animateToPage(
          index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        )
        .then((_) {
          if (!mounted) return;
          setState(() => _isAnimating = false);
        });
  }

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final homeEntries = ref.watch(homeEntriesProvider);

    final activeCount = homeEntries.maybeWhen(
      data: (entries) => entries.where((entry) => !entry.caughtUp).length,
      orElse: () => null,
    );
    final caughtUpCount = homeEntries.maybeWhen(
      data: (entries) => entries.where((entry) => entry.caughtUp).length,
      orElse: () => null,
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const _TsukiTitle(),
        actions: const [
          Padding(padding: EdgeInsets.only(right: 16), child: LogoutButton()),
        ],
      ),
      body: Column(
        children: [
          _HomeTabs(
            activeCount: activeCount,
            caughtUpCount: caughtUpCount,
            selectedIndex: _selectedSection,
            onTabChanged: _switchTab,
          ),
          Expanded(
            child: homeEntries.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => _Empty(
                'Home could not be loaded.',
                onRetry: () => ref.invalidate(_homeCatalogProvider),
              ),
              data: (entries) {
                final active = entries
                    .where((entry) => !entry.caughtUp)
                    .toList();
                final caughtUp = entries
                    .where((entry) => entry.caughtUp)
                    .toList();

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || !_page.hasClients) return;
                  final page = _page.page?.round();
                  if (page != _selectedSection) {
                    _page.jumpToPage(_selectedSection);
                  }
                });

                return PageView(
                  controller: _page,
                  onPageChanged: (index) {
                    if (!_isAnimating) {
                      setState(() => _selectedSection = index);
                    }
                  },
                  children: [
                    _EntryList(entries: active),
                    _EntryList(entries: caughtUp, caughtUpSection: true),
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

class _TsukiTitle extends StatelessWidget {
  const _TsukiTitle();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/branding/tsuki_logo_transparent.png',
          cacheWidth: 384,
          width: 58,
          height: 58,
          fit: BoxFit.contain,
        ),
        const SizedBox(width: 6),
        Text(
          'Tsuki',
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 35,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _HomeTabs extends StatelessWidget {
  const _HomeTabs({
    required this.activeCount,
    required this.caughtUpCount,
    required this.selectedIndex,
    required this.onTabChanged,
  });

  final int? activeCount;
  final int? caughtUpCount;
  final int selectedIndex;
  final ValueChanged<int> onTabChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Container(
        height: 46,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.raised.withValues(alpha: 0.36),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Stack(
          children: [
            AnimatedAlign(
              alignment: selectedIndex == 0
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: FractionallySizedBox(
                widthFactor: 0.5,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: _HomeTabButton(
                    label: 'Active',
                    count: activeCount,
                    selected: selectedIndex == 0,
                    onTap: () => onTabChanged(0),
                  ),
                ),
                Expanded(
                  child: _HomeTabButton(
                    label: 'Caught Up',
                    count: caughtUpCount,
                    selected: selectedIndex == 1,
                    onTap: () => onTabChanged(1),
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

class _HomeTabButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final countLabel = count == null ? '-' : '$count';
    final contentColor = selected ? AppColors.text : AppColors.muted;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        style: TextStyle(
          color: contentColor,
          fontSize: 13,
          fontWeight: FontWeight.w900,
        ),
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                countLabel,
                style: TextStyle(
                  color: selected
                      ? AppColors.text.withValues(alpha: 0.76)
                      : AppColors.muted.withValues(alpha: 0.80),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryList extends StatelessWidget {
  const _EntryList({required this.entries, this.caughtUpSection = false});

  final List<HomeEntry> entries;
  final bool caughtUpSection;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return _Empty(
        caughtUpSection
            ? 'Nothing caught up yet.'
            : 'Bookmark a manga to see updates here.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _HomeCard(entry: entries[index]),
    );
  }
}

class _HomeCard extends ConsumerWidget {
  const _HomeCard({required this.entry});

  final HomeEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loaded = ref.watch(_homeChaptersProvider(entry.manga)).value;
    final chapters = loaded != null && loaded.isNotEmpty
        ? loaded
        : entry.chapters;
    final latest = _latestChapter(chapters);
    final latestLabel =
        latest?.numberLabel ?? entry.manga.catalogChapterDisplayLabel;
    final highestRead = _highestReadChapter(chapters, entry.progress);
    final hasChapters = chapters.isNotEmpty;
    final caughtUp = isReadingCaughtUp(entry.progress, chapters);
    final String lastRead;
    if (highestRead != null) {
      lastRead = highestRead.numberLabel;
    } else if (entry.progress != null) {
      lastRead = 'Saved';
    } else {
      lastRead = 'Not started';
    }

    const cardRadius = 18.0;
    const buttonRadius = 12.0;
    const contentHeight = 146.0;
    const titleHeight = 40.0;
    const buttonHeight = 38.0;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(cardRadius),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(cardRadius),
        onTap: () =>
            context.push('/manga/${Uri.encodeComponent(entry.manga.id)}'),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: SizedBox(
            height: contentHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 94,
                  child: CoverArt(
                    url: entry.manga.coverUrl,
                    title: entry.manga.title,
                    borderRadius: 12,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: titleHeight,
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Text(
                            entry.manga.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(height: 1.2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      _ChapterInfoLine(
                        label: 'Latest Chapter',
                        value: latestLabel ?? 'Unavailable',
                        valueColor: latestLabel == null
                            ? AppColors.muted
                            : AppColors.accent,
                      ),
                      const SizedBox(height: 2),
                      _ChapterInfoLine(
                        label: 'Viewed Chapter',
                        value: lastRead,
                        valueColor: highestRead == null
                            ? AppColors.muted
                            : AppColors.accent,
                      ),
                      const SizedBox(height: 2),
                      _ChapterInfoLine(
                        label: 'Last Upload',
                        value: _formatUploadDate(latest?.publishedAt),
                        valueColor: latest == null
                            ? AppColors.muted
                            : AppColors.text,
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: buttonHeight,
                        width: double.infinity,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, buttonHeight),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            disabledBackgroundColor: AppColors.raised,
                            disabledForegroundColor: AppColors.muted,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(buttonRadius),
                            ),
                          ),
                          onPressed: caughtUp
                              ? null
                              : () {
                                  if (!hasChapters) {
                                    context.push(
                                      '/manga/${Uri.encodeComponent(entry.manga.id)}',
                                    );
                                    return;
                                  }
                                  final chapterId =
                                      entry.progress?.chapterId ??
                                      chapters.first.id;
                                  context.push(
                                    '/reader/${Uri.encodeComponent(entry.manga.id)}?chapter=${Uri.encodeComponent(chapterId)}',
                                  );
                                },
                          child: Text(
                            !hasChapters
                                ? 'View Chapters'
                                : caughtUp
                                ? 'Caught Up'
                                : entry.progress == null
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

CanonicalChapter? _latestChapter(List<CanonicalChapter> chapters) {
  CanonicalChapter? latestNumbered;
  CanonicalChapter? latestDated;
  for (final chapter in chapters) {
    final number = chapter.number;
    if (number != null &&
        (latestNumbered == null || number > (latestNumbered.number ?? -1))) {
      latestNumbered = chapter;
    }
    if (latestDated == null ||
        chapter.publishedAt.isAfter(latestDated.publishedAt)) {
      latestDated = chapter;
    }
  }
  return latestNumbered ?? latestDated;
}

CanonicalChapter? _highestReadChapter(
  List<CanonicalChapter> chapters,
  ReadingProgress? progress,
) {
  if (progress == null || chapters.isEmpty) return null;

  CanonicalChapter? highestNumbered;
  CanonicalChapter? current;
  for (final chapter in chapters) {
    if (chapter.id == progress.chapterId) current = chapter;
    if (!progress.openedChapterIds.contains(chapter.id)) continue;
    if (highestNumbered == null ||
        (chapter.number ?? -1) > (highestNumbered.number ?? -1)) {
      highestNumbered = chapter;
    }
  }
  return highestNumbered ?? current;
}

String _formatUploadDate(DateTime? value) {
  if (value == null || value.millisecondsSinceEpoch <= 0) return '—';
  final date = value.toLocal();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

class _ChapterInfoLine extends StatelessWidget {
  const _ChapterInfoLine({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '$label: ', style: style),
          TextSpan(
            text: value,
            style: style?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.message, {this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.auto_stories_outlined, color: AppColors.muted),
                const SizedBox(height: 10),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
