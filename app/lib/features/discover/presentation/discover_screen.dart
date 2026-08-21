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
import '../../../shared/synopsis_summary.dart';
import '../../../shared/widgets/one_time_hint.dart';
import '../data/ranking_provider.dart';

final discoverResetProvider = StateProvider<int>((ref) => 0);

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen>
    with TickerProviderStateMixin {
  final _positions = <int, int>{0: 0, 1: 0, 2: 0};

  static const _swipeDistanceThreshold = .14;
  static const _swipeVelocityThreshold = 700.0;

  static const _throwHorizontalFactor = 1.02;
  static const _throwVerticalFactor = .23;
  static const _throwRotation = .13;

  static const _dragPreviewHorizontal = 54.0;
  static const _dragPreviewVertical = 22.0;
  static const _dragPreviewRotation = .035;

  static const _nextCardScale = .965;
  static const _nextCardYOffset = 14.0;

  int _period = 0;

  double _dragY = 0;

  bool _dragging = false;
  bool _animating = false;

  late final AnimationController _swipeController;

  _SwipeAnimation _swipeAnimation = _SwipeAnimation.none;

  Offset _animationStartOffset = Offset.zero;

  Offset _animationEndOffset = Offset.zero;

  double _animationStartRotation = 0.0;
  double _animationEndRotation = 0.0;

  double _animationProgress = 0.0;

  @override
  void initState() {
    super.initState();

    _swipeController = AnimationController(vsync: this)
      ..addListener(() {
        if (!mounted) return;

        setState(() {
          _animationProgress = Curves.easeOutCubic.transform(
            _swipeController.value,
          );
        });
      });
  }

  void _resetDiscover() {
    if (!mounted) return;

    _swipeController.stop();

    setState(() {
      _positions[0] = 0;
      _positions[1] = 0;
      _positions[2] = 0;

      _period = 0;

      _dragY = 0;

      _dragging = false;
      _animating = false;

      _swipeAnimation = _SwipeAnimation.none;

      _animationStartOffset = Offset.zero;

      _animationEndOffset = Offset.zero;

      _animationStartRotation = 0.0;
      _animationEndRotation = 0.0;

      _animationProgress = 0.0;
    });
  }

  @override
  void dispose() {
    _swipeController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(discoverResetProvider, (previous, next) {
      if (previous != null && previous != next) {
        _resetDiscover();
      }
    });

    final adultMode = ref.watch(adultModeProvider);

    ref.listen<bool>(adultModeProvider, (previous, next) {
      if (previous != null && previous != next) {
        _resetDiscover();
      }
    });
    final ranking = ref.watch(rankingsProvider(RankingPeriod.values[_period]));

    final items = ranking.valueOrNull?.items ?? const <Manga>[];

    final preview = ranking.valueOrNull?.isPreview ?? false;

    final index = items.isEmpty
        ? 0
        : (_positions[_period] ?? 0).clamp(0, items.length - 1);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,

        title: Text(adultMode ? 'Adult Discover' : 'Discover'),

        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: IconButton(
              onPressed: () {
                context.push('/settings');
              },
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
            ),
          ),
        ],
      ),

      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: _DiscoverPeriodTabs(
              selectedIndex: _period,
              onChanged: (value) {
                if (value == _period || _animating) {
                  return;
                }

                setState(() {
                  _period = value;

                  _dragY = 0;
                  _dragging = false;

                  _swipeAnimation = _SwipeAnimation.none;

                  _animationProgress = 0.0;
                });

                ref.invalidate(rankingsProvider(RankingPeriod.values[value]));

                /*
                 * Do NOT show the hint again here.
                 *
                 * OneTimeHint remembers that it
                 * has already been displayed.
                 */
              },
            ),
          ),

          if (preview)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Preview Ãƒâ€šÃ‚Â· live rankings unavailable',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),

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
                        style: const TextStyle(color: AppColors.muted),
                      ),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      return _buildCardStack(
                        items: items,
                        index: index,
                        preview: preview,
                        width: constraints.maxWidth,
                        height: constraints.maxHeight,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardStack({
    required List<Manga> items,
    required int index,
    required bool preview,
    required double width,
    required double height,
  }) {
    final next = index + 1 < items.length ? items[index + 1] : null;

    final previous = index > 0 ? items[index - 1] : null;

    final upwardDragProgress = _dragY < 0
        ? (-_dragY / (height * .42)).clamp(0.0, 1.0).toDouble()
        : 0.0;

    final downwardDragProgress = _dragY > 0
        ? (_dragY / (height * .42)).clamp(0.0, 1.0).toDouble()
        : 0.0;

    Offset currentOffset = Offset.zero;

    double currentRotation = 0.0;

    if (_dragging && _dragY < 0) {
      currentOffset = Offset(
        _dragPreviewHorizontal * upwardDragProgress,
        -_dragPreviewVertical * upwardDragProgress,
      );

      currentRotation = _dragPreviewRotation * upwardDragProgress;
    } else if (_swipeAnimation == _SwipeAnimation.throwNext ||
        _swipeAnimation == _SwipeAnimation.snapCurrent) {
      currentOffset =
          Offset.lerp(
            _animationStartOffset,
            _animationEndOffset,
            _animationProgress,
          ) ??
          Offset.zero;

      currentRotation = _lerpDouble(
        _animationStartRotation,
        _animationEndRotation,
        _animationProgress,
      );
    }

    var nextProgress = upwardDragProgress;

    if (_swipeAnimation == _SwipeAnimation.throwNext) {
      /*
      * Continue the next card from exactly where
      * the user's drag left it.
      *
      * _dragY is intentionally still preserved
      * until the throw animation finishes.
      */
      final startProgress = (-_dragY / (height * .42))
          .clamp(0.0, 1.0)
          .toDouble();

      nextProgress = _lerpDouble(startProgress, 1.0, _animationProgress);
    }

    final throwOffset = Offset(
      width * _throwHorizontalFactor,
      -height * _throwVerticalFactor,
    );

    Offset previousOffset = throwOffset;

    double previousRotation = _throwRotation;

    bool showPrevious = false;

    if (previous != null) {
      if (_dragging && _dragY > 0) {
        showPrevious = true;

        final reveal = Curves.easeOutCubic.transform(downwardDragProgress);

        previousOffset =
            Offset.lerp(throwOffset, Offset.zero, reveal) ?? throwOffset;

        previousRotation = _lerpDouble(_throwRotation, 0.0, reveal);
      } else if (_swipeAnimation == _SwipeAnimation.restorePrevious ||
          _swipeAnimation == _SwipeAnimation.dismissPrevious) {
        showPrevious = true;

        previousOffset =
            Offset.lerp(
              _animationStartOffset,
              _animationEndOffset,
              _animationProgress,
            ) ??
            throwOffset;

        previousRotation = _lerpDouble(
          _animationStartRotation,
          _animationEndRotation,
          _animationProgress,
        );
      }
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,

      onVerticalDragStart: _handleDragStart,

      onVerticalDragUpdate: (details) {
        _handleDragUpdate(details, index);
      },

      onVerticalDragEnd: (details) {
        _handleDragEnd(details, width, height, items.length);
      },

      child: Stack(
        clipBehavior: Clip.none,

        alignment: Alignment.topCenter,

        children: [
          /*
           * NEXT CARD
           */
          if (next != null)
            Transform.translate(
              offset: Offset(0, _nextCardYOffset * (1.0 - nextProgress)),
              child: Transform.scale(
                scale: _lerpDouble(_nextCardScale, 1.0, nextProgress),
                alignment: Alignment.center,
                child: SizedBox(
                  height: height,
                  child: _DiscoverCard(
                    manga: next,
                    rank: index + 2,
                    period: _period,
                    inert: true,
                    preview: preview,
                  ),
                ),
              ),
            ),
          /*
           * CURRENT CARD
           */
          Transform.translate(
            offset: currentOffset,
            child: Transform.rotate(
              angle: currentRotation,
              child: SizedBox(
                height: height,
                child: _DiscoverCard(
                  manga: items[index],
                  rank: index + 1,
                  period: _period,
                  preview: preview,
                ),
              ),
            ),
          ),

          /*
           * PREVIOUS CARD
           */
          if (showPrevious && previous != null)
            Transform.translate(
              offset: previousOffset,
              child: Transform.rotate(
                angle: previousRotation,
                child: SizedBox(
                  height: height,
                  child: _DiscoverCard(
                    manga: previous,
                    rank: index,
                    period: _period,
                    inert: true,
                    preview: preview,
                  ),
                ),
              ),
            ),

          /*
           * ONE-TIME DISCOVER HINT
           *
           * The unique ID is stored using
           * SharedPreferences by OneTimeHint.
           *
           * Once it has appeared once, it will
           * never appear again for this install.
           */
          const Positioned(
            bottom: 56,
            child: OneTimeHint(
              id: 'discover_swipe',
              icon: Icons.swipe_vertical_rounded,
              text: 'Swipe up for next · down for previous',
            ),
          ),
        ],
      ),
    );
  }

  void _handleDragStart(DragStartDetails details) {
    if (_animating) {
      return;
    }

    /*
     * No hint controller here anymore.
     *
     * OneTimeHint owns and persists
     * its own animation state.
     */
    setState(() {
      _dragging = true;

      _dragY = 0.0;

      _swipeAnimation = _SwipeAnimation.none;

      _animationProgress = 0.0;
    });
  }

  void _handleDragUpdate(DragUpdateDetails details, int index) {
    if (_animating || !_dragging) {
      return;
    }

    var nextDragY = _dragY + details.delta.dy;

    if (nextDragY > 0 && index == 0) {
      nextDragY = _edgeResistance(nextDragY);
    }

    setState(() {
      _dragY = nextDragY;
    });
  }

  Future<void> _handleDragEnd(
    DragEndDetails details,
    double width,
    double height,
    int length,
  ) async {
    if (_animating || !_dragging) {
      return;
    }

    final velocity = details.primaryVelocity ?? 0.0;

    final index = _positions[_period] ?? 0;

    final distanceThreshold = height * _swipeDistanceThreshold;

    final goNext =
        index < length - 1 &&
        (_dragY <= -distanceThreshold || velocity <= -_swipeVelocityThreshold);

    final goPrevious =
        index > 0 &&
        (_dragY >= distanceThreshold || velocity >= _swipeVelocityThreshold);

    if (goNext) {
      await _commitNext(
        index: index,
        width: width,
        height: height,
        velocity: velocity.abs(),
      );

      return;
    }

    if (goPrevious) {
      await _commitPrevious(
        index: index,
        width: width,
        height: height,
        velocity: velocity.abs(),
      );

      return;
    }

    await _cancelDrag(
      index: index,
      width: width,
      height: height,
      velocity: velocity.abs(),
    );
  }

  Future<void> _commitNext({
    required int index,
    required double width,
    required double height,
    required double velocity,
  }) async {
    final dragProgress = (-_dragY / (height * .42)).clamp(0.0, 1.0).toDouble();

    final startOffset = Offset(
      _dragPreviewHorizontal * dragProgress,
      -_dragPreviewVertical * dragProgress,
    );

    final startRotation = _dragPreviewRotation * dragProgress;

    final endOffset = Offset(
      width * _throwHorizontalFactor,
      -height * _throwVerticalFactor,
    );

    final duration = _momentumDuration(
      start: startOffset,
      end: endOffset,
      velocity: velocity,
      fallbackMs: 300,
      minMs: 90,
      maxMs: 420,
    );

    _prepareAnimation(
      type: _SwipeAnimation.throwNext,
      startOffset: startOffset,
      endOffset: endOffset,
      startRotation: startRotation,
      endRotation: _throwRotation,
      duration: duration,
    );

    await _swipeController.forward(from: 0.0);

    if (!mounted) {
      return;
    }

    setState(() {
      _positions[_period] = index + 1;

      _dragY = 0.0;

      _dragging = false;

      _animating = false;

      _swipeAnimation = _SwipeAnimation.none;

      _animationProgress = 0.0;
    });

    HapticFeedback.selectionClick();
  }

  Future<void> _commitPrevious({
    required int index,
    required double width,
    required double height,
    required double velocity,
  }) async {
    final throwOffset = Offset(
      width * _throwHorizontalFactor,
      -height * _throwVerticalFactor,
    );

    final dragProgress = (_dragY / (height * .42)).clamp(0.0, 1.0).toDouble();

    final reveal = Curves.easeOutCubic.transform(dragProgress);

    final startOffset =
        Offset.lerp(throwOffset, Offset.zero, reveal) ?? throwOffset;

    final startRotation = _lerpDouble(_throwRotation, 0.0, reveal);

    final duration = _momentumDuration(
      start: startOffset,
      end: Offset.zero,
      velocity: velocity,
      fallbackMs: 300,
      minMs: 90,
      maxMs: 420,
    );

    _prepareAnimation(
      type: _SwipeAnimation.restorePrevious,
      startOffset: startOffset,
      endOffset: Offset.zero,
      startRotation: startRotation,
      endRotation: 0.0,
      duration: duration,
    );

    await _swipeController.forward(from: 0.0);

    if (!mounted) {
      return;
    }

    setState(() {
      _positions[_period] = index - 1;

      _dragY = 0.0;

      _dragging = false;

      _animating = false;

      _swipeAnimation = _SwipeAnimation.none;

      _animationProgress = 0.0;
    });

    HapticFeedback.selectionClick();
  }

  Future<void> _cancelDrag({
    required int index,
    required double width,
    required double height,
    required double velocity,
  }) async {
    if (_dragY > 0 && index > 0) {
      final throwOffset = Offset(
        width * _throwHorizontalFactor,
        -height * _throwVerticalFactor,
      );

      final dragProgress = (_dragY / (height * .42)).clamp(0.0, 1.0).toDouble();

      final reveal = Curves.easeOutCubic.transform(dragProgress);

      final startOffset =
          Offset.lerp(throwOffset, Offset.zero, reveal) ?? throwOffset;

      final startRotation = _lerpDouble(_throwRotation, 0.0, reveal);

      _prepareAnimation(
        type: _SwipeAnimation.dismissPrevious,
        startOffset: startOffset,
        endOffset: throwOffset,
        startRotation: startRotation,
        endRotation: _throwRotation,
        duration: _momentumDuration(
          start: startOffset,
          end: throwOffset,
          velocity: velocity,
          fallbackMs: 300,
          minMs: 90,
          maxMs: 420,
        ),
      );

      await _swipeController.forward(from: 0.0);
    } else if (_dragY < 0) {
      final dragProgress = (-_dragY / (height * .42))
          .clamp(0.0, 1.0)
          .toDouble();

      final startOffset = Offset(
        _dragPreviewHorizontal * dragProgress,
        -_dragPreviewVertical * dragProgress,
      );

      final startRotation = _dragPreviewRotation * dragProgress;

      _prepareAnimation(
        type: _SwipeAnimation.snapCurrent,
        startOffset: startOffset,
        endOffset: Offset.zero,
        startRotation: startRotation,
        endRotation: 0.0,
        duration: const Duration(milliseconds: 220),
      );

      await _swipeController.forward(from: 0.0);
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _dragY = 0.0;

      _dragging = false;

      _animating = false;

      _swipeAnimation = _SwipeAnimation.none;

      _animationProgress = 0.0;
    });
  }

  void _prepareAnimation({
    required _SwipeAnimation type,
    required Offset startOffset,
    required Offset endOffset,
    required double startRotation,
    required double endRotation,
    required Duration duration,
  }) {
    _swipeController.stop();

    _swipeController.duration = duration;

    setState(() {
      _dragging = false;

      _animating = true;

      _swipeAnimation = type;

      _animationStartOffset = startOffset;

      _animationEndOffset = endOffset;

      _animationStartRotation = startRotation;

      _animationEndRotation = endRotation;

      _animationProgress = 0.0;
    });
  }

  Duration _momentumDuration({
    required Offset start,
    required Offset end,
    required double velocity,
    required int fallbackMs,
    required int minMs,
    required int maxMs,
  }) {
    final remainingDistance = (end - start).distance;

    if (velocity >= 80.0) {
      final milliseconds = ((remainingDistance / velocity) * 1000 * .72)
          .round();

      return Duration(milliseconds: milliseconds.clamp(minMs, maxMs).toInt());
    }

    return Duration(milliseconds: fallbackMs.clamp(minMs, maxMs).toInt());
  }

  double _edgeResistance(double value) {
    return 48.0 * (1.0 - 1.0 / (1.0 + value.abs() / 48.0));
  }

  double _lerpDouble(double a, double b, double t) {
    return a + (b - a) * t;
  }
}

