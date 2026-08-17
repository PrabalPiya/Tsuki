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

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.mangaId, this.initialChapterId});

  final String mangaId;
  final String? initialChapterId;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

enum _BlockType { header, page, loading, error, end }

class _ReaderScreenState extends ConsumerState<ReaderScreen>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final _loaded = <int, ChapterPages>{};
  final _loading = <int>{};
  final _errors = <int, String>{};
  final _pageRatios = <String, double>{};
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
      final saved =
          ref.read(userLibraryProvider).bookmarkedManga[widget.mangaId];
      if (saved != null) repository.remember(saved);
      final manga = repository.cached(widget.mangaId) ??
          await repository.details(widget.mangaId);
      if (manga == null) {
        _setFatal('Manga unavailable right now.');
        return;
      }
      repository.remember(manga);
      final chapters = await repository.chapters(manga);
      if (chapters.isEmpty) {
        _setFatal('No readable English chapters were found.');
        return;
      }
      if (!mounted) return;
      _chapters = chapters;
      _start = chapters.indexWhere((c) => c.id == widget.initialChapterId);
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
      unawaited(_cacheChapter(pages.urls));
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
      MediaQuery.sizeOf(context).width / (_pageRatios[url] ?? .68);

  Future<void> _cacheChapter(List<String> urls) async {
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < urls.length) {
        final url = urls[cursor++];
        if (!url.startsWith('https://')) continue;
        try {
          await MangaImageCache.instance.downloadFile(url);
        } catch (_) {
          // Individual page errors remain retryable in the image widget.
        }
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));
  }

  void _onScroll() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _saveProgress);
    if (!_scroll.hasClients || _loaded.isEmpty) return;
    final current = _locate(_scroll.offset);
    if (current.ratio > .72) unawaited(_load(current.index + 1));
  }

  ({int index, int page, double relative, double ratio}) _locate(
      double offset) {
    var remaining = offset;
    final indexes = _loaded.keys.toList()..sort();
    for (final index in indexes) {
      final urls = _loaded[index]!.urls;
      final count = urls.length;
      final pagesHeight =
          urls.fold<double>(0, (sum, url) => sum + _pageHeight(url));
      final height = 72 + pagesHeight;
      if (remaining < height) {
        final within = (remaining - 72).clamp(0.0, pagesHeight);
        var page = 0;
        var pageStart = 0.0;
        while (
            page < count - 1 && pageStart + _pageHeight(urls[page]) <= within) {
          pageStart += _pageHeight(urls[page]);
          page++;
        }
        final pageHeight = _pageHeight(urls[page]);
        return (
          index: index,
          page: page,
          relative: ((within - pageStart) / pageHeight).clamp(0.0, 1.0),
          ratio: (within / pagesHeight).clamp(0.0, 1.0)
        );
      }
      remaining -= height;
    }
    final last = indexes.last;
    return (
      index: last,
      page: _loaded[last]!.urls.length - 1,
      relative: 1,
      ratio: 1
    );
  }

  Future<void> _saveProgress() async {
    if (!mounted || !_scroll.hasClients || _loaded.isEmpty) return;
    final value = _locate(_scroll.offset);
    await ref.read(userLibraryProvider.notifier).saveProgress(ReadingProgress(
        mangaId: widget.mangaId,
        chapterId: _chapters[value.index].id,
        pageIndex: value.page,
        relativeOffset: value.relative,
        chapterProgress: value.ratio,
        updatedAt: DateTime.now()));
  }

  Future<void> _markChapterOpened(int index) async {
    final existing = ref.read(userLibraryProvider).progress[widget.mangaId];
    final sameChapter = existing?.chapterId == _chapters[index].id;
    await ref.read(userLibraryProvider.notifier).saveProgress(ReadingProgress(
        mangaId: widget.mangaId,
        chapterId: _chapters[index].id,
        pageIndex: sameChapter ? existing!.pageIndex : 0,
        relativeOffset: sameChapter ? existing!.relativeOffset : 0,
        chapterProgress: sameChapter ? existing!.chapterProgress : 0,
        openedChapterIds: {...?existing?.openedChapterIds, _chapters[index].id},
        updatedAt: DateTime.now()));
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
    _start = index;
    _loaded.clear();
    _loading.clear();
    _errors.clear();
    _pageRatios.clear();
    _restored = false;
    if (mounted) setState(() {});
    await _load(_start, restore: true);
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_saveProgress());
  }

  @override
  void dispose() {
    unawaited(_saveProgress());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _hideTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final manga = ref.watch(catalogProvider).cached(widget.mangaId);
    final library = ref.watch(userLibraryProvider);
    final progress = library.progress[widget.mangaId];
    final blocks = <({int chapter, _BlockType type, String? url, int page, bool read})>[];
    if (_chapters.isNotEmpty) {
      final indexes = <int>{
        _start,
        ..._loaded.keys,
        ..._loading,
        ..._errors.keys
      }.toList()
        ..sort();
      for (final index in indexes) {
        final isRead = progress != null && progress.openedChapterIds.contains(_chapters[index].id);
        blocks.add((chapter: index, type: _BlockType.header, url: null, page: 0, read: isRead));
        final pages = _loaded[index];
        if (pages != null) {
          for (var page = 0; page < pages.urls.length; page++) {
            blocks.add((
              chapter: index,
              type: _BlockType.page,
              url: pages.urls[page],
              page: page + 1,
              read: isRead
            ));
          }
          if (index == _chapters.length - 1) {
            blocks.add(
                (chapter: index, type: _BlockType.end, url: null, page: 0, read: isRead));
          }
        } else if (_errors.containsKey(index)) {
          blocks.add(
              (chapter: index, type: _BlockType.error, url: null, page: 0, read: isRead));
        } else {
          blocks.add(
              (chapter: index, type: _BlockType.loading, url: null, page: 0, read: isRead));
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
                child: Stack(children: [
                  if (_fatalError != null)
                    _ReaderFailure(message: _fatalError!, retry: _retryInitial)
                  else if (blocks.isEmpty)
                    const Center(child: CircularProgressIndicator())
                  else
                    ListView.builder(
                        controller: _scroll,
                        itemCount: blocks.length,
                        itemBuilder: (context, position) {
                          final block = blocks[position];
                          final chapter = _chapters[block.chapter];
                          return switch (block.type) {
                            _BlockType.header =>
                              Opacity(
                                  opacity: block.read ? 1 : 1,
                                  child: _ChapterHeader(chapter: chapter)),
                            _BlockType.page => Opacity(
                                opacity: block.read ? 1 : 1,
                                child: _ReaderPage(
                                    url: block.url!,
                                    page: block.page,
                                    onAspectRatio: (ratio) =>
                                        _pageRatios[block.url!] = ratio)),
                            _BlockType.loading => const SizedBox(
                                height: 96,
                                child:
                                    Center(child: CircularProgressIndicator())),
                            _BlockType.error => _ChapterError(
                                message: _errors[block.chapter]!,
                                retry: () => _load(block.chapter)),
                            _BlockType.end => SizedBox(
                                height: 120,
                                child: Container(
                                    color: AppColors.background,
                                    child: Center(
                                        child: block.chapter < _chapters.length - 1
                                            ? FilledButton(
                                                onPressed: () => _goToChapter(
                                                    block.chapter + 1),
                                                child: const Text('Next Chapter'))
                                            : const Text("You're all caught up",
                                                style: TextStyle(
                                                    color: AppColors.muted))))),
                          };
                        }),
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
                                      child: Row(children: [
                                        IconButton(
                                            onPressed: () =>
                                                Navigator.of(context).pop(),
                                            icon: const Icon(Icons.arrow_back,
                                                color: AppColors.text)),
                                        Expanded(
                                            child: Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                                child: Text(
                                                    manga?.title ?? 'Reader',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        color: AppColors.text,
                                                        fontWeight: FontWeight.w600,
                                                        fontSize: 16)))),
                                      ]))))))
                ]))));
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
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Chapter ${chapter.numberLabel}',
              style: const TextStyle(
                  color: AppColors.text, fontWeight: FontWeight.w700)),
          if (credit != null)
            Text(credit,
                style: const TextStyle(color: AppColors.muted, fontSize: 11))
        ])));
  }
}

