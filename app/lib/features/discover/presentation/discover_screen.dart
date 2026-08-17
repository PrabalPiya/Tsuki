import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/models/manga.dart';
import '../../../core/state/providers.dart';
import '../../../core/storage/image_cache.dart';
import '../../../core/theme/app_theme.dart';
import '../data/ranking_provider.dart';

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});
  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen>
    with SingleTickerProviderStateMixin {
  final _positions = <int, int>{0: 0, 1: 0, 2: 0};
  int _period = 0;
  Offset _offset = Offset.zero;
  bool _dragging = false, _animating = false;

  late final AnimationController _hintController;
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    _hintController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    WidgetsBinding.instance.addPostFrameCallback((_) => _showSwipeHint());
  }

  void _showSwipeHint() {
    if (!mounted) return;
    _hintTimer?.cancel();
    _hintController.repeat(reverse: true);
    _hintTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) _hintController.animateTo(0);
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _hintController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ranking = ref.watch(rankingsProvider(RankingPeriod.values[_period]));
    final items = ranking.valueOrNull?.items ?? const <Manga>[];
    final preview = ranking.valueOrNull?.isPreview ?? false;
    final index = items.isEmpty
        ? 0
        : (_positions[_period] ?? 0).clamp(0, items.length - 1);
    return Scaffold(
        appBar: AppBar(
        titleSpacing: 16,
            title: const Text('Discover'),
            actions: [
              Padding(
            padding: const EdgeInsets.only(right: 16),
                  child: IconButton(
                      onPressed: () => context.push('/settings'),
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: 'Settings'))
            ]),
        body: Column(children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: _DiscoverPeriodTabs(
                  selectedIndex: _period,
                  onChanged: (value) {
                    if (value == _period) return;
                    setState(() {
                      _period = value;
                      _offset = Offset.zero;
                    });
                    ref.invalidate(rankingsProvider(RankingPeriod.values[value]));
                    _showSwipeHint();
                  })),
          if (preview)
            const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('Preview · live rankings unavailable',
                    style: TextStyle(color: AppColors.muted, fontSize: 12))),
          Expanded(
              child: ranking.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : items.isEmpty
                      ? Center(
                          child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                  ranking.valueOrNull?.unavailableReason ??
                                      'Rankings unavailable.',
                                  textAlign: TextAlign.center,
                                  style:
                                      const TextStyle(color: AppColors.muted))))
                      : LayoutBuilder(builder: (context, constraints) {
                          final progress =
                              (_offset.dx.abs() / constraints.maxWidth)
                                  .clamp(0.0, 1.0)
                                  .toDouble();
                          final next = index + 1 < items.length
                              ? items[index + 1]
                              : null;
                          final cardHeight = constraints.maxHeight;
                          return Stack(
                              alignment: Alignment.topCenter,
                              children: [
                                if (next != null)
                                  Transform.translate(
                                      offset: Offset(0, 18 * (1 - progress)),
                                      child: Transform.scale(
                                          scale: .94 + .06 * progress,
                                          child: SizedBox(
                                              height: cardHeight,
                                              child: _DiscoverCard(
                                                  manga: next,
                                                  rank: index + 2,
                                                  period: _period,
                                                  inert: true,
                                                  preview: preview)))),
                                GestureDetector(
                                    onPanStart: (_) =>
                                        setState(() => _dragging = true),
                                    onPanUpdate: (details) {
                                      if (_animating) return;
                                      setState(() {
                                        final raw = _offset + details.delta;
                                        _offset = index == 0 && raw.dx > 0
                                            ? Offset(raw.dx * .32, raw.dy)
                                            : raw;
                                      });
                                    },
                                    onPanEnd: (details) => _finishSwipe(
                                        details.velocity.pixelsPerSecond.dx,
                                        constraints.maxWidth,
                                        items.length),
                                    child: AnimatedContainer(
                                        duration: _dragging
                                            ? Duration.zero
                                            : const Duration(milliseconds: 260),
                                        curve: Curves.easeOutBack,
                                        transform: Matrix4.identity()
                                          ..translateByDouble(_offset.dx,
                                              _offset.dy * .18, 0, 1)
                                          ..rotateZ(_offset.dx /
                                              constraints.maxWidth *
                                              .10),
                                        child: SizedBox(
                                            height: cardHeight,
                                            child: _DiscoverCard(
                                                manga: items[index],
                                                rank: index + 1,
                                                period: _period,
                                                preview: preview)))),
                                Positioned(
                                    bottom: 56,
                                    child: IgnorePointer(
                                        child: FadeTransition(
                                            opacity: CurvedAnimation(
                                                parent: _hintController,
                                                curve: Curves.easeInOut),
                                            child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 14,
                                                        vertical: 9),
                                                decoration: BoxDecoration(
                                                    color: AppColors.glass,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            24),
                                                    border: Border.all(
                                                        color:
                                                            AppColors.outline)),
                                                child: const Row(children: [
                                                  Icon(Icons.swipe,
                                                      size: 18,
                                                      color: Colors.white),
                                                  SizedBox(width: 8),
                                                  Text(
                                                      'Swipe left for next · right for previous',
                                                      style: TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 12))
                                                ])))))
                              ]);
                        }))
        ]));
  }

  Future<void> _finishSwipe(double velocity, double width, int length) async {
    if (_animating) return;
    final index = _positions[_period] ?? 0;
    final left = _offset.dx < -width * .28 || velocity < -850;
    final right = _offset.dx > width * .28 || velocity > 850;
    if (left && index < length - 1) {
      _animating = true;
      setState(() {
        _dragging = false;
        _offset = Offset(-width * 1.3, _offset.dy);
      });
      await Future<void>.delayed(const Duration(milliseconds: 230));
      if (mounted) {
        setState(() {
          _positions[_period] = index + 1;
          _offset = Offset.zero;
          _animating = false;
        });
      }
      HapticFeedback.selectionClick();
      return;
    }
    if (right && index > 0) {
      _animating = true;
      setState(() {
        _dragging = false;
        _offset = Offset(width * 1.3, _offset.dy);
      });
      await Future<void>.delayed(const Duration(milliseconds: 230));
      if (mounted) {
        setState(() {
          _positions[_period] = index - 1;
          _offset = Offset.zero;
          _animating = false;
        });
      }
      HapticFeedback.selectionClick();
      return;
    }
    setState(() {
      _dragging = false;
      _offset = Offset.zero;
    });
  }
}