enum _SwipeAnimation {
  none,
  throwNext,
  restorePrevious,
  dismissPrevious,
  snapCurrent,
}

/* ===========================================================
 * DISCOVER PERIOD TABS
 * ========================================================= */

class _DiscoverPeriodTabs extends StatelessWidget {
  const _DiscoverPeriodTabs({
    required this.selectedIndex,
    required this.onChanged,
  });

  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.raised.withValues(alpha: .36),
        borderRadius: BorderRadius.circular(15),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final indicatorWidth = constraints.maxWidth / 3.0;

          final indicatorLeft = selectedIndex * indicatorWidth;

          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                left: indicatorLeft,
                top: 0.0,
                bottom: 0.0,
                width: indicatorWidth,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: .16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),

              Row(
                children: [
                  Expanded(
                    child: _DiscoverTabButton(
                      label: 'Trending',
                      selected: selectedIndex == 0,
                      onTap: () => onChanged(0),
                    ),
                  ),

                  Expanded(
                    child: _DiscoverTabButton(
                      label: 'Top Rated',
                      selected: selectedIndex == 1,
                      onTap: () => onChanged(1),
                    ),
                  ),

                  Expanded(
                    child: _DiscoverTabButton(
                      label: 'Popular',
                      selected: selectedIndex == 2,
                      onTap: () => onChanged(2),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DiscoverTabButton extends StatelessWidget {
  const _DiscoverTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,

      behavior: HitTestBehavior.opaque,

      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 160),

        curve: Curves.easeOut,

        style: TextStyle(
          color: selected ? AppColors.text : AppColors.muted,

          fontSize: 13,

          fontWeight: FontWeight.w900,
        ),

        child: Center(child: Text(label, maxLines: 1)),
      ),
    );
  }
}

