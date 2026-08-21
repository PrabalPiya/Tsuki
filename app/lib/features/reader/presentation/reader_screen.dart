import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../core/models/chapter.dart';
import '../../../core/models/reading_progress.dart';
import '../../../core/state/providers.dart';
import '../../../core/storage/image_cache.dart';
import '../../../core/theme/app_theme.dart';

const double _fallbackPageAspectRatio = .68;
const double _minimumReaderScale = 1.0;
const double _maximumReaderScale = 6.0;
const double _landscapePageAspectRatio = 1.05;
const double _landscapePageHeightFraction = .62;

double _readerPageDisplayHeight({
  required double width,
  required double viewportHeight,
  required double aspectRatio,
}) {
  final naturalHeight = width / aspectRatio;
  if (aspectRatio <= _landscapePageAspectRatio) return naturalHeight;

  return (viewportHeight * _landscapePageHeightFraction)
      .clamp(naturalHeight, width)
      .toDouble();
}

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.mangaId, this.initialChapterId});

  final String mangaId;
  final String? initialChapterId;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

enum _BlockType { header, page, loading, error, navigation }

class _ReaderScreenState extends ConsumerState<ReaderScreen>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final _loaded = <int, ChapterPages>{};
  final _loading = <int>{};
  final _errors = <int, String>{};
  final _failedPageSources = <int, Set<String>>{};
  final _pageRatios = <String, double>{};
  final _zoomTransform = TransformationController();

  List<CanonicalChapter> _chapters = const [];
  int _start = 0;
  bool _controls = false;
  bool _restored = false;
  Timer? _saveTimer;
  Timer? _hideTimer;
  String? _fatalError;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    try {
      final repository = ref.read(catalogProvider);
      final saved = ref
          .read(userLibraryProvider)
          .bookmarkedManga[widget.mangaId];

      if (saved != null && saved.isFriendlyContent) {
        repository.remember(saved);
      }

      final manga =
          repository.cached(widget.mangaId) ??
          await repository.details(widget.mangaId);

      if (manga == null) {
        _setFatal('Manga unavailable right now.');
        return;
      }

      if (!manga.isFriendlyContent) {
        _setFatal("This title isn't available in Tsuki.");
        return;
      }

      repository.remember(manga);

      final chapters = await repository.chapters(manga, allowAdult: false);
      final readable = chapters
          .where((chapter) => chapter.hasDirectlyReadableCopy)
          .toList(growable: false);

      if (readable.isEmpty) {
        _setFatal('No readable English chapters were found.');
        return;
      }

      if (!mounted) return;

      _chapters = readable;
      _start = readable.indexWhere((c) => c.id == widget.initialChapterId);
      if (_start < 0) _start = 0;
      setState(() {});
      await _load(_start, restore: true);
    } catch (_) {
      _setFatal('The reader could not be opened. Check your connection.');
    }
  }

  void _setFatal(String message) {
    if (mounted) setState(() => _fatalError = message);
  }

  Future<void> _retryInitial() async {
    setState(() => _fatalError = null);
    _chapters = const [];
    _loaded.clear();
    _loading.clear();
    _errors.clear();
    _failedPageSources.clear();
    await _initialize();
  }

  Future<void> _load(int index, {bool restore = false}) async {
    if (index < 0 ||
        index >= _chapters.length ||
        _loaded.containsKey(index) ||
        !_loading.add(index)) {
      return;
    }

    _errors.remove(index);
    if (mounted) setState(() {});

    try {
      final pages = await ref.read(catalogProvider).pages(_chapters[index]);
      if (pages.urls.isEmpty) {
        throw StateError('Chapter has no readable pages.');
      }
      if (!mounted) return;

      setState(() => _loaded[index] = pages);

      if (restore) {
        _restoreSavedPosition(index);
        await _markChapterOpened(index);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _errors[index] = 'Chapter unavailable. Try again.');
      }
    } finally {
      _loading.remove(index);
      if (mounted) setState(() {});
    }
  }

  void _restoreSavedPosition(int index) {
    if (_restored) return;
    final saved = ref.read(userLibraryProvider).progress[widget.mangaId];
    if (saved == null || saved.chapterId != _chapters[index].id) return;

    _restored = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;

      final urls = _loaded[index]!.urls;
      if (urls.isEmpty) return;

      final page = saved.pageIndex.clamp(0, urls.length - 1);
      var offset = 72.0;
      for (var i = 0; i < page; i++) {
        offset += _pageHeight(urls[i]);
      }
      offset += _pageHeight(urls[page]) * saved.relativeOffset;

      _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
    });
  }

  double _pageHeight(String url) =>
      _readerPageDisplayHeight(
        width: MediaQuery.sizeOf(context).width,
        viewportHeight: MediaQuery.sizeOf(context).height,
        aspectRatio: _pageRatios[url] ?? _fallbackPageAspectRatio,
      );

  void _onScroll() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _saveProgress);
  }

  ({int index, int page, double relative, double ratio}) _locate(
    double offset,
  ) {
    var remaining = offset;
    final indexes = _loaded.keys.toList()..sort();

    for (final index in indexes) {
      final urls = _loaded[index]!.urls;
      final count = urls.length;
      final pagesHeight = urls.fold<double>(
        0,
        (sum, url) => sum + _pageHeight(url),
      );
      final height = 72 + pagesHeight;

      if (remaining < height) {
        final within = (remaining - 72).clamp(0.0, pagesHeight);
        var page = 0;
        var pageStart = 0.0;

        while (page < count - 1 &&
            pageStart + _pageHeight(urls[page]) <= within) {
          pageStart += _pageHeight(urls[page]);
          page++;
        }

        final pageHeight = _pageHeight(urls[page]);
        return (
          index: index,
          page: page,
          relative: ((within - pageStart) / pageHeight).clamp(0.0, 1.0),
          ratio: pagesHeight <= 0
              ? 0
              : (within / pagesHeight).clamp(0.0, 1.0),
        );
      }

      remaining -= height;
    }

    final last = indexes.last;
    return (
      index: last,
      page: _loaded[last]!.urls.length - 1,
      relative: 1,
      ratio: 1,
    );
  }

  Future<void> _saveProgress() async {
    if (!mounted || !_scroll.hasClients || _loaded.isEmpty) return;

    final value = _locate(_scroll.offset);

    await ref
        .read(userLibraryProvider.notifier)
        .saveProgress(
          ReadingProgress(
            mangaId: widget.mangaId,
            chapterId: _chapters[value.index].id,
            pageIndex: value.page,
            relativeOffset: value.relative,
            chapterProgress: value.ratio,
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<void> _markChapterOpened(int index) async {
    final existing = ref.read(userLibraryProvider).progress[widget.mangaId];
    final sameChapter = existing?.chapterId == _chapters[index].id;

    await ref
        .read(userLibraryProvider.notifier)
        .saveProgress(
          ReadingProgress(
            mangaId: widget.mangaId,
            chapterId: _chapters[index].id,
            pageIndex: sameChapter ? existing!.pageIndex : 0,
            relativeOffset: sameChapter ? existing!.relativeOffset : 0,
            chapterProgress: sameChapter ? existing!.chapterProgress : 0,
            openedChapterIds: {
              ...?existing?.openedChapterIds,
              _chapters[index].id,
            },
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<void> _retryChapterWithNextSource(
    int index,
    String failedSourceId,
  ) async {
    if (index < 0 || index >= _chapters.length) return;

    final failed = _failedPageSources.putIfAbsent(index, () => <String>{});
    if (!failed.add(failedSourceId)) return;

    try {
      final replacement = await ref
          .read(catalogProvider)
          .pages(_chapters[index], skipSourceIds: failed);

      if (!mounted || replacement.urls.isEmpty) return;

      setState(() {
        _loaded[index] = replacement;
        _errors.remove(index);
      });
    } catch (_) {
      // Keep the current page error visible if every safe source copy failed.
    }
  }

  void _toggleControls() {
    setState(() => _controls = !_controls);
    _hideTimer?.cancel();

    if (_controls) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _controls = false);
      });
    }
  }

  Future<void> _goToChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;

    await _saveProgress();
    _start = index;
    _loaded.clear();
    _loading.clear();
    _errors.clear();
    _failedPageSources.clear();
    _pageRatios.clear();
    _restored = false;
    _zoomTransform.value = Matrix4.identity();

    if (mounted) setState(() {});
    if (_scroll.hasClients) _scroll.jumpTo(0);

    await _load(_start, restore: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_saveProgress());
    }
  }

  @override
  void dispose() {
    unawaited(_saveProgress());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _hideTimer?.cancel();
    _scroll.dispose();
    _zoomTransform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final manga = ref.watch(catalogProvider).cached(widget.mangaId);
    final library = ref.watch(userLibraryProvider);
    final progress = library.progress[widget.mangaId];
    final currentChapter = _start >= 0 && _start < _chapters.length
        ? _chapters[_start]
        : null;

    final blocks =
        <({int chapter, _BlockType type, String? url, int page, bool read})>[];

    if (_chapters.isNotEmpty) {
      final indexes = <int>[_start]
          .where((index) => index >= 0 && index < _chapters.length)
          .toList(growable: false);

      for (final index in indexes) {
        final isRead =
            progress != null &&
            progress.openedChapterIds.contains(_chapters[index].id);

        blocks.add((
          chapter: index,
          type: _BlockType.header,
          url: null,
          page: 0,
          read: isRead,
        ));

        final pages = _loaded[index];
        if (pages != null) {
          for (var page = 0; page < pages.urls.length; page++) {
            blocks.add((
              chapter: index,
              type: _BlockType.page,
              url: pages.urls[page],
              page: page + 1,
              read: isRead,
            ));
          }

          blocks.add((
            chapter: index,
            type: _BlockType.navigation,
            url: null,
            page: 0,
            read: isRead,
          ));
        } else if (_errors.containsKey(index)) {
          blocks.add((
            chapter: index,
            type: _BlockType.error,
            url: null,
            page: 0,
            read: isRead,
          ));
        } else {
          blocks.add((
            chapter: index,
            type: _BlockType.loading,
            url: null,
            page: 0,
            read: isRead,
          ));
        }
      }
    }

    return PopScope(
      onPopInvokedWithResult: (_, __) => unawaited(_saveProgress()),
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _toggleControls,
          child: Stack(
            children: [
              if (_fatalError != null)
                _ReaderFailure(message: _fatalError!, retry: _retryInitial)
              else if (blocks.isEmpty)
                const Center(child: CircularProgressIndicator())
              else
                InteractiveViewer(
                  transformationController: _zoomTransform,
                  minScale: _minimumReaderScale,
                  maxScale: _maximumReaderScale,
                  boundaryMargin: EdgeInsets.zero,
                  panEnabled: true,
                  scaleEnabled: true,
                  clipBehavior: Clip.hardEdge,
                  child: ListView.builder(
                    controller: _scroll,
                    itemCount: blocks.length,
                    itemBuilder: (context, position) {
                      final block = blocks[position];
                      final chapter = _chapters[block.chapter];

                      return switch (block.type) {
                        _BlockType.header => _ChapterHeader(chapter: chapter),
                        _BlockType.page => _ReaderPage(
                          url: block.url!,
                          sourceId: _loaded[block.chapter]!.sourceId,
                          page: block.page,
                          onAspectRatio: (ratio) =>
                              _pageRatios[block.url!] = ratio,
                          onLoadError: () => _retryChapterWithNextSource(
                            block.chapter,
                            _loaded[block.chapter]!.sourceId,
                          ),
                        ),
                        _BlockType.loading => const SizedBox(
                          height: 96,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                        _BlockType.error => _ChapterError(
                          message: _errors[block.chapter]!,
                          retry: () => _load(block.chapter),
                        ),
                        _BlockType.navigation => _ChapterNavigation(
                          onPrevious: block.chapter > 0
                              ? () => unawaited(_goToChapter(block.chapter - 1))
                              : null,
                          onNext: block.chapter + 1 < _chapters.length
                              ? () => unawaited(_goToChapter(block.chapter + 1))
                              : null,
                        ),
                      };
                    },
                  ),
                ),
              IgnorePointer(
                ignoring: !_controls,
                child: AnimatedOpacity(
                  opacity: _controls ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: SafeArea(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        height: 58,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        color: AppColors.glass,
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(
                                Icons.arrow_back,
                                color: AppColors.text,
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      manga?.title ?? 'Reader',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppColors.text,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 15,
                                      ),
                                    ),
                                    if (currentChapter != null)
                                      Text(
                                        'Chapter ${currentChapter.numberLabel}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppColors.muted,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 11,
                                        ),
                                      ),
                                  ],
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
            ],
          ),
        ),
      ),
    );
  }
}

