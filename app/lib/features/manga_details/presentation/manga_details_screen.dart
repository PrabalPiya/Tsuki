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

const _detailRadius = 18.0;
const _detailPadding = 16.0;
const _chapterTileHeight = 72.0;
const _chapterListHeight = 5 * 72.0 + 4 * 10.0;
const _heroAspectRatio = 0.62;
const _heroPaddingBottom = 20.0;

class MangaDetailsScreen extends ConsumerWidget {
  const MangaDetailsScreen({super.key, required this.mangaId});
  final String mangaId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(catalogProvider);
    final saved = ref.watch(userLibraryProvider).bookmarkedManga[mangaId];
    if (saved != null) repository.remember(saved);
    final cached = repository.cached(mangaId);
    if (cached != null) return _Details(manga: cached);
    return FutureBuilder<Manga?>(
        future: repository.details(mangaId),
        builder: (context, snapshot) {
          final manga = snapshot.data;
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          if (manga == null) {
            return const Scaffold(
                body: Center(child: Text('Manga unavailable right now.')));
          }
          return _Details(manga: manga);
        });
  }
}

class _Details extends ConsumerWidget {
  const _Details({required this.manga});
  final Manga manga;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(userLibraryProvider);
    final bookmarked = library.bookmarks.contains(manga.id);
    final chapters = ref.watch(chapterProvider(manga));
    final progress = library.progress[manga.id];
    final readableChapters =
        chapters.valueOrNull?.where((c) => c.hasDirectlyReadableCopy).toList();
    final hasReadable = readableChapters?.isNotEmpty == true;
    final startReadingLabel =
        progress == null ? 'Start Reading' : 'Continue Reading';
    final VoidCallback? onStartReading = hasReadable
        ? () {
            final list = readableChapters;
            if (list == null || list.isEmpty) return;
            final currentChapterId = progress?.chapterId;
            final chapterId = currentChapterId != null &&
                list.any((c) => c.id == currentChapterId)
              ? currentChapterId
              : list.first.id;
            context.push(
                '/reader/${Uri.encodeComponent(manga.id)}?chapter=${Uri.encodeComponent(chapterId)}');
          }
        : null;

    return Scaffold(
        body: CustomScrollView(slivers: [
      // Hero section - full cover image with all content overlaid on top
      SliverToBoxAdapter(
          child: _MangaHero(
              manga: manga,
              onBack: () => context.pop(),
              onToggleBookmark: () =>
                  ref.read(userLibraryProvider.notifier).toggleBookmark(manga),
              bookmarked: bookmarked,
              onStartReading: onStartReading,
              startReadingLabel: startReadingLabel)),
      // Chapters header
      SliverToBoxAdapter(
          child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  _detailPadding, 18, _detailPadding, 10),
              child: Text('Chapters',
                  style: Theme.of(context).textTheme.headlineSmall))),
      // Chapters list - fixed height showing 5 at a time, scrollable
      chapters.when(
          loading: () => const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator())),
          error: (_, __) => const SliverFillRemaining(
              hasScrollBody: false,
              child: _ModernMessage(
                  icon: Icons.cloud_off_rounded,
                  message: 'Unable to retrieve chapters right now.')),
          data: (items) {
            if (items.isEmpty) {
              return const SliverFillRemaining(
                  hasScrollBody: false,
                  child: _ModernMessage(
                      icon: Icons.menu_book_outlined,
                      message:
                          'No English chapters available from the configured sources.'));
            }
            return SliverToBoxAdapter(
                child: SizedBox(
                    height: _chapterListHeight,
                    child: ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: items.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final chapter =
                              items[items.length - index - 1];
                          final state = _chapterState(chapter, progress);
                          final readable = chapter.hasDirectlyReadableCopy;
                          return _ChapterTile(
                              chapter: chapter,
                              state: state,
                              readable: readable,
                              onTap: readable
                                  ? () => context.push(
                                      '/reader/${Uri.encodeComponent(manga.id)}?chapter=${Uri.encodeComponent(chapter.id)}')
                                  : null);
                        })));
          }),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ]));
  }

  String _chapterState(CanonicalChapter chapter, ReadingProgress? progress) {
    if (!chapter.hasDirectlyReadableCopy) return 'EXTERNAL';
    if (progress == null || !progress.openedChapterIds.contains(chapter.id)) {
      return 'NEW';
    }
    return 'READ';
  }
}