class _DiscoverPeriodTabs extends StatelessWidget {
  const _DiscoverPeriodTabs(
      {required this.selectedIndex, required this.onChanged});
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Container(
      height: 46,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: AppColors.raised.withValues(alpha: .36),
          borderRadius: BorderRadius.circular(15)),
      child: LayoutBuilder(builder: (context, constraints) {
        final indicatorWidth = constraints.maxWidth / 3;
        final indicatorLeft = selectedIndex * indicatorWidth;
        return Stack(children: [
          AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              left: indicatorLeft,
              top: 0,
              bottom: 0,
              width: indicatorWidth,
              child: DecoratedBox(
                  decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: .16),
                      borderRadius: BorderRadius.circular(12)))),
          Row(children: [
            Expanded(
                child: _DiscoverTabButton(
                    label: 'Trending',
                    selected: selectedIndex == 0,
                    onTap: () => onChanged(0))),
            Expanded(
                child: _DiscoverTabButton(
                    label: 'Top Rated',
                    selected: selectedIndex == 1,
                    onTap: () => onChanged(1))),
            Expanded(
                child: _DiscoverTabButton(
                    label: 'Popular',
                    selected: selectedIndex == 2,
                    onTap: () => onChanged(2)))
          ])
        ]);
      }));
}

class _DiscoverTabButton extends StatelessWidget {
  const _DiscoverTabButton(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          style: TextStyle(
              color: selected ? AppColors.text : AppColors.muted,
              fontSize: 13,
              fontWeight: FontWeight.w900),
          child: Center(child: Text(label, maxLines: 1))));
}