class _ChapterHeader extends StatelessWidget {
  const _ChapterHeader({required this.chapter});

  final CanonicalChapter chapter;

  @override
  Widget build(BuildContext context) {
    final credit = chapter.sourceCopies.firstOrNull?.attribution;

    return SizedBox(
      height: 72,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Chapter ${chapter.numberLabel}',
              style: const TextStyle(
                color: AppColors.text,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (credit != null)
              Text(
                credit,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 11,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReaderFailure extends StatelessWidget {
  const _ReaderFailure({required this.message, required this.retry});

  final String message;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.text),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: retry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

class _ChapterError extends StatelessWidget {
  const _ChapterError({required this.message, required this.retry});

  final String message;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 112,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: const TextStyle(color: AppColors.muted)),
          TextButton(onPressed: retry, child: const Text('Retry chapter')),
        ],
      ),
    ),
  );
}

class _ChapterNavigation extends StatelessWidget {
  const _ChapterNavigation({
    required this.onPrevious,
    required this.onNext,
  });

  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onPrevious,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Previous'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onNext,
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Next'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _ReaderPage extends StatefulWidget {
  const _ReaderPage({
    required this.url,
    required this.sourceId,
    required this.page,
    required this.onAspectRatio,
    required this.onLoadError,
  });

  final String url;
  final String sourceId;
  final int page;
  final ValueChanged<double> onAspectRatio;
  final VoidCallback onLoadError;