class _MangaHero extends StatelessWidget {
  const _MangaHero(
      {required this.manga,
      required this.onBack,
      required this.bookmarked,
      required this.onToggleBookmark,
      required this.onStartReading,
      required this.startReadingLabel});
  final Manga manga;
  final VoidCallback onBack;
  final bool bookmarked;
  final VoidCallback onToggleBookmark;
  final VoidCallback? onStartReading;
  final String startReadingLabel;

  @override
  Widget build(BuildContext context) {
    final cover = manga.coverUrl.isEmpty
        ? _HeroFallback(title: manga.title)
        : CachedNetworkImage(
            imageUrl: manga.coverUrl,
            cacheManager: MangaImageCache.instance,
            fit: BoxFit.cover,
            placeholder: (_, __) => _HeroFallback(title: manga.title),
            errorWidget: (_, __, ___) => _HeroFallback(title: manga.title));
    final heroHeight = MediaQuery.sizeOf(context).width / _heroAspectRatio;
    return SizedBox(
        height: heroHeight,
        child: Stack(
            children: [
          // Full cover image from top to bottom (complete image visible)
          // ShaderMask fades the image to transparent at the bottom edge
          Positioned.fill(
              child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white,
                        Colors.white,
                        Colors.white70,
                        Colors.transparent,
                      ],
                      stops: [0.0, 0.6, 0.8, 1.0],
                  ).createShader(bounds),
                  child: cover)),
          // Bottom gradient fade - darkens over the content area for readability
          Positioned.fill(
              child: const DecoratedBox(
                  decoration: BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                    Colors.transparent,
                    Color(0x66000000),
                    Color(0xCC000000),
                    Color(0xFF000000),
                  ],
                          stops: [0.0, 0.25, 0.5, 1.0])))),
          // Back button (top-left, above status bar)
          Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 8,
              child: IconButton(
                  onPressed: onBack,
                  style: IconButton.styleFrom(
                      backgroundColor: AppColors.glass,
                      side: const BorderSide(color: AppColors.outline)),
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: 'Back')),
          // Content anchored to the bottom
          Positioned(
              left: _detailPadding,
              right: _detailPadding,
              bottom: 12,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title
                    Text(
                      manga.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .headlineLarge
                          ?.copyWith(
                              fontSize: 24,
                              height: 1.2,
                              fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 12),
                    // Info chips (rating, status, chapter count)
                    Row(children: [
                      Expanded(
                          child: _InfoChip(
                              icon: Icons.star_rounded,
                              label: manga.ratingLabel)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _InfoChip(
                              icon: Icons.bolt_rounded,
                              label: manga.statusLabel)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _InfoChip(
                              icon: Icons.library_books_rounded,
                              label: '${manga.chapterCount} chp')),
                    ]),
                    const SizedBox(height: 12),
                    // Full synopsis
                    Text(
                      manga.synopsis,
                      textAlign: TextAlign.justify,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(
                              color: Colors.white.withValues(alpha: .92),
                              height: 1.45,
                              wordSpacing: 0.15,
                              letterSpacing: 0.02),
                    ),
                    const SizedBox(height: _heroPaddingBottom),
                    // Bookmark + Read buttons
                    Row(children: [
                      Expanded(
                        child: _BookmarkButton(
                          bookmarked: bookmarked,
                          onPressed: onToggleBookmark,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _ReadActionCard(
                            label: startReadingLabel,
                            onPressed: onStartReading),
                      ),
                    ]),
                  ]))
        ]));
  }
}

