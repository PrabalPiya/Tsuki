import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/models/reading_progress.dart';
import '../../../core/state/providers.dart';
import '../../../core/storage/image_cache.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/synopsis_summary.dart';

const double _detailRadius = 18.0;
const double _detailPadding = 28.0;

/* -----------------------------------------------------------
 * Chapter layout
 * --------------------------------------------------------- */

const double _chapterTileHeight = 60.0;
const double _chapterGap = 10.0;
const int _maxVisibleChapters = 4;

const double _fourChapterViewportHeight =
    (_chapterTileHeight * _maxVisibleChapters) +
        (_chapterGap * (_maxVisibleChapters - 1));

/* -----------------------------------------------------------
 * Hero layout
 * --------------------------------------------------------- */

const double _heroAspectRatio = 0.62;

const double _heroToChapterSpacing = 24.0;
const double _heroContentTopFactor = 0.46;

const double _heroTitleToInfoSpacing = 12.0;
const double _heroInfoToSynopsisSpacing = 17.0;
const double _heroSynopsisToActionsSpacing = 20.0;

/* -----------------------------------------------------------
 * Chapter section
 * --------------------------------------------------------- */

const double _chapterSectionOffset = -1.0;

const double _chapterTitleToListSpacing = 16.0;
const double _chapterBottomVisualSpacing = 22.0;

/* -----------------------------------------------------------
 * 3D cover preview
 * --------------------------------------------------------- */

const double _maxCoverRotation = 0.70;

const Duration _coverReturnDuration =
    Duration(milliseconds: 300);

/* ===========================================================
 * MANGA DETAILS SCREEN
 * ========================================================= */

class MangaDetailsScreen extends ConsumerWidget {
  const MangaDetailsScreen({
    super.key,
    required this.mangaId,
  });

  final String mangaId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(catalogProvider);
    final library = ref.watch(userLibraryProvider);

    final saved = library.bookmarkedManga[mangaId];

    if (saved != null) {
      repository.remember(saved);
    }

    final cached = repository.cached(mangaId);

    if (cached != null) {
      return _Details(
        manga: cached,
      );
    }

    return FutureBuilder<Manga?>(
      future: repository.details(mangaId),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (snapshot.hasError) {
          return Scaffold(
            body: _ModernMessage(
              icon: Icons.error_outline_rounded,
              message: 'Unable to load manga details.',
              onRetry: () {
                if (context.canPop()) {
                  context.pop();
                }
              },
              retryLabel: 'Go Back',
            ),
          );
        }

        final manga = snapshot.data;

        if (manga == null) {
          return Scaffold(
            body: _ModernMessage(
              icon: Icons.menu_book_outlined,
              message: 'Manga unavailable right now.',
              onRetry: () {
                if (context.canPop()) {
                  context.pop();
                }
              },
              retryLabel: 'Go Back',
            ),
          );
        }

        repository.remember(manga);

        return _Details(
          manga: manga,
        );
      },
    );
  }
}

/* ===========================================================
 * DETAILS
 * ========================================================= */

class _Details extends ConsumerWidget {
  const _Details({
    required this.manga,
  });

  final Manga manga;