/* ===========================================================
 * DISCOVER CARD
 * ========================================================= */

class _DiscoverCard extends ConsumerWidget {
  const _DiscoverCard({
    required this.manga,
    required this.rank,
    required this.period,
    required this.preview,
    this.inert = false,
  });

  final Manga manga;

  final int rank;
  final int period;

  final bool inert;
  final bool preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final marked = ref.watch(userLibraryProvider).bookmarks.contains(manga.id);
    final cardAdultMode = ref.watch(adultModeProvider);
    unawaited(
      ref
          .read(catalogProvider)
          .prewarmChapters(manga, allowAdult: cardAdultMode),
    );

    final periodLabel = ['Trending', 'Top Rated', 'Popular'][period];

    final details = ref.watch(catalogProvider).cached(manga.id);

    final chapterLabel =
        ref.watch(chapterSummaryLabelProvider(manga)).valueOrNull ??
        (details ?? manga).chapterDisplayLabel;

    final rawSynopsis = (details?.synopsis.isNotEmpty ?? false)
        ? details!.synopsis
        : manga.synopsis;

    final synopsis = summarizeSynopsis(rawSynopsis);

    return IgnorePointer(
      ignoring: inert,

      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),

        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),

          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),

            child: Material(
              color: AppColors.surface,

              child: InkWell(
                onTap: () async {
                  await ref
                      .read(catalogProvider)
                      .prewarmChapters(manga, allowAdult: cardAdultMode);
                  if (!context.mounted) return;
                  context.push('/manga/${Uri.encodeComponent(manga.id)}');
                },

                child: Stack(
                  fit: StackFit.expand,

                  children: [
                    /*
                     * COVER
                     */
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
                                  _CoverFallback(title: manga.title),
                            ),
                    ),

                    /*
                     * RANK BADGE
                     */
                    Positioned(
                      top: 14,

                      left: 14,

                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),

                        decoration: BoxDecoration(
                          color: AppColors.glass,

                          borderRadius: BorderRadius.circular(999),

                          border: Border.all(color: AppColors.outline),
                        ),

                        child: Row(
                          mainAxisSize: MainAxisSize.min,

                          children: [
                            const Icon(
                              Icons.auto_awesome,

                              size: 14,

                              color: AppColors.accent,
                            ),

                            const SizedBox(width: 6),

                            Text(
                              preview ? 'Preview $rank' : '#$rank $periodLabel',

                              style: const TextStyle(
                                color: AppColors.text,

                                fontSize: 11,

                                fontWeight: FontWeight.w800,

                                letterSpacing: .4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    /*
                     * DARK GRADIENT
                     */
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,

                            end: Alignment.bottomCenter,

                            colors: [
                              Colors.transparent,

                              Colors.black.withValues(alpha: .62),

                              Colors.black.withValues(alpha: .88),

                              Colors.black.withValues(alpha: .96),
                            ],

                            stops: const [0, .42, .72, 1],
                          ),
                        ),
                      ),
                    ),

                    /*
                     * CARD CONTENT
                     */
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.bottomLeft,

                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),

                          child: Column(
                            mainAxisSize: MainAxisSize.min,

                            crossAxisAlignment: CrossAxisAlignment.start,

                            children: [
                              Text(
                                manga.title,

                                maxLines: 2,

                                overflow: TextOverflow.ellipsis,

                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontSize: 22, height: 1.18),
                              ),

                              const SizedBox(height: 10),

                              /*
                               * INFO CHIPS
                               */
                              Row(
                                children: [
                                  Expanded(
                                    child: _InfoChip(
                                      icon: Icons.star_rounded,
                                      label: manga.ratingLabel,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: _InfoChip(
                                      icon: Icons.bolt_rounded,
                                      label: manga.statusLabel,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: _InfoChip(
                                      icon: Icons.library_books_rounded,
                                      label: '$chapterLabel chp',
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: _InfoChip(
                                      icon: Icons.category_rounded,
                                      label: manga.genres.isEmpty
                                          ? '—'
                                          : manga.genres.first,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),

                              /*
                               * SYNOPSIS
                               */
                              Text(
                                synopsis,

                                softWrap: true,

                                textAlign: TextAlign.justify,

                                maxLines: 4,

                                overflow: TextOverflow.ellipsis,

                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: .94,
                                      ),

                                      height: 1.45,

                                      letterSpacing: .02,
                                    ),
                              ),

                              const SizedBox(height: 20),

                              /*
                               * BOOKMARK BUTTON
                               */
                              _BookmarkButton(
                                bookmarked: marked,

                                onPressed: () {
                                  ref
                                      .read(userLibraryProvider.notifier)
                                      .toggleBookmark(manga);
                                },
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

/* ===========================================================
 * COVER FALLBACK
 * ========================================================= */

class _CoverFallback extends StatelessWidget {
  const _CoverFallback({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,

          end: Alignment.bottomRight,

          colors: [Color(0xFF39325F), Color(0xFF1A1923)],
        ),
      ),

      padding: const EdgeInsets.all(14),

      alignment: Alignment.bottomLeft,

      child: Text(
        title,

        maxLines: 3,

        overflow: TextOverflow.ellipsis,

        style: const TextStyle(
          color: AppColors.text,

          fontWeight: FontWeight.w700,

          fontSize: 16,
        ),
      ),
    );
  }
}

/* ===========================================================
 * INFO CHIP
 * ========================================================= */

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,

      padding: const EdgeInsets.symmetric(horizontal: 8),

      decoration: BoxDecoration(
        color: AppColors.raised.withValues(alpha: .86),

        borderRadius: BorderRadius.circular(999),

        border: Border.all(color: AppColors.outline),
      ),

      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,

        children: [
          Icon(icon, size: 14, color: AppColors.accent),

          const SizedBox(width: 5),

          Flexible(
            child: Text(
              label,

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

/* ===========================================================
 * BOOKMARK BUTTON
 * ========================================================= */

class _BookmarkButton extends StatelessWidget {
  const _BookmarkButton({required this.bookmarked, required this.onPressed});

  final bool bookmarked;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
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

              foregroundColor: bookmarked ? AppColors.accent : AppColors.text,

              side: bookmarked
                  ? BorderSide(
                      color: AppColors.accent.withValues(alpha: .65),

                      width: 1.2,
                    )
                  : const BorderSide(color: AppColors.outline, width: 1),

              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),

            icon: Icon(
              bookmarked
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,

              size: 22,
            ),

            padding: EdgeInsets.zero,
          ),
        ),
      ),
    );
  }
}