class _DiscoverCard extends ConsumerWidget {
  const _DiscoverCard(
      {required this.manga,
      required this.rank,
      required this.period,
      required this.preview,
      this.inert = false});
  final Manga manga;
  final int rank, period;
  final bool inert, preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final marked = ref.watch(userLibraryProvider).bookmarks.contains(manga.id);
    final periodLabel = ['Trending', 'Top Rated', 'Popular'][period];
    final details = ref.watch(catalogProvider).cached(manga.id);
    final chapterCount = details?.chapterCount ?? manga.chapterCount;
    final synopsis = (details?.synopsis.isNotEmpty ?? false)
        ? details!.synopsis
        : manga.synopsis;
    final shortSynopsis = _shortSynopsis(synopsis);

    return IgnorePointer(
      ignoring: inert,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Material(
              color: AppColors.surface,
              child: InkWell(
                onTap: () =>
                    context.push('/manga/${Uri.encodeComponent(manga.id)}'),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Full-bleed cover artwork
                    Positioned.fill(
                      child: manga.coverUrl.isEmpty
                          ? _CoverFallback(title: manga.title)
                          : CachedNetworkImage(
                              imageUrl: manga.coverUrl,
                              cacheManager: MangaImageCache.instance,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  _CoverFallback(title: manga.title),
                              errorWidget: (_, __, ___) =>
                                  _CoverFallback(title: manga.title)),
                    ),
                    // Rank badge - top left over the cover artwork
                    Positioned(
                      top: 14,
                      left: 14,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.glass,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: AppColors.outline),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.auto_awesome,
                              size: 14, color: AppColors.accent),
                          const SizedBox(width: 6),
                          Text(
                            preview ? 'Preview $rank' : '#$rank $periodLabel',
                            style: const TextStyle(
                                color: AppColors.text,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: .4),
                          ),
                        ]),
                      ),
                    ),
                    // Soft gradient overlay - darkens from bottom to keep
                    // the top artwork visible while content stays readable.
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.62),
                              Colors.black.withValues(alpha: 0.88),
                              Colors.black.withValues(alpha: 0.96),
                            ],
                            stops: const [0.0, 0.42, 0.72, 1.0],
                          ),
                        ),
                      ),
                    ),
                    // Content - sits directly on the gradient (no box).
                    // Anchored to the bottom, sized to fit its content.
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
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
                                    .headlineSmall
                                    ?.copyWith(
                                      fontSize: 22,
                                      height: 1.18,
                                    ),
                              ),
                              const SizedBox(height: 10),
                              // Rating, status, chapter count - below the
                              // title, styled like the details page chips.
                              Row(
                                children: [
                                  Expanded(
                                    child: _InfoChip(
                                      icon: Icons.star_rounded,
                                      label: manga.ratingLabel,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: _InfoChip(
                                      icon: Icons.bolt_rounded,
                                      label: manga.statusLabel,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: _InfoChip(
                                      icon:
                                          Icons.library_books_rounded,
                                      label: '$chapterCount chp',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              // Bio - wraps naturally to ~3-4 lines, then
                              // ellipsis. No stretching of the description.
                              Text(
                                shortSynopsis,
                                softWrap: true,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: Colors.white.withValues(
                                          alpha: .94),
                                      height: 1.45,
                                      letterSpacing: .02,
                                    ),
                              ),
                              const SizedBox(height: 20),
                              // Bookmark button directly below the bio
                              _BookmarkButton(
                                bookmarked: marked,
                                onPressed: () => ref
                                    .read(userLibraryProvider.notifier)
                                    .toggleBookmark(manga),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _shortSynopsis(String text) {
  final normalized = text
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll('<br>', ' ')
      .replaceAll('<br/>', ' ')
      .replaceAll('<br />', ' ')
      .trim();
  if (normalized.isEmpty) {
    return 'No synopsis available.';
  }
  return normalized;
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Container(
      decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF39325F), Color(0xFF1A1923)])),
      padding: const EdgeInsets.all(14),
      alignment: Alignment.bottomLeft,
      child: Text(title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: AppColors.text,
              fontWeight: FontWeight.w700,
              fontSize: 16)));
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