class _ReaderFailure extends StatelessWidget {
  const _ReaderFailure({required this.message, required this.retry});
  final String message;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.text)),
        const SizedBox(height: 16),
        FilledButton(onPressed: retry, child: const Text('Try again'))
      ]));
}

class _ChapterError extends StatelessWidget {
  const _ChapterError({required this.message, required this.retry});
  final String message;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => SizedBox(
      height: 112,
      child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(message, style: const TextStyle(color: AppColors.muted)),
        TextButton(onPressed: retry, child: const Text('Retry chapter'))
      ])));
}

class _ReaderPage extends StatefulWidget {
  const _ReaderPage(
      {required this.url, required this.page, required this.onAspectRatio});
  final String url;
  final int page;
  final ValueChanged<double> onAspectRatio;

  @override
  State<_ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<_ReaderPage> {
  double _aspectRatio = .68;
  bool _resolving = false;

  void _resolveAspect(ImageProvider provider) {
    if (_resolving) return;
    _resolving = true;
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      final ratio = info.image.width / info.image.height;
      if (mounted && ratio.isFinite && ratio > 0) {
        widget.onAspectRatio(ratio);
        setState(() => _aspectRatio = ratio);
      }
    }, onError: (_, __) {
      stream.removeListener(listener);
    });
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final height = width / _aspectRatio;
    if (widget.url.startsWith('demo://')) {
      return SizedBox(
          height: height,
          child: ColoredBox(
              color:
                  widget.page.isEven ? const Color(0xFFF4F4F4) : Colors.white,
              child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.auto_stories_outlined,
                    size: 54, color: AppColors.muted),
                const SizedBox(height: 14),
                Text('Synthetic preview page ${widget.page}',
                    style: const TextStyle(color: AppColors.muted))
              ]))));
    }
    final decodeWidth =
        (width * MediaQuery.devicePixelRatioOf(context)).round();
    return SizedBox(
        height: height,
        width: double.infinity,
        child: CachedNetworkImage(
            imageUrl: widget.url,
            cacheManager: MangaImageCache.instance,
            memCacheWidth: decodeWidth,
            imageBuilder: (_, provider) {
              _resolveAspect(provider);
              return _ZoomablePage(imageProvider: provider);
            },
            fadeInDuration: const Duration(milliseconds: 120),
            placeholder: (_, __) =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            errorWidget: (_, __, ___) => const Center(
                child: Text('Page unavailable',
                    style: TextStyle(color: AppColors.muted)))));
  }
}

class _ZoomablePage extends StatefulWidget {
  const _ZoomablePage({required this.imageProvider});
  final ImageProvider imageProvider;

  @override
  State<_ZoomablePage> createState() => _ZoomablePageState();
}

class _ZoomablePageState extends State<_ZoomablePage> {
  final _transform = TransformationController();
  bool _zoomed = false;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
      color: AppColors.background,
      child: InteractiveViewer(
          transformationController: _transform,
          minScale: 0.5,
          maxScale: 5,
          panEnabled: true,
          clipBehavior: Clip.hardEdge,
          onInteractionUpdate: (_) {
            final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
            if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
          },
          child: SizedBox.expand(
              child: Image(image: widget.imageProvider, fit: BoxFit.fitWidth))));
}