class _HeroFallback extends StatelessWidget {
  const _HeroFallback({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) => Container(
      decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF39325F), Color(0xFF1A1923)])),
      alignment: Alignment.bottomLeft,
      child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(title,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.text,
                  fontWeight: FontWeight.w700,
                  fontSize: 16))));
}

class _BookmarkButton extends StatelessWidget {
  const _BookmarkButton({
    required this.bookmarked,
    required this.onPressed,
  });
  final bool bookmarked;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: SizedBox(
            width: double.infinity,
            height: 50,
            child: IconButton(
                onPressed: onPressed,
                tooltip: bookmarked ? 'Bookmarked' : 'Bookmark',
                style: IconButton.styleFrom(
                    backgroundColor: bookmarked
                        ? AppColors.accent.withValues(alpha: .3)
                        : AppColors.raised.withValues(alpha: .6),
                    foregroundColor: bookmarked
                        ? AppColors.accent
                        : AppColors.text,
                    side: bookmarked
                        ? BorderSide(
                            color: AppColors.accent
                                .withValues(alpha: .65),
                            width: 1.2)
                        : const BorderSide(
                            color: AppColors.outline, width: 1),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14))),
                icon: Icon(
                    bookmarked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    size: 22),
                padding: EdgeInsets.zero)),
      ));
}

class _ReadActionCard extends StatelessWidget {
  const _ReadActionCard({required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
      width: double.infinity,
      height: 46,
      child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14))),
          child: Text(label)));
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
          color: AppColors.raised.withValues(alpha: .86),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppColors.outline)),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 14, color: AppColors.accent),
        const SizedBox(width: 5),
        Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)))
      ]));
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile(
      {required this.chapter,
      required this.state,
      required this.readable,
      required this.onTap});
  final CanonicalChapter chapter;
  final String state;
  final bool readable;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final read = state.startsWith('READ');
    final accent = state == 'NEW'
        ? AppColors.accent
        : state == 'EXTERNAL'
            ? AppColors.accentWarm
            : AppColors.muted.withValues(alpha: .9);
    return Opacity(
        opacity: read ? .30 : 1,
        child: SizedBox(
            height: _chapterTileHeight,
            child: InkWell(
                borderRadius: BorderRadius.circular(_detailRadius),
                onTap: onTap,
                child: Ink(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                        color: read
                            ? AppColors.surface.withValues(alpha: .72)
                            : AppColors.surface,
                        borderRadius: BorderRadius.circular(_detailRadius),
                        border: Border.all(color: AppColors.outline)),
                    child: Row(children: [
                      Expanded(
                          child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text.rich(
                                    TextSpan(children: [
                                      TextSpan(
                                          text: 'Chapter ${chapter.numberLabel}',
                                          style: const TextStyle(
                                              color: AppColors.text,
                                              fontWeight: FontWeight.w800)),
                                      if (chapter.title.trim().isNotEmpty &&
                                          !chapter.title.startsWith('Chapter '))
                                        TextSpan(
                                            text: '   ${chapter.title}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                    color: read
                                                        ? AppColors.muted.withValues(alpha: .72)
                                                        : AppColors.muted,
                                                    fontWeight:
                                                        FontWeight.w600))
                                    ]),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis))),
                      const SizedBox(width: 10),
                      SizedBox(
                          width: 72,
                          child: Align(
                              alignment: Alignment.centerRight,
                              child: Text(state,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: accent,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900))))
                    ])))));
  }
}

class _ModernMessage extends StatelessWidget {
  const _ModernMessage({required this.icon, required this.message});
  final IconData icon;
  final String message;
  @override
  Widget build(BuildContext context) => Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_detailRadius)),
      child: Padding(
          padding: const EdgeInsets.all(_detailPadding),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: AppColors.muted),
            const SizedBox(height: 10),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted))
          ])));
}