  @override
  State<_ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<_ReaderPage> {
  double _aspectRatio = _fallbackPageAspectRatio;
  bool _hasResolvedAspect = false;
  bool _resolving = false;
  bool _reportedLoadError = false;

  @override
  void didUpdateWidget(covariant _ReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.url != widget.url || oldWidget.sourceId != widget.sourceId) {
      _aspectRatio = _fallbackPageAspectRatio;
      _hasResolvedAspect = false;
      _resolving = false;
      _reportedLoadError = false;
    }
  }

  void _resolveAspect(ImageProvider provider) {
    if (_resolving) return;
    _resolving = true;

    final stream = provider.resolve(createLocalImageConfiguration(context));
    late ImageStreamListener listener;

    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        final raw = info.image.width / info.image.height;

        if (!mounted || !raw.isFinite || raw <= 0) return;

        final ratio = raw.toDouble();
        widget.onAspectRatio(ratio);

        if (!_hasResolvedAspect || (_aspectRatio - ratio).abs() > .001) {
          setState(() {
            _aspectRatio = ratio;
            _hasResolvedAspect = true;
          });
        }
      },
      onError: (_, __) {
        stream.removeListener(listener);
        _resolving = false;
      },
    );

    stream.addListener(listener);
  }

  void _reportLoadError() {
    if (_reportedLoadError) return;
    _reportedLoadError = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onLoadError();
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final viewportHeight = MediaQuery.sizeOf(context).height;
        final height = _readerPageDisplayHeight(
          width: viewportWidth,
          viewportHeight: viewportHeight,
          aspectRatio: _aspectRatio,
        );

        if (widget.url.startsWith('demo://')) {
          return SizedBox(
            width: viewportWidth,
            height: height,
            child: ColoredBox(
              color: widget.page.isEven
                  ? const Color(0xFFF4F4F4)
                  : Colors.white,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.auto_stories_outlined,
                      size: 54,
                      color: AppColors.muted,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Synthetic preview page ${widget.page}',
                      style: const TextStyle(color: AppColors.muted),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final decodeWidth =
            (viewportWidth * MediaQuery.devicePixelRatioOf(context)).ceil();

        return AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: viewportWidth,
            height: height,
            child: CachedNetworkImage(
              imageUrl: widget.url,
              httpHeaders: _sourceImageHeaders(widget.sourceId),
              cacheManager: MangaImageCache.instance,
              memCacheWidth: decodeWidth,
              imageBuilder: (_, provider) {
                _resolveAspect(provider);
                if (!_hasResolvedAspect) {
                  return const ColoredBox(
                    color: AppColors.background,
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }

                return ColoredBox(
                  color: AppColors.background,
                  child: Image(
                    image: provider,
                    width: viewportWidth,
                    height: height,
                    fit: BoxFit.contain,
                    alignment: Alignment.center,
                    filterQuality: FilterQuality.high,
                    gaplessPlayback: true,
                  ),
                );
              },
              fadeInDuration: const Duration(milliseconds: 100),
              placeholder: (_, __) => const ColoredBox(
                color: AppColors.background,
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              errorWidget: (_, __, ___) {
                _reportLoadError();
                return const ColoredBox(
                  color: AppColors.background,
                  child: Center(
                    child: Text(
                      'Trying another source...',
                      style: TextStyle(color: AppColors.muted),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

Map<String, String>? _sourceImageHeaders(String sourceId) {
  final referer = switch (sourceId) {
    'weebcentral' => 'https://weebcentral.com/',
    'asura' => 'https://asurascans.com/',
    'mangapill' => 'https://mangapill.com/',
    'comick' => 'https://comick.live/',
    'mangadex' => 'https://mangadex.org/',
    _ => null,
  };

  if (referer == null) return null;

  return <String, String>{
    'Referer': referer,
    'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
  };
}