  @override
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) {
    final library =
        ref.watch(userLibraryProvider);

    final chaptersAsync =
        ref.watch(chapterProvider(manga));

    final bookmarked =
        library.bookmarks.contains(manga.id);

    final progress =
        library.progress[manga.id];

    final loadedChapters =
        chaptersAsync.valueOrNull ??
            const <CanonicalChapter>[];

    final readableChapters = loadedChapters
        .where(
          (chapter) =>
              chapter.hasDirectlyReadableCopy,
        )
        .toList(
          growable: false,
        );

    final actualChapterCount =
        loadedChapters.isNotEmpty
            ? loadedChapters.length
            : manga.chapterCount;

    final startReadingLabel =
        progress == null
            ? 'Start Reading'
            : 'Continue Reading';

    VoidCallback? onStartReading;

    if (readableChapters.isNotEmpty) {
      onStartReading = () {
        CanonicalChapter selected =
            readableChapters.first;

        final currentId =
            progress?.chapterId;

        if (currentId != null &&
            currentId.isNotEmpty) {
          for (final chapter
              in readableChapters) {
            if (chapter.id == currentId) {
              selected = chapter;
              break;
            }
          }
        }

        context.push(
          '/reader/${Uri.encodeComponent(manga.id)}'
          '?chapter=${Uri.encodeComponent(selected.id)}',
        );
      };
    }

    final systemBottom =
        MediaQuery.paddingOf(context).bottom;

    final bottomSpacing =
        systemBottom +
            _chapterBottomVisualSpacing;

    final chapterSectionScrollable =
        loadedChapters.length >
            _maxVisibleChapters;

    return Scaffold(
      body: CustomScrollView(
        physics:
            const ClampingScrollPhysics(),
        slivers: [
          /* HERO */

          SliverToBoxAdapter(
            child: _MangaHero(
              manga: manga,
              chapterCount:
                  actualChapterCount,
              bookmarked:
                  bookmarked,
              startReadingLabel:
                  startReadingLabel,
              onStartReading:
                  onStartReading,
              onBack: () {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/');
                }
              },
              onToggleBookmark: () {
                ref
                    .read(
                      userLibraryProvider
                          .notifier,
                    )
                    .toggleBookmark(
                      manga,
                    );
              },
            ),
          ),

          /* CHAPTER HEADING */

          SliverToBoxAdapter(
            child: Transform.translate(
              offset: const Offset(
                0,
                _chapterSectionOffset,
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(
                  horizontal:
                      _detailPadding,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Chapters',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(
                              fontSize: 28,
                              fontWeight:
                                  FontWeight.w800,
                            ),
                      ),
                    ),

                    if (chapterSectionScrollable)
                      Container(
                        padding:
                            const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration:
                            BoxDecoration(
                          color:
                              AppColors.surface
                                  .withValues(
                            alpha: 0.7,
                          ),
                          borderRadius:
                              BorderRadius.circular(
                            999,
                          ),
                          border:
                              Border.all(
                            color:
                                AppColors.outline,
                          ),
                        ),
                        child: Row(
                          mainAxisSize:
                              MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons
                                  .unfold_more_rounded,
                              size: 15,
                              color:
                                  AppColors.muted,
                            ),
                            const SizedBox(
                              width: 4,
                            ),
                            Text(
                              'Scroll',
                              style:
                                  Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color:
                                            AppColors.muted,
                                        fontSize:
                                            11,
                                        fontWeight:
                                            FontWeight
                                                .w700,
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

          SliverToBoxAdapter(
            child: Transform.translate(
              offset: const Offset(
                0,
                _chapterSectionOffset,
              ),
              child: const SizedBox(
                height:
                    _chapterTitleToListSpacing,
              ),
            ),
          ),

          /* CHAPTER CONTENT */

          chaptersAsync.when(
            loading: () {
              return SliverToBoxAdapter(
                child: Transform.translate(
                  offset: const Offset(
                    0,
                    _chapterSectionOffset,
                  ),
                  child: const SizedBox(
                    height: 150,
                    child: Center(
                      child:
                          CircularProgressIndicator(),
                    ),
                  ),
                ),
              );
            },

            error: (
              error,
              stackTrace,
            ) {
              return SliverToBoxAdapter(
                child: Transform.translate(
                  offset: const Offset(
                    0,
                    _chapterSectionOffset,
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(
                      horizontal:
                          _detailPadding,
                    ),
                    child: _ModernMessage(
                      icon:
                          Icons.cloud_off_rounded,
                      message:
                          'Unable to retrieve chapters right now.',
                      retryLabel: 'Retry',
                      onRetry: () {
                        ref.invalidate(
                          chapterProvider(
                            manga,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
            },

            data: (items) {
              if (items.isEmpty) {
                return SliverToBoxAdapter(
                  child: Transform.translate(
                    offset: const Offset(
                      0,
                      _chapterSectionOffset,
                    ),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(
                        horizontal:
                            _detailPadding,
                      ),
                      child: _ModernMessage(
                        icon: Icons
                            .menu_book_outlined,
                        message:
                            'No English chapters available from the configured sources.',
                        retryLabel:
                            'Refresh',
                        onRetry: () {
                          ref.invalidate(
                            chapterProvider(
                              manga,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                );
              }

              return SliverToBoxAdapter(
                child: Transform.translate(
                  offset: const Offset(
                    0,
                    _chapterSectionOffset,
                  ),
                  child: _ChapterViewport(
                    manga: manga,
                    chapters: items,
                    progress: progress,
                  ),
                ),
              );
            },
          ),

          SliverToBoxAdapter(
            child: SizedBox(
              height:
                  bottomSpacing,
            ),
          ),
        ],
      ),
    );
  }
}

/* ===========================================================
 * CHAPTER VIEWPORT
 * ========================================================= */

class _ChapterViewport
    extends StatefulWidget {
  const _ChapterViewport({
    required this.manga,
    required this.chapters,
    required this.progress,
  });

  final Manga manga;

  final List<CanonicalChapter>
      chapters;

  final ReadingProgress? progress;

  @override
  State<_ChapterViewport>
      createState() =>
          _ChapterViewportState();
}

class _ChapterViewportState
    extends State<_ChapterViewport> {
  late final ScrollController
      _controller;

  @override
  void initState() {
    super.initState();

    _controller =
        ScrollController();
  }

  @override
  void dispose() {
    _controller.dispose();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final reversed =
        widget.chapters.reversed
            .toList(
      growable: false,
    );

    final visibleCount =
        reversed.length <
                _maxVisibleChapters
            ? reversed.length
            : _maxVisibleChapters;

    final double viewportHeight;

    if (visibleCount ==
        _maxVisibleChapters) {
      viewportHeight =
          _fourChapterViewportHeight;
    } else {
      viewportHeight =
          (_chapterTileHeight *
                  visibleCount) +
              (_chapterGap *
                  (visibleCount - 1));
    }

    final canScroll =
        reversed.length >
            _maxVisibleChapters;

    return Padding(
      padding:
          const EdgeInsets.symmetric(
        horizontal:
            _detailPadding,
      ),
      child: SizedBox(
        width:
            double.infinity,
        height:
            viewportHeight,
        child: ClipRect(
          child: Scrollbar(
            controller:
                _controller,
            thumbVisibility:
                false,
            thickness:
                3,
            radius:
                const Radius.circular(
              999,
            ),
            child:
                ListView.separated(
              controller:
                  _controller,
              padding:
                  EdgeInsets.zero,
              primary:
                  false,
              shrinkWrap:
                  false,
              clipBehavior:
                  Clip.hardEdge,
              physics:
                  canScroll
                      ? const ClampingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
              itemCount:
                  reversed.length,

              separatorBuilder:
                  (
                context,
                index,
              ) {
                return const SizedBox(
                  height:
                      _chapterGap,
                );
              },

              itemBuilder:
                  (
                context,
                index,
              ) {
                final chapter =
                    reversed[index];

                final readable =
                    chapter
                        .hasDirectlyReadableCopy;

                final state =
                    _chapterState(
                  chapter,
                  widget.progress,
                );

                return SizedBox(
                  height:
                      _chapterTileHeight,
                  child:
                      _ChapterTile(
                    chapter:
                        chapter,
                    state:
                        state,
                    readable:
                        readable,
                    onTap:
                        readable
                            ? () {
                                context.push(
                                  '/reader/${Uri.encodeComponent(widget.manga.id)}'
                                  '?chapter=${Uri.encodeComponent(chapter.id)}',
                                );
                              }
                            : null,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  String _chapterState(
    CanonicalChapter chapter,
    ReadingProgress? progress,
  ) {
    if (progress == null) {
      return 'NEW';
    }

    if (!progress
        .openedChapterIds
        .contains(
          chapter.id,
        )) {
      return 'NEW';
    }

    return 'READ';
  }
}

/* ===========================================================
 * HERO
 * ========================================================= */

class _MangaHero extends StatelessWidget {
  const _MangaHero({
    required this.manga,
    required this.chapterCount,
    required this.onBack,
    required this.bookmarked,
    required this.onToggleBookmark,
    required this.onStartReading,
    required this.startReadingLabel,
  });

  final Manga manga;
  final int chapterCount;

  final VoidCallback onBack;

  final bool bookmarked;
  final VoidCallback onToggleBookmark;

  final VoidCallback? onStartReading;
  final String startReadingLabel;

  void _showCoverPreview(
  BuildContext context,
) {
  if (manga.coverUrl.trim().isEmpty) {
    return;
  }

  showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    barrierLabel: 'Cover preview',
    transitionDuration: const Duration(
      milliseconds: 220,
    ),

    pageBuilder: (
      dialogContext,
      animation,
      secondaryAnimation,
    ) {
      return _CoverPreviewOverlay(
        manga: manga,
      );
    },

    transitionBuilder: (
      context,
      animation,
      secondaryAnimation,
      child,
    ) {
      /*
       * IMPORTANT:
       * Do not scale the fullscreen overlay here.
       *
       * Just return it normally.
       */
      return child;
    },
  );
}

  @override
  Widget build(
    BuildContext context,
  ) {
    final coverUrl =
        manga.coverUrl.trim();

    final Widget cover;

    if (coverUrl.isEmpty) {
      cover =
          _HeroFallback(
        title:
            manga.title,
      );
    } else {
      cover =
          CachedNetworkImage(
        imageUrl:
            coverUrl,
        cacheManager:
            MangaImageCache.instance,
        fit:
            BoxFit.cover,

        placeholder:
            (_, __) {
          return _HeroFallback(
            title:
                manga.title,
          );
        },

        errorWidget:
            (_, __, ___) {
          return _HeroFallback(
            title:
                manga.title,
          );
        },
      );
    }

    final width =
        MediaQuery.sizeOf(
      context,
    ).width;

    final baseHeroHeight =
        width /
            _heroAspectRatio;

    final synopsis =
        summarizeSynopsis(
      manga.synopsis,
    );

    final title =
        manga.title
                .trim()
                .isEmpty
            ? 'Untitled'
            : manga.title
                .trim();

    final pageBackground =
        Theme.of(context)
            .scaffoldBackgroundColor;

    final contentWidth =
        width -
            (_detailPadding * 2);

    final titleStyle =
        Theme.of(context)
            .textTheme
            .headlineLarge
            ?.copyWith(
              fontSize:
                  30,
              height:
                  1.2,
              fontWeight:
                  FontWeight.w800,
              color:
                  Colors.white,
              shadows:
                  const [
                Shadow(
                  color:
                      Colors.black,
                  blurRadius:
                      8,
                  offset:
                      Offset(
                    0,
                    1,
                  ),
                ),
                Shadow(
                  color:
                      Colors.black54,
                  blurRadius:
                      16,
                ),
              ],
            );

    final synopsisStyle =
        Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(
              color:
                  Colors.white
                      .withValues(
                alpha:
                    0.94,
              ),
              height:
                  1.42,
              wordSpacing:
                  0.15,
              letterSpacing:
                  0.02,
            );

    /*
     * Measure only the content that is actually visible.
     *
     * No fake blank title line.
     * No fake blank synopsis lines.
     */
    final titlePainter =
        TextPainter(
      text:
          TextSpan(
        text:
            title,
        style:
            titleStyle,
      ),
      textDirection:
          TextDirection.ltr,
      maxLines:
          2,
      ellipsis:
          '…',
    )..layout(
        maxWidth:
            contentWidth,
      );

    final synopsisPainter =
        TextPainter(
      text:
          TextSpan(
        text:
            synopsis,
        style:
            synopsisStyle,
      ),
      textDirection:
          TextDirection.ltr,
      textAlign:
          TextAlign.justify,
      maxLines:
          10,
    )..layout(
        maxWidth:
            contentWidth,
      );

    /*
     * Title always starts at the same visual position.
     */
    final contentTop =
        baseHeroHeight *
            _heroContentTopFactor;

    /*
     * Natural content flow:
     *
     * Title actual height
     * + exact gap
     * + info chips
     * + exact gap
     * + synopsis actual height
     * + exact gap
     * + buttons
     */
    final contentHeight =
        titlePainter.height +
            _heroTitleToInfoSpacing +
            34 +
            _heroInfoToSynopsisSpacing +
            synopsisPainter.height +
            _heroSynopsisToActionsSpacing +
            50;

    /*
     * Hero finishes exactly after the action buttons
     * plus the exact Bookmark/Read -> Chapters spacing.
     */
    final layoutHeight =
        contentTop +
            contentHeight +
            _heroToChapterSpacing;

    return SizedBox(
      height:
          layoutHeight,
      child:
          Stack(
        clipBehavior:
            Clip.hardEdge,
        children: [
          /* COVER */

          Positioned.fill(
            child:
                cover,
          ),

          /* MAIN DARKNESS */

          const Positioned.fill(
            child:
                IgnorePointer(
              child:
                  DecoratedBox(
                decoration:
                    BoxDecoration(
                  gradient:
                      LinearGradient(
                    begin:
                        Alignment.topCenter,
                    end:
                        Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Color(
                        0x18000000,
                      ),
                      Color(
                        0x70000000,
                      ),
                      Color(
                        0xC0000000,
                      ),
                      Color(
                        0xE0000000,
                      ),
                      Color(
                        0xF5000000,
                      ),
                    ],
                    stops: [
                      0.00,
                      0.20,
                      0.34,
                      0.49,
                      0.67,
                      1.00,
                    ],
                  ),
                ),
              ),
            ),
          ),

          /* SECOND DARKNESS */

          Positioned(
            left:
                0,
            right:
                0,
            bottom:
                0,
            height:
                layoutHeight *
                    0.74,
            child:
                const IgnorePointer(
              child:
                  DecoratedBox(
                decoration:
                    BoxDecoration(
                  gradient:
                      LinearGradient(
                    begin:
                        Alignment.topCenter,
                    end:
                        Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Color(
                        0x50000000,
                      ),
                      Color(
                        0xA8000000,
                      ),
                      Color(
                        0xD8000000,
                      ),
                      Color(
                        0xF0000000,
                      ),
                    ],
                    stops: [
                      0.00,
                      0.15,
                      0.35,
                      0.61,
                      1.00,
                    ],
                  ),
                ),
              ),
            ),
          ),

          /* BOTTOM FADE INTO PAGE BACKGROUND */

          Positioned(
            left:
                0,
            right:
                0,
            bottom:
                0,
            height:
                120,
            child:
                IgnorePointer(
              child:
                  DecoratedBox(
                decoration:
                    BoxDecoration(
                  gradient:
                      LinearGradient(
                    begin:
                        Alignment.topCenter,
                    end:
                        Alignment.bottomCenter,
                    colors: [
                      pageBackground
                          .withValues(
                        alpha:
                            0,
                      ),
                      pageBackground
                          .withValues(
                        alpha:
                            0.20,
                      ),
                      pageBackground
                          .withValues(
                        alpha:
                            0.62,
                      ),
                      pageBackground,
                    ],
                    stops:
                        const [
                      0.00,
                      0.38,
                      0.76,
                      1.00,
                    ],
                  ),
                ),
              ),
            ),
          ),

          /* COVER TAP SURFACE */

          if (coverUrl.isNotEmpty)
            Positioned.fill(
              child:
                  GestureDetector(
                behavior:
                    HitTestBehavior.translucent,
                onTap:
                    () {
                  _showCoverPreview(
                    context,
                  );
                },
                child:
                    const SizedBox.expand(),
              ),
            ),

          /* BACK BUTTON */

          Positioned(
            top:
                MediaQuery.paddingOf(
                          context,
                        ).top -
                    2,
            left:
                20,
            child:
                IconButton(
              onPressed:
                  onBack,
              style:
                  IconButton.styleFrom(
                backgroundColor:
                    AppColors.glass,
                side:
                    const BorderSide(
                  color:
                      AppColors.outline,
                ),
              ),
              icon:
                  const Icon(
                Icons
                    .arrow_back_rounded,
              ),
              tooltip:
                  'Back',
            ),
          ),

          /* NATURAL HERO CONTENT FLOW */

          Positioned(
            left:
                _detailPadding,
            right:
                _detailPadding,
            top:
                contentTop,
            child:
                Column(
              mainAxisSize:
                  MainAxisSize.min,
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                /* TITLE */

                Text(
                  title,
                  softWrap:
                      true,
                  maxLines:
                      2,
                  overflow:
                      TextOverflow.ellipsis,
                  style:
                      titleStyle,
                ),

                const SizedBox(
                  height:
                      _heroTitleToInfoSpacing,
                ),

                /* INFO */

                Row(
                  children: [
                    Expanded(
                      child:
                          _InfoChip(
                        icon:
                            Icons.star_rounded,
                        label:
                            manga.ratingLabel,
                      ),
                    ),

                    const SizedBox(
                      width:
                          14,
                    ),

                    Expanded(
                      child:
                          _InfoChip(
                        icon:
                            Icons.bolt_rounded,
                        label:
                            manga.statusLabel,
                      ),
                    ),

                    const SizedBox(
                      width:
                          14,
                    ),

                    Expanded(
                      child:
                          _InfoChip(
                        icon:
                            Icons
                                .library_books_rounded,
                        label:
                            '$chapterCount chp',
                      ),
                    ),
                  ],
                ),

                const SizedBox(
                  height:
                      _heroInfoToSynopsisSpacing,
                ),

                /* SYNOPSIS */

                Text(
                  synopsis,
                  textAlign:
                      TextAlign.justify,
                  maxLines:
                      10,
                  overflow:
                      TextOverflow.clip,
                  style:
                      synopsisStyle,
                ),

                const SizedBox(
                  height:
                      _heroSynopsisToActionsSpacing,
                ),

                /* ACTIONS */

                Row(
                  children: [
                    Expanded(
                      child:
                          _BookmarkButton(
                        bookmarked:
                            bookmarked,
                        onPressed:
                            onToggleBookmark,
                      ),
                    ),

                    const SizedBox(
                      width:
                          16,
                    ),

                    Expanded(
                      child:
                          _ReadActionCard(
                        label:
                            startReadingLabel,
                        onPressed:
                            onStartReading,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ===========================================================
 * COVER PREVIEW OVERLAY
 * ========================================================= */

class _CoverPreviewOverlay
    extends StatelessWidget {
  const _CoverPreviewOverlay({
    required this.manga,
  });

  final Manga manga;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Material(
      color: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          /*
           * FULLSCREEN BLUR.
           *
           * This never scales, so you will no longer
           * see the blurred rectangle growing outward
           * from the edges.
           */
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,

              onTap: () {
                Navigator.of(context).pop();
              },

              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: 20,
                  sigmaY: 20,
                ),
                child: ColoredBox(
                  color: Colors.black.withValues(
                    alpha: 0.72,
                  ),
                ),
              ),
            ),
          ),

          /*
           * 3D COVER.
           *
           * Kept completely separate from the
           * fullscreen blur.
           */
          SafeArea(
            child: Center(
              child: _CoverEntranceAnimation(
                child: _RotatingCoverCard(
                  manga: manga,
                ),
              ),
            ),
          ),

          /*
           * CLOSE BUTTON
           */
          Positioned(
            top:
                MediaQuery.paddingOf(context).top +
                    14,
            right: 18,
            child: IconButton(
              onPressed: () {
                Navigator.of(context).pop();
              },

              style: IconButton.styleFrom(
                backgroundColor:
                    Colors.black.withValues(
                  alpha: 0.45,
                ),
                foregroundColor: Colors.white,
                side: BorderSide(
                  color:
                      Colors.white.withValues(
                    alpha: 0.15,
                  ),
                ),
              ),

              icon: const Icon(
                Icons.close_rounded,
              ),
            ),
          ),

          /*
           * DRAG HINT
           */
          Positioned(
            left: 0,
            right: 0,
            bottom:
                MediaQuery.paddingOf(context).bottom +
                    28,
            child: IgnorePointer(
              child: Row(
                mainAxisAlignment:
                    MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.swipe_rounded,
                    size: 18,
                    color:
                        Colors.white.withValues(
                      alpha: 0.65,
                    ),
                  ),

                  const SizedBox(
                    width: 8,
                  ),

                  Text(
                    'Drag to rotate',
                    style: TextStyle(
                      color:
                          Colors.white.withValues(
                        alpha: 0.68,
                      ),
                      fontSize: 13,
                      fontWeight:
                          FontWeight.w600,
                    ),
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

class _CoverEntranceAnimation
    extends StatefulWidget {
  const _CoverEntranceAnimation({
    required this.child,
  });

  final Widget child;

  @override
  State<_CoverEntranceAnimation>
      createState() =>
          _CoverEntranceAnimationState();
}

class _CoverEntranceAnimationState
    extends State<_CoverEntranceAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController
      _controller;

  late final Animation<double>
      _scale;

  late final Animation<double>
      _opacity;

  @override
  void initState() {
    super.initState();

    _controller =
        AnimationController(
      vsync: this,
      duration: const Duration(
        milliseconds: 220,
      ),
    );

    final curved =
        CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );

    _scale =
        Tween<double>(
      begin: 0.94,
      end: 1.0,
    ).animate(curved);

    _opacity =
        Tween<double>(
      begin: 0,
      end: 1,
    ).animate(curved);

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(
        scale: _scale,
        child: widget.child,
      ),
    );
  }
}

/* ===========================================================
 * ROTATING 3D COVER CARD
 * ========================================================= */

class _RotatingCoverCard
    extends StatefulWidget {
  const _RotatingCoverCard({
    required this.manga,
  });

  final Manga manga;

  @override
  State<_RotatingCoverCard>
      createState() =>
          _RotatingCoverCardState();
}

class _RotatingCoverCardState
    extends State<_RotatingCoverCard>
    with SingleTickerProviderStateMixin {
  double _rotationY =
      0;

  late final AnimationController
      _animationController;

  Animation<double>?
      _returnAnimation;

  @override
  void initState() {
    super.initState();

    _animationController =
        AnimationController(
      vsync:
          this,
      duration:
          _coverReturnDuration,
    );

    _animationController
        .addListener(
      () {
        final animation =
            _returnAnimation;

        if (animation ==
            null) {
          return;
        }

        setState(
          () {
            _rotationY =
                animation.value;
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _animationController
        .dispose();

    super.dispose();
  }

  void _dragStart(
    DragStartDetails details,
  ) {
    _animationController
        .stop();
  }

  void _dragUpdate(
    DragUpdateDetails details,
  ) {
    final delta =
        details.delta.dx /
            230;

    setState(
      () {
        _rotationY =
            (_rotationY +
                    delta)
                .clamp(
          -_maxCoverRotation,
          _maxCoverRotation,
        );
      },
    );
  }

  void _dragEnd(
    DragEndDetails details,
  ) {
    _returnAnimation =
        Tween<double>(
      begin:
          _rotationY,
      end:
          0,
    ).animate(
      CurvedAnimation(
        parent:
            _animationController,
        curve:
            Curves.easeOutBack,
      ),
    );

    _animationController
      ..reset()
      ..forward();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final screen =
        MediaQuery.sizeOf(
      context,
    );

    final double cardWidth =
        screen.width *
                    0.76 >
                360
            ? 360
            : screen.width *
                0.76;

    final cardHeight =
        cardWidth *
            1.50;

    final rotationPercent =
        (_rotationY /
                _maxCoverRotation)
            .clamp(
      -1.0,
      1.0,
    );

    final tiltStrength =
        rotationPercent
            .abs();

    return GestureDetector(
      behavior:
          HitTestBehavior.opaque,

      onHorizontalDragStart:
          _dragStart,

      onHorizontalDragUpdate:
          _dragUpdate,

      onHorizontalDragEnd:
          _dragEnd,

      child:
          Transform(
        alignment:
            Alignment.center,

        transform:
            Matrix4.identity()
              ..setEntry(
                3,
                2,
                0.0015,
              )
              ..rotateY(
                _rotationY,
              ),

        child:
            Container(
          width:
              cardWidth,
          height:
              cardHeight,

          decoration:
              BoxDecoration(
            borderRadius:
                BorderRadius.circular(
              22,
            ),

            boxShadow: [
              BoxShadow(
                color:
                    Colors.black
                        .withValues(
                  alpha:
                      0.72,
                ),
                blurRadius:
                    48,
                spreadRadius:
                    6,
                offset:
                    Offset(
                  -rotationPercent *
                      25,
                  24,
                ),
              ),

              BoxShadow(
                color:
                    Colors.white
                        .withValues(
                  alpha:
                      0.06,
                ),
                blurRadius:
                    18,
                spreadRadius:
                    1,
              ),
            ],
          ),

          child:
              ClipRRect(
            borderRadius:
                BorderRadius.circular(
              22,
            ),

            child:
                Stack(
              fit:
                  StackFit.expand,
              children: [
                /* COVER IMAGE */

                CachedNetworkImage(
                  imageUrl:
                      widget
                          .manga
                          .coverUrl,

                  cacheManager:
                      MangaImageCache
                          .instance,

                  fit:
                      BoxFit.cover,

                  placeholder:
                      (
                    context,
                    url,
                  ) {
                    return _HeroFallback(
                      title:
                          widget
                              .manga
                              .title,
                    );
                  },

                  errorWidget:
                      (
                    context,
                    url,
                    error,
                  ) {
                    return _HeroFallback(
                      title:
                          widget
                              .manga
                              .title,
                    );
                  },
                ),

                /* DARK SIDE */

                IgnorePointer(
                  child:
                      DecoratedBox(
                    decoration:
                        BoxDecoration(
                      gradient:
                          LinearGradient(
                        begin:
                            rotationPercent >
                                    0
                                ? Alignment
                                    .centerRight
                                : Alignment
                                    .centerLeft,

                        end:
                            rotationPercent >
                                    0
                                ? Alignment
                                    .centerLeft
                                : Alignment
                                    .centerRight,

                        colors: [
                          Colors.black
                              .withValues(
                            alpha:
                                tiltStrength *
                                    0.38,
                          ),

                          Colors.transparent,

                          Colors.transparent,
                        ],

                        stops:
                            const [
                          0,
                          0.42,
                          1,
                        ],
                      ),
                    ),
                  ),
                ),

                /* MOVING LIGHT / CARD SHINE */

                IgnorePointer(
                  child:
                      Opacity(
                    opacity:
                        0.12 +
                            tiltStrength *
                                0.25,

                    child:
                        Transform.translate(
                      offset:
                          Offset(
                        -rotationPercent *
                            90,
                        0,
                      ),

                      child:
                          const DecoratedBox(
                        decoration:
                            BoxDecoration(
                          gradient:
                              LinearGradient(
                            begin:
                                Alignment(
                              -1,
                              -0.7,
                            ),

                            end:
                                Alignment(
                              1,
                              0.7,
                            ),

                            colors: [
                              Colors.transparent,

                              Color(
                                0x18FFFFFF,
                              ),

                              Color(
                                0xA8FFFFFF,
                              ),

                              Color(
                                0x14FFFFFF,
                              ),

                              Colors.transparent,
                            ],

                            stops: [
                              0.10,
                              0.34,
                              0.50,
                              0.67,
                              0.90,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                /* CARD EDGE */

                IgnorePointer(
                  child:
                      DecoratedBox(
                    decoration:
                        BoxDecoration(
                      borderRadius:
                          BorderRadius.circular(
                        22,
                      ),

                      border:
                          Border.all(
                        color:
                            Colors.white
                                .withValues(
                          alpha:
                              0.20,
                        ),

                        width:
                            1.2,
                      ),
                    ),
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

/* ===========================================================
 * HERO FALLBACK
 * ========================================================= */

class _HeroFallback
    extends StatelessWidget {
  const _HeroFallback({
    required this.title,
  });

  final String title;

  @override
  Widget build(
    BuildContext context,
  ) {
    final displayTitle =
        title.trim().isEmpty
            ? 'Untitled'
            : title.trim();

    return Container(
      decoration:
          const BoxDecoration(
        gradient:
            LinearGradient(
          begin:
              Alignment.topLeft,
          end:
              Alignment.bottomRight,
          colors: [
            Color(
              0xFF39325F,
            ),
            Color(
              0xFF1A1923,
            ),
          ],
        ),
      ),
      alignment:
          Alignment.bottomLeft,
      child:
          Padding(
        padding:
            const EdgeInsets.all(
          14,
        ),
        child:
            Text(
          displayTitle,
          maxLines:
              3,
          overflow:
              TextOverflow.ellipsis,
          style:
              const TextStyle(
            color:
                AppColors.text,
            fontWeight:
                FontWeight.w700,
            fontSize:
                16,
          ),
        ),
      ),
    );
  }
}

/* ===========================================================
 * BOOKMARK BUTTON
 * ========================================================= */

class _BookmarkButton
    extends StatelessWidget {
  const _BookmarkButton({
    required this.bookmarked,
    required this.onPressed,
  });

  final bool bookmarked;
  final VoidCallback onPressed;

  @override
  Widget build(
    BuildContext context,
  ) {
    return ClipRRect(
      borderRadius:
          BorderRadius.circular(
        14,
      ),
      child:
          BackdropFilter(
        filter:
            ImageFilter.blur(
          sigmaX:
              12,
          sigmaY:
              12,
        ),
        child:
            SizedBox(
          width:
              double.infinity,
          height:
              50,
          child:
              IconButton(
            onPressed:
                onPressed,
            tooltip:
                bookmarked
                    ? 'Bookmarked'
                    : 'Bookmark',
            style:
                IconButton.styleFrom(
              backgroundColor:
                  bookmarked
                      ? AppColors.accent
                          .withValues(
                          alpha:
                              0.30,
                        )
                      : AppColors.raised
                          .withValues(
                          alpha:
                              0.60,
                        ),
              foregroundColor:
                  bookmarked
                      ? AppColors.accent
                      : AppColors.text,
              side:
                  bookmarked
                      ? BorderSide(
                          color:
                              AppColors.accent
                                  .withValues(
                            alpha:
                                0.65,
                          ),
                        )
                      : const BorderSide(
                          color:
                              AppColors.outline,
                        ),
              shape:
                  RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(
                  14,
                ),
              ),
            ),
            icon:
                Icon(
              bookmarked
                  ? Icons
                      .favorite_rounded
                  : Icons
                      .favorite_border_rounded,
              size:
                  22,
            ),
          ),
        ),
      ),
    );
  }
}

/* ===========================================================
 * READ BUTTON
 * ========================================================= */

class _ReadActionCard
    extends StatelessWidget {
  const _ReadActionCard({
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(
    BuildContext context,
  ) {
    return SizedBox(
      width:
          double.infinity,
      height:
          50,
      child:
          FilledButton(
        onPressed:
            onPressed,
        style:
            FilledButton.styleFrom(
          shape:
              RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(
              14,
            ),
          ),
        ),
        child:
            Text(
          label,
        ),
      ),
    );
  }
}

/* ===========================================================
 * INFO CHIP
 * ========================================================= */

class _InfoChip
    extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(
    BuildContext context,
  ) {
    final displayLabel =
        label.trim().isEmpty
            ? '-'
            : label.trim();

    return Container(
      height:
          34,
      padding:
          const EdgeInsets.symmetric(
        horizontal:
            8,
      ),
      decoration:
          BoxDecoration(
        color:
            AppColors.raised
                .withValues(
          alpha:
              0.86,
        ),
        borderRadius:
            BorderRadius.circular(
          999,
        ),
        border:
            Border.all(
          color:
              AppColors.outline,
        ),
      ),
      child:
          Row(
        mainAxisAlignment:
            MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size:
                14,
            color:
                AppColors.accent,
          ),

          const SizedBox(
            width:
                5,
          ),

          Flexible(
            child:
                Text(
              displayLabel,
              maxLines:
                  1,
              overflow:
                  TextOverflow.ellipsis,
              style:
                  const TextStyle(
                fontSize:
                    12,
                fontWeight:
                    FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ===========================================================
 * CHAPTER TILE
 * ========================================================= */

class _ChapterTile
    extends StatelessWidget {
  const _ChapterTile({
    required this.chapter,
    required this.state,
    required this.readable,
    required this.onTap,
  });

  final CanonicalChapter chapter;
  final String state;
  final bool readable;
  final VoidCallback? onTap;

  @override
  Widget build(
    BuildContext context,
  ) {
    final read =
        state == 'READ';

    late final Color accent;

    if (state == 'NEW') {
      accent =
          AppColors.accent;
    } else {
      accent =
          AppColors.muted
              .withValues(
        alpha:
            0.9,
      );
    }

    final chapterTitle =
        chapter.title.trim();

    return Opacity(
      opacity:
          read ? 0.30 : 1,
      child:
          Material(
        color:
            Colors.transparent,
        child:
            InkWell(
          onTap:
              readable ? onTap : null,
          borderRadius:
              BorderRadius.circular(
            _detailRadius,
          ),
          child:
              Ink(
            height:
                _chapterTileHeight,
            padding:
                const EdgeInsets.symmetric(
              horizontal:
                  20,
            ),
            decoration:
                BoxDecoration(
              color:
                  AppColors.surface,
              borderRadius:
                  BorderRadius.circular(
                _detailRadius,
              ),
              border:
                  Border.all(
                color:
                    AppColors.outline,
              ),
            ),
            child:
                Row(
              children: [
                Expanded(
                  child:
                      Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text:
                              'Chapter ${chapter.numberLabel}',
                          style:
                              const TextStyle(
                            color:
                                AppColors.text,
                            fontSize:
                                15.5,
                            fontWeight:
                                FontWeight.w800,
                          ),
                        ),

                        if (chapterTitle.isNotEmpty &&
                            !chapterTitle
                                .toLowerCase()
                                .startsWith(
                                  'chapter ',
                                ))
                          TextSpan(
                            text:
                                '   $chapterTitle',
                            style:
                                Theme.of(
                              context,
                            )
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color:
                                          AppColors.muted,
                                      fontWeight:
                                          FontWeight.w600,
                                    ),
                          ),
                      ],
                    ),
                    maxLines:
                        2,
                    softWrap:
                        true,
                    overflow:
                        TextOverflow.ellipsis,
                  ),
                ),

                const SizedBox(
                  width:
                      14,
                ),

                Text(
                  state,
                  maxLines:
                      1,
                  style:
                      TextStyle(
                    color:
                        accent,
                    fontSize:
                        11,
                    fontWeight:
                        FontWeight.w900,
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

/* ===========================================================
 * MESSAGE
 * ========================================================= */

class _ModernMessage
    extends StatelessWidget {
  const _ModernMessage({
    required this.icon,
    required this.message,
    this.onRetry,
    this.retryLabel = 'Retry',
  });

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Center(
      child:
          Padding(
        padding:
            const EdgeInsets.all(
          28,
        ),
        child:
            Column(
          mainAxisSize:
              MainAxisSize.min,
          children: [
            Icon(
              icon,
              size:
                  34,
              color:
                  AppColors.muted,
            ),

            const SizedBox(
              height:
                  12,
            ),

            Text(
              message,
              textAlign:
                  TextAlign.center,
              style:
                  Theme.of(
                context,
              )
                      .textTheme
                      .bodyMedium
                      ?.copyWith(
                        color:
                            AppColors.muted,
                        height:
                            1.4,
                      ),
            ),

            if (onRetry != null) ...[
              const SizedBox(
                height:
                    18,
              ),

              OutlinedButton.icon(
                onPressed:
                    onRetry,
                icon:
                    const Icon(
                  Icons.refresh_rounded,
                ),
                label:
                    Text(
                  retryLabel,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}